# Local targets: decisions

Append-only: the decision and a short reason. The current state is in
[`local-targets.md`](local-targets.md).

## 2026-11-24: land the clean-up, provision the values and deploy, all now

All three stages in one pass: land the source change, provision the private values, then deploy and
check. Han allowed appending, which lets the agent append to the box's `.env` and HA's `secrets.yaml` without reading them.
