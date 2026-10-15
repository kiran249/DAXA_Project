terraform {
  required_version = ">= 1.6.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.43"
    }
  }
}

provider "digitalocean" {
  token = var.do_token

  # Only needed when create_backup_bucket = true (Spaces is S3-compatible and
  # uses its own key pair, separate from the API token).
  spaces_access_id  = var.spaces_access_id
  spaces_secret_key = var.spaces_secret_key
}
