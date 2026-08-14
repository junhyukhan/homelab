# homelab

A single box that hosts long-running personal services, run with Docker Compose
and reached over Tailscale by default. All state is in named Docker volumes; all
config is in this repo. **[SPEC.md](SPEC.md) is the source of truth** for what runs
and why — this README is the runbook.

## Architecture

```
Internet → Cloudflare Edge → cloudflared tunnel ─┐
                                                  ├─→ homelab_net → registry
Tailnet devices → 100.65.77.63:30500 ────────────┤               → duri → Supabase cloud (egress)
              ├─→ https://jun-hp-spectre.tail114865.ts.net ─(tailscale serve · TLS)→ 127.0.0.1:3000 → duri
              ├─→ https://jun-hp-spectre.tail114865.ts.net:8443 ─(serve)→ 127.0.0.1:9091 → transmission
              └─→ 100.65.77.63:8123 ─────────────────────────────→ home-assistant (host net)

  torrent stack:  gluetun ──WireGuard──→ Windscribe (Japan) ──→ BitTorrent swarm
                     └── transmission shares its namespace; no other route exists
```

- **The box:** i7-7th-gen laptop, 8 GB RAM, Debian, headless, on Tailscale.
- **Two ways in, no inbound ports:** Tailscale (the default — being on the tailnet
  *is* the auth) and a cloudflared tunnel (egress-only, for consciously-public
  services behind Cloudflare Access). See [SPEC.md](SPEC.md) §Access planes.

## Services

| Service        | Address / port         | State (volume)         | Plane             |
|----------------|------------------------|------------------------|-------------------|
| cloudflared    | — (the tunnel)         | none                   | n/a               |
| registry       | `100.65.77.63:30500`   | `homelab_registry_data`| Tailscale-private (port bound to `${TAILSCALE_IP}`) |
| home-assistant | `100.65.77.63:8123`    | `homelab_ha_data`      | LAN + Tailscale (intentional), never public |
| duri           | `https://jun-hp-spectre.tail114865.ts.net` | none (data in Supabase cloud) | Tailscale-private, HTTPS via `tailscale serve` (container on loopback `127.0.0.1:3000`) |
| gerbera        | DLNA on the LAN (`:49494`, SSDP `:1900`) | `homelab_gerbera_data`; media read-only | LAN + Tailscale (intentional), never public |
| gluetun        | — (owns the torrent netns) | none                   | Tailscale-private, never public |
| transmission   | `https://jun-hp-spectre.tail114865.ts.net:8443` | `homelab_transmission_config` + `homelab_torrent_downloads` (binds `/srv/torrents`) | Tailscale-private via gluetun, never public |

`100.65.77.63:30500` (`${REGISTRY_HOST}`) is the one canonical registry address —
there is no `registry.homelab` name. Home Assistant uses host networking for
mDNS/SSDP discovery, so it's reached on the host IP directly, not via the bridge.

**transmission has no network of its own** — it runs in gluetun's namespace
(`network_mode: "service:gluetun"`), so all its traffic crosses the Windscribe
WireGuard tunnel and it goes dark if gluetun stops. Its UI is published *by
gluetun* on loopback and fronted by `tailscale serve` on **:8443** (duri holds
`/` on 443). Consequence worth knowing before you touch it: **recreating gluetun
means recreating transmission**, since the namespace belongs to the container
instance. See [docs/torrent.md](docs/torrent.md).

## Quick start

Config not in git, set up once (see the runbooks below):

- `.env` — copy from `.env.example`, fill in.
- `cloudflared/<tunnel-id>.json` — the tunnel credentials (`docs/tunnel-setup.md`).
- `torrent/gluetun.env` + `torrent/transmission.env` — WireGuard key material and
  the RPC password, both from their `.example` templates (`docs/torrent.md`).
  `/srv/torrents` must also exist on the box, or transmission refuses to start —
  that refusal is deliberate, see [SPEC.md](SPEC.md).

Then, from the box over Tailscale SSH:

```bash
ssh jun@100.65.77.63
cd ~/homelab
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

**duri's app secrets are pushed, not pasted.** `duri.env.example` is the contract —
the key *names* it declares are what ships and what gets checked:

```bash
scripts/push-duri-env.sh --dry-run   # names only; verifies the source has them all
scripts/push-duri-env.sh             # backs up the box's copy, then replaces it
```

Values move file-to-file and are never printed. `scripts/deploy-duri.sh` refuses to
deploy if the box is missing a declared key — a missing secret otherwise surfaces
as a runtime 503 that a human finds by tapping a button. Adding a key to the
example is how you add it to the deploy. The container only picks up a changed env
on recreate (`docker compose up -d --force-recreate duri`), which the deploy does.

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
  version/SHA tags, pinned inline in `compose.yaml`, never `:latest`.
- **Deploy/update duri** (the one build-on-dev app): `./scripts/deploy-duri.sh`
  from the Mac — one command does build → push → pin → reconcile → verify. Roll
  back with `--tag <old-sha>`. See SPEC.md §Deploy and the `deploy-duri` skill.
- **duri HTTPS (secure context):** duri is served over HTTPS via `tailscale serve`
  at `https://jun-hp-spectre.tail114865.ts.net` (needed for the PWA + Web Crypto).
  `./scripts/serve-duri.sh` (re)asserts and verifies that config; the container
  itself binds loopback only. See SPEC.md §Decisions "On-box TLS via tailscale serve".
- **Expose something publicly:** add a cloudflared ingress rule + DNS CNAME +
  Cloudflare Access policy. Default is Tailscale-private; public is opt-in per
  service. See [SPEC.md](SPEC.md) §Access planes.
- **Torrent stack (gluetun + transmission):** first-run setup and the **leak
  check** are in [docs/torrent.md](docs/torrent.md). Two scripts own its
  out-of-compose state — `./scripts/settings-transmission.sh` (peer port,
  UPnP/NAT-PMP off, LPD off, upload cap) and `./scripts/serve-transmission.sh`
  (HTTPS on :8443). **Re-run the leak check after any change to that stack.**

Whenever a permanent service changes, update [SPEC.md](SPEC.md) first, then the code.

## Runbooks

| Doc | What |
|-----|------|
| [SPEC.md](SPEC.md) | Source of truth: goals, architecture, decisions |
| [docs/bootstrap.md](docs/bootstrap.md) | Stand up the box from a clean Debian install to a running stack |
| [docs/tunnel-setup.md](docs/tunnel-setup.md) | Create the locally-managed cloudflared tunnel |
| [docs/add-a-service.md](docs/add-a-service.md) | Steady-state workflow for new services |
| [docs/torrent.md](docs/torrent.md) | Torrent stack: Windscribe prerequisites, first run, **leak check** |

The pre-migration k3s manifests are preserved on the **`legacy-k3s`** branch.
