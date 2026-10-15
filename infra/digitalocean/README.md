# DAXA GPU host on DigitalOcean (NVIDIA L40S)

This directory sets up the DAXA production host as code. One `terraform apply`
creates the infrastructure, and cloud-init configures the server on its first
boot.

| Requirement | How it is met |
|---|---|
| GPU: 1x NVIDIA L40S, 48 GB VRAM | Droplet size `gpu-l40sx1-48gb` |
| 8 vCPU, 64 GiB RAM, 500 GiB NVMe | Included in that size; the NVMe disk is the boot disk |
| 250 GiB persistent block storage | `digitalocean_volume.data`, mounted at `/mnt/daxa_data` (`postgres/`, `recordings/`, `backups/`) and protected with `prevent_destroy` |
| Ubuntu, AI/ML-ready image | `droplet_image`, which ships with the NVIDIA driver and CUDA |
| SSH access | Key-only SSH as the sudo user `daxa`. Password and root login are disabled, and fail2ban is enabled |
| Firewall | DigitalOcean Cloud Firewall: port 22 only from `ssh_allowed_cidrs`, 80/443 (TCP and UDP) public, everything else closed |
| HTTPS | Caddy reverse proxy with automatic Let's Encrypt certificates and HSTS. Only Caddy publishes ports |
| Off-server PostgreSQL backups | Daily `pg_dump`, encrypted with **age** (only the public key is on the server), uploaded to a private, versioned Spaces bucket in a **different region** (`nyc3`), with automatic expiry after 35 days |
| Docker + NVIDIA Container Toolkit | Installed and configured by `scripts/bootstrap.sh` |
| DNS | A static reserved IP, plus optional DigitalOcean DNS records (`app`, `api`, `auth`) |

```
infra/digitalocean/
  terraform/                 droplet, volume, VPC, firewall, reserved IP, DNS, Spaces bucket, project
  cloud-init/                first-boot config (users, SSH hardening, systemd backup timer)
  scripts/bootstrap.sh       mounts the volume, installs Docker + NVIDIA toolkit, runs a GPU check
  scripts/pg-backup.sh       encrypted off-server PostgreSQL backup
deploy/
  docker-compose.yml         Caddy (HTTPS), PostgreSQL 16, Keycloak 26, GPU check service
  caddy/Caddyfile            app / api / auth virtual hosts
  postgres/init/             creates the app and Keycloak databases and roles
```

---

## 0. Prerequisites (information needed from the DAXA team)

1. **A DigitalOcean API token** with read/write scope (DigitalOcean: API > Tokens).
2. **GPU Droplet access.** New accounts often need GPU Droplets enabled or a
   limit increase through a support ticket before an L40S can be created.
3. **A Spaces access key** (DigitalOcean: Spaces Object Storage > Access Keys).
   Use a full-access key for Terraform. For the server, create a second key
   scoped to the backup bucket only (read/write) once the bucket exists.
4. **SSH public keys** for everyone who needs server access.
5. **Admin IP ranges** (office or VPN) that may reach SSH.
6. **The domain** to use, and whether its DNS is hosted at DigitalOcean.
7. **An age key pair for backups**, created on an admin workstation and *not*
   on the server:
   ```bash
   age-keygen -o daxa-backup.age-key   # private key: store it in the password manager or vault, never on the server
   age-keygen -y daxa-backup.age-key   # prints the public key (age1...); this one goes on the server
   ```
8. Install `terraform` 1.6 or later and, optionally, `doctl`.

Check that the region and image are available before applying:

```bash
doctl compute size list | grep -i l40s                     # confirm gpu-l40sx1-48gb is offered
doctl compute region list                                  # the region must offer it (default: tor1)
doctl compute image list --public | grep -i -E 'gpu|ai'    # confirm the AI/ML-ready image slug
```

## 1. Provision

```bash
cd infra/digitalocean/terraform
cp terraform.tfvars.example terraform.tfvars    # fill in SSH keys, CIDRs, domain, bucket name
export TF_VAR_do_token=dop_v1_xxx
export TF_VAR_spaces_access_id=xxx
export TF_VAR_spaces_secret_key=xxx

terraform init
terraform plan -out tfplan        # review: 1 droplet, 1 volume, firewall, reserved IP, bucket ...
terraform apply tfplan
terraform output
```

> **State:** `terraform.tfstate` contains sensitive values. Keep it out of git
> (it is ignored here). For team use, move it to a remote backend, for example
> a separate Spaces bucket with the S3 backend.

The first boot takes about 5 to 10 minutes. To watch it:

