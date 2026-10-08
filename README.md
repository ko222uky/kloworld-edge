# kloworld-edge

The front door of the KLOWORLD droplet. This repo does two things:

- **Host setup**: [`scripts/provision.sh`](scripts/provision.sh) installs Docker, swap, the
  firewall and unattended upgrades, and creates the shared `edge` Docker network.
- **The edge proxy**: one [Caddy](https://caddyserver.com/docs/) container, the only thing
  on the droplet listening on ports 80/443. It obtains and renews a Let's Encrypt certificate
  for every hostname, and forwards each hostname to one app.

Each app lives in its own repo, runs as its own compose project, and publishes no public
ports. Its entry container joins the `edge` network under an alias, and the proxy reaches it
by that name. Routing *inside* an app (paths, logins) stays in the app.

```
                 ┌──────────────── droplet ────────────────────────────────────────┐
Internet ─:443─► │ edge proxy ──(network: edge)──► datadrift-gateway:80  (/opt/mlops-demo)
                 │ /opt/kloworld-edge          └─► <next-app>:<port>    (/opt/<next-app>)
                 └─────────────────────────────────────────────────────────────────┘
```

| App | Hostname | Repo | Entry on `edge` |
|---|---|---|---|
| Data drift simulator | https://datadrift.kloworld.com | [data-drift-simulator](https://github.com/ko222uky/data-drift-simulator) | `datadrift-gateway:80` |

## Layout

```
.
├── compose.yml            # the proxy: ports 80/443, joins the external `edge` network
├── caddy/
│   ├── Caddyfile          # shared snippet (common), then imports every site file
│   └── sites/*.caddy      # one file per app: hostname -> container on `edge`
└── scripts/
    ├── provision.sh       # one-time host setup (idempotent)
    └── deploy.sh          # pull, validate, start, reload (no downtime)
```

## Adding an app

1. **DNS:** at the DNS provider for `kloworld.com`, add an `A` record for the new name
   pointing at the droplet (`142.93.51.106`). On Cloudflare, set it to **DNS only** (grey
   cloud), or Let's Encrypt validation can fail. Check with `nslookup <name>`.
2. **The app's compose file:** don't publish ports 80/443. Attach the entry container
   (the web server, or the app itself if it's a single container) to the `edge` network
   with a unique alias:

   ```yaml
   services:
     web:
       networks:
         default:
         edge:
           aliases: [myapp-web]
       # Optional, for health checks from the droplet only (pick a free port):
       ports: ["127.0.0.1:8002:3000"]

   networks:
     edge:
       external: true
   ```

   Ports in use on `127.0.0.1`: 8001 (datadrift). Never publish a port without the
   `127.0.0.1:` prefix. Docker's port rules bypass `ufw`, so it would be open to the world.
3. **The site file:** add `caddy/sites/myapp.caddy`:

   ```caddyfile
   myapp.kloworld.com {
   	import common
   	reverse_proxy myapp-web:3000
   }
   ```

   Then add the app to the table above.
4. **Deploy:** start the app first (`docker compose up -d` in its directory on the
   droplet), then the proxy: `bash /opt/kloworld-edge/scripts/deploy.sh`. The certificate
   arrives within seconds.

If the app sits behind its own reverse proxy and cares about the client's IP or the
`https` scheme, have that proxy trust the `X-Forwarded-*` headers from private addresses.
In Caddy that's `trusted_proxies static private_ranges` in the `servers` global option.
This proxy overwrites those headers on every request, so clients can't spoof them.

### Cloning a second private repo on the droplet

GitHub accepts a deploy key for one repository only. Give each private repo its own key and
a host alias:

```bash
ssh-keygen -t ed25519 -N "" -C "deploy@kloworld:myapp" -f ~/.ssh/github_myapp
cat >> ~/.ssh/config <<'EOF'
Host github-myapp
  HostName github.com
  User git
  IdentityFile ~/.ssh/github_myapp
  IdentitiesOnly yes
EOF
cat ~/.ssh/github_myapp.pub   # add on GitHub: repo → Settings → Deploy keys (read-only)
git clone git@github-myapp:ko222uky/myapp.git /opt/myapp
```

## Setting up a fresh droplet

```bash
ssh root@<droplet-ip> 'bash -s' < scripts/provision.sh        # from your machine
ssh root@<droplet-ip>
git clone https://github.com/ko222uky/kloworld-edge.git /opt/kloworld-edge
bash /opt/kloworld-edge/scripts/deploy.sh
```

Then set up each app from its own repo. In this order, every hostname already has a running
app behind it when the proxy first asks for its certificate.

## Changing the config

Edit on a branch, open a PR (CI validates the Caddyfile and the scripts), and merge. Then
apply it on the droplet:

```bash
bash /opt/kloworld-edge/scripts/deploy.sh
```

The script pulls, validates the Caddyfile, then runs `caddy reload`. A bad config is rejected
before it replaces the running one, and a good one is applied with no dropped connections.
There's no automatic deploy here: the proxy changes rarely, and each change should be
watched.

## Testing locally

To check a site file or try an app behind HTTPS on your machine, run the proxy with a scratch
config that serves a `*.localhost` name with Caddy's internal CA:

```bash
docker network create edge                         # once
# start the app with its edge overlay, e.g. in data-drift-simulator:
#   HTTP_PORT=8001 docker compose -f docker-compose.yml -f compose.edge.yml up -d
mkdir -p /tmp/edgetest/sites && cp caddy/Caddyfile /tmp/edgetest/
printf 'datadrift.localhost {\n\ttls internal\n\timport common\n\treverse_proxy datadrift-gateway:80\n}\n' \
  > /tmp/edgetest/sites/test.caddy
MSYS_NO_PATHCONV=1 docker run -d --name edgetest --network edge -p 127.0.0.1:8443:443 \
  -v /tmp/edgetest:/etc/caddy:ro caddy:2.11-alpine
curl -k https://datadrift.localhost:8443/
docker rm -f edgetest
```

Browsers resolve `*.localhost` to your machine and will warn about the internal certificate.
For datadrift, also set `PUBLIC_HOST=datadrift.localhost`,
`PUBLIC_ORIGIN=https://datadrift.localhost:8443` and `COOKIE_SECURE=true`.

## Operations

All commands run from `/opt/kloworld-edge`.

| Task | Command |
|---|---|
| Status | `docker compose ps` |
| Logs (certificates, upstream errors) | `docker compose logs -f --tail=100 caddy` |
| Who's on the edge network | `docker network inspect edge -f '{{range .Containers}}{{.Name}} {{end}}'` |
| Apply config changes | `bash scripts/deploy.sh` |

## Troubleshooting

| Symptom | Check |
|---|---|
| Certificate error in the browser | The name must resolve to the droplet (`nslookup`), and on Cloudflare it must be DNS only. Look for ACME errors in the logs. Don't add an `AAAA` record unless IPv6 works end to end |
| `502 Bad Gateway` | The proxy can't reach the alias. Is the app running, and is its entry container on `edge` (see the inspect command above)? The alias and port in the site file must match |
| `deploy.sh` fails at "Validating" | Caddyfile syntax error. The message names the file and line, and the running config is untouched |
| Ports 80/443 "address already in use" | Another container publishes them, such as an app that still has its old ports. `docker ps --format '{{.Names}} {{.Ports}}'` |

## Notes

- **Keep the `caddy_data` volume.** It holds the certificates and the ACME account. If you
  delete it, every name is re-issued at once, and Let's Encrypt's rate limits (5 duplicate
  certificates per week) can lock a name out.
- **The `edge` network is created outside compose** (by `provision.sh` and `deploy.sh`), so
  `docker compose down` in any one project never tries to remove it from under the others.
- **Server hardening** (sshd, fail2ban, backups, a Cloud Firewall) belongs in
  `scripts/provision.sh`, since it applies to the whole droplet.
