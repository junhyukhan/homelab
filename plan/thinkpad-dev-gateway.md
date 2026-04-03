# Dev Gateway: cloudflared Ingress Setup

## Context
The active dev machine (currently the Fedora ThinkPad) exposes dev services (e.g., `npm run dev`) to the internet via a locally-managed cloudflared tunnel, without touching the Cloudflare dashboard each time. All exposed services sit behind Cloudflare Access for authentication.

The dev gateway role is **machine-independent** — it can move to any machine by re-stowing the config and creating a new tunnel. The cloudflared config lives in the `config` dotfiles repo under `cloudflared/`, managed with GNU Stow like all other configs.

The homelab k3s cluster is **unchanged** — it continues to run permanent services (Gitea, registry, etc.) with explicit Cloudflare tunnel routes.

## Current Infrastructure

### Devices (all on Tailscale)
| Device | Role | OS |
|--------|------|----|
| Old laptop (i7-7th, 8GB) | Homelab — k3s node | Linux |
| Fedora ThinkPad | Dev workstation (active dev gateway) | Fedora |
| MacBook Pro | Personal machine | macOS |

### Cloudflare Routing (current)
| Hostname | Target | Type |
|----------|--------|------|
| `domain.com` | Cloudflare Workers | Static blog (untouched) |
| `ssh.domain.com` | Homelab :22 | Browser SSH |
| `ssh-fedora.domain.com` | ThinkPad :22 | Browser SSH |
| `ssh-mbp.domain.com` | MacBook :22 | Browser SSH |
| `gitea.domain.com` | Homelab k3s | Git service |
| `registry.domain.com` | Homelab k3s | Docker registry |
| `dashboard.domain.com` | Homelab k3s | Monitoring |

### Architecture After This Plan
```
Cloudflare Edge
│
├─ domain.com ──────────────→ Workers (blog, unchanged)
├─ ssh.domain.com ──────────→ Homelab tunnel (unchanged)
├─ ssh-fedora.domain.com ──→ ThinkPad tunnel (unchanged, remote-managed)
├─ ssh-mbp.domain.com ─────→ MacBook tunnel (unchanged)
├─ gitea.domain.com ────────→ Homelab tunnel (unchanged)
├─ registry.domain.com ────→ Homelab tunnel (unchanged)
│
└─ *.domain.com ────────────→ Dev gateway tunnel (locally-managed)
   │                            cloudflared ingress rules
   │                            ├─ app1.domain.com → localhost:3000
   │                            ├─ app2.domain.com → localhost:5173
   │                            └─ catch-all → 404
```

Specific routes (remote-managed) always take precedence over the wildcard. The wildcard catch-all is handled by a **locally-managed** tunnel on the active dev machine using cloudflared's ingress config file.

---

## Step 1: Cloudflare DNS — Add Wildcard Record
In the Cloudflare DNS dashboard, add a single record:
- **Type**: CNAME
- **Name**: `*`
- **Target**: `<tunnel-id>.cfargotunnel.com` (will be created in Step 2)
- **Proxy**: Enabled (orange cloud)

This is set once. Update the CNAME target only when moving the dev gateway to a different machine (new tunnel ID).

## Step 2: Create a Locally-Managed Tunnel
A locally-managed tunnel keeps its routing config in a local YAML file instead of the Cloudflare dashboard. This is what allows us to change routes without touching the dashboard.

```bash
# Login (one-time)
cloudflared tunnel login

# Create the tunnel
cloudflared tunnel create dev-gateway

# Note the tunnel ID — use it for the DNS CNAME in Step 1
```

This generates a credentials file at `~/.cloudflared/<tunnel-id>.json`. This file stays on-machine and **never enters any repo**.

## Step 3: Add cloudflared Config to Dotfiles Repo
Add the config to the `config` dotfiles repo so it can be stowed to any machine:

```
config/
├── cloudflared/              # stow on active dev machine only
│   └── .cloudflared/
│       └── config.yml
├── shell/
├── nvim/
├── ...
```

