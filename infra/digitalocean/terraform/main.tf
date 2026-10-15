locals {
  name        = "${var.project_name}-${var.environment}"
  volume_name = "${var.project_name}-data"
  tags        = [var.project_name, var.environment, "gpu"]

  # Public keys installed for admin_username via cloud-init.
  admin_authorized_keys = values(var.ssh_public_keys)
}

# ---------------------------------------------------------------------------
# SSH keys
# ---------------------------------------------------------------------------
resource "digitalocean_ssh_key" "admin" {
  for_each   = var.ssh_public_keys
  name       = "${local.name}-${each.key}"
  public_key = each.value
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
resource "digitalocean_vpc" "main" {
  name     = "${local.name}-vpc"
  region   = var.region
  ip_range = var.vpc_cidr
}

# ---------------------------------------------------------------------------
# 250 GiB persistent block storage: PostgreSQL data + audio recordings.
# Lives independently of the droplet, so rebuilding the server keeps the data.
# ---------------------------------------------------------------------------
resource "digitalocean_volume" "data" {
  name                     = local.volume_name
  region                   = var.region
  size                     = var.data_volume_size_gib
  initial_filesystem_type  = "ext4"
  initial_filesystem_label = "daxa-data"
  description              = "DAXA PostgreSQL data and audio recordings"
  tags                     = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# GPU Droplet: 1x NVIDIA L40S 48 GB, 8 vCPU, 64 GiB RAM, 500 GiB NVMe
# ---------------------------------------------------------------------------
resource "digitalocean_droplet" "gpu" {
  name       = "${local.name}-gpu-01"
  region     = var.region
  size       = var.droplet_size
  image      = var.droplet_image
  vpc_uuid   = digitalocean_vpc.main.id
  monitoring = true
  ipv6       = true
  tags       = local.tags

  ssh_keys = concat(
    [for k in digitalocean_ssh_key.admin : k.fingerprint],
    var.existing_ssh_key_fingerprints,
  )

  volume_ids = [digitalocean_volume.data.id]

  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    admin_username        = var.admin_username
    admin_authorized_keys = local.admin_authorized_keys
    disable_root_ssh      = var.disable_root_ssh
    volume_name           = local.volume_name
    data_mount_point      = var.data_mount_point
    backup_schedule       = var.backup_schedule
    backup_bucket_name    = var.backup_bucket_name
    backup_spaces_region  = var.backup_spaces_region
    bootstrap_script      = file("${path.module}/../scripts/bootstrap.sh")
    backup_script         = file("${path.module}/../scripts/pg-backup.sh")
  })

  lifecycle {
    # Editing cloud-init or a newer image must never silently rebuild the
    # production server. Recreate deliberately with `terraform apply -replace`.
    ignore_changes = [user_data, image, ssh_keys]
  }
}

# Static public IP that survives droplet rebuilds — point DNS here.
resource "digitalocean_reserved_ip" "gpu" {
  region = var.region
}

resource "digitalocean_reserved_ip_assignment" "gpu" {
  ip_address = digitalocean_reserved_ip.gpu.ip_address
  droplet_id = digitalocean_droplet.gpu.id
}

# ---------------------------------------------------------------------------
# Cloud firewall: only SSH (restricted), HTTP (ACME + redirect) and HTTPS.
# PostgreSQL, Keycloak admin, model servers etc. are never exposed directly;
# they sit behind the Caddy reverse proxy on the Docker network.
# ---------------------------------------------------------------------------
resource "digitalocean_firewall" "gpu" {
  name        = "${local.name}-fw"
  droplet_ids = [digitalocean_droplet.gpu.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_allowed_cidrs
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTP/3 (QUIC)
  inbound_rule {
    protocol         = "udp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "icmp"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# ---------------------------------------------------------------------------
# DNS (optional)
# ---------------------------------------------------------------------------
resource "digitalocean_record" "app" {
  for_each = var.manage_dns ? toset(var.dns_records) : toset([])

  domain = var.domain
  type   = "A"
  name   = each.value
  value  = digitalocean_reserved_ip.gpu.ip_address
  ttl    = 300
}

# ---------------------------------------------------------------------------
# Off-server backup bucket: private, versioned, auto-expiring.
# ---------------------------------------------------------------------------
resource "digitalocean_spaces_bucket" "backups" {
  count = var.create_backup_bucket ? 1 : 0

  name          = var.backup_bucket_name
  region        = var.backup_spaces_region
  acl           = "private"
  force_destroy = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "expire-old-backups"
    enabled = true

    expiration {
      days = var.backup_retention_days
    }

    noncurrent_version_expiration {
      days = 7
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Group everything in a DigitalOcean project.
# ---------------------------------------------------------------------------
resource "digitalocean_project" "daxa" {
  name        = "DAXA ${title(var.environment)}"
  description = "DAXA platform: frontend, APIs, PostgreSQL, Keycloak, orchestration, AI services"
  purpose     = "Machine learning / AI / Data processing"
  environment = title(var.environment)

  resources = concat(
    [
      digitalocean_droplet.gpu.urn,
      digitalocean_volume.data.urn,
      digitalocean_reserved_ip.gpu.urn,
    ],
    [for b in digitalocean_spaces_bucket.backups : b.urn],
  )
}
