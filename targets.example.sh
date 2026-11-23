# Copy to ~/.config/homelab/targets.sh OUTSIDE this public checkout.
# This is sourced shell code: use only your own reviewed file, no credentials.
# Fill values on each relevant machine before using deployment/verification tools.
# Empty placeholders deliberately do not establish working connection targets.
# Existing environment values take precedence over this example's local defaults.
export BOX_HOST="${BOX_HOST:-}"           # an alias from your private SSH config
export BOX_HOSTNAME="${BOX_HOSTNAME:-}"   # server's short hostname (for verify.sh)
export BOX_URL="${BOX_URL:-}"             # https://<box-fqdn>, without trailing slash
export REGISTRY_HOST="${REGISTRY_HOST:-}" # <tailnet-ip>:30500
export DURI_DIR="${DURI_DIR:-}"           # absolute path to the private app checkout
# Compose separately reads local .env: TAILSCALE_IP, REGISTRY_HOST, BOX_FQDN.
# The server needs BOX_HOSTNAME and BOX_HOST for remote verification dispatch.
