#!/usr/bin/env bash
#
# deploy-duri.sh — one-command deploy of duri to the homelab box (SPEC Pattern A).
#
# Cross-builds the amd64 image from duri's main HEAD, stamps it with the git SHA +
# OCI provenance, pushes to the Tailscale-private registry, pins the tag INLINE in
# compose.yaml (git = the deploy log), commits+pushes this repo, reconciles the box
# (git pull && up -d), and verifies the running commit via /api/version.
#
# Usage:
#   scripts/deploy-duri.sh                # build + deploy duri@<main HEAD sha>
#   scripts/deploy-duri.sh --tag <sha>    # (re)deploy an EXISTING registry tag — rollback path, no rebuild
#   scripts/deploy-duri.sh --dry-run      # print the plan, change nothing
#   scripts/deploy-duri.sh --dirty-ok     # allow a dirty duri working tree (SHA gets a -dirty suffix)
#
# Env overrides: DURI_DIR, BOX_HOST, BOX_SSH_KEY, REGISTRY_HOST, BOX_URL.
set -euo pipefail

# --- config (defaults match the current homelab) -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DURI_DIR="${DURI_DIR:-$(cd "$HOMELAB_DIR/../duri/v3" && pwd)}"
REGISTRY_HOST="${REGISTRY_HOST:-100.65.77.63:30500}"
BOX_HOST="${BOX_HOST:-jun@100.65.77.63}"
BOX_SSH_KEY="${BOX_SSH_KEY:-$HOME/.ssh/id_ed25519__jun_hp_spectre__homeserver}"
BOX_URL="${BOX_URL:-http://100.65.77.63:3000}"
BOX_HOMELAB_DIR="${BOX_HOMELAB_DIR:-~/homelab}"

TAG=""; DRY_RUN=0; DIRTY_OK=0; SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; SKIP_BUILD=1; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --dirty-ok) DIRTY_OK=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
run() { if [[ $DRY_RUN == 1 ]]; then echo "  [dry-run] $*"; else eval "$*"; fi; }
ssh_box() { ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$BOX_SSH_KEY" "$BOX_HOST" "$@"; }

# --- 1. resolve the tag from duri's git state --------------------------------
if [[ -z "$TAG" ]]; then
  TAG="$(git -C "$DURI_DIR" rev-parse --short HEAD)"
  if ! git -C "$DURI_DIR" diff --quiet || ! git -C "$DURI_DIR" diff --cached --quiet; then
    if [[ $DIRTY_OK == 1 ]]; then TAG="${TAG}-dirty"
    else echo "✗ duri working tree is dirty — commit first, or pass --dirty-ok" >&2; exit 1; fi
  fi
fi
IMAGE="$REGISTRY_HOST/duri:$TAG"
say "Deploying duri → $IMAGE  (dry-run=$DRY_RUN, skip-build=$SKIP_BUILD)"

# --- 2. build + push (skipped on --tag rollback) -----------------------------
if [[ $SKIP_BUILD == 0 ]]; then
  # NEXT_PUBLIC_* (public, inlined into the client bundle) — extracted file-to-file
  # from the prod env into a temp, never printed. Server secrets are NOT baked.
  ARGFILE="$(mktemp)"; trap 'rm -f "$ARGFILE"' EXIT
  grep -E '^NEXT_PUBLIC_SUPABASE_(URL|ANON_KEY)=' "$DURI_DIR/.env.hosted" > "$ARGFILE"
  # shellcheck disable=SC1090
  set -a; . "$ARGFILE"; set +a
  say "Cross-building amd64 (the box can't run arm64)…"
  run "docker buildx build --platform linux/amd64 --load \
    --build-arg NEXT_PUBLIC_SUPABASE_URL --build-arg NEXT_PUBLIC_SUPABASE_ANON_KEY \
    --build-arg BUILD_SHA='$TAG' --build-arg BUILD_TIME='$(date -u +%Y-%m-%dT%H:%M:%SZ)' \
    -t '$IMAGE' '$DURI_DIR'"
  say "Pushing to the registry…"
  run "docker push '$IMAGE'"
else
  say "Rollback/pin mode — reusing existing registry image (no rebuild)."
fi

# --- 3. pin the tag inline in compose.yaml, commit + push --------------------
COMPOSE="$HOMELAB_DIR/compose.yaml"
if grep -qE "^\s*image: \\\$\{REGISTRY_HOST\}/duri:$TAG(\s|$)" "$COMPOSE"; then
  say "compose.yaml already pins duri:$TAG — no bump needed."
else
  say "Pinning duri:$TAG in compose.yaml…"
  run "sed -i.bak -E 's#(image: \\\$\{REGISTRY_HOST\}/duri:)[^ ]+#\\1$TAG#' '$COMPOSE' && rm -f '$COMPOSE.bak'"
  run "git -C '$HOMELAB_DIR' add compose.yaml"
  run "git -C '$HOMELAB_DIR' commit -m 'deploy(duri): $TAG'"
  run "git -C '$HOMELAB_DIR' push"
fi

# --- 4. reconcile the box (GitOps pull) --------------------------------------
say "Reconciling the box (git pull && up -d duri)…"
run "ssh -o BatchMode=yes -o ConnectTimeout=10 -i '$BOX_SSH_KEY' '$BOX_HOST' \
  'cd $BOX_HOMELAB_DIR && git pull --ff-only && docker compose up -d duri'"

# --- 5. verify the running commit --------------------------------------------
if [[ $DRY_RUN == 1 ]]; then say "dry-run: skipping verify."; exit 0; fi
say "Verifying $BOX_URL/api/version reports $TAG…"
for i in $(seq 1 10); do
  live="$(curl -s -m 5 "$BOX_URL/api/version" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true)"
  if [[ "$live" == "$TAG" ]]; then
    printf '\n\033[1;32m✓ deployed — %s is live at %s\033[0m\n' "$TAG" "$BOX_URL"
    prev="$(git -C "$HOMELAB_DIR" log -2 --format=%s -- compose.yaml | sed -n '2p' | sed 's/deploy(duri): //')"
    [[ -n "$prev" ]] && echo "  rollback: scripts/deploy-duri.sh --tag $prev"
    exit 0
  fi
  sleep 3
done
echo "✗ verify failed — $BOX_URL/api/version did not report $TAG (got: '${live:-<none>}')" >&2
echo "  check: ssh $BOX_HOST 'docker logs --tail 40 homelab-duri-1'" >&2
exit 1
