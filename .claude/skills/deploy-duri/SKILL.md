---
name: deploy-duri
description: Deploy the duri app to the homelab box. Use when asked to deploy/redeploy/ship duri, roll it back, or check what version is live. Wraps scripts/deploy-duri.sh (build → push → pin → reconcile → verify).
---

# Deploy duri to the homelab

duri is the one **Pattern-A** app (built on a dev machine, pushed to the Tailscale
registry, run on the box). The whole deploy is one script — don't hand-run the
steps; the script encodes the footguns.

## Deploy (current `main`)
```bash
cd ~/workdir/repos/homelab && ./scripts/deploy-duri.sh
```
It: refuses a dirty duri tree → cross-builds **amd64** (the box can't run arm64) →
stamps the git SHA + OCI labels → pushes to `${REGISTRY_HOST}` → pins the tag
**inline in `compose.yaml`** (git = the deploy log) → commits+pushes this repo →
reconciles the box (`git pull && up -d duri`) → verifies `/api/version` reports the
SHA. On success it prints the rollback command.

Preview first with `--dry-run` (changes nothing). Deploy an uncommitted tree with
`--dirty-ok` (tags `<sha>-dirty`) — avoid for real deploys.

## Roll back
```bash
./scripts/deploy-duri.sh --tag <old-sha>    # re-pins + reconciles, no rebuild (image is still in the registry)
```

## What's live right now
```bash
curl -s http://100.65.77.63:3000/api/version         # {"version":"<sha>","builtAt":...}
# or, without HTTP:
ssh -i ~/.ssh/id_ed25519__jun_hp_spectre__homeserver jun@100.65.77.63 \
  'docker inspect --format "{{index .Config.Labels \"org.opencontainers.image.revision\"}}" homelab-duri-1'
```

## Notes / guardrails
- **Secrets:** the script feeds the *public* `NEXT_PUBLIC_*` Supabase values as build
  args (extracted file-to-file from `duri-v3/.env.hosted`, never printed). Server
  secrets (`SUPABASE_SERVICE_ROLE_KEY`, `DATABASE_URL`, `ANTHROPIC_API_KEY`) are **not**
  baked — the box supplies them at runtime via `duri.env`.
- **Never `:latest`.** The tag is always a git SHA, pinned in `compose.yaml`.
- **SSH is over Tailscale** (`jun@100.65.77.63`), key `id_ed25519__jun_hp_spectre__homeserver`
  — the `~/.ssh/config` alias points at a LAN IP that isn't reachable off-LAN.
- Env overrides (`DURI_DIR`, `BOX_HOST`, `BOX_SSH_KEY`, `BOX_URL`) exist for a
  different machine/box. Defaults match the current setup.
- **Next rung (not built):** a self-hosted GitHub Actions runner on the box would
  turn merge-to-main into an auto-deploy — see `SPEC.md` §Deploy.
