# homelab

A single box that hosts long-running personal services, run with Docker Compose
and reached over Tailscale by default. All state is in named Docker volumes; all
config is in this repo. **[SPEC.md](SPEC.md) is the source of truth** for what runs
and why — this README is the runbook.

## Architecture

```
Internet → Cloudflare Edge → cloudflared tunnel ─┐
                                                  ├─→ homelab_net → registry
Tailnet devices → 100.65.77.63:<port> ───────────┘               → (future services)
              └─→ 100.65.77.63:8123 ─────────────────────────────→ home-assistant (host net)
```

- **The box:** i7-7th-gen laptop, 8 GB RAM, Debian, headless, on Tailscale.
- **Two ways in, no inbound ports:** Tailscale (the default — being on the tailnet
  *is* the auth) and a cloudflared tunnel (egress-only, for consciously-public
  services behind Cloudflare Access). See [SPEC.md](SPEC.md) §Access planes.

## Services

| Service        | Address / port         | State (volume)         | Plane             |
|----------------|------------------------|------------------------|-------------------|
| cloudflared    | — (the tunnel)         | none                   | n/a               |
| registry       | `100.65.77.63:30500`   | `homelab_registry_data`| Tailscale-private |
| home-assistant | `100.65.77.63:8123`    | `homelab_ha_data`      | Tailscale-private |

`100.65.77.63:30500` (`${REGISTRY_HOST}`) is the one canonical registry address —
there is no `registry.homelab` name. Home Assistant uses host networking for
mDNS/SSDP discovery, so it's reached on the host IP directly, not via the bridge.

## Quick start

Config not in git, set up once (see the runbooks below):

- `.env` — copy from `.env.example`, fill in.
- `cloudflared/<tunnel-id>.json` — the tunnel credentials (`docs/tunnel-setup.md`).

Then, from the box over Tailscale SSH:

```bash
ssh jun@100.65.77.63
cd <repo>
git pull && docker compose up -d
```

## Day-to-day

```bash
docker compose ps                     # what's running
docker compose logs -f <service>      # tail logs
docker compose up -d                  # apply compose.yaml changes / pull updates
docker compose restart <service>      # e.g. after editing cloudflared/config.yml
docker compose pull && docker compose up -d   # update images
docker compose down                   # stop the stack (volumes persist)
```

The deploy loop is intentionally manual: **SSH in, `git pull`, `docker compose
up -d`.** There's no remote control plane. Optionally you can drive it from the Mac
without exposing the daemon:

```bash
docker context create homelab --docker "host=ssh://jun@100.65.77.63"
docker --context homelab compose up -d
```

## Adding / changing services

- **Add a service:** `docs/add-a-service.md` (build on a dev machine → push to the
  registry → compose block → **decide the access plane** → `up -d`). Own images use
  version/SHA tags, never `:latest`.
- **Expose something publicly:** add a cloudflared ingress rule + DNS CNAME +
  Cloudflare Access policy. Default is Tailscale-private; public is opt-in per
  service. See [SPEC.md](SPEC.md) §Access planes.

Whenever a permanent service changes, update [SPEC.md](SPEC.md) first, then the code.

## Runbooks

| Doc | What |
|-----|------|
| [SPEC.md](SPEC.md) | Source of truth: goals, architecture, decisions |
| [docs/cleanup-k3s.md](docs/cleanup-k3s.md) | One-time k3s → Docker teardown (gated on a verified backup) |
| [docs/data-migration.md](docs/data-migration.md) | Restore PVC data into the named volumes |
| [docs/tunnel-setup.md](docs/tunnel-setup.md) | Create the locally-managed cloudflared tunnel |
| [docs/add-a-service.md](docs/add-a-service.md) | Steady-state workflow for new services |

The pre-migration k3s manifests are preserved on the **`legacy-k3s`** branch.
