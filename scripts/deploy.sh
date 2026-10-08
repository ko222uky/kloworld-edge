#!/usr/bin/env bash
# Apply the edge proxy's configuration on the droplet. Safe to re-run; a config change is
# applied with a graceful reload, so no app sees downtime.
#
#   bash /opt/kloworld-edge/scripts/deploy.sh            # pull latest, validate, apply
#   SKIP_PULL=1 bash /opt/kloworld-edge/scripts/deploy.sh # apply the checked-out tree as-is
set -euo pipefail

EDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$EDGE_DIR"

if [[ -z "${SKIP_PULL:-}" && -d .git ]]; then
    echo "==> Pulling latest config"
    git pull --ff-only
fi

if ! docker network inspect edge >/dev/null 2>&1; then
    echo "==> Creating the shared edge network"
    docker network create edge
fi

echo "==> Validating the Caddyfile"
docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

echo "==> Starting the proxy"
docker compose up -d

echo "==> Reloading the configuration"
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

docker compose ps
echo
echo "Sites:"
grep -hoE '^[a-z0-9.-]+\.[a-z]+' caddy/sites/*.caddy | sed 's|^|  https://|'
