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

- No orchestrator (k3s, Nomad, Swarm). One box, one compose *stack*.
  > **Amended 2026-08-14.** This used to read "one `compose.yaml`". It is now one
  > stack assembled from more than one file: the root `compose.yaml` pulls in
  > `torrent/compose.yaml` via compose's top-level `include:`. The intent behind
  > the non-goal was *no orchestrator, no control plane* — not a literal one-file
  > rule — and the torrent stack has a hard reason to sit in its own file (every
  > service in it must be inside gluetun's network namespace, and a reader must
  > not be able to add a sibling service without noticing that). `docker compose
  > up -d` at the root still brings up everything, so the deploy loop is unchanged.
  > See §Decisions and [`docs/decisions/torrent-vpn.md`](docs/decisions/torrent-vpn.md).
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
Tailnet devices ──→ <tailscale-ip>:30500 ────────┤                        → duri ──→ Supabase cloud (egress)
                ├─→ https://<box>.<magicdns> ──(tailscale serve · on-box TLS)──→ 127.0.0.1:3000 ─┘
                ├─→ https://<box>.<magicdns>:8443 ─(tailscale serve)──→ 127.0.0.1:9091 ─┐
                └─→ <tailscale-ip>:8123 ────────────────────────────────→ home-assistant (host net)
                                                                                         │
   ┌─────────────────────────────────────────────────────────────────────────────────────┘
   │  gluetun (netns owner) ──WireGuard──→ Windscribe (Japan) ──→ BitTorrent swarm
   └─→ transmission  ── network_mode: service:gluetun ── has NO network stack of its own
              │
              │  writes ${TORRENT_DOWNLOADS}/complete   (incomplete/ is a sibling)
              ▼
   Home LAN ──→ gerbera (host net · SSDP multicast) ──reads ro──→ /media
       └─→ Hisense M2 Pro projector (VIDAA · 콘텐츠 공유)
           NOTE: shares the torrent stack's VOLUME, never its NETWORK.
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

> **Why the planes are what they are:** [`docs/decisions/access-planes.md`](docs/decisions/access-planes.md)
> — duri's on-box TLS (and the silent PWA breakage that forced it), and why Home Assistant's LAN
> reachability is intended rather than an oversight to harden. This section states the current fact;
> that record holds the reasoning.

**Tailscale — private (the default).** Reachable only from tailnet devices. No
public DNS, no Cloudflare. Being on the tailnet *is* the auth. A service is on
this plane automatically just by running on the host; reached via
`<tailscale-ip>:<port>`. Registry, Home Assistant, and SSH live here.

A service that needs a **secure context** (browser HTTPS — required for PWA
service workers and Web Crypto) is fronted by **`tailscale serve`** at
`https://<box>.<magicdns>`, which terminates TLS on the box with an
auto-provisioned Let's Encrypt cert and proxies to a loopback port — still
tailnet-only, no public exposure. **duri** uses this (see §Services and the
on-box-TLS decision); plain `<tailscale-ip>:<port>` HTTP is not a secure context.

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
| registry       | Tailscale-private, never public | Cloudflare Access breaks `docker push` (no OAuth redirects). Published port is bound to `${TAILSCALE_IP}` only, so the box's home-LAN interface can't reach the unauthenticated registry. |
| home-assistant | LAN + Tailscale (intentional), never public | Reachable from both the home LAN and the tailnet, on purpose — housemates use it on the LAN, the human reaches it off-network over Tailscale. Host networking binds `:8123` on all host interfaces, which is exactly what's wanted here. No public (Cloudflare) route. Do **not** scope it to the tailnet with `server_host` / a firewall — that would break intended LAN access. |
| cloudflared    | n/a (is the tunnel)      | — |
| duri           | Tailscale-private, never public | Personal two-person app; both partners reach it over Tailscale (same as HA), but over **HTTPS via `tailscale serve`** at `https://<box>.<magicdns>` — duri is a PWA and needs a secure context. The container port is bound to **loopback** (`127.0.0.1:3000`); serve is the only tailnet-facing door. Its Supabase-cloud backend is reached by egress — nothing inbound. A public route is a possible future upgrade (cloudflared ingress), not the current design. |
| gluetun        | Tailscale-private, never public | Owns the torrent namespace. Publishes transmission's UI on **loopback** (`127.0.0.1:9091`) only. Its *egress* does not use the box's ISP route at all — it goes out over WireGuard to Windscribe. Never gets a cloudflared ingress: a public door into a VPN namespace defeats the point of the namespace. |
| gerbera        | LAN + Tailscale (intentional), never public | DLNA media server for the living-room projector (Hisense M2 Pro, **VIDAA OS**), which cannot join the tailnet — VIDAA is a closed ecosystem with no Jellyfin/Kodi/VLC client, so the LAN is the only path to it. Discovery is **SSDP multicast**, which a docker bridge does not carry, so `network_mode: host` is *required* — the same forced exception as Home Assistant, for the same class of reason. Host networking binds every interface, so LAN reachability is a consequence of the protocol, not a preference. Mitigated by disabling the admin UI (see §Media serving). Never public: a DLNA server has no business on the internet. |
| transmission   | Tailscale-private, never public | Has **no network stack of its own** (`network_mode: service:gluetun`), so it has no plane independent of gluetun's — this is the containment guarantee, not a convenience. Reached over Tailscale at **`https://<box>.<magicdns>:8443`** via a second `tailscale serve` mount. RPC is password-protected *in addition to* the tailnet boundary. |

