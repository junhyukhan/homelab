# Living-room audio — public summary

The original personal decision record has been retained verbatim in a private
archive. This summary preserves reusable design constraints, not a fresh claim
about live device state or permission to reconfigure it.

A single-input network audio receiver can arbitrate music and projector audio
without software control of a physical amplifier switch. The declarative HA
package keeps the two input-switch actions; HomeKit exposes only the intended
script entities. Device IPs, MACs, reservations and diagnostic observations belong
in private configuration/records.

Keep a reserved **numeric LAN IP** in the receiver's REST URLs. An mDNS hostname
may fall through to a public DNS wildcard when local resolution fails; do not
trade a privacy cleanup for off-LAN command delivery. The package's URLs are now
`!secret` references resolved from the private HA volume. Provision the values
before deploying; see [local-targets.md](../local-targets.md).

No automatic input-switch detection, new integration or service deployment is
introduced by this cleanup.
