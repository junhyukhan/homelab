# Local targets: decisions

Append-only. Han's words verbatim; the current state is in [`local-targets.md`](local-targets.md).

## 2026-11-24: land the clean-up, provision the values and deploy, all now

> yes, start on the homelab clean-up

> all three now, and yes you can append

All three stages in one pass: land the source change, provision the private values, then deploy and
check. "append" lets the agent append to the box's `.env` and HA's `secrets.yaml` without reading them.
