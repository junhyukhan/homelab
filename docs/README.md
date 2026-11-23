# homelab — docs

**Read this first.** This file is a router: it says where each answer lives. Its table states no
facts of its own; the lists below it are kept by hand, so check them against their folders. The facts live in [`../SPEC.md`](../SPEC.md), the source of
truth. When something changes, `SPEC.md` updates first and code follows. Commands, deploy and
repo rules are in [`../AGENTS.md`](../AGENTS.md).

## Where to look

| Looking for | Go to |
|---|---|
| Required private/local inputs and the pre-deploy migration gate | [`local-targets.md`](local-targets.md) |
| What the homelab is for, and what it deliberately is not | `SPEC.md` §Goals, §Non-goals |
| How the box is laid out; the registry's one canonical name | §Architecture |
| Which service is reachable how, and what actually enforces it | §Access planes, §Host firewall |
| One service: duri, the registry and cloudflared (§Services' body), or the torrent stack, media serving, Home Assistant, the HomeKit bridge (its subsections) | §Services |
| Day-to-day commands, the deploy loop, per-service addresses, bootstrap and recovery | [`../README.md`](../README.md), the runbook |
| Services anticipated but not built | §Anticipated future services |
| Limits the design must respect; the `.env` keys | §Constraints |
| Why a choice was made | §Decisions (with rationale), then [`decisions/`](decisions/) |
| How deploys and verification work (`scripts/verify.sh`), and the next rung | §Deploy / control model |
| A procedure | §Operational runbooks, and the runbooks below |
| What is undecided | §Open questions |

## Runbooks

- [`add-a-service.md`](add-a-service.md): the everyday workflow for adding a service on Compose.
- [`bootstrap.md`](bootstrap.md): stand up the homelab from a clean OS install.
- [`torrent.md`](torrent.md): the torrent stack's first-run setup and leak check.
- [`tunnel-setup.md`](tunnel-setup.md): create the locally-managed cloudflared tunnel.

## Plans and summaries

- [`home-assistant-followups.md`](../plan/home-assistant-followups.md): Home Assistant follow-ups.
- [`duri-followups.md`](../plan/duri-followups.md) and
  [`box-hardening.md`](../plan/box-hardening.md): public summaries. Their original
  machine-specific plans are retained privately; the summaries do not claim a new
  live measurement or authorize pending work.

## Decisions

Historical records live in [`decisions/`](decisions/). Two personalized records
now have public summaries, as marked below; their originals are retained privately.
Use `decisions/TEMPLATE.md` for new decision records.

- [`access-planes.md`](decisions/access-planes.md): which service is reachable how.
- [`app-env-contract.md`](decisions/app-env-contract.md): app env as a contract, pushed and gated.
- [`branch-reclamation.md`](decisions/branch-reclamation.md): three stale branches were
  squash-merge residue, not unreclaimed work.
- [`dlna-media.md`](decisions/dlna-media.md): serving downloads to the projector.
- [`living-room-audio.md`](decisions/living-room-audio.md): public design summary; personal record retained privately.
- [`torrent-vpn.md`](decisions/torrent-vpn.md): public design summary; personal record retained privately.
