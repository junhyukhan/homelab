# Runbook: torrent stack (transmission behind Windscribe)

First-run setup and the leak check. Design and rationale live in
[SPEC.md §The torrent stack](../SPEC.md); the decision record is
[`decisions/torrent-vpn.md`](decisions/torrent-vpn.md).

**The invariant this whole stack exists to hold:** transmission runs inside
gluetun's network namespace (`network_mode: "service:gluetun"`), so it has no
interface that routes to the home ISP. Not a firewall rule — a structural
property. §3 is how you prove it's still true.

---

## 1. Prerequisites (one time, manual)

### 1.1 Get the WireGuard config from Windscribe

Log in and generate a WireGuard config at
<https://windscribe.com/getconfig/wireguard>. You need three values out of it:

| From the generated `.conf` | Goes to |
|---|---|
| `[Interface] PrivateKey` | `WIREGUARD_PRIVATE_KEY` |
| `[Interface] Address` (e.g. `100.x.x.x/32`) | `WIREGUARD_ADDRESSES` |
| `[Peer] PresharedKey` | `WIREGUARD_PRESHARED_KEY` |

Windscribe **requires** the preshared key — gluetun will not start without it.

### 1.2 Fill in the two gitignored env files, on the box

```bash
ssh jun@100.65.77.63
cd ~/homelab && git pull

cp torrent/gluetun.env.example      torrent/gluetun.env
cp torrent/transmission.env.example torrent/transmission.env
# edit both in place (nano/vim), then lock them down:
chmod 600 torrent/gluetun.env torrent/transmission.env
```

Generate the RPC password rather than choosing one: `openssl rand -base64 24`.

> **Never `cat`/`echo` these files, and never paste key material into a commit,
> a chat, or a command argument.** `torrent/*.env` is gitignored; the
> `*.env.example` templates are the tracked contract.

### 1.3 Create the downloads directory

The bind-volume **refuses to start the container** if this path is missing —
deliberately, so a missing disk can never be silently redirected onto the
internal SSD (see SPEC.md). Create it, owned by `PUID:PGID` from `.env`:

```bash
sudo mkdir -p /srv/torrents
sudo chown 1000:1000 /srv/torrents      # match PUID/PGID in .env
```

There is **no external disk on the box today** — `/srv/torrents` is on the
internal NVMe (~200 G free). When a real disk arrives: mount it, point
`TORRENT_DOWNLOADS` in `.env` at its mountpoint, `docker compose up -d`.

### 1.4 Add the new `.env` keys

`.env` on the box predates this stack, so it is missing two keys. Compare against
`.env.example` and add:

```
TORRENT_DOWNLOADS=/srv/torrents
VPN_SERVER_REGIONS=Japan
```

Both have compose-level defaults, so the stack comes up without them — but set
them explicitly so the box's config is readable on its own terms.

---

## 2. Bring it up

```bash
cd ~/homelab
docker compose up -d              # the root stack includes torrent/compose.yaml
docker compose ps                 # gluetun + transmission should both appear
```

Then, **from the Mac** (these two own out-of-compose state):

```bash
./scripts/settings-transmission.sh   # peer port, no-portmap, no-lpd, upload cap
./scripts/serve-transmission.sh      # HTTPS on :8443, verifies it answers 401
```

### Check which WireGuard implementation gluetun used

Relevant to the thermal budget: userspace `wireguard-go` costs materially more
CPU than the in-kernel module, on a chassis that's already sharing the CPU with
Home Assistant and duri.

```bash
docker compose logs gluetun | grep -iE "wireguard|kernel|userspace"
```

If it fell back to userspace, consider lowering the upload cap:
`UPLOAD_LIMIT_KBPS=800 ./scripts/settings-transmission.sh`.

### If gluetun won't start

Almost always the region name or the key material:

```bash
docker compose logs gluetun | tail -30
# valid region names for your subscription tier:
docker run --rm qmcgaw/gluetun:v3.41.3 format-servers -windscribe
```

A wrong `SERVER_REGIONS` fails loudly with a server-not-found error. "Build a
Plan" subscriptions only reach the regions you actually purchased.

---

## 3. Leak check — run after ANY change to this stack

Four assertions. All four must pass. **These are the acceptance criteria.**

