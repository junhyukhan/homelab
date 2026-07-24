# AGENTS.md — homelab

Guidance for any coding agent working in this repository.

Single box (i7-7th-gen laptop, 8 GB RAM, Debian, headless, on Tailscale) that hosts
long-running personal services with Docker Compose. All state is in named Docker
volumes; all config is in this repo.

## Read first

- **`SPEC.md`** — the source of truth for *what* runs and *why* (goals, architecture,
  access planes, decisions). Read it before adding, removing, or changing any service.
  This is homelab's "read-first" state layer (its equivalent of a `docs/README.md`).
- **`README.md`** — the runbook: deploy loop, day-to-day commands, per-service addresses,
  bootstrap/recovery.
- **`docs/decisions/`** — append-only decision logs: the **verbatim ask + Discussion** behind
  each choice (copy `docs/decisions/TEMPLATE.md`). `SPEC.md §Decisions` states *what* was
  decided as current fact; `docs/decisions/` preserves the *why* and how it evolved, in Han's
  own words. This is the workspace-wide shape — see `../docs/repo-docs-standardization.md`.

Keep both current: **when a permanent service changes, update `SPEC.md` first, then the
code** — spec before config, never reverse-derive the spec from `compose.yaml`.

## Boundaries (do not violate)

- **State & config:** all durable state lives in named Docker volumes; all config lives
  in this repo. Nothing important lives only on the box.
- **Secrets:** live in `*.env` files (e.g. `.env`, `duri.env`) which are gitignored —
  never read or print their values. To learn what keys a file holds, read the matching
  `*.env.example`. When a secret must move, do it file-to-file (never echo/cat to console).
- **No inbound ports.** Two ways in: Tailscale (the default — being on the tailnet *is*
  the auth) and an egress-only cloudflared tunnel (for consciously-public services behind
  Cloudflare Access). Public exposure is opt-in per service, never the default.
- **Own images are pinned** by version/SHA tag inline in `compose.yaml`, never `:latest`.

## Deploy loop

Intentionally manual, run *on the box* over Tailscale SSH — there is no remote control plane:

```bash
ssh jun@100.65.77.63
cd ~/homelab
git pull && docker compose up -d
```

`duri` is the one build-on-dev app: build → push → pin → reconcile → verify via
`./scripts/deploy-duri.sh` from the Mac (roll back with `--tag <old-sha>`).
(Claude Code: the `deploy-duri` skill wraps this.) duri is served over HTTPS via
`tailscale serve` (`./scripts/serve-duri.sh`); the container binds loopback only —
a secure context is required because duri is a PWA using Web Crypto.

## Runbooks

`docs/bootstrap.md` (clean Debian → running stack) · `docs/tunnel-setup.md` (cloudflared
tunnel) · `docs/add-a-service.md` (steady-state workflow for new services). The
pre-migration k3s manifests are preserved on the `legacy-k3s` branch.
