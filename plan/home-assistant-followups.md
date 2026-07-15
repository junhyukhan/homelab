# Home Assistant: Follow-ups

## Context

Home Assistant runs as the `home-assistant` service in [`compose.yaml`](../compose.yaml)
(`network_mode: host`, state in the `ha_data` volume) and has been through browser
onboarding. This doc tracks work that was explicitly out of scope for the initial
deploy but is expected to land on top of it over time.

Design decisions for the current deployment (why host networking, why the `ha_data`
volume, plane assignment) live in [`SPEC.md`](../SPEC.md) and the inline comments in
`compose.yaml`. This file is roadmap-only; prune items as they ship.

**Why HA Core and not HAOS.** HAOS wants bare metal or a dedicated VM with its own
supervisor and add-on store. On this box we run HA Core — a single container with
just the Python app. Things HAOS would install as "add-ons" (Mosquitto,
Zigbee2MQTT, Music Assistant, Wyoming services) become their own compose services
instead. This keeps each service on an independent image/upgrade cycle and fits the
"one `compose.yaml`, no orchestrator" model in SPEC.md.

## Roadmap

### 1. Music Assistant

Its own compose service, not an HA add-on (we run HA Core, so there is no add-on
store). Integrates with HA over the Music Assistant integration. Primary sources
will be local library + streaming; primary sink will be the WiiM Mini on the living
room amp, reached via mDNS.

Requires: a new service block in `compose.yaml` plus a named volume for its library
cache / metadata. Playback device discovery needs `network_mode: host` (same reason
as HA) — which means, like HA, it won't be on `homelab_net` and is reached on the
host's Tailscale IP directly.

### 2. Voice stack (Wyoming / Whisper / Piper)

Three services communicating over the Wyoming protocol:

* **Whisper** (STT) — transcribes mic audio to text
* **Piper** (TTS) — turns responses back into audio
* **Wyoming satellites** (optional) — physical mic/speaker endpoints around
  the house (ESP32-S3 boxes, etc.)

HA connects to Whisper/Piper as "Assist" pipeline stages. These are plain TCP
services and don't need host networking — put them on `homelab_net`. Reachability
wrinkle: HA is on host networking and is **not** on `homelab_net`, so it can't
resolve them by compose DNS. Publish each Wyoming service's port on the host and
point HA at `127.0.0.1:<port>` (or the Tailscale IP). This is the same host-net
consequence documented for HA in SPEC.md.

Decision pending: whether to run Whisper on CPU (slow, simple) or pick a host with
a GPU (adds complexity). Fine to start CPU-only — the box has no GPU.

### 3. ~~Bind HA only to Tailscale~~ — decided against

HA is reachable on **every** host interface because of `network_mode: host`, which
means it's on both the home LAN and the tailnet. This is **intended**: housemates
use it on the LAN, the human reaches it over Tailscale when off-network. It's never
public.

So do **not** add `http: server_host:` to `/config/configuration.yaml` — that binds
HA to a single interface and would break the LAN access that's wanted here. This
item is kept only as a signpost so the LAN exposure isn't mistaken for an oversight
and "hardened" away. See the plane assignment in SPEC.md. (`trusted_proxies` /
`use_x_forwarded_for` would only matter if an ingress were ever put in front — see
#7 — which isn't planned.)

### 4. Image version pinning

Currently on `:stable` in `compose.yaml`. Once the deployment is settled, consider
pinning to a specific release (e.g., `:2025.10.4`) and bumping on purpose. Tradeoff:
security updates stop arriving automatically on `docker compose pull`; in exchange,
upgrades stop being surprises. Revisit after ~1 month of daily use.

### 5. Bluetooth (if needed)

HA's Bluetooth integration currently logs `NET_ADMIN`/`NET_RAW` permission errors —
harmless until something actually needs BLE (e.g., presence detection via phone, BT
thermometers). If a BLE-dependent integration is added later, extend the
`home-assistant` service in `compose.yaml` with:

```yaml
    cap_add:
      - NET_ADMIN
      - NET_RAW
```

And optionally mount `/run/dbus:/run/dbus:ro` for BlueZ access. Not worth doing
preemptively.

### 6. HACS (Home Assistant Community Store)

Community integrations and custom Lovelace cards. Installed from inside HA, not via
compose. Only add if a specific integration the user wants is HACS-only. Adds a
small attack surface (third-party code running inside HA) — worth the tradeoff case
by case, not as a default.

### 7. TLS / ingress in front of HA

Not planned. Tailscale is the transport security layer; HA is only reachable from
the tailnet. The cloudflared tunnel is **not set up yet** (`cloudflared/config.yml`
still has placeholder values and no real ingress routes), and even once it is, HA
stays Tailscale-private per its plane assignment in SPEC.md. Revisit only if
exposure to a non-Tailscale audience is ever needed (e.g., sharing with a
non-technical household member who can't be asked to install Tailscale) — that would
mean a conscious cloudflared ingress rule + a Cloudflare Access policy, per
SPEC.md §Access planes.

### 8. Backup automation

The `ha_data` volume is the only state; a manual snapshot is
`docker run --rm -v homelab_ha_data:/config -v "$PWD":/backup alpine tar czf /backup/ha-backup.tar.gz -C /config .`.
Follow-ups:

* A scheduled job (cron or a systemd timer **on the box** — no orchestrator, so no
  CronJob) that writes the tarball somewhere off-node (R2 / the Mac's iCloud folder
  via Tailscale SSH).
* Consider HA's built-in backup (`Settings → System → Backups`) instead — it handles
  DB vacuum and auto-scheduling in-app, and is the lower-maintenance option.

### 9. Integrations that need onboarding (already handled in browser)

Tracked here for completeness, not as open work:

* **LG ThinQ** — appliances (AC, dryer, etc.)
* **Roborock** — robot vacuum
* **WiiM Mini** — streaming amp endpoint
* Anything else auto-discovered via mDNS/SSDP once host networking kicked in

## Out of scope for this repo

* Voice assistant hardware (mic/speaker boxes) — lives on ESP32, not this box
* Any integration configuration stored in HA's `/config/configuration.yaml` — that's
  onboarding territory, not declarative-config territory
