# VPC, subnets, NAT, and the VPC endpoints that keep image pulls and secret reads off
# the NAT Gateway's per-GB meter.
#
# The endpoint list is not incidental: the Anubis image is 12.8 GB, and ECR stores layer
# blobs in S3. Without the S3 *gateway* endpoint (which is free), every layer pull is
# billed at the NAT's $0.045/GB. The interface endpoints cost $0.01/hr each per AZ and
# are worth disabling at very low volume — see architecture/cost-model.md §1.1.

locals {
  availability_zones = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # Deterministic /20 public and private subnets carved out of the VPC CIDR. Private
  # subnets are sized larger because every pod IP comes from them (VPC CNI assigns pod
  # IPs from the subnet, and a 12.8 GB image means few but large pods -- still, ENI
  # secondary-IP allocation is what exhausts a small subnet first).
  public_subnet_cidrs  = [for index in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 8, index)]
  private_subnet_cidrs = [for index in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 4, index + 1)]
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

# --------------------------------------------------------------------------------------
# Subnets
# --------------------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = var.availability_zone_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-${local.availability_zones[count.index]}"
    # Required for the AWS Load Balancer Controller to auto-discover subnets for an
    # internet-facing ALB.
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

resource "aws_subnet" "private" {
  count = var.availability_zone_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.availability_zones[count.index]

  tags = merge(var.tags, {
    Name                                        = "${var.name_prefix}-private-${local.availability_zones[count.index]}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# --------------------------------------------------------------------------------------
# NAT
#
# nat_gateway_count of 1 is the launch configuration: one NAT shared by all private
# subnets. It is a single-AZ dependency for egress -- acceptable when the alternative is
# $37/month per additional AZ and all outbound traffic is to LLM providers that are
# already a hard dependency. Raise to availability_zone_count at medium scale.
# --------------------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count  = var.nat_gateway_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-nat-${count.index}" })
}

resource "aws_nat_gateway" "main" {
  count = var.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name_prefix}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.main]
}

# --------------------------------------------------------------------------------------
# Routing
# --------------------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ so that, when nat_gateway_count is raised to match the
# AZ count, each AZ egresses through its own NAT with no cross-AZ data charge.
resource "aws_route_table" "private" {
  count = var.availability_zone_count

  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-private-${local.availability_zones[count.index]}" })
}

resource "aws_route" "private_nat" {
  count = var.availability_zone_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[min(count.index, var.nat_gateway_count - 1)].id
}

resource "aws_route_table_association" "private" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --------------------------------------------------------------------------------------
# VPC endpoints
# --------------------------------------------------------------------------------------

# Free, and the highest-value endpoint here: ECR layer blobs live in S3, so this is what
# keeps 12.8 GB image pulls off the NAT meter.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-s3" })
}

resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_interface_endpoints ? 1 : 0

  name        = "${var.name_prefix}-vpc-endpoints"
  description = "HTTPS from inside the VPC to interface endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc-endpoints" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset([
    "ecr.api",        # ECR control plane calls (GetAuthorizationToken, BatchGetImage)
    "ecr.dkr",        # the Docker registry protocol itself
    "secretsmanager", # External Secrets Operator
    "logs",           # container logs to CloudWatch
    "sts",            # IRSA token exchange
  ]) : toset([])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-${replace(each.value, ".", "-")}" })
}
