variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  description = "VPC id from the network module."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet ids. Node groups run here."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet ids. Only the ALB lives here; nodes do not."
  type        = list(string)
}

variable "api_public_access_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API endpoint. Narrow this to office/VPN ranges once the cluster is established; 0.0.0.0/0 relies on IAM alone."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "log_retention_days" {
  description = "CloudWatch retention for control-plane logs."
  type        = number
  default     = 30
}

# --- general node group -----------------------------------------------------------

variable "general_instance_type" {
  description = "Instance type for the general node group (anubis-api, portal-server). Must be x86_64: the image ships x86 PyTorch wheels and a wolfi chromium apk."
  type        = string
  default     = "m7i.xlarge"
}

variable "general_disk_size_gb" {
  description = "Root volume for general nodes. 150 GB is the floor: the image is 12.8 GB and a rolling deploy keeps two tags resident."
  type        = number
  default     = 150
}

variable "general_desired_size" {
  description = "Initial node count for the general group. Owned by cluster-autoscaler after creation."
  type        = number
  default     = 2
}

variable "general_min_size" {
  type        = number
  description = "Minimum general nodes."
  default     = 2
}

variable "general_max_size" {
  type        = number
  description = "Maximum general nodes."
  default     = 6
}

# --- media node group -------------------------------------------------------------

variable "media_instance_type" {
  description = "Instance type for the media node group (anubis-stateful). CPU-heavy: ffmpeg, librosa, noisereduce, moviepy."
  type        = string
  default     = "m7i.2xlarge"
}

variable "media_disk_size_gb" {
  description = "Root volume for media nodes. Larger than general because media batches write big temporary audio files under /tmp."
  type        = number
  default     = 200
}

variable "media_desired_size" {
  type        = number
  description = "Initial node count for the media group."
  default     = 1
}

variable "media_min_size" {
  type        = number
  description = "Minimum media nodes. Must stay at 1: anubis-stateful holds in-process media-job state and cannot be evicted to zero."
  default     = 1
}

variable "media_max_size" {
  type        = number
  description = "Maximum media nodes."
  default     = 2
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
