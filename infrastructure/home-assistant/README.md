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
| Probes | `startupProbe` (`failureThreshold: 60 × periodSeconds: 10` = 10-min ceiling), then `livenessProbe` | First boot loads integrations and runs DB migrations, taking 1–2 minutes. A plain `livenessProbe` with default thresholds would kill the container before it finishes. |
| Env | `TZ=Asia/Seoul` | Used for scheduling, sunrise/sunset calculations, log timestamps. Defaults to UTC otherwise. |

**hostNetwork tradeoffs.** HA binds to **every** interface on the host, not
just Tailscale — reachable from both the VPN and the local LAN. The home LAN
is trusted, so this is accepted. NetworkPolicy doesn't apply to hostNetwork
pods (non-issue; not used elsewhere in the repo).

#### Access

Over Tailscale, from any device:

* Primary: `http://<tailscale-ip>:8123` (hostNetwork, direct host bind)
* Fallback: `http://<tailscale-ip>:30123` (Service NodePort)
* In-cluster DNS: `http://home-assistant.infrastructure:8123` (for other pods calling into HA; HA itself runs on the host network and cannot resolve this address)

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

Verify the output file is non-zero before trusting it — if `kubectl exec` fails
the redirect still creates an empty file with no warning.

Deleting the PVC (or the namespace) wipes all of this.

#### Notes

* No TLS or ingress in front of HA. Tailscale is the transport security layer.
* Bluetooth integrations (if desired later) need `NET_ADMIN` and `NET_RAW`
  capabilities added to the container.
* See [`plan/home-assistant-followups.md`](../../plan/home-assistant-followups.md)
  for roadmap items (Music Assistant, voice stack, post-onboarding hardening).
