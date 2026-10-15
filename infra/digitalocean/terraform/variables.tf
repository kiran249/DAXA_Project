# ---------------------------------------------------------------------------
# Credentials (pass via environment: TF_VAR_do_token, TF_VAR_spaces_access_id,
# TF_VAR_spaces_secret_key — never commit them).
# ---------------------------------------------------------------------------
variable "do_token" {
  description = "DigitalOcean API token with read/write scope."
  type        = string
  sensitive   = true
}

variable "spaces_access_id" {
  description = "Spaces access key ID (only required to create the backup bucket)."
  type        = string
  default     = null
  sensitive   = true
}

variable "spaces_secret_key" {
  description = "Spaces secret key (only required to create the backup bucket)."
  type        = string
  default     = null
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------
variable "project_name" {
  description = "Prefix for all resource names."
  type        = string
  default     = "daxa"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project_name))
    error_message = "project_name must be lowercase letters, digits and dashes (max 21 chars)."
  }
}

variable "environment" {
  description = "Environment label (production, staging, ...)."
  type        = string
  default     = "production"
}

variable "region" {
  description = "Region with L40S capacity. Check: doctl compute size list | grep l40s ; doctl compute region list."
  type        = string
  default     = "tor1"
}

variable "vpc_cidr" {
  description = "Private network range for the VPC."
  type        = string
  default     = "10.120.0.0/20"
}

# ---------------------------------------------------------------------------
# GPU Droplet
# ---------------------------------------------------------------------------
variable "droplet_size" {
  description = "1x NVIDIA L40S (48 GB VRAM), 8 vCPU, 64 GiB RAM, 500 GiB NVMe boot disk."
  type        = string
  default     = "gpu-l40sx1-48gb"
}

variable "droplet_image" {
  description = <<-EOT
    AI/ML-ready Ubuntu image (NVIDIA driver + CUDA preinstalled).
    Confirm the current slug before applying:
      doctl compute image list --public | grep -i -E 'gpu|ai/ml'
  EOT
  type        = string
  default     = "gpu-h100x1-base"
}

variable "admin_username" {
  description = "Non-root sudo user created on the server for SSH access."
  type        = string
  default     = "daxa"
}

variable "disable_root_ssh" {
  description = "Disable SSH login as root (admin_username keeps sudo)."
  type        = bool
  default     = true
}

variable "ssh_public_keys" {
  description = "Map of key name => OpenSSH public key to register and install on the server."
  type        = map(string)
  default     = {}
}

variable "existing_ssh_key_fingerprints" {
  description = "Fingerprints of SSH keys already registered in the DigitalOcean account."
  type        = list(string)
  default     = []
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to reach SSH (port 22). Use office/VPN IPs, e.g. [\"203.0.113.10/32\"]."
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "Provide at least one CIDR for SSH access."
  }
}

# ---------------------------------------------------------------------------
# Persistent block storage
# ---------------------------------------------------------------------------
variable "data_volume_size_gib" {
  description = "Persistent block storage for PostgreSQL data and audio recordings."
  type        = number
  default     = 250
}

variable "data_mount_point" {
  description = "Where the data volume is mounted on the server."
  type        = string
  default     = "/mnt/daxa_data"
}

# ---------------------------------------------------------------------------
# DNS (optional — only if the domain's nameservers point at DigitalOcean)
# ---------------------------------------------------------------------------
variable "manage_dns" {
  description = "Create A records in DigitalOcean DNS for the subdomains below."
  type        = bool
  default     = false
}

variable "domain" {
  description = "Domain already added to DigitalOcean Networking > Domains (e.g. daxa.example.com)."
  type        = string
  default     = ""
}

variable "dns_records" {
  description = "Record names to point at the server's reserved IP (\"@\" = apex)."
  type        = list(string)
  default     = ["app", "api", "auth"]
}

# ---------------------------------------------------------------------------
# Off-server backups (DigitalOcean Spaces)
# ---------------------------------------------------------------------------
variable "create_backup_bucket" {
  description = "Create a private, versioned Spaces bucket for encrypted PostgreSQL backups."
  type        = bool
  default     = true
}

variable "backup_bucket_name" {
  description = "Globally unique Spaces bucket name."
  type        = string
  default     = "daxa-pg-backups"
}

variable "backup_spaces_region" {
  description = "Spaces region for backups. A different region from the droplet gives geographic separation."
  type        = string
  default     = "nyc3"
}

variable "backup_retention_days" {
  description = "Delete backup objects older than this many days."
  type        = number
  default     = 35
}

variable "backup_schedule" {
  description = "systemd OnCalendar expression for the backup job (server time is UTC)."
  type        = string
  default     = "*-*-* 02:30:00"
}
