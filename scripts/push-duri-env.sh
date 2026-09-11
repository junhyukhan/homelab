#!/usr/bin/env bash
#
# push-duri-env.sh — project duri's server-only secrets onto the box, without a
# human ever copy-pasting a key.
#
# The keys shipped are exactly the NAMES declared in `duri.env.example` (the
# contract); the values come from **Infisical** (`prod` environment), exported
# into a 0600 temp file. Nothing else is read and nothing is sent that the
# contract does not declare.
#
# Infisical is the single source of truth — repos/docs/decisions/secrets-management.md.
# This script is the box's delivery mechanism: option C in that record, export on
# the Mac and scp to the box, so the box holds no Infisical credential of its own.
# The trade is that the box is stale until this runs; the deploy preflight's
# liveness check is what catches a value that is present but dead.
#
# **No value is ever printed, echoed, or passed as a command argument.** The
# extraction is `grep` redirected straight into a 0600 temp file, which is
# `scp`'d and then removed by an EXIT trap — the same file-to-file discipline
# `deploy-duri.sh` already uses for its build args.
#
# Usage:
#   scripts/push-duri-env.sh              # preflight, back up, push, verify
#   scripts/push-duri-env.sh --dry-run    # report what WOULD be pushed (names only)
#
# Env overrides: DURI_DIR, BOX_HOST, BOX_SSH_KEY, BOX_HOMELAB_DIR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DURI_DIR="${DURI_DIR:-$(cd "$HOMELAB_DIR/../duri-v3" && pwd)}"
BOX_HOST="${BOX_HOST:-jun@100.65.77.63}"
BOX_SSH_KEY="${BOX_SSH_KEY:-$HOME/.ssh/id_ed25519__jun_hp_spectre__homeserver}"
BOX_HOMELAB_DIR="${BOX_HOMELAB_DIR:-~/homelab}"

CONTRACT="$HOMELAB_DIR/duri.env.example"
INFISICAL_ENV="${INFISICAL_ENV:-prod}"
SOURCE=""   # set below — exported from Infisical into a 0600 temp file

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ssh_box() { ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$BOX_SSH_KEY" "$BOX_HOST" "$@"; }

[[ -f "$CONTRACT" ]] || die "contract not found: $CONTRACT"
command -v infisical >/dev/null || die "infisical CLI not found — brew install infisical/get-cli/infisical"

# --- pull the values from Infisical, file-to-file -----------------------------
# `--output-file` writes straight to disk, so values never pass through a shell
# variable, an echoed pipe, or the process table. The temp file is chmod 600
# BEFORE the export writes into it, so it is never briefly world-readable. Both
# temps are removed by the single EXIT trap set here.
SOURCE="$(mktemp)"; chmod 600 "$SOURCE"
trap 'rm -f "$SOURCE" "${STAGE:-}"' EXIT
say "Exporting the '$INFISICAL_ENV' environment from Infisical"
( cd "$DURI_DIR" && infisical export --env="$INFISICAL_ENV" --format=dotenv --output-file="$SOURCE" ) \
  || die "infisical export failed — logged in? (infisical login). Nothing was sent."
# An empty export is the dangerous case: the projection below would come out
# short, and without this the failure would surface as a confusing count error
# rather than the real cause.
[[ -s "$SOURCE" ]] || die "infisical export produced an EMPTY file — refusing to push. Nothing was sent."
ok "exported $(grep -cE '^[A-Z][A-Z0-9_]*=' "$SOURCE") key(s) from Infisical"

# The contract's declared key names. Comments and blanks are skipped; only the
# name is taken, so a stray value in the example can never leak into this list.
# bash 3.2 (what macOS ships) has no `mapfile`, and this runs on the Mac —
# read the names with a portable loop instead.
KEYS=()
while IFS= read -r _k; do [ -n "$_k" ] && KEYS+=("$_k"); done < <(grep -oE '^[A-Z][A-Z0-9_]*=' "$CONTRACT" | tr -d '=')
[[ ${#KEYS[@]} -gt 0 ]] || die "contract declares no keys — refusing to push an empty env"

say "Contract declares ${#KEYS[@]} key(s): ${KEYS[*]}"

# --- preflight the SOURCE ----------------------------------------------------
# A wholesale replace is only safe if every declared key is present here, so a
# missing one must stop us BEFORE the box file is touched. `grep -q` tests
# presence without emitting the value.
say "Preflight: $SOURCE"
MISSING=()
for k in "${KEYS[@]}"; do
  if grep -qE "^${k}=.+" "$SOURCE"; then ok "$k"; else bad "$k  (absent or empty)"; MISSING+=("$k"); fi
done
[[ ${#MISSING[@]} -eq 0 ]] || die "Infisical '$INFISICAL_ENV' is missing: ${MISSING[*]} — fix it there first, nothing was sent"

if [[ $DRY_RUN == 1 ]]; then
  say "dry-run: would replace $BOX_HOMELAB_DIR/duri.env with the ${#KEYS[@]} key(s) above."
  echo "  (a timestamped backup would be kept on the box)"
  exit 0
fi

# --- build the projection, file-to-file --------------------------------------
STAGE="$(mktemp)"; chmod 600 "$STAGE"   # the EXIT trap set above covers both temps
{
  echo "# Generated by scripts/push-duri-env.sh — do not hand-edit."
  echo "# Keys are the contract in homelab/duri.env.example; values come from"
  echo "# Infisical, environment: $INFISICAL_ENV. Re-run the script to update."
  echo "# Pushed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAGE"
for k in "${KEYS[@]}"; do
  grep -E "^${k}=" "$SOURCE" | head -1 >> "$STAGE"
done

# Sanity: the projection must have exactly the declared keys. Counts only —
# never the contents.
GOT="$(grep -cE '^[A-Z][A-Z0-9_]*=' "$STAGE")"
[[ "$GOT" -eq "${#KEYS[@]}" ]] || die "projection has $GOT keys, expected ${#KEYS[@]} — refusing to push"

# --- back up, then replace ---------------------------------------------------
# Replace rather than merge, on purpose: the contract is the source of truth, so
# a key on the box that is not declared is by definition undeclared and should
# not survive. The backup is the escape hatch if that judgement is wrong.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
say "Backing up the box's current duri.env → duri.env.bak.$STAMP"
ssh_box "cd $BOX_HOMELAB_DIR && [ -f duri.env ] && cp -p duri.env duri.env.bak.$STAMP || true"

say "Pushing ${#KEYS[@]} key(s) to $BOX_HOST:$BOX_HOMELAB_DIR/duri.env"
scp -q -o BatchMode=yes -i "$BOX_SSH_KEY" "$STAGE" "$BOX_HOST:$BOX_HOMELAB_DIR/duri.env"
ssh_box "chmod 600 $BOX_HOMELAB_DIR/duri.env"

# --- verify by NAME on the box ----------------------------------------------
say "Verifying on the box (names only)"
REMOTE_KEYS="$(ssh_box "grep -oE '^[A-Z][A-Z0-9_]*=' $BOX_HOMELAB_DIR/duri.env | tr -d '=' | sort | tr '\n' ' '")"
for k in "${KEYS[@]}"; do
  case " $REMOTE_KEYS " in *" $k "*) ok "$k" ;; *) die "verify failed: $k did not land" ;; esac
done

say "Done. The container does NOT pick this up until it is recreated:"
echo "  ssh $BOX_HOST 'cd $BOX_HOMELAB_DIR && docker compose up -d --force-recreate duri'"
echo "  (or just run scripts/deploy-duri.sh, which recreates as part of the deploy)"
