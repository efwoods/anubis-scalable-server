# EKS cluster and the two node groups the architecture calls for.
#
# Two node groups, not one, because the workloads have opposite shapes:
#   * general -- the chat/CRUD API tier and the portal. Many small-ish pods, scales on
#     request volume.
#   * media   -- the single-replica anubis-stateful pod running ffmpeg, librosa,
#     noisereduce, and moviepy. CPU-bound and bursty. Tainted so nothing else lands on
#     it, which is what stops a diarization batch from starving live chat -- the exact
#     failure mode of the current single host.
#
# x86_64 only. The image installs x86 PyTorch/torchcodec wheels and the wolfi chromium
# apk; Graviton instance types will not run it.

data "aws_partition" "current" {}

# --------------------------------------------------------------------------------------
# Cluster
# --------------------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster"
  description = "EKS control plane"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-cluster" })
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.api_public_access_cidrs
  }

  # "api" lets IAM principals be granted cluster access through EKS access entries
  # instead of hand-editing the aws-auth ConfigMap.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = merge(var.tags, { Name = var.cluster_name })

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# IRSA. Every service account that touches an AWS API (External Secrets Operator, the
# Load Balancer Controller, cluster-autoscaler, the EBS/EFS CSI drivers) authenticates
# through this provider rather than through node instance credentials.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

# --------------------------------------------------------------------------------------
# Node groups
# --------------------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# Larger-than-default root volumes: the image is 12.8 GB and a rolling deploy keeps two
# tags resident. 150 GB is the floor for general; media nodes get 200 GB because media
# batches write large temporary audio files under /tmp.
resource "aws_launch_template" "general" {
  name_prefix   = "${var.cluster_name}-general-"
  instance_type = var.general_instance_type

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.general_disk_size_gb
      volume_type           = "gp3"
      throughput            = 250
      iops                  = 4000
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # pods reach IMDS through one extra hop
  }

  monitoring { enabled = true }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-general" })
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_launch_template" "media" {
  name_prefix   = "${var.cluster_name}-media-"
  instance_type = var.media_instance_type

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.media_disk_size_gb
      volume_type           = "gp3"
      throughput            = 500
      iops                  = 6000
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  monitoring { enabled = true }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-media" })
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_eks_node_group" "general" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "general"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  scaling_config {
    desired_size = var.general_desired_size
    min_size     = var.general_min_size
    max_size     = var.general_max_size
  }

  launch_template {
    id      = aws_launch_template.general.id
    version = aws_launch_template.general.latest_version
  }

  update_config { max_unavailable = 1 }

  labels = { workload = "general" }

  tags = merge(var.tags, {
    # Consumed by cluster-autoscaler for node group auto-discovery.
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  })

  lifecycle {
    # desired_size is owned by cluster-autoscaler at runtime; Terraform sets the initial
    # value and then stops fighting the autoscaler over it.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

resource "aws_eks_node_group" "media" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "media"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  scaling_config {
    desired_size = var.media_desired_size
    min_size     = var.media_min_size
    max_size     = var.media_max_size
  }

  launch_template {
    id      = aws_launch_template.media.id
    version = aws_launch_template.media.latest_version
  }

  update_config { max_unavailable = 1 }

  labels = { workload = "media" }

  # Only pods that explicitly tolerate this land here. anubis-stateful does; nothing
  # else should.
  taint {
    key    = "workload"
    value  = "media"
    effect = "NO_SCHEDULE"
  }

  tags = merge(var.tags, {
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# --------------------------------------------------------------------------------------
# Addons
#
# The CSI drivers are EKS-managed addons. The Load Balancer Controller, External Secrets
# Operator, cluster-autoscaler, and metrics-server are Helm releases installed by
# helm/platform -- Terraform provisions only their IRSA roles (modules/secrets and
# below), so that the cluster's application layer stays in Helm where it can be rolled
# back independently of infrastructure.
# --------------------------------------------------------------------------------------

data "aws_eks_addon_version" "this" {
  for_each = toset(["vpc-cni", "coredns", "kube-proxy", "aws-ebs-csi-driver", "aws-efs-csi-driver"])

  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

resource "aws_eks_addon" "this" {
  for_each = data.aws_eks_addon_version.this

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = each.key
  addon_version               = each.value.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  service_account_role_arn = contains(["aws-ebs-csi-driver", "aws-efs-csi-driver"], each.key) ? aws_iam_role.csi[each.key].arn : null

  tags = var.tags

  depends_on = [aws_eks_node_group.general]
}

resource "aws_iam_role" "csi" {
  for_each = toset(["aws-ebs-csi-driver", "aws-efs-csi-driver"])

  name = "${var.cluster_name}-${each.value}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.oidc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.oidc.url, "https://", "")}:aud" = "sts.amazonaws.com"
          "${replace(aws_iam_openid_connect_provider.oidc.url, "https://", "")}:sub" = each.value == "aws-ebs-csi-driver" ? "system:serviceaccount:kube-system:ebs-csi-controller-sa" : "system:serviceaccount:kube-system:efs-csi-controller-sa"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "csi" {
  for_each = {
    "aws-ebs-csi-driver" = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    "aws-efs-csi-driver" = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
  }

  role       = aws_iam_role.csi[each.key].name
  policy_arn = each.value
}

# --------------------------------------------------------------------------------------
# IRSA roles for the Helm-installed controllers
# --------------------------------------------------------------------------------------

locals {
  oidc_host = replace(aws_iam_openid_connect_provider.oidc.url, "https://", "")
}

resource "aws_iam_role" "load_balancer_controller" {
  name = "${var.cluster_name}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.oidc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })

  tags = var.tags
}

# The controller's permission set is large and AWS publishes it as a single document.
# Kept as a file rather than inlined so it can be refreshed verbatim from upstream:
#   curl -o iam/alb-controller-policy.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
resource "aws_iam_policy" "load_balancer_controller" {
  name        = "${var.cluster_name}-alb-controller"
  description = "AWS Load Balancer Controller, from the upstream published policy document."
  policy      = file("${path.module}/iam/alb-controller-policy.json")
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

resource "aws_iam_role" "cluster_autoscaler" {
  name = "${var.cluster_name}-cluster-autoscaler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.oidc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "cluster-autoscaler"
  role = aws_iam_role.cluster_autoscaler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeImages",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
          }
        }
      },
    ]
  })
}