Contents of `config.yml`:

```yaml
tunnel: dev-gateway
credentials-file: <HOME>/.cloudflared/<tunnel-id>.json

ingress:
  # Dev services — add/remove entries here, then restart cloudflared
  # - hostname: app1.domain.com
  #   service: http://localhost:3000

  # Catch-all: return 404 for unmatched hostnames (required by cloudflared)
  - service: http_status:404
```

Link it on the active dev machine:
```bash
cd ~/dev/config
stow -t ~ cloudflared
```

**Note**: `credentials-file` must be an absolute path. Update it after stowing if you switch machines (different home directory path).

## Step 4: Set Up the Service Daemon

### Fedora (systemd)
Create `/etc/systemd/system/cloudflared-dev.service`:

```ini
[Unit]
Description=cloudflared dev tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=<user>
ExecStart=/usr/local/bin/cloudflared tunnel run dev-gateway
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now cloudflared-dev
```

### macOS (launchd)
```bash
cloudflared service install
# Or create a plist manually at ~/Library/LaunchAgents/
```

## Step 5: Cloudflare Access Policy
In Cloudflare Zero Trust dashboard, create an Access application:
- **Application domain**: `*.domain.com`
- **Policy**: email OTP, or whichever auth method you prefer

This gates all wildcard subdomains behind authentication. Set once.

## Step 6: Verify
```bash
# Start a test server
python3 -m http.server 8080
```

Add to `~/.cloudflared/config.yml` (above the catch-all):
```yaml
  - hostname: test.domain.com
    service: http://localhost:8080
```

```bash
# Fedora
sudo systemctl restart cloudflared-dev

# macOS
# launchctl kickstart -k gui/$(id -u)/com.cloudflare.cloudflared
```

Visit `test.domain.com` — should prompt Cloudflare Access, then show the Python server.

---

## Day-to-Day Workflow

### Expose a dev server
1. Start the service: `npm run dev -- --host` (port 3000)
2. Edit `~/.cloudflared/config.yml`:
   ```yaml
     - hostname: myapp.domain.com
       service: http://localhost:3000
   ```
3. Restart cloudflared (`sudo systemctl restart cloudflared-dev`)
4. `myapp.domain.com` is live behind Cloudflare Access.

### Stop exposing
1. Remove or comment out the hostname entry
2. Restart cloudflared

### Naming convention
- Permanent homelab services: descriptive names (`gitea`, `registry`, `dashboard`)
- Ephemeral dev services: short project names (`myapp`, `preview`, `api`, `test`)
- SSH: prefixed (`ssh`, `ssh-fedora`, `ssh-mbp`)

---

## Moving the Dev Gateway to Another Machine

1. On the new machine:
   ```bash
   cloudflared tunnel login
   cloudflared tunnel create dev-gateway
   cd ~/dev/config && stow -t ~ cloudflared
   ```
2. Update `credentials-file` path in `config.yml` (new tunnel ID, new home path)
3. Update the wildcard CNAME in Cloudflare DNS to the new tunnel ID
4. Set up the service daemon (Step 4)

5. On the old machine:
   ```bash
   stow -t ~ -D cloudflared
   cloudflared tunnel delete dev-gateway
   # Remove the systemd/launchd service
   ```

---

## What Stays Unchanged
- **Homelab k3s** — all manifests, services, and tunnel routes remain as-is
- **Existing SSH tunnels** — `ssh.domain.com`, `ssh-fedora.domain.com`, `ssh-mbp.domain.com` keep their current remote-managed tunnel configs
- **Blog** — `domain.com` stays on Cloudflare Workers
- **This repo (homelab)** — no files are modified; the cloudflared config lives in the `config` dotfiles repo

## Future Considerations
- If cloudflared restarts become annoying, add Caddy between cloudflared and localhost for zero-downtime reloads
- If the homelab k3s setup feels like overhead later, revisit the Docker Compose migration plan (`plan/migration-k3s-to-docker.md`)
