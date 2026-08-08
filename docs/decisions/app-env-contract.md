# App env as a contract, pushed and gated

**Status:** done (2026-08-08)

## Why — the ask (verbatim)

> **Verbatim (2026-08-08):** "hmm how do i improve the dev ops for homelab?"

Then, having been shown four ranked options (env contract as a gate · box-drift reporting ·
healthchecks · deploy-on-merge via a self-hosted runner):

> **Verbatim (2026-08-08):** "i don't need a self hosted runner right now. but i do want to
> automate the 'copy env value, ssh into box and paste' ops. a deploy script that just scp/cp
> the .env into the box?"

Selected alongside it: **Env contract as a gate.**

## Discussion

### What prompted it

duri's `/say` voice logger shipped needing `OPENAI_API_KEY`. Han added it to Vercel, then asked
whether `.env.hosted` was the homelab's env file too. It is not — and the repo actively misled
him:

- `.env.hosted` is read by `deploy-duri.sh` **only** to extract the two `NEXT_PUBLIC_SUPABASE_*`
  values as *build args*. Its own comment says "Server secrets are NOT baked."
- The container's runtime env is `env_file: duri.env`, a gitignored file **on the box**.
- **`duri.env.example` declared `ANTHROPIC_API_KEY`** — a key duri reads **nowhere** — and did
  not declare `OPENAI_API_KEY` at all. Three prose references said the same (`SPEC.md` ×2,
  `compose.yaml` ×1), all predating the 2026-07-29 OpenAI decision.

So doing the *correct* thing — reading the `.example` rather than the secret — returned the wrong
answer. **A stale template is worse than no template**, because consulting it is the right
instinct and it silently rewards you with a wrong belief.

The failure mode this produces is the real complaint: a missing server secret does not fail the
build, the push, or the container start. It surfaces at **runtime** as a 503 that a human finds by
tapping a button.

### The decision

**`duri.env.example` is promoted from documentation to a machine-read contract.** Two scripts read
the key *names* from it and act:

- **`scripts/push-duri-env.sh`** — projects exactly those keys from duri's `.env.hosted` onto the
  box. Replaces the copy-value-ssh-paste ritual.
- **`scripts/deploy-duri.sh`** (new step 1b) — refuses to deploy when the box is missing a
  declared key, checking **names only**.

Adding a key to the example is therefore how you add it to the deploy. A key not listed is not
shipped and not checked, which makes the list's accuracy load-bearing rather than aspirational —
the property the old file lacked.

The declared set was **derived from duri's actual `process.env` reads**, not from memory:
`SUPABASE_SERVICE_ROLE_KEY`, `DATABASE_URL`, `OPENAI_API_KEY`. (`BUILD_SHA`, `BUILD_TIME`,
`NODE_ENV`, `PORT` come from the image/runtime; `NEXT_PUBLIC_*` are public and baked at build.)

### Secret discipline

No value is printed, echoed, or passed as a command argument anywhere in the new path. Extraction
is `grep` redirected into a `0600` temp file, `scp`'d, removed by an `EXIT` trap — the same
file-to-file discipline `deploy-duri.sh` already used for build args. Every verification step
compares **names**, never contents.

### Replace, not merge — and why

`push-duri-env.sh` **replaces** the box's file rather than merging into it. The contract is the
source of truth, so a key on the box that nothing declares is by definition undeclared and should
not survive; merging would let stale keys accumulate forever, which defeats the point.

Two guards make that safe:

1. It **preflights the source** and aborts before touching the box if `.env.hosted` is missing any
   declared key — so a wholesale replace can never drop a key it simply failed to find.
2. It takes a **timestamped backup on the box** (`duri.env.bak.<UTC>`) first.

### Deliberately not done

- **Self-hosted runner / deploy-on-merge** — explicitly declined ("i don't need a self hosted
  runner right now"). `SPEC.md` §"Next rung" already defers it until manual deploys chafe; that
  deferral stands.
- **Box-drift reporting** and **healthchecks** were offered and not selected. Both remain real
  gaps: the box currently runs `a8813c4` while duri's `main` is further ahead, and nothing reports
  it; and no service has a healthcheck, so `restart: unless-stopped` hides a crash-loop
  indefinitely.

### A bug caught while building this

The first draft used `mapfile`, which is **bash 4+**; macOS ships **bash 3.2**, and these scripts
run on the Mac. It was introduced into *both* scripts and would have broken the next deploy
outright. Replaced with a portable `while read` loop. Caught by actually running `--dry-run`
rather than by reading the diff — which is the argument for the dry-run flag existing.