At migration time the ingress list has **no real routes** — only a commented
example and the `http_status:404` catch-all. Nothing currently needs a public door.

---

## Services

Six services. That's the whole homelab.

| Service        | Image                                          | Networking          | State             | Plane             |
|----------------|------------------------------------------------|---------------------|-------------------|-------------------|
| cloudflared    | `cloudflare/cloudflared:latest`                | `homelab_net`       | none              | n/a (is the tunnel) |
| registry       | `registry:2`                                   | published `${TAILSCALE_IP}:30500:5000` | `registry_data` vol | Tailscale-private |
| home-assistant | `ghcr.io/home-assistant/home-assistant:stable` | `network_mode: host` | `ha_data` vol + git-tracked `./ha/packages` (ro) | LAN + Tailscale (intentional), never public |
| duri           | `${REGISTRY_HOST}/duri:<tag>`                  | `homelab_net`, published `127.0.0.1:3000`; HTTPS via `tailscale serve` | none (stateless; data in Supabase cloud) | Tailscale-private |
| gerbera        | `gerbera/gerbera:3.2.1`                        | **`network_mode: host`** (SSDP multicast) | `gerbera_data` vol; media read-only | LAN + Tailscale (intentional), never public |
| gluetun        | `qmcgaw/gluetun:v3.41.3`                       | `homelab_net`, published `127.0.0.1:9091`; **owns the torrent netns** | none | Tailscale-private |
| transmission   | `lscr.io/linuxserver/transmission:4.1.3-r0-ls357` | **`network_mode: service:gluetun`** — no stack of its own | `transmission_config` vol + `torrent_downloads` bind-volume | Tailscale-private (via gluetun) |

**cloudflared** — locally-managed tunnel. Runs
`tunnel --no-autoupdate --config /etc/cloudflared/config.yml run`. Mounts the
git-tracked `./cloudflared/config.yml` and the human-supplied, gitignored
credentials JSON, both read-only. On `homelab_net` so it can route to other
bridge services when a future ingress rule points at one.

**registry** — `registry:2` with `REGISTRY_STORAGE_DELETE_ENABLED=true`. Volume
`registry_data:/var/lib/registry`. Published as `${TAILSCALE_IP}:30500:5000` —
bound to the tailnet interface, **not** `0.0.0.0`, so this unauthenticated HTTP
registry (with delete enabled) isn't exposed on the box's home LAN. Any service
that pulls from the local registry declares `depends_on: [registry]` for
cold-start ordering.

**home-assistant** — `network_mode: host` (required for mDNS/SSDP device
discovery, same reason it was `hostNetwork: true` under k3s). Volume
`ha_data:/config`, `TZ=${TZ}`, plus a **read-only bind of `./ha/packages`** at
`/config/packages` (git-tracked declarative config, merged via HA's `packages:`
feature — see §HA config: the volume/git split). Because it's on host networking it is **not** on
`homelab_net` and cannot resolve other services by compose DNS — this is expected
and accepted; HA doesn't pull from the registry or call other homelab services. A
future service that needs to talk *to* HA reaches it at `<tailscale-ip>:8123`.
**Do not move HA onto the bridge to "fix" this — it breaks device discovery.**
Host networking also means `:8123` listens on every host interface, including the
home LAN — and that's **intended**: HA is meant to be reachable both on the home LAN
(for housemates) and over Tailscale (for the human off-network). It is never public.
Do **not** scope it to the tailnet with `server_host` or a host firewall — that
would break the intended LAN access.

