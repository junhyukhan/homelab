#!/usr/bin/env bash
#
# serve-transmission.sh — assert the `tailscale serve` config that fronts
# transmission's web UI over HTTPS on the tailnet.
#
# WHY PORT 8443 AND NOT 443
# duri already owns `/` on 443 (`tailscale serve status` →
# `/ proxy http://127.0.0.1:3000`). Re-serving the root for transmission would
# REPLACE duri's mount and take duri down. So transmission gets its own HTTPS
# port. A path prefix (--set-path /transmission) was rejected: transmission
# serves and redirects to absolute /transmission/web/ paths, which collide with
# serve's prefix-stripping.
#
# The 443/8443/10000 port restriction people remember is a **Funnel** limit, not
# a serve limit — serve takes any port. 8443 is convention, not a constraint.
#
# serve config lives in tailscaled state, not compose — this script IS its
# git-tracked source of truth. Idempotent: safe to re-run (re-asserts the mount).
#
# The container itself publishes only on loopback (127.0.0.1:9091, published by
# gluetun on transmission's behalf), so serve is the sole tailnet-facing door.
# Nothing here is public: no Funnel, no cloudflared ingress. See SPEC.md
# §Access planes — a public door into a VPN namespace would defeat the namespace.
#
# One-time prereqs on the box (same as duri's, already satisfied if serve-duri
# has ever run): MagicDNS + HTTPS certs enabled in the tailnet, and
# `sudo tailscale set --operator=$USER` so serve is managed without root.
#
# Usage:
#   scripts/serve-transmission.sh              # assert serve on the box + verify
#   scripts/serve-transmission.sh --dry-run    # print the plan, change nothing
#
# Env overrides: BOX_HOST, BOX_SSH_KEY, TRANSMISSION_PORT, SERVE_PORT, BOX_URL.
set -euo pipefail

BOX_HOST="${BOX_HOST:-jun@100.65.77.63}"
BOX_SSH_KEY="${BOX_SSH_KEY:-$HOME/.ssh/id_ed25519__jun_hp_spectre__homeserver}"
TRANSMISSION_PORT="${TRANSMISSION_PORT:-9091}"
SERVE_PORT="${SERVE_PORT:-8443}"
BOX_URL="${BOX_URL:-https://jun-hp-spectre.tail114865.ts.net}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { grep '^#' "$0" | sed 's/^# \?//'; exit 0; }

say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ssh_box() { ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$BOX_SSH_KEY" "$BOX_HOST" "$@"; }

SERVE_CMD="tailscale serve --bg --https=${SERVE_PORT} http://127.0.0.1:${TRANSMISSION_PORT}"
TARGET_URL="${BOX_URL}:${SERVE_PORT}"

# Guard: refuse to run if duri's 443 mount isn't where we expect it. If someone
# has already rearranged serve, silently stacking another mount on top is the
# wrong move — stop and let a human look.
say "Checking existing serve config (duri's 443 mount must be intact)"
if [[ $DRY_RUN == 1 ]]; then
  echo "  [dry-run] ssh $BOX_HOST 'tailscale serve status'"
else
  existing="$(ssh_box 'tailscale serve status' 2>&1 || true)"
  echo "$existing"
  if ! grep -q '127.0.0.1:3000' <<<"$existing"; then
    echo
    echo "✗ refusing to continue — duri's proxy to 127.0.0.1:3000 was not found in" >&2
    echo "  the current serve config. Serve state is not what this script assumes;" >&2
    echo "  inspect it and run scripts/serve-duri.sh if duri's mount is missing." >&2
    exit 1
  fi
fi

say "Asserting: $SERVE_CMD"
if [[ $DRY_RUN == 1 ]]; then
  echo "  [dry-run] ssh $BOX_HOST '$SERVE_CMD'"
else
  ssh_box "$SERVE_CMD"
  ssh_box "tailscale serve status"
fi

say "Verifying $TARGET_URL reaches transmission over HTTPS…"
if [[ $DRY_RUN == 1 ]]; then
  echo "  [dry-run] curl -sS -o /dev/null -w '%{http_code}' $TARGET_URL/transmission/web/"
  exit 0
fi

code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 "${TARGET_URL}/transmission/web/" || true)"
case "$code" in
  401)
    printf '\n\033[1;32m✓ transmission is served over HTTPS at %s (HTTP 401)\033[0m\n' "$TARGET_URL"
    echo "  401 is the expected, correct answer: the UI is reachable AND demanding"
    echo "  its RPC password. Log in at ${TARGET_URL}/transmission/web/"
    ;;
  2*|3*)
    printf '\n\033[1;33m⚠ reachable at %s (HTTP %s) but it did NOT ask for a password\033[0m\n' "$TARGET_URL" "$code"
    echo "  Expected 401. Check USER/PASS in torrent/transmission.env are set and" >&2
    echo "  that the container was recreated after they were added:" >&2
    echo "    docker compose up -d --force-recreate transmission" >&2
    exit 1
    ;;
  403)
    printf '\n\033[1;31m✗ HTTP 403 — transmission rejected the SOURCE IP\033[0m\n' >&2
    echo "  This is rpc-whitelist: through serve, the request's source inside the" >&2
    echo "  netns is the docker bridge gateway, not 127.0.0.1. Widen WHITELIST in" >&2
    echo "  torrent/compose.yaml and recreate. See SPEC.md §The torrent stack." >&2
    exit 1
    ;;
  421)
    printf '\n\033[1;31m✗ HTTP 421 — transmission rejected the HOST HEADER\033[0m\n' >&2
    echo "  This is rpc-host-whitelist: serve forwards the MagicDNS name. Add it to" >&2
    echo "  HOST_WHITELIST in torrent/compose.yaml and recreate." >&2
    exit 1
    ;;
  *)
    echo "✗ verify failed — $TARGET_URL returned '${code}' (expected 401)" >&2
    echo "  000 means the serve/cert/tailnet path is broken, or gluetun is down —" >&2
    echo "  transmission has no network of its own, so a dead tunnel means no UI." >&2
    exit 1
    ;;
esac
