# Host-hardening record — public summary

The original machine-specific plan, observations and completion record have been
retained verbatim in a private archive. This summary does not assert a new live
measurement or authorize firewall/service changes.

The intended policy is deny inbound by default, retain tailnet/loopback access,
and allow the explicit LAN ports required for media discovery and HomeKit.
Removing those LAN exceptions breaks the intended features. Actual LAN CIDRs,
probe-host addresses, reservations and private-app operational details are not
public examples.

See `SPEC.md` for the design and `docs/local-targets.md` for the local-input
boundary. A future authorized rollout must verify reachability from the relevant
network plane; listening sockets alone do not prove firewall exposure.
