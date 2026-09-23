# homelab — docs

**Read this first.** This file is a router: it says where each answer lives and states no facts of
its own, so it cannot drift from them. The facts live in [`../SPEC.md`](../SPEC.md), the source of
truth. When something changes, `SPEC.md` updates first and code follows. Commands, deploy and
repo rules are in [`../AGENTS.md`](../AGENTS.md).

## Where to look

| Looking for | Go to |
|---|---|
| What the homelab is for, and what it deliberately is not | `SPEC.md` §Goals, §Non-goals |
| How the box is laid out; the registry's one canonical name | §Architecture |
| Which service is reachable how, and what actually enforces it | §Access planes, §Host firewall |
| One service: the torrent stack, media serving, Home Assistant, the HomeKit bridge | §Services and its subsections |
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

## Open work

The manifest's declared backlog, in `../plan/`:

- [`duri-followups.md`](../plan/duri-followups.md): the duri service after its first homelab deploy.
- [`home-assistant-followups.md`](../plan/home-assistant-followups.md): Home Assistant follow-ups.

Also in `plan/`: [`box-hardening.md`](../plan/box-hardening.md), executed 2026-09-14.

## Decisions

One file per topic in [`decisions/`](decisions/), each a verbatim ask plus Discussion; copy
`decisions/TEMPLATE.md` to start one.

- [`access-planes.md`](decisions/access-planes.md): which service is reachable how.
- [`app-env-contract.md`](decisions/app-env-contract.md): app env as a contract, pushed and gated.
- [`branch-reclamation.md`](decisions/branch-reclamation.md): three stale branches were
  squash-merge residue, not unreclaimed work.
- [`dlna-media.md`](decisions/dlna-media.md): serving downloads to the projector.
- [`living-room-audio.md`](decisions/living-room-audio.md): one speaker, two sources, one switch.
- [`torrent-vpn.md`](decisions/torrent-vpn.md): Transmission behind Windscribe.
