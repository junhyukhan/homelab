# Torrent VPN — public summary

The original personal decision record has been retained verbatim in a private
archive. It is history, not new deployment authorization.

Transmission shares gluetun's network namespace; it does not get its own network
or published ports. Only gluetun publishes the loopback RPC port. The UI uses a
separate tailnet-only HTTPS serve port so it cannot replace the existing app's
root mount. Keep the RPC password and narrow host/source allowlists in addition
to the tailnet boundary.

Actual MagicDNS names are supplied locally through `BOX_FQDN`, never published or
replaced with `*`. Private application source checkout names are not needed to
explain the design. See [the specification](../../SPEC.md) and
[the leak-check runbook](../torrent.md) for the service contracts.
