# Homelab Specification

The source of truth for what the homelab is, how it's shaped, and why. When
something changes, **this file updates first; code follows.** Every other file in
the repo (`compose.yaml`, `cloudflared/config.yml`, the `docs/` runbooks) should
trace back to a section here.

Status: post-migration target state (k3s → Docker Compose).

---

## Goals

- A **hub that hosts long-running personal services** on one box, reachable over
  Tailscale by default.
- **All state in named Docker volumes, all config in git.** The repo declares the
  homelab; the box just runs it.
- Adding a **private** service is: edit `compose.yaml`, `docker compose up -d`,
  done. Adding a **public** one adds a cloudflared ingress rule and a Cloudflare
  Access policy on top — nothing more.
- Stay deliberately small. If a change is adding Kubernetes-shaped complexity back
  in, it's wrong.

## Non-goals

- No orchestrator (k3s, Nomad, Swarm). One box, one `compose.yaml`.
- No CI-to-homelab pipeline. The deploy loop is human-driven over SSH (§ Deploy model).
- No on-box builds. The box is RAM-constrained; it runs artifacts, it doesn't
  build them (see Decision: Pattern A).
- No reverse proxy (Caddy/nginx/Traefik) at this scale. cloudflared's own ingress
  does the only L7 routing needed.
- No public exposure by default. Public is opt-in, per service, per §ref Access planes.

---

## Architecture

```
Internet → Cloudflare Edge → cloudflared tunnel ─┐
                                                  ├─→ homelab_net (bridge) → registry
Tailnet devices ──→ <tailscale-ip>:<port> ───────┘                        → (future services)
                └─→ <tailscale-ip>:8123 ────────────────────────────────→ home-assistant (host net)
```

- **The box:** an i7-7th-gen laptop, 8 GB RAM, Debian, headless. Reachable over
  Tailscale SSH. Its stable Tailscale IP is the one canonical address for
  everything published off it.
- **`homelab_net`:** a user-defined bridge network. Services on it resolve each
  other by compose service name. Home Assistant is the deliberate exception — it
  uses host networking and is *not* on this bridge (see its service note).
- **Two ways in, no inbound ports:** Tailscale (the default auth plane) and the
  cloudflared tunnel (egress-only; opens no ports). See §Access planes.

### The registry address — one canonical name

There is **no `registry.homelab` DNS name; do not invent one.** The registry is
addressed as **`<tailscale-ip>:30500`** from every machine — the Mac, the
ThinkPad, and the homelab pulling its own images. Using the published Tailscale
port uniformly means the same image reference works regardless of who's pulling.

In this repo that address is carried in the **`REGISTRY_HOST`** env var
(`.env`, defaulting to `100.65.77.63:30500`). Image references use
`${REGISTRY_HOST}/<name>:<tag>`, never a bare literal and never a service-name
form like `registry:5000`. The compose service is still *named* `registry` on
`homelab_net`, but nothing references it by that name for pulls.

> The one place the literal IP is unavoidable is `/etc/docker/daemon.json` on the
> box (`insecure-registries`), because Docker's daemon config can't read env vars.
> That literal lives only in the cleanup runbook, not in the repo's service defs.

If you ever want the homelab to pull via an internal `registry:5000` name instead,
that's a deliberate change to raise — don't split the naming silently.

---

## Access planes — the private/public split

Every service sits on one or both planes. This is a **mechanical decision made per
service**, not inferred.

**Tailscale — private (the default).** Reachable only from tailnet devices. No
public DNS, no Cloudflare. Being on the tailnet *is* the auth. A service is on
this plane automatically just by running on the host; reached via
`<tailscale-ip>:<port>`. Registry, Home Assistant, and SSH live here.

**Cloudflared tunnel — public, behind Cloudflare Access.** Reachable at
`something.${BASE_DOMAIN}`, gated by a Cloudflare Access policy (email OTP or
similar). The tunnel egresses from the box, so no inbound ports open. A service is
on this plane **only if a cloudflared ingress rule exists for it.**

**The rule:**
- Default is Tailscale-private. Public exposure requires a *conscious* ingress
  rule. Never add one speculatively.
- A public route is **additive**, not a replacement — a Cloudflare-reachable
  service is still reachable over Tailscale.
- Decide per service by one question: *do I need to reach this from a device not
  on my tailnet (or share it)?* No → Tailscale only. Yes → ingress rule + Access
  policy.

**Locked plane assignments:**