**duri** — the human's couples-finance app (Next.js PWA), referenced as
`${REGISTRY_HOST}/duri:<tag>`. Built on a dev machine and pushed to the registry per
Pattern A; the box only runs it. **Stateless on the box:** its database, auth
(Supabase Auth + Postgres RLS), realtime, and file storage all live in **Supabase
cloud** (Seoul), reached by egress — so duri has **no local volume**. Published on
**`127.0.0.1:3000`** (loopback; Next serves on `3000` in-container) and fronted by
**`tailscale serve`** at `https://<box>.<magicdns>`, which terminates TLS on the
box and proxies to that loopback port. duri is a **PWA** and so needs a **secure
context** (HTTPS) — for the service worker and `crypto.randomUUID`; plain HTTP on
the Tailscale IP is not one, which silently broke the logger (2026-07-17), so HTTPS
is now the only door. serve config is asserted by `scripts/serve-duri.sh`.
**Tailscale-private:** both partners reach it over Tailscale, the same way they
reach Home Assistant — **no cloudflared ingress**. Server-only
secrets (Supabase service-role key, `DATABASE_URL`, OpenAI key) come from a
gitignored `duri.env` consumed via `env_file` (kept out of the shared `.env`); the
`NEXT_PUBLIC_*` Supabase URL + anon key are baked into the image at build time and
so aren't runtime env here. Going public later is an additive cloudflared ingress +
Cloudflare Access decision — not designed in now.

### The torrent stack — gluetun + transmission

Lives in its own file, [`torrent/compose.yaml`](torrent/compose.yaml), pulled into the
root stack by compose `include:`. Purpose: run BitTorrent so that **every packet it
sends or receives goes through the Windscribe VPN tunnel, with no code path that can
fall back to the home ISP connection.**

**The namespace-sharing guarantee — the whole design rests on this.**
`transmission` is declared `network_mode: "service:gluetun"`. It therefore has **no
network interfaces of its own**: it shares gluetun's Linux network namespace, whose
only routes are `lo` and gluetun's WireGuard `tun0`. This is not a firewall rule, a
policy, or a "leak protection" feature that can be misconfigured — transmission is
*structurally incapable* of reaching the ISP, in the same way a process with no
socket cannot open a connection. Two consequences follow, and both are load-bearing:

- **If gluetun stops, transmission loses all connectivity** — it does not fall back,
  it goes dark. That is the desired failure mode, and it is the second acceptance
  test in the leak-check runbook. `depends_on` with `service_healthy` also means
  transmission won't *start* until the tunnel is actually up.
- **`ports:` and `networks:` may appear on `gluetun` ONLY.** A container using
  `network_mode: service:` has no stack to publish from; compose does not reject
  these keys on such a service, it **silently ignores them** — the UI would simply
  never be reachable and nothing would say why. Both keys are commented as such at
  the transmission block. Anything later added to this stack that needs the tunnel
  gets `network_mode: "service:gluetun"` too, and publishes via gluetun.

**gluetun** — `VPN_SERVICE_PROVIDER=windscribe`, `VPN_TYPE=wireguard`,
`SERVER_REGIONS=${VPN_SERVER_REGIONS}` (default `Japan` — lowest latency from Korea).
Needs `cap_add: NET_ADMIN` and `/dev/net/tun` to create the WireGuard interface. The
three pieces of key material (`WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`,
`WIREGUARD_PRESHARED_KEY`) come from a gitignored `torrent/gluetun.env` — they are the
only secrets in the stack and they are never in git. Windscribe **requires** the
preshared key to be set; obtain all three from <https://windscribe.com/getconfig/wireguard>.
Non-secret VPN config stays inline in `torrent/compose.yaml` so the routing is
readable in git.

> **`SERVER_REGIONS` values are gluetun's, not Windscribe's marketing names**, and
> they vary by subscription tier ("Build a Plan" accounts only reach purchased
> regions). The authoritative list is the image's own:
> `docker run --rm qmcgaw/gluetun:v3.41.3 format-servers -windscribe`. A wrong value fails
> at startup with a server-not-found error — loud, not silent. `VPN_SERVER_REGIONS`
> is a shared-`.env` key so the region can change without editing compose.
> **Verified 2026-08-14:** `Japan` is valid and resolves to a Tokyo exit (M247).

**transmission** — `lscr.io/linuxserver/transmission`, pinned to an explicit upstream
version tag (`4.1.3-r0-ls357`) rather than `:latest`. Note this is *stricter* than
cloudflared (`:latest`) and Home Assistant (`:stable`): a torrent client's settings
semantics are exactly the kind of thing a silent major-version bump changes underneath
a config file, and this stack's correctness depends on those settings. Two volumes:

