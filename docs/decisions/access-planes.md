# Access planes — which service is reachable how

**Status:** DECIDED · record written 2026-07-30, reconstructed from artifacts

Governs the **Access planes** section of [`../../SPEC.md`](../../SPEC.md). Newest decision first.

> ## ⚠ No verbatim ask — this record is reconstructed
>
> Both decisions below were made on 2026-07-15 and 2026-07-17. The convention that a decision gets a
> record with Han's exact words landed in `config/claude/.claude/AGENTS.md` on **2026-07-19** —
> *after* both — so nothing was skipped at the time. Dated against `git log` before writing this, per
> the rule in `config/docs/decisions/artifact-checking.md`.
>
> **What follows is reconstructed from the commit bodies and the current `SPEC.md`, not from Han.**
> The reasoning is his; the *wording* is the agent's, written at commit time. Nothing here is quoted
> as verbatim, because inventing a quote would defeat the point of the convention. If Han wants his
> own framing on either decision, it should be added above the Discussion as a dated quote.
>
> Surfaced on 2026-07-30 by the records-owed check in `repos/ops/index.py` — the deterministic
> backstop from `repos/docs/decisions/decision-capture.md`, doing exactly the job it was specified
> for: it cannot reconstruct a record, but it made a silent absence visible.

---

## 2026-07-17 — duri is served over HTTPS via `tailscale serve`; the plain-HTTP door is closed

**Source:** commit `419b116` — *"feat(duri): serve over HTTPS via tailscale serve; close plain-HTTP
door"*.

### Discussion

**The forcing constraint was a bug, not a preference.** duri is a PWA, and its service worker and
`crypto.randomUUID` both require a **secure context**. Plain HTTP on the Tailscale IP is not one, so
the logger's Save button *silently* broke — no error, just a dead button. That failure mode is worth
recording on its own: the symptom pointed at the app, and the cause was the transport.

**Decided:** front duri with `tailscale serve`, which terminates on-box Let's Encrypt TLS at the
box's MagicDNS name, and rebind the container from `${TAILSCALE_IP}:3000` to **loopback**
(`127.0.0.1:3000`) so serve is the *only* tailnet-facing door. Closing the plain-HTTP port is what
makes this a decision rather than an addition — leaving both open would have left the broken path
reachable and the bug intermittently reproducible.

**A structural wrinkle, deliberately handled:** `tailscale serve` state lives in `tailscaled`, not in
`compose.yaml` — so the access plane is *not* fully described by the compose file. `scripts/serve-duri.sh`
was added as a git-tracked, idempotent source of truth precisely so the configuration isn't invisible
box state. Anyone reading `compose.yaml` alone will get the wrong picture; that script is the rest of it.

**Deferred, not rejected:** a curated public door via cloudflared + Cloudflare Access, for a family
member on a different household. Noted in SPEC at the time as planned, not built.

## 2026-07-15 — Home Assistant is LAN **and** Tailscale, on purpose

**Source:** commit `5bfd573` — *"docs: HA is intentionally LAN + Tailscale, not Tailscale-only"*.

### Discussion

This one is a decision **not** to change something, which is exactly the kind that leaves no trace
and gets silently undone later.

HA runs with `network_mode: host` (for mDNS/device discovery, the same reason it was
`hostNetwork: true` under k3s). A side effect is that `:8123` binds on *all* host interfaces, so HA
is reachable from the home LAN as well as the tailnet. SPEC.md previously framed this as a caveat —
*"tighten with a host firewall or HA `trusted_networks` if that matters."*

**That framing was wrong, and the fix was to invert it.** The LAN reachability is intended:
housemates use HA on the LAN; Han reaches it off-network over Tailscale. Never public.

**Decided:** record LAN + Tailscale as the intended plane, and turn the follow-up item that said
"bind to Tailscale" into a signpost *against* doing so. SPEC.md now carries the prohibition
explicitly:

> Do **not** scope it to the tailnet with `server_host` / a firewall — that would break intended LAN
> access.

**Why the inversion matters more than the config:** nothing in the system distinguishes "a port is
open because nobody tightened it" from "a port is open on purpose." A future agent or a future Han
reading a security caveat will act on it. The record and the SPEC line exist so that the next person
to notice `:8123` on the LAN stops instead of hardening it.

## Related

- [`repos/knowledge/homelab-box.md`](../../../knowledge/homelab-box.md),
  [`repos/knowledge/tailnet.md`](../../../knowledge/tailnet.md) — the cross-repo facts layer, which
  cites this plane rather than restating it
- [`repos/docs/decisions/decision-capture.md`](../../../docs/decisions/decision-capture.md) — why
  this record exists here rather than in the meta-repo
