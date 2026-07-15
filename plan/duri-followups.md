# duri: Follow-ups

Roadmap for the `duri` service after its initial homelab deploy. duri runs as a
stateless Pattern A container (Supabase-cloud backend, Tailscale-private on `:3000`)
— see [`SPEC.md`](../SPEC.md) §Services. This file is roadmap-only; prune items as
they ship.

## 1. Healthcheck

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
