# Local targets and private address configuration

Public files declare behavior; actual hostnames, addresses and private source
checkout paths belong only in private configuration. **Source preparation is not
a live migration.** Do not deploy these changes before the inputs below exist
and have passed native configuration validation.

## Scripts

Copy `targets.example.sh` to `~/.config/homelab/targets.sh` on each relevant machine,
then fill the identifiers privately. This is sourced shell code: use only a file
you own and have reviewed. It must contain **identifiers only, not credentials**;
never point `HOMELAB_TARGETS_FILE` at an environment-secret file.

- `BOX_HOST`: a private SSH alias. Keep user, address and key in SSH configuration.
- `BOX_HOSTNAME`: the server's short hostname; used to decide whether verification
  should run locally or re-exec over SSH. Required on the server too, so remote
  verification does not loop back to itself.
- `BOX_URL`: the HTTPS serve origin, without a trailing slash or port.
- `REGISTRY_HOST`: the canonical `<tailnet-ip>:30500` address.
- `DURI_DIR`: an absolute local source-checkout path, supplied only where needed.

Scripts load this file explicitly (independent of interactive shell startup), or
use `HOMELAB_TARGETS_FILE` to choose another reviewed file. They require only the
inputs they use and fail before connection/deployment if one is absent. Existing
exported values can override the example's `${NAME:-local-value}` assignments.
For direct shell commands shown in other runbooks, load the identifier file into
your own shell first; exporting in a child script does not change its parent.

## Compose

The server's existing private `.env` needs:

- `TAILSCALE_IP`: the actual tailnet interface IPv4; empty/missing is rejected so
  the registry binding cannot silently become a wildcard.
- `REGISTRY_HOST`: the same canonical registry address used by the build machine.
- `BOX_FQDN`: the exact MagicDNS hostname (no scheme, path or port), required by
  Transmission's host-header allowlist. Never replace it with `*`.

Keep all other existing substitution values and image pins. This does not change
network modes, TLS termination, container ports, credentials or the VPN namespace.

## Home Assistant

Public packages reference three `!secret` keys. Provision them in the existing
volume's private `/config/secrets.yaml` **before** HA loads the updated packages:

- `homekit_advertise_ip`: the server's reserved numeric LAN IP, used by both bridges.
- `wiim_bluetooth_url` and `wiim_wifi_url`: complete numeric-IP URLs for the two
  existing commands. Their paths/commands are shown in `ha/local-values.example.yaml`.

That example is a key-name contract, not a complete secrets file. **Do not overwrite
or dump the existing secrets file.** Keep actual addresses, MACs and router
reservations in private recovery records. Numeric device URLs and stable DHCP
reservations remain required: an mDNS name can fall through to public DNS and send
commands off-LAN. Bridge names, ports, entity allowlists and REST behavior must stay
unchanged so this cleanup does not force re-pairing or alter device exposure.

## Adoption checklist (not executed by source preparation)

1. Verify and provision the local identifier file on the relevant machines, the
   Compose substitution values, and the three HA entries without exposing any
   existing credentials. Use a privately recorded address map, not public defaults.
2. Run native Compose and HA configuration validation under separate authorization.
   Syntax checks with synthetic data do not prove the server's config will load.
3. Only then authorize a deployment/reload and verify service reachability, existing
   HomeKit pairing and both audio actions. Preserve rollback material privately.

No deployment, restart, credential read or server-side migration is implied by
this document or by successful offline tests.

## Offline checks

```bash
python3 -B -m unittest discover -s scripts -p 'test_local_targets.py' -v
```

Tests use synthetic homes, targets and command stubs. Optional YAML checks use
PyYAML if it is already available; do not install it just to run these tests.
They never contact a real machine or open credential/environment-secret files.
