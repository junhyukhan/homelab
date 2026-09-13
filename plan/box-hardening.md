# Box hardening — open, needs root at the machine

From the 2026-09-12 security review (report: `plan/secrets-review-2026-09-12.md`, gitignored —
this repo is public). Finding **H2**: the box's "reachable only over Tailscale" premise was false.

**Nothing here has been run.** These need root, and an agent session cannot `sudo`
non-interactively — so they are Han's to execute, ideally with a second SSH session held open.

## What was measured, 2026-09-12

Verified directly, not inferred:

- `sshd` listens on `0.0.0.0:22` and `[::]:22`, and **offers password auth** — a probe with
  `PubkeyAuthentication=no` returned `Permission denied (publickey,password)`.
  `docs/bootstrap.md:49-51` already recommends `PasswordAuthentication no`; it was never applied.
- **Samba active** on `0.0.0.0:139` / `0.0.0.0:445` (+ IPv6), exporting `[homes]`. Since `jun` is in
  the `docker` group (root-equivalent), that share would serve `~/homelab/duri.env` to anyone on
  the LAN holding that password.
- **Home Assistant on `0.0.0.0:8123`**, plus `:21063`/`:21064`, and Gerbera on the LAN IP.
- **No host firewall**: `ufw`, `nftables`, `firewalld` all inactive.
- Correctly Tailscale-bound already: `:443`, `:8443`, `:30500`, `:41616`. Loopback-bound: `:9091`,
  `:18554`. So the pattern exists — it was applied to the services `SPEC.md` knows about.

## Decisions taken 2026-09-12/14

- **Samba: OFF entirely.** Han: the box is no longer used for Time Machine backups, so disabling
  beats firewalling.
- **Home Assistant: Tailscale-only.** This **overturns** the 2026-07-15 decision — see
  `plan/home-assistant-followups.md` §3 and the amended `SPEC.md` row.
- **Gerbera: undecided.** Han thinks it serves torrented media. DLNA clients (a TV, say) cannot use
  Tailscale, so a default-deny firewall will cut them off. Identify the consumer before deciding.

## The steps, in this order

Order is deliberate: least-likely-to-lock-you-out first, and the firewall last because a wrong
rule on a headless box means physical access.

### 1. SSH password auth off

Hold a second SSH session open before running this.

```bash
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh      # -t validates BEFORE reload
```

Verify from the Mac — should report `(publickey)` only:

```bash
ssh -o BatchMode=yes -o PubkeyAuthentication=no jun@100.65.77.63 true
```

### 2. Samba off

```bash
sudo systemctl disable --now smbd nmbd
ss -tln | grep -E ':445|:139'    # expect no output
```

### 3. Firewall — this is what scopes HA to the tailnet

Chosen over `http: server_host:` in HA's `configuration.yaml` deliberately: a malformed config
stops HA booting, a firewall rule is reversible.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0
sudo ufw allow in on lo
sudo ufw allow 22/tcp            # keep SSH reachable while verifying
sudo ufw enable
```

Then, once everything is confirmed reachable over Tailscale, tighten SSH:

```bash
sudo ufw delete allow 22/tcp
```

### 4. Afterwards

Send `ss -tln | grep '0.0.0.0'` back to a session and reconcile **`SPEC.md`** with it. SPEC says
*"Six services. That's the whole homelab."* (`SPEC.md:164`) and there are more — Samba and Gerbera
are in neither the service table nor the access-plane table. Whatever survives step 3 should be
documented; whatever does not should be removed from the box.

## Still open from the same review

- **M1 — Postgres TLS.** `grep -c 'sslmode=verify-full' ~/homelab/duri.env` returned **0**, so the
  connection was not authenticated TLS. Partly fixed in duri-v3 branch `fix/db-tls` (adds
  `ssl: "require"`, which encrypts but does **not** verify the server certificate). `verify-full`
  needs Supabase's CA bundled into the homelab image — not done, not filed elsewhere.
- **H1 — write path.** An Infisical session on the Mac can *write* to `prod`, and with the Vercel
  syncs live a write now propagates to production. The *read* half is closed: the secret-guard hook
  now blocks the CLI's value-printing commands (`config`, 26 test cases). No permission rule denies
  the write subcommands; Han's call, deliberately left.
