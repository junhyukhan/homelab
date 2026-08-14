# Transmission behind Windscribe (gluetun)

**Status:** in progress (2026-08-14) — built, not yet deployed. Awaiting the manual
WireGuard-config prerequisite and the on-box leak check in [`docs/torrent.md`](../torrent.md).

## Why — the ask (verbatim)

> **Verbatim (2026-08-14):** "# Work Order: Transmission behind Windscribe (gluetun)
>
> ## Step 0 — SPEC.md first
> Add the torrent stack to SPEC.md before writing any compose file.
> Document: purpose, the namespace-sharing guarantee, volumes, access path.
>
> ## Prerequisites (manual)
> - WireGuard config from https://windscribe.com/getconfig/wireguard
>   Need: private key, addresses (100.x.x.x/32), preshared key.
> - Into .env, gitignored. Never committed.
>
> ## Deliverables
> 1. `torrent/compose.yaml`:
>    - `gluetun` (qmcgaw/gluetun): VPN_SERVICE_PROVIDER=windscribe,
>      VPN_TYPE=wireguard, cap_add NET_ADMIN, /dev/net/tun,
>      SERVER_REGIONS=Japan (latency from Korea).
>    - `transmission` (lscr.io/linuxserver/transmission):
>      network_mode: "service:gluetun", depends_on gluetun.
> 2. Volumes:
>    - named volume for transmission config
>    - bind mount to external disk for /downloads
> 3. Transmission settings: fixed peer port, UPnP/NAT-PMP off,
>    Local Peer Discovery off, RPC password set.
> 4. Global upload rate limit (thermals — sustained seeding on a
>    7th-gen laptop chassis).
> 5. SPEC.md updated; leak-check procedure documented.
>
> ## Constraints
> - `ports:` and `networks:` on gluetun ONLY. A container using
>   network_mode: service: cannot publish ports — silent failure.
> - Access via `tailscale serve`, same pattern as duri-v3. No reverse
>   proxy, no cloudflared, no router ports.
> - No key material in git.
>
> ## Acceptance criteria
> - `docker compose exec transmission curl -s ifconfig.me` returns the
>   Windscribe exit IP, never the home ISP IP.
> - Stopping gluetun leaves transmission with zero connectivity.
> - Web UI reachable on the tailnet only.
> - Memory footprint checked against duri-v3's headroom on 8GB.
>
> ## Out of scope
> - Ephemeral port forwarding (ws-ephemeral, 7-day renewal).
>   Compatible with the no-inbound-ports design if added later."

Four forks were put back to Han before any file was written; all four took the
recommended option.

> **Verbatim (2026-08-14, on the four forks):** selected "Bind mount on internal disk
> (Recommended)", "torrent/compose.yaml, root includes it (Recommended)", "Second HTTPS
> port, 8443 (Recommended)", "Git-tracked asserter script (Recommended)".

## Discussion

### What the work order assumed that the box contradicted

Two items could not be executed as written. Both were found by checking the box
rather than by reading the repo, which is the general lesson worth keeping:

1. **"bind mount to external disk for /downloads" — there is no external disk.**
   The box has a single 238 GB NVMe (LVM, ~200 G free on `/`); `/media` holds only an
   empty `cdrom` and `/mnt/timemachine` is a directory on the root filesystem, not a
   mount. Decided: bind to `/srv/torrents` on the internal disk, via
   `${TORRENT_DOWNLOADS}` so the path moves to a real disk later without a compose edit.

2. **"Access via `tailscale serve`, same pattern as duri" — duri already owns `/` on
   443.** Confirmed live: `tailscale serve status` shows `/ proxy http://127.0.0.1:3000`.
   Serving transmission at the root would have *replaced* that mount and taken duri
   down — the pattern is reusable, the port is not. Decided: `--https=8443`.
   `--set-path /transmission` was considered and rejected: transmission serves and
   redirects to absolute `/transmission/web/` paths, which collide with serve's
   prefix-stripping. Worth recording that the 443/8443/10000 port restriction commonly
   cited is a **Funnel** limit, not a serve limit — serve takes any port.

### The bind-volume form, and why not a plain bind mount

The work order said "bind mount". A plain `- /srv/torrents:/downloads` has a failure
mode that matters precisely *because* an external disk is the eventual target: if the
host path is missing, **Docker silently creates it** as an empty root-owned directory,
and transmission fills the internal SSD while every status command reports healthy.

The `type: none, o: bind, device:` named-volume form instead **refuses to start**.
Verified on the box rather than assumed:

```
docker: Error response from daemon: error while mounting volume ...:
failed to mount local volume: mount /srv/does-not-exist-guard-test:...: no such file or directory
```

