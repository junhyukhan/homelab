# Handoff: Homelab Migration (k3s → Docker Compose)

You are Claude Code, picking up a homelab migration that was scoped in a planning
conversation. This document is the source of truth for that scope. Read it fully
before touching any files. Decisions marked **LOCKED** were made deliberately —
do not re-open or "improve" them without asking. Surface questions rather than
guessing.

**Before executing anything: review this handoff.** Read it end to end, then
report back with (a) anything ambiguous, internally contradictory, or missing,
(b) any LOCKED decision you think is actually wrong (flag it, don't silently
comply *or* silently override), and (c) your intended task order. Wait for the
human's go-ahead before starting Task 1. This document was written by another
model from a planning conversation; treat it as high-signal but not infallible.

---

## 0. Prime directive

Transition this repository from a Kubernetes (k3s) architecture to a Docker
Compose architecture. The homelab is a **hub that hosts long-running personal
services**, reachable over Tailscale by default (and via Cloudflare Tunnel when a
service is consciously made public — see §3.1), with all state in named Docker
volumes and all config in git. Adding a private service should mean: edit
`compose.yaml`, `docker compose up -d`, done. A public one adds a cloudflared
ingress rule and a Cloudflare Access check on top.

The end state is deliberately small. If a step is adding Kubernetes-shaped
complexity back in, you've gone wrong.

---

## 1. Hard boundaries — what you MUST NOT do

These steps touch the live homelab machine (an old i7-7th-gen laptop, 8GB RAM,
Debian, reachable over Tailscale SSH) or destroy data. **You cannot verify their
real-world effect from here, so you must not run them.** Generate them as an
executable runbook for the human to run, and stop for confirmation where noted.

- **Do not run the k3s uninstall.** Produce the command; the human runs it on the box.
- **Do not delete, move, or assume the safety of any PVC data.** The backup-and-verify
  step is human-gated. The rest of the plan must not proceed in the runbook until the
  human confirms the backup is real and non-empty.
- **Do not run `docker compose up` against the real homelab.** You can lint/validate
  compose files locally; you cannot deploy.
- **Do not touch the Cloudflare dashboard, DNS, or Zero Trust config.** Produce
  instructions; the human clicks.
- **Do not commit secrets.** `.env` and the cloudflared tunnel credentials JSON
  are gitignored and human-supplied. You produce `.env.example` only. (The new
  design has no tunnel *token* — see §4.)

Everything in the repo (compose files, config, docs, runbooks) is yours to write.
Everything that changes the live machine or external services is the human's to
execute.

---

## 2. Current state (what the repo is now)

A k3s homelab managed with Kustomize. Structure:

```
homelab/
├── kustomization.yaml              # root aggregator
├── infrastructure/                 # namespace: infrastructure
│   ├── cloudflared/                # tunnel (TUNNEL_TOKEN via SecretGenerator)
│   ├── gitea/                      # Helm chart, SQLite
│   └── home-assistant/             # hostNetwork, 5Gi PVC
├── operations/
│   └── registry/                   # registry:2, 20Gi PVC, NodePort 30500
├── observability/
│   └── k3s-dashboard/              # custom app, DEPRECATED
└── README.md
```

Deployed via `kustomize build --enable-helm . | kubectl apply -f -`. Controlled
remotely from a MacBook via kubeconfig pointing at `https://<tailscale-ip>:6443`.

A prior migration plan exists at `plan/migration-k3s-to-docker.md`. **Treat it as
input, not gospel** — several decisions below override it (Gitea, Caddy, tunnel
style). Where this handoff and that plan disagree, this handoff wins.

---

## 3. Target state

```
Internet → Cloudflare Edge → cloudflared tunnel → homelab_net (bridge) → services
```

Services after migration:

| Service        | Image                          | Networking            | State            | Access plane        |
|----------------|--------------------------------|-----------------------|------------------|---------------------|
| cloudflared    | cloudflare/cloudflared:latest  | homelab_net           | none             | n/a (is the tunnel) |
| registry       | registry:2                     | published :30500      | registry_data vol| Tailscale-private   |
| home-assistant | ghcr.io/home-assistant/home-assistant:stable | network_mode: host | ha_data vol | Tailscale-private |
| duri (planned) | `<tailscale-ip>:30500/duri:<tag>` | homelab_net        | tbd              | decide per §3.1     |