| Service        | Plane                    | Why |
|----------------|--------------------------|-----|
| registry       | Tailscale-private, never public | Cloudflare Access breaks `docker push` — Docker auth doesn't do OAuth browser redirects. |
| home-assistant | Tailscale-private        | Reached only from the user's own tailnet devices; keeping it private is strictly better. |
| cloudflared    | n/a (is the tunnel)      | — |
| duri (planned) | undecided                | Defer with the rest of duri's spec. |

At migration time the ingress list has **no real routes** — only a commented
example and the `http_status:404` catch-all. Nothing currently needs a public door.

---

## Services

Four services. That's the whole homelab.

| Service        | Image                                          | Networking          | State             | Plane             |
|----------------|------------------------------------------------|---------------------|-------------------|-------------------|
| cloudflared    | `cloudflare/cloudflared:latest`                | `homelab_net`       | none              | n/a (is the tunnel) |
| registry       | `registry:2`                                   | published `30500:5000` | `registry_data` vol | Tailscale-private |
| home-assistant | `ghcr.io/home-assistant/home-assistant:stable` | `network_mode: host` | `ha_data` vol    | Tailscale-private |
| duri (planned) | `${REGISTRY_HOST}/duri:<tag>`                  | `homelab_net`       | tbd               | decide per §Access planes |

**cloudflared** — locally-managed tunnel. Runs
`tunnel --no-autoupdate --config /etc/cloudflared/config.yml run`. Mounts the
git-tracked `./cloudflared/config.yml` and the human-supplied, gitignored
credentials JSON, both read-only. On `homelab_net` so it can route to other
bridge services when a future ingress rule points at one.

**registry** — `registry:2` with `REGISTRY_STORAGE_DELETE_ENABLED=true`. Volume
`registry_data:/var/lib/registry`. Published `30500:5000`. Any service that pulls
from the local registry declares `depends_on: [registry]` for cold-start ordering.

**home-assistant** — `network_mode: host` (required for mDNS/SSDP device
discovery, same reason it was `hostNetwork: true` under k3s). Volume
`ha_data:/config`, `TZ=${TZ}`. Because it's on host networking it is **not** on
`homelab_net` and cannot resolve other services by compose DNS — this is expected
and accepted; HA doesn't pull from the registry or call other homelab services. A
future service that needs to talk *to* HA reaches it at `<tailscale-ip>:8123`.
**Do not move HA onto the bridge to "fix" this — it breaks device discovery.**

**duri (planned)** — the human's own service, referenced as
`${REGISTRY_HOST}/duri:<tag>`. Deferred until a small spec addition lands (port,
DB need, access plane). Don't scaffold beyond a commented placeholder; don't add a
cloudflared ingress rule for it by default.

### Anticipated future services (not built now)

Home Assistant's voice/media follow-ups (see `plan/home-assistant-followups.md`):
- **Music Assistant** — will also want host networking (playback discovery).
- **Wyoming** satellites (Whisper, Piper) — bridge-network services, no host net.

The current design blocks none of these. Don't build them now; just don't design
in a way that forecloses them.

---

## Constraints

- **8 GB RAM budget.** Everything runs on one modest box. This is the reason for
  no orchestrator, no on-box builds, and keeping the service count small.
- **Volume ownership.** State lives in named volumes (`registry_data`, `ha_data`).
  When restoring data into them, file ownership must match `PUID`/`PGID`.
- **Secrets.** `.env` (gitignored) and the cloudflared credentials JSON
  (human-supplied, gitignored) never enter git. The repo ships `.env.example`
  only. There is **no `TUNNEL_TOKEN`** in the new design (see Decisions).
- **Registry is plain HTTP over Tailscale.** Every Docker host that pulls from it
  — including the homelab itself — needs it in `insecure-registries`.

### `.env` keys