- `transmission_config:/config` — a named volume, per the usual state rule.
- `torrent_downloads:/downloads` — a **named volume that binds to a host path**
  (`type: none, o: bind, device: ${TORRENT_DOWNLOADS}`, default `/srv/torrents`).
  Bulk media does not belong inside `/var/lib/docker`, and this form makes the disk
  swappable later without touching compose. **Why this form and not a plain
  `volumes: - /srv/torrents:/downloads` bind:** a plain bind mount whose host path is
  missing is *silently created as an empty root-owned directory* by Docker — so the
  day an external disk fails to mount, transmission would cheerfully fill the box's
  internal SSD instead, and nothing would report it. The bind-volume form **refuses
  to start the container** (`failed to mount local volume: … no such file or
  directory`). Verified on the box, not assumed. There is **no external disk today**;
  `/srv/torrents` is on the 238 GB internal NVMe (~200 G free) and the runbook's
  `mkdir` step is what makes it exist.

Settings that BitTorrent-over-VPN correctness depends on — **fixed peer port, UPnP and
NAT-PMP off, Local Peer Discovery off, a global upload cap** — are *not* env vars in
this image; they live in `/config/settings.json`, which transmission **rewrites on
shutdown**, so hand-editing a running container's copy is silently discarded.
`scripts/settings-transmission.sh` is therefore the git-tracked source of truth for
them, asserted over `transmission-remote` (the same "a script is the source of truth
for out-of-compose state" pattern `serve-duri.sh` established). Why each matters:

- **UPnP/NAT-PMP off** — port-mapping requests would be aimed at the *router* and are
  a classic way for a client to announce itself outside the tunnel. Also pointless
  here: the box publishes no inbound ports by design.
- **Local Peer Discovery off** — LPD multicasts on the local network, i.e. the home
  LAN, which is precisely the leak the tunnel exists to prevent.
- **Fixed peer port** — a stable port is a prerequisite for adding Windscribe
  ephemeral port forwarding later (out of scope now, see below) and keeps the
  behaviour reproducible run-to-run.
- **Global upload cap** — thermal, not network: sustained seeding pins the CPU on a
  7th-gen laptop chassis that also runs Home Assistant and duri.

RPC is password-protected via the `USER`/`PASS` env vars in a gitignored
`torrent/transmission.env`. **Do not put credentials into `settings.json` by hand** —
the image's docs are explicit that doing so prevents s6 from stopping transmission
cleanly. Two whitelists also have to be widened or the UI is unreachable *through
`tailscale serve`* in two different, confusingly-worded ways: `rpc-whitelist` sees the
request's source as the docker bridge gateway rather than `127.0.0.1` (**403
Unauthorized IP Address**), and `rpc-host-whitelist` sees `Host:
<box>.<magicdns>` (**421 Misdirected Request**). `WHITELIST` and `HOST_WHITELIST`
handle these; both are narrow allowlists, not `*`.

**Access path** — `tailscale serve` on a **second HTTPS port, 8443**:
`https://<box>.<magicdns>:8443` → `127.0.0.1:9091`, asserted by
`scripts/serve-transmission.sh`. It has to be a second port because **duri already
owns `/` on 443**; re-serving the root would replace duri's mount and take duri down.
A path prefix (`--set-path /transmission`) was rejected: transmission serves and
redirects to absolute `/transmission/web/` paths, which collide with serve's
prefix-stripping. The 443/8443/10000 restriction people remember applies to
**Funnel**, not serve — serve accepts any port; 8443 is chosen by convention.

**Leak-check procedure: [`docs/torrent.md`](docs/torrent.md)** — first-run setup plus
the three assertions (exit IP is Windscribe's, transmission goes dark when gluetun
stops, UI is tailnet-only). Run it after any change to this stack.

### Media serving — gerbera (DLNA)

Serves finished downloads to the living-room projector. Lives in the **root**
`compose.yaml`, deliberately **not** in `torrent/compose.yaml`.

**The rule that defines this service: it shares the torrent stack's *volume*,
never its *network*.** Gerbera reads the same files transmission writes, but its
traffic must go over the LAN to the projector. Putting it in gluetun's namespace
would make it unreachable from the living room *and* would tunnel a
living-room video stream through Tokyo. Volume sharing is the intended coupling;
network sharing would be a bug.

**Why `network_mode: host` is forced, not chosen.** DLNA discovery is SSDP
multicast (`239.255.255.250:1900`). Docker bridge networks do not carry multicast
to the LAN, so a bridged Gerbera is simply never discovered — it would appear to
"work" while being invisible to the projector. This is the same forced exception
Home Assistant has for mDNS/SSDP, and it carries the same consequence: **no
`ports:` key**, because host networking ignores it (compose does not error — the
same silent-failure shape as the `network_mode: service:` trap in the torrent
stack). Both are commented inline.

