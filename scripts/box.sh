# box.sh — where the box is and how to reach it. Sourced by the other scripts; not run.
#
# BOX_HOST is an alias from ~/.ssh/config, so the user, address and key live there
# and no script names a key file. On the machine that runs these scripts:
#
#   Host jhkn-homelab
#       HostName jun-hp-spectre.tail114865.ts.net
#       User jun
#       IdentityFile <your key>
#
# Env overrides: BOX_HOST, BOX_URL.

BOX_HOST="${BOX_HOST:-jhkn-homelab}"
BOX_URL="${BOX_URL:-https://jun-hp-spectre.tail114865.ts.net}"   # HTTPS via tailscale serve

say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ssh_box() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOX_HOST" "$@"; }