| Key             | Value / default        | Used by / status |
|-----------------|------------------------|------------------|
| `TZ`            | `Asia/Seoul`           | home-assistant (`TZ`), and future services |
| `REGISTRY_HOST` | `100.65.77.63:30500`   | image refs for own services (`${REGISTRY_HOST}/...`), docs |
| `BASE_DOMAIN`   | (human's domain)       | reserved — used by cloudflared ingress hostnames once a public route exists |
| `PUID`          | e.g. `1000`            | reserved — forward-looking for future services; **not** consumed by registry/HA (they run as root) |
| `PGID`          | e.g. `1000`            | reserved — as above |

`REGISTRY_HOST` is this repo's addition to the originally-scoped key set
(`PUID`, `PGID`, `TZ`, `BASE_DOMAIN`), so the canonical registry address is
declared in one place instead of hardcoded. `PUID`/`PGID`/`BASE_DOMAIN` are
carried now as forward-looking keys; no current service consumes them.

---

## Decisions (with rationale)

All **LOCKED** — do not re-open without asking.

- **Drop Gitea entirely.** GitHub holds source; the registry holds images. Gitea
  was doing a job nothing currently needs. Removing it also removes a Helm chart,
  a SQLite volume, and SSH port-publishing complexity.
- **Drop k3s-dashboard.** Already deprecated.
- **No Caddy.** cloudflared's ingress does the L7 hostname routing; Cloudflare
  terminates TLS and Cloudflare Access does auth. A reverse proxy would add a
  second config and a reload dance for zero benefit at this scale. It's an
  add-later tool (on-box TLS, or tunnel-restart downtime becoming annoying), not a
  starting component. Matches the ThinkPad dev gateway's cloudflared-only model.
- **Locally-managed cloudflared tunnel; ingress rules in a git-tracked config.**
  Not the dashboard-managed token-only style. Routes belong in the repo — a
  "declarative homelab" must actually declare where traffic goes. The config file
  is mounted into the container; the credentials JSON is human-supplied and
  gitignored.
- **This is a NEW tunnel, not a reconfig.** The old k3s cloudflared used a
  remote-managed `TUNNEL_TOKEN`. Locally-managed tunnels use no token — they
  authenticate with a credentials JSON from `cloudflared tunnel create`. The old
  `TUNNEL_TOKEN` is **discarded**, a brand-new tunnel is created, and the DNS
  CNAMEs are re-pointed to the new tunnel ID. No `TUNNEL_TOKEN` anywhere in the
  new design. Procedure: `docs/tunnel-setup.md`.
- **Registry over Tailscale, published `30500:5000`.** Not behind Cloudflare
  Access — Docker's push auth can't do OAuth browser redirects, which would break
  `docker push`. Tailscale is already an authenticated network. The Mac's existing
  `insecure-registries` + `docker push <tailscale-ip>:30500/...` habits are unchanged.
- **Pattern A for own services.** Build the image on a dev machine (Mac via
  apple/container, ThinkPad via Docker), push to `${REGISTRY_HOST}`, homelab pulls
  and runs it. The homelab repo references the image; it never holds source and
  never builds. Homelab = runs artifacts.
- **No `:latest` for own images.** Version tags (`duri:v1`) or git-SHA tags.
  `:latest` won't re-pull reliably on `up -d`.
- **Home Assistant stays `network_mode: host`.** Required for mDNS/SSDP discovery.

---

## Deploy / control model

There's no API-server-style remote control after migration. The loop is:

```
tailscale ssh into the box → git pull && docker compose up -d
```

Optional later upgrade: `docker context create homelab --docker "host=ssh://homelab"`
lets compose commands run from the Mac over SSH (feels like remote kubectl again)
without exposing the Docker daemon. Not built now. No CI-to-homelab — out of
scope, and it has a bootstrap problem.

---

## Operational runbooks

The human executes these; the repo only documents them.

- **`docs/cleanup-k3s.md`** — ordered, gated teardown of k3s: back up PVC data,
  human-verify the backup, uninstall k3s, install Docker, set the box's own
  `insecure-registries`, clean the Mac's kubeconfig.
- **`docs/data-migration.md`** — move backed-up volume data into named Docker
  volumes via a temp Alpine container; verify ownership vs `PUID`/`PGID`.
- **`docs/add-a-service.md`** — steady-state workflow: build on a dev machine →
  push to `${REGISTRY_HOST}` → add a compose block → **decide the access plane** →
  `docker compose up -d <service>`.
- **`docs/tunnel-setup.md`** — create the locally-managed tunnel, place the creds
  JSON on the box, add the DNS CNAME. Cross-references `plan/thinkpad-dev-gateway.md`
  (same pattern).

---

## Open questions

- Exact PVC directory names under `/var/lib/rancher/k3s/storage/` (HA vs
  registry) — read off the box; the cleanup runbook explains how to identify them.
- `duri` specifics: port, DB need, and access plane. Deferred until a spec
  addition lands.
- Whether the registry needs any data restored at all, or if every image is
  rebuildable from source and can simply be re-pushed.
