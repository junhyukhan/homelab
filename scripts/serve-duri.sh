#!/usr/bin/env bash
#
# serve-duri.sh — assert the `tailscale serve` config that fronts duri over HTTPS.
#
# duri is a PWA and needs a SECURE CONTEXT (HTTPS) for its service worker and Web
# Crypto (crypto.randomUUID); plain HTTP on the Tailscale IP is not one and
# silently broke the logger's Save button (2026-07-17). `tailscale serve`
# terminates TLS on the box (auto-provisioned Let's Encrypt cert for the node's
# MagicDNS name) and proxies to duri's loopback port — tailnet-only, no public
# exposure. See SPEC.md §Decisions "On-box TLS via tailscale serve".
#
# serve config lives in tailscaled state, not compose — this script IS its
# git-tracked source of truth. Idempotent: safe to re-run (re-asserts the mount).
#
# One-time prereqs on the box (not done here):
#   - MagicDNS + HTTPS certs enabled in the tailnet (admin console).
#   - sudo tailscale set --operator=$USER   # so serve is managed without root.
#
# Usage:
#   scripts/serve-duri.sh              # assert serve on the box + verify HTTPS
#   scripts/serve-duri.sh --dry-run    # print the plan, change nothing
#
# Env overrides: BOX_HOST, BOX_SSH_KEY, DURI_PORT, BOX_URL.
set -euo pipefail

BOX_HOST="${BOX_HOST:-jun@100.65.77.63}"
BOX_SSH_KEY="${BOX_SSH_KEY:-$HOME/.ssh/id_ed25519__jun_hp_spectre__homeserver}"
DURI_PORT="${DURI_PORT:-3000}"
BOX_URL="${BOX_URL:-https://jun-hp-spectre.tail114865.ts.net}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { grep '^#' "$0" | sed 's/^# \?//'; exit 0; }

say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ssh_box() { ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$BOX_SSH_KEY" "$BOX_HOST" "$@"; }

# Proxy the node's HTTPS (443) root at the MagicDNS name to duri on loopback.
# `--bg` persists the config across reboots (stored in tailscaled state).
SERVE_CMD="tailscale serve --bg http://127.0.0.1:${DURI_PORT}"

say "Asserting: $SERVE_CMD"
if [[ $DRY_RUN == 1 ]]; then
  echo "  [dry-run] ssh $BOX_HOST '$SERVE_CMD'"
else
  ssh_box "$SERVE_CMD"
  ssh_box "tailscale serve status"
fi

say "Verifying $BOX_URL reaches duri over HTTPS…"
if [[ $DRY_RUN == 1 ]]; then
  echo "  [dry-run] curl -sS -o /dev/null -w '%{http_code}' $BOX_URL/"
else
  code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 "$BOX_URL/" || true)"
  # Unauthenticated root 307-redirects to /login — any 2xx/3xx means duri answered
  # over TLS. A 000 means the cert/serve/tailnet path is broken.
  if [[ "$code" =~ ^[23] ]]; then
    printf '\n\033[1;32m✓ duri is served over HTTPS at %s (HTTP %s)\033[0m\n' "$BOX_URL" "$code"
  else
    echo "✗ verify failed — $BOX_URL returned '${code}' (expected 2xx/3xx)" >&2
    exit 1
  fi
fi
