# The stateful tier: RDS PostgreSQL (pgvector), ElastiCache Redis, and the EFS volume
# that holds the shared Hugging Face weight cache.
#
# Division of responsibility, from architecture §2:
#   * Postgres  -- assistants, threads, runs, checkpoints, the 640-dim vector store, and
#                  the api_metrics table that backs metering AND the rolling-window rate
#                  limiter. Everything durable. Multi-AZ is not optional here.
#   * Redis     -- Agent Server pubsub, cancellation, and streaming signalling only. No
#                  user or run data. Sized small on purpose; LangChain's own reference
#                  configuration keeps it at 2 GiB even at 500 req/s.
#   * EFS       -- Hugging Face model weights, so a cold pod does not re-download the
#                  embedding and GoEmotions models at lifespan startup. Retired by
#                  upstream change #5.

# --------------------------------------------------------------------------------------
# Security groups
# --------------------------------------------------------------------------------------

resource "aws_security_group" "postgres" {
  name        = "${var.name_prefix}-postgres"
  description = "PostgreSQL, reachable only from EKS nodes"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.node_security_group_id]
  }

  dynamic "ingress" {
    for_each = var.admin_access_cidrs
    content {
      description = "PostgreSQL admin access"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-postgres" })
}

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis"
  description = "Redis, reachable only from EKS nodes"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.node_security_group_id]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis" })
}

resource "aws_security_group" "efs" {
  name        = "${var.name_prefix}-efs"
  description = "NFS, reachable only from EKS nodes"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from EKS nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [var.node_security_group_id]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-efs" })
}

# --------------------------------------------------------------------------------------
# RDS PostgreSQL
# --------------------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-postgres"
  subnet_ids = var.private_subnet_ids
  tags       = merge(var.tags, { Name = "${var.name_prefix}-postgres" })
}

resource "aws_db_parameter_group" "main" {
  name   = "${var.name_prefix}-postgres16"
  family = "postgres16"

  # TLS on every connection. The Agent Server and the app both honour sslmode in the
  # connection URI; forcing it server-side means a misconfigured client fails loudly
  # instead of silently sending credentials in the clear.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Log slow statements. The graph's identity-document load runs every turn
  # (load_consciousness), so a query regression there shows up here first.
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  tags = var.tags
}

resource "random_password" "postgres" {
  length  = 40
  special = true
  # RDS rejects these in a master password.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_instance" "main" {
  identifier     = "${var.name_prefix}-postgres"
  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.master_username
  password = random_password.postgres.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.postgres.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false

  multi_az = var.multi_az

  backup_retention_period = var.backup_retention_days
  backup_window           = "07:00-08:00" # UTC, off-peak for US traffic
  maintenance_window      = "sun:08:30-sun:09:30"
  copy_tags_to_snapshot   = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  apply_immediately          = false

  # The store is every avatar's identity. Deleting it should require deliberate,
  # explicit intent -- not a stray `terraform destroy`.
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-postgres-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  tags = merge(var.tags, { Name = "${var.name_prefix}-postgres" })

  lifecycle {
    # The timestamp() above changes on every plan; it only matters at destroy time.
    ignore_changes = [final_snapshot_identifier]
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.name_prefix}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# --------------------------------------------------------------------------------------
# ElastiCache Redis
# --------------------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.name_prefix}-redis"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "random_password" "redis_auth" {
  length  = 64
  special = false # ElastiCache AUTH tokens are restricted to alphanumerics and a few symbols
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.name_prefix}-redis"
  description          = "Agent Server pubsub, cancellation, and run streaming"

  engine         = "redis"
  engine_version = var.redis_version
  node_type      = var.redis_node_type
  port           = 6379

  # A primary plus one replica with automatic failover. Redis holds no durable data, so
  # this is about avoiding a streaming outage, not about data loss.
  num_cache_clusters         = var.redis_node_count
  automatic_failover_enabled = var.redis_node_count > 1
  multi_az_enabled           = var.redis_node_count > 1

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  # Snapshots are pointless for ephemeral pubsub data and cost money.
  snapshot_retention_limit = 0
  maintenance_window       = "sun:09:30-sun:10:30"

  apply_immediately = false

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis" })
}

# --------------------------------------------------------------------------------------
# EFS -- shared Hugging Face weight cache
# --------------------------------------------------------------------------------------

resource "aws_efs_file_system" "models" {
  creation_token   = "${var.name_prefix}-models"
  encrypted        = true
  throughput_mode  = "elastic"
  performance_mode = "generalPurpose"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-models" })
}

resource "aws_efs_mount_target" "models" {
  count = length(var.private_subnet_ids)

  file_system_id  = aws_efs_file_system.models.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# Root-squash-free access point so the container (running as root, writing into
# /root/.cache/huggingface) owns what it writes.
resource "aws_efs_access_point" "models" {
  file_system_id = aws_efs_file_system.models.id

  posix_user {
    uid = 0
    gid = 0
  }

  root_directory {
    path = "/huggingface"
    creation_info {
      owner_uid   = 0
      owner_gid   = 0
      permissions = "0755"
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-models" })
}