**The client constrains the design.** The projector is a Hisense M2 Pro running
**VIDAA U7.6**, a closed OS: no Jellyfin, Kodi or VLC client exists for it. Its
built-in **콘텐츠 공유** ("content sharing") menu is a DLNA browser, which is why
DLNA — rather than a media server with a native app — is the integration point.
Plex does have a VIDAA app, but was rejected: direct-play failures on VIDAA are
widely reported, and a failed direct play means *server-side transcoding*, which
is precisely the sustained CPU load the thermal budget forbids. DLNA direct-plays
or fails honestly; it never quietly costs CPU.

**Config is a git-tracked file, and the admin UI is off.** Unlike transmission —
whose `settings.json` is rewritten on shutdown, forcing the asserter-script
pattern — Gerbera does not rewrite its `config.xml` at runtime (state lives in a
separate SQLite DB). So the file itself can be the source of truth, mounted
read-only from `media/gerbera/config.xml`. The admin UI is **disabled**
(`<ui enabled="no"/>`): host networking would otherwise expose an unauthenticated
admin panel on the home LAN with no way to bind it to loopback. Disabling it costs
nothing — media still serves, and the library stays current via **inotify
autoscan** declared in the config rather than by clicking Rescan in a browser.

**The UDN is pinned in git.** Gerbera generates a random UUID per config; a
changing UDN makes the projector treat the server as brand new each restart,
losing its place in 콘텐츠 공유. It is fixed in the tracked `config.xml`.

**What it serves.** `${TORRENT_DOWNLOADS}/complete` mounted **read-only** at
`/media`. Read-only is deliberate: a DLNA server has no reason to modify media,
and it means a bug or compromise there cannot touch the library. It points at
`complete/` specifically — **not** the parent — because transmission writes
in-progress files to a sibling `incomplete/` directory (an image default, already
enabled) and moves them on completion. Same filesystem, so completion is an atomic
rename rather than a copy. Pointing Gerbera at the parent would surface
half-written files in 콘텐츠 공유 as broken, unplayable entries.

**Known limitation: subtitles.** DLNA's handling of external `.srt` files is
unreliable and varies by renderer. Media with *embedded* subtitle tracks is the
path that works. If external subtitles turn out to matter, that is the trigger to
reconsider a Google TV dongle + Jellyfin, not to add a transcoding server here.

### HA config: the volume/git split

Home Assistant gets config from **two places, and the boundary is deliberate**:

| Location | Holds | Written by |
|---|---|---|
| `ha_data` volume (`/config`) | **Onboarding state** — integrations, credentials, device/entity registry, recorder DB | HA itself, via the browser |
| `./ha/packages` → `/config/packages` (**ro**, git) | **Declarative config** — things a decision put in place | A human, in this repo |

The rule: *if its silent disappearance would go unnoticed, it belongs in git.* A
credential HA obtained through an OAuth flow is state and belongs in the volume. A
`rest_command` carrying a hardcoded device IP is a decision, and burying it in a Docker
volume means a volume restore would delete it with nothing to say so.

This is the same pattern as gerbera's `config.xml` — a file HA does not rewrite can be
the source of truth in git, unlike transmission's `settings.json`, which is rewritten on
shutdown and therefore needs the asserter-script pattern instead.

Mechanically it needs **one line** in the volume's `configuration.yaml`, which is
onboarding-side and therefore not in git:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

First occupant is `ha/packages/wiim.yaml` (living-room audio input switching). See
[`docs/decisions/living-room-audio.md`](docs/decisions/living-room-audio.md).

### Anticipated future services (not built now)

Home Assistant's voice/media follow-ups (see `plan/home-assistant-followups.md`):
- **Music Assistant** — will also want host networking (playback discovery).
- **Wyoming** satellites (Whisper, Piper) — bridge-network services, no host net.