This also satisfies SPEC's "all state in named volumes" convention without burying
bulk media in `/var/lib/docker`. It is the same class of bug as the `ports:`-on-a-
`service:`-namespace trap the work order itself called out: **the dangerous failures
here are the silent ones**, so each was converted into a loud one.

### Two silent failures found before first boot

Transmission behind a shared namespace has *two* separate whitelists that both reject
the `tailscale serve` path, with error messages that don't obviously point at the cause:

- `rpc-whitelist` — the request's source inside the netns is the docker bridge gateway,
  not `127.0.0.1` → **403 Unauthorized IP Address**.
- `rpc-host-whitelist` — the `Host` header is the MagicDNS name → **421 Misdirected Request**.

Handled with the `WHITELIST` / `HOST_WHITELIST` env vars, kept as narrow allowlists
rather than `*`. Documented in the runbook because the next person to change the access
path will hit them again.

### Why a namespace and not a killswitch

`network_mode: "service:gluetun"` was preferred over any firewall/killswitch approach
because it removes the class of failure rather than guarding it: a namespace has no
state where a rule is missing, mis-ordered, or flushed. transmission has no interface
that reaches the ISP, so "leaking" isn't a thing it can do wrong — it's a thing it
cannot express. The cost is the `ports:`/`networks:`-on-gluetun-only rule, which
compose enforces by *ignoring* the keys rather than erroring, so it's called out inline
at the transmission block and in SPEC.

### Settings that aren't env vars

Fixed peer port, UPnP/NAT-PMP off, LPD off, and the upload cap live only in
`/config/settings.json`, which transmission **rewrites on shutdown** — so editing it on
a running container is silently discarded, and shipping a git-tracked copy means a
stop/copy/start dance every time. Chose the asserter-script form
(`scripts/settings-transmission.sh`, over `transmission-remote`), matching the pattern
`serve-duri.sh` already set for out-of-compose state: the script is the source of truth,
it is idempotent, and re-running it is the drift check.

The upload cap is a **thermal** control, not a bandwidth one — the reason is the 7th-gen
laptop chassis shared with Home Assistant and duri, so the value belongs to the box, not
to the link.

### Resolved at first deploy (2026-08-14)

- **`SERVER_REGIONS=Japan` is valid** — resolves to a Tokyo exit (M247, Windscribe's
  host). Closed.
- **WireGuard is kernelspace, not userspace** — gluetun logs `[wireguard] Using
  available kernelspace implementation`. Encryption is on the cheap path, so there is
  more thermal headroom than the worst case assumed; the upload cap stays a deliberate
  ceiling rather than a necessary one. Closed.
- **Leak check**: assertion 1 (exit IP ≠ home ISP) and assertion 3 (UI bound to
  `127.0.0.1:9091`) both pass. Assertion 2 still to run — see Open questions.

### What first setup actually cost — two traps worth keeping

Both were configuration, not design, and both are now documented in
`torrent/gluetun.env.example` and `docs/torrent.md §4a`:

1. **Restart ≠ recreate.** Env vars are baked in at container *creation*, so
   `restart: unless-stopped` kept replaying the *original* environment after the env
   file was corrected. The failure mode is nasty because the symptom is an error you
   have already fixed, reappearing with fresh timestamps — it reads as "my fix didn't
   work" when the fix was never loaded. The tell is `stat` on the env file versus the
   container's `.Created`. This was already documented for duri in the README but not
   here, which is exactly why it bit.

2. **Windscribe's `Address` line is dual-stack.** It carries IPv4 *and* IPv6
   comma-separated; pasting the whole line makes gluetun refuse to start, since the box
   has no IPv6. Keeping only the IPv4 `/32` is the *safer* configuration rather than a
   workaround: with no IPv6 address in the tunnel the namespace has no IPv6 route at
   all, so transmission cannot leak over IPv6 — a common hole in dual-stack setups.

   A near-miss belongs with these: `[Peer]` holds both `PublicKey` and `PresharedKey`,
   adjacent and visually identical, and the wrong one went in first. The shape check
   (`len=44 charset_ok=yes ends_with_eq=yes`) diagnoses all of these **without ever
   printing the secret**, and is now in both docs.

### Open questions

- **Leak-check assertion 2 has not been run** — stopping gluetun to confirm
  transmission loses all connectivity. It is the assertion that actually proves the
  containment guarantee rather than inferring it, so run it before real use.
- **Image tags are pinned to real, current upstream releases** (`gluetun v3.41.3`,
  `transmission 4.1.3-r0-ls357`, both resolved from their GitHub releases rather than
  guessed). This is stricter than the repo's existing upstream practice
  (`cloudflared:latest`, `home-assistant:stable`) — deliberately, because a torrent
  client's settings semantics are what a silent major bump would break, and this
  stack's correctness lives in those settings. The tradeoff is that updates are now
  manual for these two.
