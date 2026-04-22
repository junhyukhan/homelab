# Home Assistant: Follow-ups

## Context

Home Assistant Core is deployed in `infrastructure/home-assistant/` on the k3s
cluster and has been through browser onboarding. This doc tracks the work that
was explicitly out of scope for the initial deploy but is expected to land on
top of it over time.

Design decisions for the current deployment (hostNetwork, Recreate, PVC size,
probes, etc.) live in the service README —
[`infrastructure/home-assistant/README.md`](../infrastructure/home-assistant/README.md).
This file is roadmap-only; prune items as they ship.

**Why HA Core and not HAOS.** HAOS wants bare metal or a dedicated VM with its
own supervisor and add-on store. Inside k3s we run HA Core — a single container
with just the Python app. Things HAOS would install as "add-ons" (Mosquitto,
Zigbee2MQTT, Music Assistant, Wyoming services) become their own pods instead.
This is cleaner for Kubernetes and gives each service an independent upgrade
cycle.

## Roadmap

### 1. Music Assistant

Separate pod, not an HA add-on (we run HA Core, so there is no add-on store).
Integrates with HA over the Music Assistant integration. Primary sources will
be local library + streaming; primary sink will be the WiiM Mini on the living
room amp, reached via mDNS.

Requires: its own Deployment + Service + PVC for library cache / metadata.
Device discovery requires `hostNetwork: true` (same reason as HA).

### 2. Voice stack (Wyoming / Whisper / Piper)

Three pods communicating over the Wyoming protocol:

* **Whisper** (STT) — transcribes mic audio to text
* **Piper** (TTS) — turns responses back into audio
* **Wyoming satellites** (optional) — physical mic/speaker endpoints around
  the house (ESP32-S3 boxes, etc.)

HA connects to Whisper/Piper as "Assist" pipeline stages. Wyoming pods don't
need hostNetwork — they talk TCP to HA by Service DNS.

Decision pending: whether to run Whisper on CPU (slow, simple) or pick a host
with a GPU (adds scheduling complexity). Fine to start CPU-only.

### 3. Post-onboarding hardening: bind HA only to Tailscale

Today HA is reachable on **every** host interface because of `hostNetwork`.
After onboarding is complete, add this to `/config/configuration.yaml` to
restrict it to the Tailscale interface:

```yaml
http:
  server_host: <tailscale-ip>
```

Don't do this before onboarding — `server_host` restricts which network
interface HA listens on. Setting it to the Tailscale IP before onboarding
stops HA from responding on the LAN interface your browser may be using to
reach the wizard. Verify your browser can reach HA via the Tailscale IP before
restricting. Also worth considering: `trusted_proxies` / `use_x_forwarded_for`
if we ever put an ingress in front.

### 4. Image version pinning

Currently on `:stable`. Once the deployment is settled, consider pinning to
a specific release (e.g., `:2025.10.4`) and bumping on purpose. Tradeoff:
security updates stop arriving automatically; in exchange, upgrades stop
being surprises. Revisit after ~1 month of daily use.

### 5. Bluetooth (if needed)

HA's Bluetooth integration currently logs `NET_ADMIN/NET_RAW` permission
errors — harmless until something actually needs BLE (e.g., presence
detection via phone, BT thermometers). If a BLE-dependent integration is
added later, extend the deployment with:

```yaml
containers:
  - name: home-assistant
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
```

And optionally mount `/run/dbus` for BlueZ access. Not worth doing
preemptively.

### 6. HACS (Home Assistant Community Store)

Community integrations and custom Lovelace cards. Installed from inside HA,
not via Kubernetes. Only add if a specific integration the user wants is
HACS-only. Adds a small attack surface (third-party code running inside HA)
— worth the tradeoff case by case, not as a default.

### 7. TLS / ingress in front of HA

Not planned. Tailscale is the transport security layer; HA is only reachable
from the tailnet. Revisit only if exposure to a non-Tailscale audience is
ever needed (e.g., sharing with a non-technical household member who can't be
asked to install Tailscale).

### 8. Backup automation

The `tar czf` command in the service README is a manual snapshot. Follow-ups:

* Scheduled CronJob that writes the tarball somewhere off-node (S3 / R2 /
  the Mac's iCloud folder via Tailscale SSH).
* Consider HA's built-in backup (`Settings → System → Backups`) instead —
  it handles DB vacuum and auto-scheduling in-app.

### 9. Integrations that need onboarding (already handled in browser)

Tracked here for completeness, not as open work:

* **LG ThinQ** — appliances (AC, dryer, etc.)
* **Roborock** — robot vacuum
* **WiiM Mini** — streaming amp endpoint
* Anything else auto-discovered via mDNS/SSDP once `hostNetwork` kicked in

## Out of scope for this repo

* Voice assistant hardware (mic/speaker boxes) — lives on ESP32, not k3s
* Any integration configuration stored in HA's `/config/configuration.yaml`
  — that's onboarding territory, not declarative manifest territory