### 3.1 Transmission's exit IP is Windscribe's, never the home ISP

```bash
cd ~/homelab

# What transmission sees as its public IP (inside gluetun's namespace):
docker compose exec transmission curl -s ifconfig.me; echo

# What the BOX sees as its public IP (the home ISP):
curl -s ifconfig.me; echo
```

**Pass:** the two differ, and the first is a Windscribe address in the configured
region. **Fail:** they match — stop and do not add torrents.

> `curl` is present in the linuxserver image, so this works as the work order
> specified. If a future image drops it, use
> `docker compose exec gluetun wget -qO- ifconfig.me` — same namespace, same answer.

Cross-check the tunnel's own view:

```bash
docker compose exec gluetun wget -qO- https://ipinfo.io/json
```

### 3.2 Stopping gluetun leaves transmission with zero connectivity

The important one: it proves containment is structural, not best-effort.

```bash
docker compose stop gluetun
docker compose exec transmission curl -s --max-time 10 ifconfig.me; echo "exit=$?"
```

**Pass:** it fails — no output, non-zero exit (typically 6, DNS resolution
failure, or 28, timeout). Transmission has no route at all.
**Fail:** any IP is returned. That would mean transmission has an interface it
should not have; check that `network_mode: "service:gluetun"` is still on the
transmission service and that nothing added a `networks:` key to it.

Bring it back:

```bash
docker compose start gluetun
docker compose up -d transmission    # re-attaches to the new namespace
```

> **Recreating gluetun always requires recreating transmission.** A namespace is
> tied to the container instance, so when gluetun is replaced (image bump,
> config change) transmission must be recreated to join the new one — otherwise
> it sits attached to a namespace that no longer routes anywhere. This is the
> one ongoing operational cost of the design.

### 3.3 The web UI is reachable on the tailnet only

```bash
# On the box: bound to loopback, NOT 0.0.0.0 — this should show 127.0.0.1:9091
docker compose port gluetun 9091
ss -tlnp | grep 9091
```

**Pass:** the listener is on `127.0.0.1`, never `0.0.0.0`. From another tailnet
device, `https://jun-hp-spectre.tail114865.ts.net:8443/transmission/web/` prompts
for the RPC password. From a device on the home LAN but *not* on the tailnet,
nothing is reachable.

`scripts/serve-transmission.sh` asserts this and treats **HTTP 401 as the pass
condition** — reachable *and* demanding a password. It decodes 403
(`rpc-whitelist` rejected the source IP) and 421 (`rpc-host-whitelist` rejected
the Host header) explicitly, because both are easy to hit and neither error text
points at its cause.

### 3.4 Memory footprint fits the 8 GB budget

```bash
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"
free -h
```

Baseline measured 2026-08-14, *before* this stack: 7.6 Gi total, 6.3 Gi
available, containers ~578 MB (home-assistant 479, duri 74, registry 25). Expect
gluetun ~30 MB and transmission ~100 MB idle. **Transmission's memory grows with
the number of active torrents** — that count, not the container itself, is the
thing to watch over time.

---

## 4. Day-to-day

```bash
docker compose logs -f transmission
docker compose logs -f gluetun

# Re-assert settings after an upgrade or a config restore (it's also the drift check):
./scripts/settings-transmission.sh
./scripts/settings-transmission.sh --dry-run     # show intent, change nothing

# Lower the upload cap if the chassis is running hot:
UPLOAD_LIMIT_KBPS=800 ./scripts/settings-transmission.sh
```

**After upgrading either image, re-run §3.** An image bump can reset
`settings.json` semantics or change gluetun's namespace, and both scripts plus
the leak check are what confirm the invariant survived.

## Known limitation: no inbound peer connections

Without port forwarding, transmission is outbound-only — it reaches peers that
accept connections, but no peer can initiate to it. Swarm performance suffers and
some trackers flag the client as non-connectable. The fix is Windscribe ephemeral
port forwarding, **out of scope** for now because it needs renewal every 7 days,
i.e. standing automation. It stays compatible with the no-inbound-ports design:
the forwarded port opens at Windscribe's edge and arrives *inside* the tunnel, so
the home router still has nothing open. Wiring it up later means adding
`FIREWALL_VPN_INPUT_PORTS` on gluetun matching the already-fixed peer port.