**duri public door (planned, curated).** A second, additive entry point to duri for
a **family member on a different household** who shouldn't be forced onto Tailscale:
a `cloudflared` ingress rule (`duri.${BASE_DOMAIN}` → `http://duri:3000` over
`homelab_net`) behind a **Cloudflare Access** policy (Google IdP, email allowlist,
long session). The tailnet door (`tailscale serve`) stays the primary, end-to-end
path for the two owners; the public door is the RLS-isolated, Access-gated way in
for curated non-tailnet users. Access is warranted here — home-hosted backend +
financial data means a perimeter so RLS isn't the sole boundary. App-side external-
household onboarding is the real work (tracked in duri's `build/progress.md`); the
homelab side is just the ingress rule + Access policy when it's picked up.

**Windscribe ephemeral port forwarding (out of scope, deliberately).** Without a
forwarded port transmission is connectable *outbound only* — it can reach peers that
accept connections but no peer can initiate to it, which costs swarm performance and
makes it a partial ("no-incoming") peer. The fix is Windscribe's ephemeral port
forwarding (e.g. the `ws-ephemeral` helper), which needs **renewal every 7 days** —
a standing automation, which is exactly the kind of thing this repo asks about before
adding. It is **compatible with the no-inbound-ports design**: the forwarded port is
opened at Windscribe's edge and arrives *inside the tunnel*, so the box still opens
nothing on the home router. Adding it later means the port becomes a
`FIREWALL_VPN_INPUT_PORTS` value on gluetun plus a matching transmission peer port —
which is why the peer port is fixed and declared now rather than left random.

The current design blocks none of these. Don't build them now; just don't design
in a way that forecloses them.

---

## Constraints

- **8 GB RAM budget.** Everything runs on one modest box. This is the reason for
  no orchestrator, no on-box builds, and keeping the service count small.
  Measured 2026-08-14 before adding the torrent stack: 7.6 Gi total, **6.3 Gi
  available**, containers totalling ~578 MB (home-assistant 479, duri 74,
  registry 25). gluetun (~30 MB) + transmission (~100 MB idle) fit with wide
  margin; transmission's RAM grows with the number of active torrents, so that
  count — not the container itself — is the thing to watch.
- **CPU/thermal budget is tighter than the RAM budget.** A 7th-gen laptop chassis
  running sustained seeding will heat-soak. This is why the upload cap exists, and
  why it is a *thermal* setting rather than a bandwidth one. **Measured 2026-08-14:**
  gluetun uses the **kernelspace** WireGuard implementation on this box
  (`[wireguard] Using available kernelspace implementation`), not userspace
  `wireguard-go` — so encryption is on the cheap path and there is more headroom
  than the worst case. Re-check that log line after a kernel or image change.
- **Volume ownership.** State lives in named volumes (`registry_data`, `ha_data`,
  `transmission_config`, and the bind-backed `torrent_downloads`).
  When restoring data into them, file ownership must match `PUID`/`PGID`.
  transmission is a linuxserver image and **does** honour `PUID`/`PGID` — the first
  service here that does, which is what those long-reserved keys were for.
- **Secrets.** `.env` (gitignored), the per-app `duri.env` (gitignored), and the
  cloudflared credentials JSON (human-supplied, gitignored) never enter git. The repo
  ships `.env.example` only. There is **no `TUNNEL_TOKEN`** in the new design (see
  Decisions).
- **Registry is plain HTTP over Tailscale.** Every Docker host that pulls from it
  — including the homelab itself — needs it in `insecure-registries`.

### `.env` keys

| Key             | Value / default        | Used by / status |
|-----------------|------------------------|------------------|
| `TZ`            | `Asia/Seoul`           | home-assistant (`TZ`), and future services |
| `REGISTRY_HOST` | `100.65.77.63:30500`   | image refs for own services (`${REGISTRY_HOST}/...`), docs |
| `BASE_DOMAIN`   | (human's domain)       | reserved — used by cloudflared ingress hostnames once a public route exists |
| `PUID`          | e.g. `1000`            | **now consumed** by transmission (a linuxserver image); still not by registry/HA, which run as root |
| `PGID`          | e.g. `1000`            | **now consumed** by transmission — as above |
| `TORRENT_DOWNLOADS` | `/srv/torrents`    | host path behind the `torrent_downloads` bind-volume. Must **exist on the box** or transmission refuses to start (by design). Point it at an external disk's mountpoint when there is one |
| `VPN_SERVER_REGIONS` | `Japan`           | gluetun `SERVER_REGIONS`. Valid values come from `docker run --rm qmcgaw/gluetun:v3.41.3 format-servers -windscribe`, and depend on the Windscribe plan tier |
| ~~`DURI_TAG`~~  | —                      | **retired** — duri's version is now pinned **inline** in `compose.yaml` (git SHA), like every other service. A leftover `DURI_TAG` in `.env` is harmless/unused; drop it when convenient |

duri's own **application** secrets (`SUPABASE_SERVICE_ROLE_KEY`, `DATABASE_URL`,
`OPENAI_API_KEY`) do **not** live in the shared `.env`. They sit in a separate
gitignored `duri.env` consumed by that service's `env_file`, so app secrets stay
scoped to the app.

**`duri.env.example` is the contract, not a doc.** Two scripts read the key *names*
from it: `push-duri-env.sh` ships exactly those keys, and `deploy-duri.sh`
refuses to deploy when the box is missing one. Adding a key there is how you add
it to the deploy. It said `ANTHROPIC_API_KEY` until 2026-08-08 — a key duri reads
nowhere — while the key it actually needs (`OPENAI_API_KEY`, the voice-logging
parse seam, decided 2026-07-29) was undeclared and absent from the box. That is
the failure this contract exists to make impossible: a stale template is worse
than none, because reading it is the *correct* instinct. With `DURI_TAG` retired, the shared `.env` carries only
non-secret substitution vars (`TZ`, `REGISTRY_HOST`, `TAILSCALE_IP`).

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
- **On-box TLS via `tailscale serve`, not Caddy** (added 2026-07-17). duri is a
  PWA and needs a **secure context** (HTTPS) for its service worker and Web Crypto
  (`crypto.randomUUID`); plain HTTP on the Tailscale IP is not a secure context and
  silently broke the logger's Save button. `tailscale serve` delivers exactly the
  "add-later on-box TLS" the No-Caddy note anticipated — **without** adding Caddy:
  it terminates TLS on the box with an auto-provisioned Let's Encrypt cert for the
  node's MagicDNS name and proxies to `127.0.0.1:3000`, tailnet-only, no public
  exposure, and no separate reverse-proxy config/reload (it's part of tailscaled).
  Prereqs: MagicDNS + HTTPS certs enabled in the tailnet, and a one-time
  `sudo tailscale set --operator=$USER` on the box so serve is managed without
  root. The serve config lives in tailscaled state (not compose), so
  **`scripts/serve-duri.sh` is the git-tracked source of truth** that reasserts it.
  cloudflared stays the plane for anything *public* — serve is tailnet-only.
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
- **Registry over Tailscale, published `${TAILSCALE_IP}:30500:5000`.** Not behind Cloudflare
  Access — Docker's push auth can't do OAuth browser redirects, which would break
  `docker push`. Tailscale is already an authenticated network. The published port
  is bound to `${TAILSCALE_IP}` (not `0.0.0.0`) so it stays off the home LAN. The
  Mac's existing `insecure-registries` + `docker push <tailscale-ip>:30500/...`
  habits are unchanged.
- **Pattern A for own services.** Build the image on a dev machine (Mac via
  apple/container, ThinkPad via Docker), push to `${REGISTRY_HOST}`, homelab pulls
  and runs it. The homelab repo references the image; it never holds source and
  never builds. Homelab = runs artifacts.
- **No `:latest` for own images.** Version tags (`duri:v1`) or git-SHA tags.
  `:latest` won't re-pull reliably on `up -d`.
- **Home Assistant stays `network_mode: host`.** Required for mDNS/SSDP discovery.
- **Torrent traffic is contained by a shared network namespace, not by rules**
  (added 2026-08-14). transmission runs `network_mode: "service:gluetun"`, so it has
  no interfaces beyond gluetun's WireGuard tunnel and cannot route to the ISP even
  if misconfigured. Chosen over a firewall/killswitch approach because a namespace
  has no failure mode where a rule is missing, mis-ordered, or flushed. The direct
  cost is the `ports:`/`networks:`-on-gluetun-only constraint, which compose enforces
  by *silence* rather than by error — hence the inline comments. See
  [`docs/decisions/torrent-vpn.md`](docs/decisions/torrent-vpn.md).
- **The torrent stack is a separate compose file, included** (added 2026-08-14).
  `torrent/compose.yaml` + root `include:`. Keeping the namespace-sharing services
  in one file makes the guarantee legible and makes it hard to add a service to the
  stack without confronting it. It stays *one* stack — `docker compose up -d` at the
  root is unchanged — so this is not a second control plane. Amends the "one
  `compose.yaml`" wording in §Non-goals.
- **Transmission's UI gets its own `tailscale serve` port, 8443** (added 2026-08-14).
  duri already holds `/` on 443; re-serving root would silently replace duri's mount.
  A `--set-path` prefix breaks on transmission's absolute `/transmission/web/`
  redirects. Serve (unlike Funnel) is not restricted to 443/8443/10000, so the port
  is a convention choice, not a constraint.
- **No public route for anything in the torrent stack, ever.** A cloudflared ingress
  into a VPN namespace would defeat the namespace. This is a standing exception
  alongside the registry's.
- **DLNA (gerbera) for the projector, not Plex or Jellyfin** (added 2026-08-15). The
  Hisense M2 Pro runs VIDAA, a closed OS with no Jellyfin/Kodi/VLC client. Plex has a
  VIDAA app but reported direct-play failures there mean server-side transcoding, which
  the thermal budget forbids. DLNA is what the projector's 콘텐츠 공유 menu already
  speaks. `network_mode: host` is **forced** by SSDP multicast, which docker bridges
  do not carry — so LAN exposure is a protocol consequence, mitigated by disabling the
  admin UI. Gerbera shares the torrent stack's **volume, never its network**: media
  goes to the living room over the LAN, not through Windscribe.
  See [`docs/decisions/dlna-media.md`](docs/decisions/dlna-media.md).
- **Declarative HA config is git-tracked and bind-mounted; onboarding state stays in the
  volume** (added 2026-08-16). HA config was previously all volume-resident, which is right
  for onboarding but wrong for config a decision put in place — it would vanish on a volume
  restore with nothing to notice. `./ha/packages` is now mounted read-only at
  `/config/packages` and merged via HA's `packages:` feature. Same pattern as gerbera's
  `config.xml`; the split is specified in §HA config: the volume/git split.
- **The living-room speaker is driven through the WiiM, not switched at the amp**
  (added 2026-08-16). The Marshall Acton III is a dumb amp with a *physical* input selector
  no software can reach, so the projector's Bluetooth was re-pointed at the WiiM Mini and
  the Marshall locked on AUX permanently. The WiiM has exactly **one active input**, so
  music and projector audio can never both be live — a structural ceiling, not a setting.
  The one remaining gesture (music → projector) is driven by the WiiM's **local HTTP API**
  via a `rest_command`, chosen over HACS integrations because it needs no third-party code
  in HA. Full-automation (Rung 2, VIDAA MQTT) is deferred on sequencing, not merit.
  See [`docs/decisions/living-room-audio.md`](docs/decisions/living-room-audio.md).

---

## Deploy / control model

There's no API-server-style remote control. The primitive is manual GitOps:

```
tailscale ssh into the box → git pull && docker compose up -d
```

The desired state — **including each own-image's version, pinned inline in
`compose.yaml` as a git SHA** (never `:latest`) — lives in git, so `git blame`
is the deploy history and `git revert` is rollback. Own-image versions used to
sit in the shared `.env` (`DURI_TAG`); they're now inline like every upstream
image, which also keeps the non-secret version pointer out of a secret-named file.

**duri** (the one Pattern-A app) wraps that loop in one command,
`scripts/deploy-duri.sh` (see the `deploy-duri` skill): cross-build amd64 →
stamp SHA + OCI provenance → push → pin the tag in `compose.yaml` + commit/push →
reconcile the box → verify `/api/version`. This encodes the footguns (the
arm64→amd64 cross-build crash-loop chief among them) so a deploy is one rigorous
step, not ten remembered ones.

Optional later upgrade: `docker context create homelab --docker "host=ssh://homelab"`
lets compose commands run from the Mac over SSH without exposing the Docker daemon.
Not built now.

### Next rung — deploy-on-merge (backlog, not built)

When one-command deploys start to chafe, the non-overboard automation is a
**self-hosted GitHub Actions runner on the box**. It's already on the tailnet, so
it can reach the Tailscale-private registry — which resolves the CI-to-homelab
"bootstrap problem" that kept cloud CI out (GitHub-hosted runners can't see the
private registry). That turns merge-to-`main` into an auto build+deploy while
keeping the artifact flow (build → registry → compose) unchanged. Deliberately
deferred: it adds a standing component to maintain, and one-command manual deploys
are sufficient at the current cadence. Revisit only when manual starts to hurt.

---

## Operational runbooks

The human executes these; the repo only documents them.

- **`docs/bootstrap.md`** — stand up the box from a clean Debian install to a
  running stack: base packages, Tailscale (new node → new IP), SSH, Docker,
  `insecure-registries`, clone the repo, bring up the stack (HA fresh, registry
  empty), and clean the Mac's old k3s kubeconfig.
- **`docs/add-a-service.md`** — steady-state workflow: build on a dev machine →
  push to `${REGISTRY_HOST}` → add a compose block → **decide the access plane** →
  `docker compose up -d <service>`.
- **`docs/tunnel-setup.md`** — create the locally-managed tunnel, place the creds
  JSON on the box, add the DNS CNAME. Same locally-managed cloudflared pattern the
  dev-machine gateway uses (that config lives in the `config` dotfiles repo).

---

## Open questions

- None currently. (duri's port / DB / access plane are resolved: a stateless
  container with a Supabase-cloud backend, Tailscale-private and served over HTTPS
  via `tailscale serve` (loopback `127.0.0.1:3000` behind on-box TLS) — see
  §Services. Making duri public later is a known, additive cloudflared decision, not
  an open design question.)
