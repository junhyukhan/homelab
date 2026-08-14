#!/usr/bin/env bash
#
# settings-transmission.sh — assert the transmission settings that BitTorrent-
# over-VPN correctness depends on.
#
# WHY THIS SCRIPT EXISTS
# These four settings are NOT environment variables in the linuxserver image.
# They live only in /config/settings.json, which transmission REWRITES ON
# SHUTDOWN from its in-memory state — so hand-editing that file on a running
# container is silently discarded, and shipping a git-tracked copy would mean a
# stop/copy/start dance for every change. This script is therefore the
# git-tracked source of truth for them, applied over transmission-remote. Same
# pattern as scripts/serve-duri.sh, which owns duri's out-of-compose serve state.
#
# It is idempotent: re-running it is also the drift check.
#
# WHAT IT ASSERTS, AND WHY EACH ONE MATTERS
#   --no-portmap  UPnP/NAT-PMP off. Port-mapping requests are aimed at the ROUTER
#                 and are a classic way for a client to announce itself outside
#                 the tunnel. Also pointless here: the box publishes no inbound
#                 ports by design.
#   --no-lpd      Local Peer Discovery off. LPD multicasts on the local network —
#                 i.e. the home LAN — which is precisely the leak the tunnel
#                 exists to prevent.
#   --port        Fixed peer port. Reproducible run-to-run, and a prerequisite
#                 for Windscribe ephemeral port forwarding later (SPEC.md
#                 §Anticipated future services).
#   --uplimit     Global upload cap. THERMAL, not bandwidth: sustained seeding
#                 pins the CPU on a 7th-gen laptop chassis that also runs Home
#                 Assistant and duri.
#
# Credentials are read INSIDE the container from TR_AUTH via `--authenv`, so the
# RPC password never appears in a command line, a process list on this machine,
# or this console. See SPEC.md §Secrets.
#
# Usage:
#   scripts/settings-transmission.sh              # assert, then show the result
#   scripts/settings-transmission.sh --dry-run    # print the plan, change nothing
#
# Env overrides: BOX_HOST, BOX_SSH_KEY, PEER_PORT, UPLOAD_LIMIT_KBPS.
set -euo pipefail

BOX_HOST="${BOX_HOST:-jun@100.65.77.63}"
BOX_SSH_KEY="${BOX_SSH_KEY:-$HOME/.ssh/id_ed25519__jun_hp_spectre__homeserver}"
# Keep PEER_PORT in step with PEERPORT in torrent/compose.yaml.
PEER_PORT="${PEER_PORT:-51413}"
# Thermal ceiling, in kB/s. Lower it if the chassis runs hot under sustained
# seeding; this is the knob the SPEC's CPU/thermal budget refers to.
UPLOAD_LIMIT_KBPS="${UPLOAD_LIMIT_KBPS:-1500}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { grep '^#' "$0" | sed 's/^# \?//'; exit 0; }

say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ssh_box() { ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$BOX_SSH_KEY" "$BOX_HOST" "$@"; }

# Runs inside the transmission container. $USER/$PASS come from
# torrent/transmission.env via env_file; TR_AUTH + --authenv keep them off the
# command line. Single-quoted here on purpose: expansion happens in there.
REMOTE_SCRIPT='
  set -eu
  export TR_AUTH="$USER:$PASS"
  tr() { transmission-remote 127.0.0.1:9091 --authenv "$@"; }
  tr --no-portmap
  tr --no-lpd
  tr --port '"$PEER_PORT"'
  tr --uplimit '"$UPLOAD_LIMIT_KBPS"'
'

say "Asserting transmission settings on $BOX_HOST"
cat <<EOF
  portmapping (UPnP/NAT-PMP) : disabled
  local peer discovery (LPD) : disabled
  peer port                  : $PEER_PORT
  global upload limit        : $UPLOAD_LIMIT_KBPS kB/s
EOF

if [[ $DRY_RUN == 1 ]]; then
  echo
  echo "  [dry-run] would run, inside the transmission container:"
  echo "    transmission-remote --authenv --no-portmap --no-lpd --port $PEER_PORT --uplimit $UPLOAD_LIMIT_KBPS"
  exit 0
fi

ssh_box "cd ~/homelab && docker compose exec -T transmission sh -c '$REMOTE_SCRIPT'"

say "Current session state (transmission's own report)"
# `-si` prints the session config back. Grep to the lines we just asserted so a
# drift is visible at a glance rather than buried in the full dump.
ssh_box "cd ~/homelab && docker compose exec -T transmission sh -c '
  export TR_AUTH=\"\$USER:\$PASS\"
  transmission-remote 127.0.0.1:9091 --authenv -si
'" | grep -iE "listenport|peer port|up limit|upload limit|portmap|lpd|local peer" || {
  echo "  (could not match the expected lines — dumping full session info)" >&2
  ssh_box "cd ~/homelab && docker compose exec -T transmission sh -c '
    export TR_AUTH=\"\$USER:\$PASS\"
    transmission-remote 127.0.0.1:9091 --authenv -si
  '"
}

printf '\n\033[1;32m✓ settings asserted\033[0m\n'
echo "Re-run this after any transmission upgrade or config restore — it is the drift check."