Four services. That's the whole homelab.

**Registry address — one canonical name, used everywhere.** There is no
`registry.homelab` DNS name; do not invent one. The registry is addressed as
**`<tailscale-ip>:30500`** from every machine, including the homelab pulling its
own images. (`<tailscale-ip>` is the homelab's stable Tailscale IP.) Rationale:
using the published Tailscale port uniformly means the same image reference works
whether the puller is the Mac, the ThinkPad, or the homelab itself — no separate
in-network `registry:5000` name to keep in sync. The compose service is still
*named* `registry` on `homelab_net`, but image references in `compose.yaml` use
the `<tailscale-ip>:30500/...` form, not the service name. If you ever want the
homelab to pull via the internal `registry:5000` instead, that's a deliberate
change to raise with the human — don't split the naming silently.

### 3.1 Access planes — the private/public split (apply this to every service)

There are two access planes, and every service sits on one or both. This is a
**mechanical decision you make for each service**, not something to infer.

**Tailscale — private (the default).** Reachable only from devices on the
tailnet. No public DNS, no Cloudflare. Being on the tailnet *is* the auth. A
service is on this plane automatically just by running on the host — it needs no
extra config. Reached via `<tailscale-ip>:<port>` (or a published port / host
networking). Registry, Home Assistant, and SSH live here.

**Cloudflared tunnel — public, behind Cloudflare Access.** Reachable from the
internet at `something.${BASE_DOMAIN}`, gated by a Cloudflare Access policy (email
OTP or similar). The tunnel egresses from the box, so no inbound ports are opened.
A service is on this plane **only if you add a cloudflared ingress rule for it** —
otherwise it has no public route at all.

**The rule:**
- Default is **Tailscale-private**. Public exposure requires a *conscious*
  cloudflared ingress rule. Never add one speculatively.
- A public route is **additive**, not a replacement. A service reachable over
  Cloudflare is still reachable over Tailscale; the ingress rule just adds a
  second door with Access as the lock.
- Decide per service by one question: *do I need to reach this from a device
  that isn't on my tailnet (or share it with someone)?* No → Tailscale only.
  Yes → add an ingress rule + confirm the Access policy covers it.

**Locked plane assignments:**
- **Registry → Tailscale-private, never public.** Cloudflare Access breaks
  `docker push` (Docker's auth doesn't do OAuth browser redirects). This is the
  same reason it's not routed through Cloudflare in §4. Do not add an ingress
  rule for it.
- **Home Assistant → Tailscale-private.** Reached only from the user's own
  devices, all on the tailnet. No public route; keeping it private is strictly
  better security. (It also uses host networking for mDNS, unrelated to the plane
  choice.)
- **duri → undecided.** Defer with the rest of duri's spec. If the user wants it
  on their phone off-tailnet or shared, it gets an ingress rule + Access policy;
  otherwise Tailscale-only like everything else.

When you generate `cloudflared/config.yml` in Task 3, the ingress list should
therefore be **empty of real routes** at migration time (only the commented
example + the `http_status:404` catch-all). Nothing currently needs a public
route. Do not invent one.

---

## 4. Decisions already made — LOCKED

**LOCKED: Drop Gitea entirely.** GitHub holds source; the registry holds images.
Gitea was doing a job nothing currently needs. Do not carry it over. Removing it
also removes the Helm chart, SQLite volume, and SSH port-publishing complexity.

**LOCKED: Drop k3s-dashboard.** Already deprecated. Gone.

**LOCKED: No Caddy.** cloudflared's own ingress config does the L7 hostname
routing we need. No TLS to terminate (Cloudflare does it), no auth to add
(Cloudflare Access does it), no caching needed. Adding Caddy would mean a second
config file and a `caddy reload` dance for zero benefit at this scale. It's a
"add later if a specific need appears" tool (on-box TLS, or tunnel-restart
downtime becoming annoying), not a starting component. The ThinkPad dev gateway
already uses cloudflared-only ingress; the homelab matches it for one mental model.

**LOCKED: Locally-managed cloudflared tunnel, ingress rules in a git-tracked
config file.** Not the dashboard-managed token-only style. Reason: routes belong
in the repo, otherwise a "declarative homelab" doesn't actually declare where
traffic goes. Config file mounted into the container; credentials JSON is
human-supplied and gitignored.

> **Migration cost — this is a NEW tunnel, not a reconfig of the old one.** The
> current k3s cloudflared uses a remote-managed `TUNNEL_TOKEN`. Locally-managed
> tunnels don't use a token at all — they authenticate with a credentials JSON
> file created by `cloudflared tunnel create`. So the existing `TUNNEL_TOKEN` is
> **discarded**, a brand-new tunnel is created, and the DNS CNAMEs are re-pointed
> to the new tunnel ID. Do **not** carry `TUNNEL_TOKEN` forward into `.env` or
> `compose.yaml` — it has no role in the new design. The tunnel-setup runbook
> (Task 4.4) owns the create-and-repoint procedure.

**LOCKED: Registry access over Tailscale, published on a host port (30500 → 5000).**
Not routed through Cloudflare Access — Docker's push auth flow doesn't do OAuth
browser redirects, so putting the registry behind Access breaks `docker push`.
Tailscale is already an authenticated network; that's sufficient. The Mac's
existing `insecure-registries` config and `docker push <tailscale-ip>:30500/...`
muscle memory stay unchanged.

**LOCKED: Pattern A for the human's own services.** Build the image on a dev
machine (Mac via apple/container, or ThinkPad via Docker), push to the homelab
registry at `<tailscale-ip>:30500`, homelab pulls and runs it. The homelab repo
references `image: <tailscale-ip>:30500/duri:<tag>` (see the canonical-address
note in §3) — it never holds source code and never builds. Homelab = runs
artifacts, not a build machine (it's RAM-constrained).

**LOCKED: No `:latest` for own images.** Use version tags (`duri:v1`) or git-SHA
tags. `:latest` won't re-pull reliably on `up -d`.

**LOCKED: Home Assistant stays `network_mode: host`.** Required for mDNS/SSDP
device discovery, same reason it was `hostNetwork: true` in k3s. Its future
follow-ups (Music Assistant, Whisper, Piper, Wyoming) are out of scope for this
migration but should be *anticipated* as future compose services — Music
Assistant will also want host networking; Wyoming pods won't. Don't build them
now; just don't design in a way that blocks them.

**LOCKED: Secrets in `.env`, gitignored.** `PUID`, `PGID`, `TZ=Asia/Seoul`,
`BASE_DOMAIN`. You produce `.env.example`. Note: the cloudflared tunnel does
**not** use an env var — its credentials are a JSON file (see the tunnel note
above and §1), supplied by the human and gitignored, not an `.env` key. Do not
add `TUNNEL_TOKEN` to `.env.example`.

---

## 5. Your task sequence

Do these in order. Commit at each meaningful step with clear messages.

### Task 1 — Write `SPEC.md` first
This is the highest-leverage artifact. Write it as if the migration is already
done and future-you is reading it fresh. Structure: Goals, Non-goals,
Architecture, Services (current + planned), Constraints (8GB RAM budget, secrets,
volume ownership), Decisions-with-rationale (pull from §4 above), and links to
the operational runbooks you'll write in Task 4. Every file you generate
afterward should trace back to a section here. When something changes later,
SPEC.md updates first, code follows.

### Task 2 — Archive the old architecture
This step deletes the k8s manifests off `main`, which is destructive. Per §1,
you **propose** it and let the human execute (or explicitly approve) — do not
silently force-wipe `main`. Present it as a reviewable diff / PR, or as the exact
git commands for the human to run. The sequence:
1. Create branch `legacy-k3s`, commit current state to preserve history.
2. Return to the working branch (`main`).
3. Delete: `infrastructure/`, `operations/`, `observability/`, `kustomization.yaml`,
   and the old `plan/migration-k3s-to-docker.md` (its decisions now live in SPEC.md
   and this handoff). Keep other `plan/` docs (dev gateway, HA follow-ups) — they're
   still live.

**Do not create a new repo. Do not rename it.** Same repo, branch-and-wipe. This
was decided explicitly: the homelab is the same project, the runtime changing is
one commit in a continuous history.

### Task 3 — Generate the Compose stack
Produce in the repo root:

- **`compose.yaml`** — services from §3 on a bridge network `homelab_net`:
  - `cloudflared`: `command: tunnel --no-autoupdate --config /etc/cloudflared/config.yml run`;
    mount `./cloudflared/config.yml` and the creds JSON read-only; on `homelab_net`.
  - `registry`: `REGISTRY_STORAGE_DELETE_ENABLED=true`; volume `registry_data:/var/lib/registry`;
    `ports: ["30500:5000"]`; on `homelab_net`.
  - `home-assistant`: `network_mode: host`; `TZ=${TZ}`; volume `ha_data:/config`.
    With host networking it is **not** on `homelab_net`, so it cannot resolve other
    services by compose service-name DNS. This is expected and accepted — HA
    doesn't pull from the registry or call other homelab services, and host
    networking is required for mDNS/SSDP device discovery. **Do not "fix" this by
    moving HA onto the bridge network** — that breaks device discovery. If a future
    service needs to talk *to* HA, it reaches it at `<tailscale-ip>:8123`.
  - Add `depends_on: [registry]` to any service that pulls from the local registry
    (makes cold-start ordering explicit).
- **`cloudflared/config.yml`** — `tunnel`, `credentials-file`, and an `ingress:`
  list. Per §3.1, this list has **no real routes at migration time** — everything
  currently runs Tailscale-private. Include one *commented* worked example showing
  the shape of a future route, and the required `service: http_status:404`
  catch-all as the only live entry. Do not add a route for HA or the registry;
  both are intentionally private (the registry's public exposure would break
  `docker push`).
- **`.env.example`** — keys from §4.
- **`.gitignore`** — ensure `.env`, `.DS_Store`, and the cloudflared credentials
  file specifically. Use a **scoped** pattern, not blanket `*.json` (a config or
  compose tool may legitimately want a tracked JSON later). The creds file lives
  in the cloudflared config dir and is named `<tunnel-id>.json`, so ignore
  `cloudflared/*.json` (and, if you keep the creds elsewhere, that exact path).
  Do not ignore all JSON repo-wide.

Validate compose syntax locally (`docker compose config`) but **do not deploy**.

### Task 4 — Write the human runbooks (this is the transition kickoff)
These are documents the human executes; you only write them. Put them in `docs/`
or link from SPEC.md. Required runbooks:

1. **`cleanup-k3s.md`** — the ordered, gated procedure:
   ```
   1. Back up PVC data:
      sudo cp -a /var/lib/rancher/k3s/storage/ ~/homelab_migration_backup/
   2. VERIFY the backup (ls, du -sh) is real and non-empty.
      → STOP. Human confirms before continuing.
   3. Uninstall k3s: /usr/local/bin/k3s-uninstall.sh
   4. Install Docker: curl -fsSL https://get.docker.com | sh
      then: sudo usermod -aG docker $USER  (re-login for group)
   4b. Trust the registry over HTTP on the homelab's OWN daemon. The registry
      serves plain HTTP over Tailscale, so the homelab must be told it's an
      insecure registry or it can't pull its own images (e.g. duri). Add to
      /etc/docker/daemon.json:
        { "insecure-registries": ["<tailscale-ip>:30500"] }
      then: sudo systemctl restart docker
      (This mirrors the same setting the Mac and ThinkPad already have in their
      Docker configs — the homelab needs it too now that it's a Docker host, not
      a k3s node.)
   5. Clean the Mac's kubeconfig:
      kubectl config delete-context homeserver
      kubectl config delete-cluster <cluster-name>
      remove the k3s-config merge from ~/.zshrc  (keep orbstack context)
   ```
   Note that `k3s-uninstall.sh` removes k3s, its bundled containerd, kubelet
   state, and the systemd unit — but NOT the PVC data on disk (hence step 1) and
   NOT anything on the Mac (hence step 5).

2. **`data-migration.md`** — move backed-up volume data into the named Docker
   volumes via a temp Alpine container, e.g.:
   ```
   docker run --rm -v ha_data:/dest -v ~/homelab_migration_backup/<ha-path>:/src \
     alpine cp -a /src/. /dest/
   ```
   Do it for HA. For the registry: if every image in it is rebuildable from source
   (the human's own projects), skip the restore and re-push instead; only restore
   if there's something that can't be rebuilt. Remind the human to verify file
   ownership matches PUID/PGID.

3. **`add-a-service.md`** — the steady-state workflow: build on dev machine → push
   to `registry.homelab:30500` → add a compose block → **decide the access plane
   (§3.1): Tailscale-private by default; add a cloudflared ingress rule + confirm
   the Cloudflare Access policy only if it needs off-tailnet reach** → `docker
   compose up -d <service>`. Make the plane decision an explicit checklist item,
   not an afterthought.

4. **`tunnel-setup.md`** — creating the locally-managed tunnel
   (`cloudflared tunnel create`), where the creds JSON goes on the box, and the
   DNS CNAME step in the Cloudflare dashboard. Cross-reference the existing dev
   gateway plan, which uses the same pattern.

### Task 5 — Rewrite `README.md`
Remove all k3s/kubectl/kustomize/NodePort/PVC language. Document the new
architecture, a quick-start (`git pull && docker compose up -d` over Tailscale
SSH), and the day-to-day operations. Keep it a runbook, not study notes — the
k8s-concepts explainers from the old README don't carry over.

---

## 6. The deploy/control model (context for your docs)

After migration there's no API-server-style remote control. The loop is
Tailscale SSH into the box, then `git pull && docker compose up -d`. Document
this. Optionally mention `docker context create homelab --docker "host=ssh://homelab"`
as a "make it feel like remote kubectl again" upgrade the human can add later —
it runs compose commands from the Mac over SSH without exposing the Docker daemon.
Don't build CI-to-homelab; it's out of scope and has a bootstrap problem.

---

## 7. Open questions to surface (don't guess)

- Exact PVC directory names under `/var/lib/rancher/k3s/storage/` — the human
  reads these off the box; your runbook should tell them how to identify HA vs
  registry, not hardcode paths.
- `duri` deployment specifics (port, whether it needs a DB, and its access plane
  per §3.1 — Tailscale-private vs. public-behind-Access) — defer until the human
  writes a small spec addition for it. Don't scaffold it speculatively beyond a
  commented placeholder, and don't add a cloudflared ingress rule for it by default.
- Whether the registry needs any data restored at all (see Task 4.2).

---

## 8. Definition of done for this handoff

- `SPEC.md` exists and every generated file traces to it.
- `legacy-k3s` branch preserves the old state; `main` is clean of k8s manifests.
- `compose.yaml`, `cloudflared/config.yml`, `.env.example`, `.gitignore` exist and
  `docker compose config` validates.
- Runbooks in `docs/` cover cleanup, data migration, add-a-service, tunnel setup.
- The cleanup runbook includes the homelab-side `insecure-registries` daemon
  config (step 4b) — without it the homelab can't pull its own images.
- Every image reference uses the canonical `<tailscale-ip>:30500/...` form; no
  invented `registry.homelab` hostname anywhere.
- No `TUNNEL_TOKEN` in `.env.example` or `compose.yaml`; the tunnel uses a
  gitignored credentials JSON.
- `.gitignore` scopes the creds file precisely (not blanket `*.json`).
- `README.md` reflects the new architecture with no k3s residue.
- Nothing touching the live box or Cloudflare has been executed by you — only
  documented for the human.

First, review this handoff and report back per the instruction in §0. Then, on
the human's go-ahead, start with Task 1. Ask before deviating from anything LOCKED.
