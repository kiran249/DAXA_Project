#!/usr/bin/env bash
# DAXA GPU host bootstrap — invoked once by cloud-init on first boot.
# Idempotent: safe to re-run manually (sudo /usr/local/sbin/daxa-bootstrap ...).
#
# Usage: daxa-bootstrap <admin_user> <volume_name> <mount_point>
set -euo pipefail

ADMIN_USER="${1:?admin user}"
VOLUME_NAME="${2:?volume name}"
MOUNT_POINT="${3:?mount point}"

exec > >(tee -a /var/log/daxa-bootstrap.log) 2>&1
echo "=== DAXA bootstrap $(date -Is) ==="
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 0. Admin SSH keys: DigitalOcean installs account keys for root only. Merge
#    them into the admin user so disabling root SSH can never lock us out.
# ---------------------------------------------------------------------------
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"
touch "$ADMIN_HOME/.ssh/authorized_keys"
if [ -s /root/.ssh/authorized_keys ]; then
  cat /root/.ssh/authorized_keys "$ADMIN_HOME/.ssh/authorized_keys" \
    | grep -E '^(ssh-|ecdsa-|sk-)' | sort -u > "$ADMIN_HOME/.ssh/authorized_keys.new"
  mv "$ADMIN_HOME/.ssh/authorized_keys.new" "$ADMIN_HOME/.ssh/authorized_keys"
fi
chown "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME/.ssh/authorized_keys"
chmod 0600 "$ADMIN_HOME/.ssh/authorized_keys"

# ---------------------------------------------------------------------------
# 1. Persistent block storage
# ---------------------------------------------------------------------------
DEVICE="/dev/disk/by-id/scsi-0DO_Volume_${VOLUME_NAME}"
for _ in $(seq 1 30); do [ -e "$DEVICE" ] && break; sleep 2; done
if [ ! -e "$DEVICE" ]; then
  echo "ERROR: volume device $DEVICE not found" >&2
  exit 1
fi

if ! blkid "$DEVICE" >/dev/null 2>&1; then
  echo "Volume has no filesystem; formatting ext4"
  mkfs.ext4 -L daxa-data "$DEVICE"
fi

mkdir -p "$MOUNT_POINT"
if ! grep -q "$DEVICE" /etc/fstab; then
  # Drop any auto-generated entry for the same mount point first.
  sed -i "\# ${MOUNT_POINT} #d" /etc/fstab
  echo "$DEVICE $MOUNT_POINT ext4 defaults,nofail,discard,noatime 0 2" >> /etc/fstab
fi
mountpoint -q "$MOUNT_POINT" || mount "$MOUNT_POINT"

# Layout on the volume. The official postgres image runs as uid/gid 999.
install -d -m 0700 -o 999 -g 999 "$MOUNT_POINT/postgres"
install -d -m 0750 -o "$ADMIN_USER" -g "$ADMIN_USER" "$MOUNT_POINT/recordings"
install -d -m 0700 -o root -g root "$MOUNT_POINT/backups/postgres"

# ---------------------------------------------------------------------------
# 2. Docker Engine + Compose plugin
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "$ADMIN_USER"

# ---------------------------------------------------------------------------
# 3. NVIDIA Container Toolkit (GPU access from containers)
# ---------------------------------------------------------------------------
if ! command -v nvidia-ctk >/dev/null 2>&1; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
fi
nvidia-ctk runtime configure --runtime=docker
systemctl enable docker
systemctl restart docker

# ---------------------------------------------------------------------------
# 4. Hardening services
# ---------------------------------------------------------------------------
if sshd -t; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
else
  echo "WARN: sshd config test failed; removing hardening drop-in" >&2
  rm -f /etc/ssh/sshd_config.d/99-daxa-hardening.conf
fi
systemctl enable --now fail2ban
systemctl enable --now unattended-upgrades

# Backups activate once /etc/daxa/backup.env exists (ConditionPathExists).
systemctl daemon-reload
systemctl enable --now daxa-pg-backup.timer

# App checkout location
install -d -m 0755 -o "$ADMIN_USER" -g "$ADMIN_USER" /opt/daxa

# ---------------------------------------------------------------------------
# 5. Verification (logged, non-fatal)
# ---------------------------------------------------------------------------
echo "--- nvidia-smi ---"
nvidia-smi || echo "WARN: nvidia-smi failed (driver missing? wrong image?)"
echo "--- GPU inside a container ---"
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L \
  || echo "WARN: container GPU test failed"
df -h "$MOUNT_POINT"

echo "=== DAXA bootstrap complete $(date -Is) ==="
