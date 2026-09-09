# duri: Follow-ups

Roadmap for the `duri` service after its initial homelab deploy. duri runs as a
stateless Pattern A container (Supabase-cloud backend, Tailscale-private on `:3000`)
— see [`SPEC.md`](../SPEC.md) §Services. This file is roadmap-only; prune items as
they ship.

## 1. The deploy preflight checks that a key EXISTS, not that it works

`deploy-duri.sh` §1b verifies the box carries every name declared in
`duri.env.example`. Its own comment says why it exists: a missing server secret
*"surfaces at RUNTIME as a 503 that a human discovers by tapping a button
(exactly how `OPENAI_API_KEY` was found absent on 2026-08-08)"*.

**A stale-but-present key sails through it, and fails exactly the same way.**
Demonstrated 2026-09-09: the OpenAI key was replaced in `duri-v3/.env.local`,
the deploy of `00a149a` passed preflight with all three names ✓, and the box
went live serving `/say` against a key from `.env.hosted` that no longer
matches — verified by comparing SHA-256 of the two files' values (167 vs 164
characters, different hashes; no value was printed). So the check that exists to
prevent a runtime 503 does not prevent this runtime 503.

The gap is one layer down from the one the preflight closed, and closing it is
cheap: after the name check, make one `GET https://api.openai.com/v1/models`
with the box's key and fail the deploy on a non-200. ~10 lines, no new
dependency, and it is the same diagnostic that settled the 2026-08-04 key
incident recorded in `duri-v3/build/progress.md`.

**Keep the same file-to-file discipline the rest of the script has** — read the
value into a variable or a 0600 temp file and send it as a header; never echo
it, never pass it as an inline argument, never let it reach a log. The existing
preflight is careful to be NAMES-only precisely so it can be run noisily; a
validity check has to handle a value, so it must be quiet by construction.

**Deliberately not solved here: the four-copies problem underneath it.** The
same logical secret lives in `duri-v3/.env.local`, `duri-v3/.env.hosted`,
`~/homelab/duri.env` on the box, and Vercel's dashboard, with no parent and
nothing detecting divergence. A validity check catches the symptom at deploy
time for *this* box; it does nothing for Vercel and nothing for the drift
itself. Han is choosing a secrets-management approach separately (2026-09-09) —
if that lands first, this item may reduce to "the manager is the source of
truth" rather than a check.

## 2. Healthcheck

Add a `healthcheck` to the `duri` service so `docker compose ps` reports health (not
just "Up"), restarts are gated on real readiness, and a future `depends_on` could
wait for it.

**Gotcha:** the image is built `FROM node:*-bookworm-slim`, which ships **no `curl`
or `wget`**. So the healthcheck must use Node's built-in `fetch` (Node 22 has it
global), not a shell HTTP client. Hitting `/login` is a good probe — it's a real
route, returns `200`, and needs no auth.

Add to the `duri` service in [`compose.yaml`](../compose.yaml):

```yaml
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/login').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
```

Kept at the compose layer (not a Dockerfile `HEALTHCHECK`) so the runtime concern
stays in the homelab declaration, consistent with the build-vs-run split (Dockerfile
in the app repo, run config here). Update SPEC.md's Services notes when it lands.

## Already tracked elsewhere (not open work here)

- **Going public** (cloudflared ingress + Cloudflare Access) — a known additive
  decision, noted in SPEC.md §Access planes. Not planned now.
- **Image version discipline** — own images use version/SHA tags, never `:latest`
  (SPEC §Decisions). The update loop is build+push a new tag → bump `DURI_TAG` →
  `up -d`.
