#!/usr/bin/env bash
# One-time setup of a fresh Ubuntu 24.04 DigitalOcean droplet for KLOWORLD apps. Run as
# root, streamed over SSH from your machine (the droplet doesn't need the code for this):
#
#   ssh root@<droplet-ip> 'bash -s' < scripts/provision.sh
#
# What it does (idempotent -- safe to re-run):
#   1. installs Docker Engine + the compose plugin from Docker's apt repository
#   2. adds a swap file (building PyTorch/Next.js images needs more than 2 GB RAM)
#   3. enables the firewall: SSH, HTTP, HTTPS (TCP + UDP for HTTP/3) only
#   4. turns on unattended security upgrades
#   5. creates the shared `edge` Docker network that the proxy and the apps join
#
# Per-app setup (clone, .env) lives in each app's repo.
set -euo pipefail

SWAP_SIZE="${SWAP_SIZE:-4G}"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing base packages"
apt-get update -q
apt-get install -yq ca-certificates curl git ufw unattended-upgrades openssl

echo "==> Installing Docker"
if ! command -v docker >/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

echo "==> Configuring swap (${SWAP_SIZE})"
if ! swapon --show | grep -q /swapfile; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
fi

echo "==> Configuring firewall"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

echo "==> Enabling unattended security upgrades"
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> Creating the shared edge network"
docker network inspect edge >/dev/null 2>&1 || docker network create edge

cat <<EOF

Provisioning complete.

Next steps:
  1. Clone this repo to /opt/kloworld-edge and run: bash /opt/kloworld-edge/scripts/deploy.sh
  2. Set up each app from its own repo (it joins the edge network; no ports 80/443).
EOF
