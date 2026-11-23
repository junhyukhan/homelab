# box.sh — shared local target configuration. Sourced, not run.
# Actual host identities and private source paths never have public defaults.
# Optional reviewed shell fragment, containing identifiers only (no credentials):
#   ~/.config/homelab/targets.sh
# Override its location with HOMELAB_TARGETS_FILE; see targets.example.sh.
# Never point this at a credential/environment-secret file.

_TARGETS_FILE="${HOMELAB_TARGETS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/homelab/targets.sh}"
if [[ -f "$_TARGETS_FILE" ]]; then
  source "$_TARGETS_FILE" || return 2
fi
unset _TARGETS_FILE

# Validate only values required by the caller, before any network/service action.
# Report key names, never values.
require_target() {
  local key
  for key in "$@"; do
    if [[ -z "${!key:-}" ]]; then
      printf 'Missing local target: %s (see docs/local-targets.md)\n' "$key" >&2
      return 2
    fi
  done
}

say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ssh_box() {
  require_target BOX_HOST || return 2
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOX_HOST" "$@"
}
