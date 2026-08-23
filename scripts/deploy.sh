#!/usr/bin/env bash
#
# deploy.sh — the deploy loop, run ON THE BOX. Replaces `git pull && docker compose up -d`.
#
# WHY THIS EXISTS, AND WHY THE ONE-LINER WAS WRONG
# ------------------------------------------------
# `docker compose up -d` only recreates a container when the COMPOSE DEFINITION
# changes. Config that is BIND-MOUNTED from this repo — ha/packages, cloudflared,
# gerbera's config.xml — is invisible to it. Pull a change to one of those, run the
# old one-liner, and compose prints "Running" while the container keeps serving the
# old config. Nothing reports it. Verified on the box 2026-08-16.
#
# This script closes that: it diffs what the pull actually changed, maps those paths
# to services via scripts/bind-config.map, and restarts exactly those. Then it runs
# verify.sh, so a deploy that did not take is LOUD instead of silent.
#
# It is deliberately still human-triggered and still runs on the box — no control
# plane, no CI pipeline (SPEC.md §Non-goals). It replaces the one-liner, not the model.
#
# Usage:
#   scripts/deploy.sh              # pull, reconcile, restart what changed, verify
#   scripts/deploy.sh --dry-run    # show what WOULD happen, change nothing
#   scripts/deploy.sh --no-verify  # skip the verify pass (not recommended)
#
# duri is NOT deployed by this script — it is an artifact with a pinned image tag
# and its own build/push/pin/reconcile flow. Use scripts/deploy-duri.sh from the Mac.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/homelab}"
MAP_FILE="scripts/bind-config.map"
DRY_RUN=0
RUN_VERIFY=1

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --no-verify) RUN_VERIFY=0 ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# This pulls and restarts containers — it belongs on the box, not the Mac. Running
# it on a dev machine would "succeed" against the wrong docker daemon and repo.
if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "✗ $REPO_DIR is not a git checkout — run this ON THE BOX (ssh jun-hp-spectre)" >&2
  exit 1
fi
cd "$REPO_DIR"

say "Fetching"
before="$(git rev-parse HEAD)"
if [[ $DRY_RUN == 1 ]]; then
  git fetch --quiet
  after="$(git rev-parse '@{u}')"
  note "[dry-run] would fast-forward $(git rev-parse --short "$before") -> $(git rev-parse --short "$after")"
else
  git pull --ff-only --quiet
  after="$(git rev-parse HEAD)"
fi

if [[ "$before" == "$after" ]]; then
  note "already up to date at $(git rev-parse --short HEAD)"
else
  note "$(git rev-parse --short "$before") -> $(git rev-parse --short "$after")"
fi

changed="$(git diff --name-only "$before" "$after" || true)"

say "Reconciling the stack"
if [[ $DRY_RUN == 1 ]]; then
  note "[dry-run] docker compose up -d"
else
  docker compose up -d
fi

# The part `docker compose up -d` cannot do. Compose already handled any service
# whose DEFINITION changed; these are the ones whose bind-mounted CONTENT changed.
say "Restarting services whose bind-mounted config changed"
restarted=0
if [[ -z "$changed" ]]; then
  note "no file changes — nothing to restart"
else
  while read -r prefix service; do
    [[ -z "${prefix:-}" || "$prefix" == \#* ]] && continue
    if grep -q "^${prefix}" <<<"$changed"; then
      hits="$(grep "^${prefix}" <<<"$changed" | tr '\n' ' ')"
      if [[ $DRY_RUN == 1 ]]; then
        note "[dry-run] would restart $service  (changed: $hits)"
      else
        note "restarting $service  (changed: $hits)"
        docker compose restart "$service"
      fi
      restarted=$((restarted + 1))
    fi
  done < <(grep -vE '^\s*(#|$)' "$MAP_FILE")
  [[ $restarted == 0 ]] && note "no bind-mounted config changed — nothing to restart"
fi

if [[ $RUN_VERIFY == 1 && $DRY_RUN == 0 ]]; then
  say "Verifying"
  exec ./scripts/verify.sh
fi

printf '\n\033[1;32m✓ deploy complete\033[0m\n'
