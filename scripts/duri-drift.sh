#!/usr/bin/env bash
#
# duri-drift.sh — how far the duri pin in compose.yaml trails duri's main.
#
# The box does not auto-deploy, so after a duri merge nothing else says the box is
# behind: on 2026-08-08 it sat two releases behind for days. This answers "is there
# code to deploy?" from git alone: no SSH, no tailnet, so it works off the network.
# What the box is actually serving is /api/version.
#
# Commits that cannot change the image (docs/, build/, *.md) are not counted: on
# 2026-09-07 four docs-only commits read as "4 behind" while the box ran the latest
# code. The exclusions are a closed list, never an allow-list, so a new source
# directory is over-reported rather than missed.
#
# Usage:
#   scripts/duri-drift.sh
#
# Exit status: 0 current, 1 code to deploy, 2 cannot tell (never read as current).
# Env overrides: DURI_DIR (default ../duri-v3), DURI_REF (default main).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DURI_DIR="${DURI_DIR:-$HOMELAB_DIR/../duri-v3}"
REF="${DURI_REF:-main}"

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { grep '^#' "$0" | sed 's/^# \?//'; exit 0; }

pin="$(sed -n 's|^[[:space:]]*image:[[:space:]]*[^[:space:]]*/duri:\([^[:space:]#]*\).*|\1|p' \
  "$HOMELAB_DIR/compose.yaml" | head -1)"
[[ -n "$pin" ]] || { echo "? no pinned duri tag in compose.yaml" >&2; exit 2; }
[[ -d "$DURI_DIR/.git" ]] || { echo "? no duri checkout at $DURI_DIR (set DURI_DIR)" >&2; exit 2; }

# A tag may carry a -dirty suffix (deploy-duri.sh --dirty-ok); compare on the SHA.
sha="${pin%%-*}"
head="$(git -C "$DURI_DIR" rev-parse --short "$REF" 2>/dev/null)" \
  || { echo "? no $REF in $DURI_DIR" >&2; exit 2; }
# A pin absent from history (rebased away, or never built from this repo) is
# unknown, not zero: zero would read as "current".
git -C "$DURI_DIR" cat-file -e "$sha^{commit}" 2>/dev/null \
  || { echo "? box pin $pin is not in duri's history" >&2; exit 2; }

behind="$(git -C "$DURI_DIR" rev-list --count "$sha..$REF")" || exit 2
deployable="$(git -C "$DURI_DIR" rev-list --count "$sha..$REF" -- \
  . ':(exclude)docs/' ':(exclude)build/' ':(exclude)*.md')" || exit 2

if [[ "$deployable" == 0 ]]; then
  echo "✓ duri pin $pin is current with $REF $head ($behind non-deployable commit(s) since)"
  exit 0
fi
echo "✗ duri pin $pin trails $REF $head: $deployable deployable of $behind commit(s). Deploy: scripts/deploy-duri.sh"
exit 1
