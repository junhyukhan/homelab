# Box hardening — EXECUTED 2026-09-14

From the 2026-09-12 security review (report: `plan/secrets-review-2026-09-12.md`, gitignored —
this repo is public). Finding **H2**: the box's "reachable only over Tailscale" premise was false.

**Status: done.** Han ran every step on 2026-09-14. What is now true is recorded in
[`SPEC.md`](../SPEC.md) §"Host firewall" — **that is the source of truth; this file is history.**

## What was done

| Step | State |
|---|---|
| 1. SSH password auth off | ✅ `passwordauthentication no`; key-only login verified |
| 2. Samba off (`smbd`/`nmbd` disabled) | ✅ `:445`/`:139` gone — closes the `duri.env`-over-the-LAN hole |
| 3. `ufw` default-deny + tailnet/LAN rules | ✅ HA `:8123` blocked from LAN, open over tailnet |
| 4. Reconcile `SPEC.md` | ✅ §"Host firewall" added, with measured evidence |
| Gerbera | ✅ **kept** — see correction 1. Stray `gerbtest` container removed |

Measured from a LAN host (192.168.45.40) afterwards: `:8123` blocked from LAN / 200 over
tailnet · `:445`,`:139` closed · `:22` blocked from LAN, open over tailnet · `:49494` open.

## Three corrections to this document's own earlier claims

Recorded because each one cost real time or real breakage, and the pattern is the same in all
three: **a claim about the box was trusted over the document that owns the facts about the box.**

### 1. "Samba and Gerbera are in neither the service table nor the access-plane table" — FALSE of Gerbera

Gerbera is in **both** (`SPEC.md` §Services, §"Locked plane assignments") with an explicit
rationale: it serves the living-room projector (Hisense M2 Pro, VIDAA OS), which cannot join
the tailnet, and `network_mode: host` is *required* because SSDP discovery is multicast. Acting
on this sentence would have taken out the projector's media. The claim was true of Samba only.

**Compounding it:** the supporting evidence gathered at the time was void. `journalctl -u gerbera`
returned nothing and was read as "no clients in 30 days" — but Gerbera is a **container**, not a
systemd unit, so that command could never have returned anything regardless of the truth. An empty
result was treated as evidence of absence when it was only evidence of the wrong instrument.

### 2. The HomeKit ports were flagged as a finding that SPEC had already decided

H2 listed `:21063`/`:21064` on `0.0.0.0` as part of the problem. `SPEC.md` §"HomeKit bridge" says
of exactly that binding: *"host networking means that is on every interface including the home
LAN, **which is correct** — HomeKit is a LAN protocol and the pairing iPhones are on the LAN, not
the tailnet."* The ports, the two-bridge design and the reason were all written down first.

Consequence: the initial firewall step had no LAN rules, and would have silently broken the
household's Apple Home control surface. The rules now in `SPEC.md` §"Host firewall" exist because
that section was finally read.

### 3. "SSH first because key auth is already proven" — it was not, and it locked Han out

The review had measured that sshd **offered** password auth. It never tested that a **key-only**
login from the Mac succeeds. Those are different claims, and step 1 depended on the second.

Root cause, once diagnosed: the Mac's key has a non-default filename
(`id_ed25519__jun_hp_spectre__homeserver`), so `ssh` offered it only while it happened to be
loaded in `ssh-agent`. The agent had forgotten it. `authorized_keys` on the box had been correct
since October. Fixed on the Mac with an `IdentityFile` entry in `~/.ssh/config`, which does not
depend on agent state.

**The rule this yields, which belongs in any future step that disables a fallback:**
prove the primary path works *with the fallback explicitly disabled* — here,
`ssh -o BatchMode=yes -o PasswordAuthentication=no` — **before** changing the server, not after.

## Still open from the same review

- **M1 — Postgres TLS.** Fixed in duri-v3 PR #53: `ssl: "require"`, with the hosted handshake
  verified client-side (TLSv1.3). `verify-full` remains open and is **not** a setting to flip
  later — the pooler presents `SELF_SIGNED_CERT_IN_CHAIN`, so without Supabase's CA bundled into
  the image first it fails every connection. See `duri-v3/src/lib/db/index.ts`.
- **H1 — write path.** An Infisical session on the Mac can *write* to `prod`, and with the Vercel
  syncs live a write now propagates to production. The *read* half is closed: the secret-guard hook
  now blocks the CLI's value-printing commands (`config`, 26 test cases). No permission rule denies
  the write subcommands; Han's call, deliberately left.
