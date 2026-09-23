---
workspace:
  # docs/README.md routes into SPEC.md by section; SPEC.md stays the source of truth
  # (7,761 words, past the 1,500-word readfirst budget). Since 2026-09-23.
  readfirst: docs/README.md
  decisions: docs/decisions/
  backlog: [plan/duri-followups.md, plan/home-assistant-followups.md]
  # Deliberately null. `docker compose config -q` validates against duri.env,
  # which exists only on the box — it can never pass on a laptop. And it isn't
  # needed: this repo's chore surface is docs-only (SPEC.md, docs/), and a docs
  # change has no behavior to verify. The gate for a docs-only chore is the
  # path restriction the supervisor enforces, not a command. compose.yaml is
  # deploy-adjacent and stays manual regardless of what the class allows.
  verify: null
  autonomy: chore
---

# AGENTS.md — homelab

Guidance for any coding agent working in this repository.

Single box (i7-7th-gen laptop, 8 GB RAM, Debian, headless, on Tailscale) that hosts
long-running personal services with Docker Compose. All state is in named Docker
volumes; all config is in this repo.

## Read first

- **`docs/README.md`** — the read-first router: which `SPEC.md` section, runbook or record
  answers which question. It states no facts of its own.
- **`SPEC.md`** — the source of truth for *what* runs and *why* (goals, architecture,
  access planes, decisions). Read it before adding, removing, or changing any service.
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
- **Secrets:** live in gitignored `*.env` files (e.g. `.env`, `duri.env`); the global `.env`
  rule governs reading and moving them.
  **`duri.env.example` is a machine-read contract, not a doc**: `scripts/push-duri-env.sh`
  ships exactly the keys it declares and `scripts/deploy-duri.sh` refuses to deploy when
  the box lacks one, so it must stay accurate — it declared a key duri reads nowhere until
  2026-08-08. See `docs/decisions/app-env-contract.md`.
- **No inbound ports.** Two ways in: Tailscale (the default — being on the tailnet *is*
  the auth) and an egress-only cloudflared tunnel (for consciously-public services behind
  Cloudflare Access). Public exposure is opt-in per service, never the default.
- **Own images are pinned** by version/SHA tag inline in `compose.yaml`, never `:latest`.

## Deploy loop

Intentionally manual, run *on the box* over Tailscale SSH — there is no remote control plane:

```bash
ssh jun@100.65.77.63
cd ~/homelab
./scripts/deploy.sh
```

**Do NOT use `git pull && docker compose up -d`.** It silently skips bind-mounted
config (`ha/packages`, `cloudflared/`, gerbera's `config.xml`) — compose only recreates
on *definition* changes, so it prints `Running` and does nothing. `deploy.sh` restarts
whatever the pull actually changed, then runs `scripts/verify.sh`. Run `verify.sh`
standalone any time (from the box or the Mac) to assert the box matches the repo.

`duri` is the one build-on-dev app: build → push → pin → reconcile → verify via
`./scripts/deploy-duri.sh` from the Mac (roll back with `--tag <old-sha>`). Its app
secrets are projected onto the box by `./scripts/push-duri-env.sh` — never hand-copied.
(Claude Code: the `deploy-duri` skill wraps this.) duri is served over HTTPS via
`tailscale serve` (`./scripts/serve-duri.sh`); the container binds loopback only —
a secure context is required because duri is a PWA using Web Crypto.

## Runbooks

`docs/bootstrap.md` (clean Debian → running stack) · `docs/tunnel-setup.md` (cloudflared
tunnel) · `docs/add-a-service.md` (steady-state workflow for new services). The
pre-migration k3s manifests are preserved on the `legacy-k3s` branch.
