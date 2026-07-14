# Runbook: Bootstrap a fresh homelab box

Stand up the homelab from a clean OS install to a running Compose stack. This
replaces the old in-place k3s→Docker migration — the box is being reimaged, HA
starts fresh (no data restore), and the registry starts empty (re-push images).

Assumes: **Debian 13 (minimal / netinst, no desktop)** freshly installed, with an
SSH server and a sudo user `jun`. Commands are apt-based; adjust for another distro.

> **The Tailscale IP changes.** A reinstalled machine re-joins Tailscale as a new
> node, so the old `100.65.77.63` almost certainly won't carry over. Everywhere
> below, `<TS_IP>` means *the new* `tailscale ip -4`. Thanks to the `${TAILSCALE_IP}`
> env var, only three spots need the real value: `.env` (`TAILSCALE_IP`,
> `REGISTRY_HOST`) and `/etc/docker/daemon.json`.

---

## 1. Base packages

```bash
sudo apt update && sudo apt -y full-upgrade
sudo apt -y install curl git ca-certificates
```

## 2. Tailscale (this is how you'll reach the box)

Run at the physical console or over the local network first, since you don't have
remote access yet.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4          # ← record this; it's <TS_IP> from here on
```

Optionally enable Tailscale SSH: `sudo tailscale up --ssh`. In the Tailscale admin
console, remove the old (pre-reinstall) node so the machine list stays clean.

## 3. SSH access from the Mac

From the **Mac**, install your key and refresh the host entry (the box's key and
IP changed):

```bash
ssh-keygen -R <TS_IP>                                    # drop any stale host key
ssh-copy-id -i ~/.ssh/id_ed25519__jun_hp_spectre__homeserver jun@<TS_IP>
```

Recommended after confirming key login works: disable SSH password auth
(`PasswordAuthentication no` in `/etc/ssh/sshd_config`, then
`sudo systemctl restart ssh`). From here you can work over `ssh jun@<TS_IP>`.

## 4. Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER        # then log out/in, or: newgrp docker
docker compose version               # confirm the Compose plugin is present
```

## 5. Trust the registry over HTTP

The registry is plain HTTP over Tailscale, so the box must treat it as insecure to
pull its own images. `daemon.json` can't read env vars — use the literal `<TS_IP>`:

```bash
echo '{ "insecure-registries": ["<TS_IP>:30500"] }' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
```

## 6. Clone the repo and set secrets

```bash
git clone https://github.com/junhyukhan/homelab.git ~/homelab
cd ~/homelab
cp .env.example .env
```

Edit `.env`:
```
TZ=Asia/Seoul
TAILSCALE_IP=<TS_IP>
REGISTRY_HOST=<TS_IP>:30500
BASE_DOMAIN=<your-domain>        # only used once you expose a public route
```

## 7. cloudflared tunnel — set up now, or defer

Nothing is public at first, and the `cloudflared` service will crash-loop without a
valid tunnel. Pick one:

- **Defer (simplest):** just don't start `cloudflared` yet — bring up only the
  other services (step 8). No file edit needed; add the tunnel the day you expose
  something.
- **Set it up now:** follow `docs/tunnel-setup.md` (create the tunnel, drop the
  creds JSON in `~/homelab/cloudflared/<tunnel-id>.json`, fill `config.yml`).

## 8. Bring up the stack

```bash
cd ~/homelab

# Deferring the tunnel — start only registry + HA (cloudflared stays down, no crash-loop):
docker compose up -d registry home-assistant

# OR, if you set the tunnel up in step 7 — start everything:
docker compose up -d

docker compose ps
```

- **Home Assistant** → open `http://<TS_IP>:8123` and do first-run onboarding fresh.
- **Registry** → starts empty. Push images as you build them (`docs/add-a-service.md`);
  verify with `curl http://<TS_IP>:30500/v2/_catalog`.

## 9. Clean up the Mac (old k3s leftovers)

On the **Mac**, remove the dead k3s context and any stale SSH host config:

```bash
kubectl config delete-context homeserver
kubectl config delete-cluster <name>          # kubectl config get-clusters
# remove the k3s-config line from ~/.zshrc (keep the orbstack context)
# if ~/.ssh/config has a Host entry for the box, update its HostName to <TS_IP>
```

---

## Steady state

From then on it's the normal loop — SSH in, `git pull && docker compose up -d`. See
the top-level `README.md` and `docs/add-a-service.md`.
