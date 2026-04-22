### Home Assistant

**Namespace:** `infrastructure`

Home Assistant Core (the container flavor, not HAOS) running as a single-replica
Deployment. Hub for household automation — smart-home integrations (WiiM,
Chromecast, MQTT, etc.) live here.

#### Configuration

| Item | Value | Rationale |
| :--- | :--- | :--- |
| Image | `ghcr.io/home-assistant/home-assistant:stable` | Moving tag; matches `cloudflared:latest` / `registry:2` style. Pin to a release (e.g., `:2025.10`) if reproducibility becomes important. |
| Storage | 5Gi PVC at `/config` (local-path) | Enough for config + SQLite recorder DB on a single-node cluster. Easy to resize. |
| Replicas | 1, `strategy: Recreate` | Two HA pods cannot share `:8123` on the host, so rolling updates aren't possible. Brief downtime during upgrades is acceptable. |
| Network | `hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet` | hostNetwork is required for mDNS/SSDP device auto-discovery (WiiM, Chromecast, AirPlay, etc.); multicast doesn't cross pod network boundaries. `ClusterFirstWithHostNet` restores in-cluster DNS, which hostNetwork otherwise bypasses. |
| Service | NodePort 30123 (`:8123` also bound by hostNetwork) | Kept for consistency with other services, in-cluster DNS (`home-assistant.infrastructure:8123`), and as a stable fallback if hostNetwork is ever removed. |
| Probes | `startupProbe` (5-min grace), then `livenessProbe` | First boot installs Python deps and can take 1–2 minutes. A plain liveness probe with default thresholds would loop forever. |
| Env | `TZ=Asia/Seoul` | Used for scheduling, sunrise/sunset calculations, log timestamps. Defaults to UTC otherwise. |

**Core vs HAOS.** HAOS wants bare metal or a dedicated VM with its own
supervisor and add-on store. Inside k3s we run HA Core — a single container
with just the Python app. Things HAOS would install as add-ons (Mosquitto,
Zigbee2MQTT, Music Assistant, Wyoming services) become their own pods. Cleaner
for Kubernetes; gives us independent upgrade cycles.

**hostNetwork tradeoffs.** HA binds to **every** interface on the host, not
just Tailscale — reachable from both the VPN and the local LAN. The home LAN
is trusted, so this is accepted. NetworkPolicy doesn't apply to hostNetwork
pods (non-issue; not used elsewhere in the repo).

#### Access

Over Tailscale, from any device:

* Primary: `http://<tailscale-ip>:8123` (hostNetwork, direct host bind)
* Fallback: `http://<tailscale-ip>:30123` (Service NodePort)
* In-cluster DNS: `http://home-assistant.infrastructure:8123`

First boot takes 1–2 minutes before the onboarding page is reachable.
Onboarding (admin user, location, integrations) is done in a browser — there
is no CLI flow for it.

#### Deployment

```bash
kubectl apply -k infrastructure/home-assistant/
```

#### Config backup

`/config` holds the SQLite recorder DB, `configuration.yaml`, secrets, and
integration state. Snapshot before any risky change:

```bash
kubectl exec -n infrastructure deployment/home-assistant -- \
  tar czf - -C /config . > ha-config-backup-$(date +%F).tar.gz
```

Deleting the PVC (or the namespace) wipes all of this.

#### Notes

* No TLS or ingress in front of HA. Tailscale is the transport security layer.
* Bluetooth integrations (if desired later) need `NET_ADMIN` and `NET_RAW`
  capabilities added to the container.
* See [`plan/home-assistant-followups.md`](../../plan/home-assistant-followups.md)
  for roadmap items (Music Assistant, voice stack, post-onboarding hardening).