```bash
ssh daxa@$(terraform output -raw public_ip)
sudo tail -f /var/log/daxa-bootstrap.log     # ends with "DAXA bootstrap complete"
```

## 2. Verify the host

```bash
nvidia-smi                                   # L40S, 48 GB
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
df -h /mnt/daxa_data                         # about 250 GiB volume
sudo sshd -T | grep -E 'passwordauth|permitrootlogin'
systemctl list-timers daxa-pg-backup.timer
```

## 3. DNS

Point A records at the **reserved IP** (`terraform output public_ip`). This IP
stays the same if the droplet is ever rebuilt.

- With DNS hosted at DigitalOcean, set `manage_dns = true` and `domain`, then
  run `terraform apply`.
- With DNS hosted elsewhere, create the records listed by
  `terraform output dns_records_to_create`.

## 4. Deploy the base stack (HTTPS, PostgreSQL, Keycloak)

```bash
# on the server
git clone <DAXA repo URL> /opt/daxa
cd /opt/daxa/deploy
cp .env.example .env && chmod 600 .env && nano .env    # set domains and strong passwords (openssl rand -base64 32)
docker compose up -d
docker compose --profile gpu-check run --rm gpu-check
```

Caddy issues certificates automatically once DNS resolves to the server.

Frontend, backend, workflow orchestration and AI model services are added to
`deploy/docker-compose.yml`. Caddy already routes `APP_DOMAIN` to
`frontend:3000` and `API_DOMAIN` to `backend:8000`. A commented example shows
how a GPU service requests the L40S. Audio recordings go in
`/mnt/daxa_data/recordings`, which is on the persistent volume.

The Keycloak admin console is blocked publicly. Reach it through an SSH tunnel:

```bash
ssh -L 8080:localhost:8080 daxa@<ip> \
  'docker run --rm --network daxa_edge -p 8080:8080 alpine/socat TCP-LISTEN:8080,fork TCP:keycloak:8080'
# then open http://localhost:8080/admin
```

## 5. Enable off-server backups

```bash
sudo cp /etc/daxa/backup.env.example /etc/daxa/backup.env
sudo chmod 600 /etc/daxa/backup.env
sudo nano /etc/daxa/backup.env       # AGE_RECIPIENT=age1..., bucket-scoped Spaces key
sudo systemctl start daxa-pg-backup.service && journalctl -u daxa-pg-backup -n 50
```

How the backups are protected:

- They are encrypted on the server with the age **public** key, so a
  compromised server cannot read old backups.
- The bucket is private, versioned and in a separate region. Objects expire
  after `backup_retention_days`.
- Every upload is checked with `rclone check`, and `SHA256SUMS` is stored next
  to the dumps.
- The newest 3 days are also kept on the volume for quick restores.
- Optional: set `HEALTHCHECK_URL` (for example healthchecks.io) to get an alert
  when a nightly backup fails or doesn't run.

### Restore (practise this quarterly)

```bash
# on a workstation that holds the age private key
rclone copy spaces:<bucket>/postgres/<host>/<STAMP> ./restore
cd restore && sha256sum -c SHA256SUMS
age -d -i daxa-backup.age-key globals.sql.age > globals.sql
age -d -i daxa-backup.age-key daxa.dump.age   > daxa.dump
# copy to the target server, then:
docker exec -i daxa-postgres psql -U postgres < globals.sql
docker exec -i daxa-postgres pg_restore -U postgres -d daxa --clean --if-exists < daxa.dump
```

### Additional data protection (recommended)

- **Volume snapshots** of the 250 GiB volume (DigitalOcean: Volumes > Take
  Snapshot, or `doctl compute volume snapshot`) before upgrades. They also
  cover audio recordings.
- **Audio recordings** aren't included in the PostgreSQL backup. If they must
  also be stored off-server, add an `rclone sync` to a `crypt` remote in the
  same bucket.

## 6. Day-2 notes

- Changes to `user_data` and `image` are ignored by Terraform on purpose, so an
  edit can never rebuild production. To rebuild deliberately, run
  `terraform apply -replace=digitalocean_droplet.gpu`. The data volume and
  reserved IP are kept.
- Unattended upgrades apply security patches, but NVIDIA driver, CUDA and
  kernel packages are held back. Upgrade them in a maintenance window, then
  reboot.
- Docker publishes ports by writing iptables rules, which bypass UFW. The
  DigitalOcean Cloud Firewall in front of the droplet is the authoritative
  firewall. Don't publish additional ports in compose files.
- Billing: GPU Droplets are billed per second **while they exist, even when
  powered off**. Check current L40S pricing on the DigitalOcean pricing page.
  The volume, reserved IP (free while assigned) and Spaces are billed
  separately.
