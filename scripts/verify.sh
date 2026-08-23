#!/usr/bin/env bash
#
# verify.sh — assert the box actually matches what this repo declares.
#
# WHY THIS EXISTS
# ---------------
# The deploy model is manual GitOps, so "did that take?" was answered by eyeballing
# `docker ps`. That misses exactly the failures this repo keeps running into: things
# compose IGNORES SILENTLY rather than erroring on. Every check below exists because
# something in SPEC.md says it can break without saying so.
#
# It also covers the OUT-OF-COMPOSE state — `tailscale serve` mounts and HA's
# configuration.yaml include — which lives on the box, not in compose, and which a
# volume restore or a fresh box would silently drop.
#
# Runs on the box. Invoked from anywhere else, it re-execs itself over SSH, so the
# same command works from the Mac:
#   scripts/verify.sh
#
# Exit status is 0 only if every check passes — safe to chain or run from a cron.
#
# Env overrides: BOX_SSH_HOST, REPO_DIR.
set -uo pipefail

BOX_HOSTNAME="jun-hp-spectre"
BOX_SSH_HOST="${BOX_SSH_HOST:-jun-hp-spectre}"
REPO_DIR="${REPO_DIR:-$HOME/homelab}"

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { grep '^#' "$0" | sed 's/^# \?//'; exit 0; }

# Re-exec on the box if we're not already there. Everything below inspects docker,
# listening sockets and tailscaled — all of which only mean anything on the box.
if [[ "$(hostname -s 2>/dev/null)" != "$BOX_HOSTNAME" ]]; then
  exec ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOX_SSH_HOST" \
    "cd '$REPO_DIR' && ./scripts/verify.sh"
fi

cd "$REPO_DIR"

FAILED=0
say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }

# Services that are intentionally NOT running. A check that always fails gets
# ignored, and an ignored check is worse than no check — so a known-down service
# is a WARNING with a stated reason, never a silent skip and never a failure.
#
# Each entry must carry a reason, and the entry is DELETED the moment that reason
# stops being true:
#
#   cloudflared — the tunnel has never been created. cloudflared/config.yml still
#     holds <TUNNEL_NAME_OR_ID> placeholders, which is the documented state in
#     SPEC.md §Access planes ("no real routes"). It therefore crash-loops roughly
#     every 60s. Runbook to finish it: docs/tunnel-setup.md.
EXPECTED_DOWN="cloudflared"

# ── 1. Repo state ────────────────────────────────────────────────────────────
# A box that is behind, or dirty, makes every check below a lie about main.
say "Repo"
git fetch --quiet origin 2>/dev/null || true
head_sha="$(git rev-parse HEAD)"
up_sha="$(git rev-parse '@{u}' 2>/dev/null || echo unknown)"
if [[ "$head_sha" == "$up_sha" ]]; then
  ok "in sync with upstream at $(git rev-parse --short HEAD)"
else
  bad "box is NOT at upstream: HEAD=$(git rev-parse --short HEAD) upstream=$(git rev-parse --short "$up_sha" 2>/dev/null || echo '?')"
fi
if [[ -z "$(git status --porcelain)" ]]; then
  ok "working tree clean"
else
  bad "working tree dirty — the box has changes that are not in git:"
  git status --short | sed 's/^/      /'
fi

# ── 2. Services ──────────────────────────────────────────────────────────────
# Derived from compose, not hardcoded, so a new service is covered automatically.
say "Services"
running="$(docker compose ps --services --status running 2>/dev/null)"
for svc in $(docker compose config --services 2>/dev/null); do
  if grep -qx "$svc" <<<"$running"; then
    ok "$svc running"
  elif grep -qw "$svc" <<<"$EXPECTED_DOWN"; then
    state="$(docker compose ps -a --format '{{.Status}}' "$svc" 2>/dev/null | head -1)"
    warn "$svc not running — EXPECTED, see EXPECTED_DOWN in this script (currently: ${state:-absent})"
  else
    bad "$svc NOT running"
  fi
done

# ── 3. Bind-mount coverage ───────────────────────────────────────────────────
# The check that stops the silent-no-op defect from coming back: every `./` bind
# compose declares must have a restart mapping, or deploy.sh would quietly skip it.
say "Bind-mounted config is covered by scripts/bind-config.map"
mapped="$(grep -vE '^\s*(#|$)' scripts/bind-config.map | awk '{print $1}' | sed 's:/*$::')"
for path in $(grep -hoE '^\s+- \./[^:]+' compose.yaml torrent/compose.yaml 2>/dev/null | sed 's/.*\.\///'); do
  found=0
  while read -r p; do
    [[ -z "$p" ]] && continue
    # A row covers the exact path or anything beneath it. Trailing slashes are
    # normalised off both sides so `cloudflared` and `cloudflared/` both match.
    [[ "$path" == "$p" || "$path" == "$p"/* ]] && found=1
  done <<<"$mapped"
  if [[ $found == 1 ]]; then
    ok "./$path is mapped"
  else
    bad "./$path is bind-mounted but has NO row in scripts/bind-config.map — deploy.sh would not restart its service"
  fi
done

# ── 4. HA out-of-compose state ───────────────────────────────────────────────
# The `packages:` include lives in the ha_data VOLUME, not git. A volume restore
# drops it and HA keeps starting happily with the scripts simply gone.
say "Home Assistant declarative config"
if docker exec homelab-home-assistant-1 test -d /config/packages 2>/dev/null; then
  ok "/config/packages is mounted"
  for f in $(ls -1 ha/packages/ 2>/dev/null); do
    if docker exec homelab-home-assistant-1 test -f "/config/packages/$f" 2>/dev/null; then
      ok "  $f present in the container"
    else
      bad "  $f is in git but NOT in the container"
    fi
  done
else
  bad "/config/packages is NOT mounted — the ha/packages bind is missing"
fi
if docker exec homelab-home-assistant-1 grep -qE '^\s*packages:\s*!include_dir_named packages' /config/configuration.yaml 2>/dev/null; then
  ok "configuration.yaml has the packages include"
else
  bad "configuration.yaml is MISSING 'packages: !include_dir_named packages' — everything in ha/packages/ is being ignored"
fi

# ── 5. Listening ports ───────────────────────────────────────────────────────
# Loopback-bound ports are a containment guarantee, not a detail: duri and
# transmission must NOT be listening on all interfaces.
say "Listening ports"
listening="$(ss -ltn 2>/dev/null)"
check_port() { grep -q "$1" <<<"$listening" && ok "$2 ($1)" || bad "$2 ($1) NOT listening"; }
check_port ":8123"            "home-assistant"
check_port ":49494"           "gerbera (DLNA)"
check_port ":30500"           "registry"
check_port "127.0.0.1:3000"   "duri (loopback-only)"
check_port "127.0.0.1:9091"   "transmission (loopback-only)"
# HomeKit bridge ports are read from the package file so adding a bridge needs no edit here.
for hkport in $(grep -oE '^\s+port:\s*[0-9]+' ha/packages/homekit.yaml 2>/dev/null | grep -oE '[0-9]+'); do
  check_port ":$hkport" "homekit bridge"
done

# ── 6. tailscale serve ───────────────────────────────────────────────────────
# Lives in tailscaled state, not compose. duri is a PWA and needs the secure
# context; losing this mount broke it silently once already (2026-07-17).
say "tailscale serve (out-of-compose state)"
serve="$(tailscale serve status 2>/dev/null)"
if [[ -z "$serve" ]]; then
  bad "no tailscale serve config (or 'tailscale set --operator' not granted)"
else
  grep -q "127.0.0.1:3000" <<<"$serve" && ok "duri served over HTTPS" || bad "duri serve mount MISSING"
  grep -q "127.0.0.1:9091" <<<"$serve" && ok "transmission served on :8443"  || bad "transmission serve mount MISSING"
fi

# ── 7. Torrent containment ───────────────────────────────────────────────────
# The whole VPN design rests on transmission having no network stack of its own.
say "Torrent containment"
netmode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' homelab-transmission-1 2>/dev/null || echo '?')"
if [[ "$netmode" == container:* ]]; then
  ok "transmission shares gluetun's netns ($netmode)"
else
  bad "transmission NetworkMode is '$netmode' — expected container:<gluetun>. It may be reaching the ISP directly."
fi

# ── Result ───────────────────────────────────────────────────────────────────
if [[ $FAILED == 0 ]]; then
  printf '\n\033[1;32m✓ all checks passed — the box matches the repo\033[0m\n'
  exit 0
else
  printf '\n\033[1;31m✗ %d check(s) failed\033[0m\n' "$FAILED"
  exit 1
fi
