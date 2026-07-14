# Runbook: Tear down k3s, stand up Docker

You run this **on the homelab box** (and a couple of steps on the Mac). Claude
does not run any of it. Go in order. **Do not skip the backup-verify gate.**

Prereqs: you've read SPEC.md, and `docs/data-migration.md` and
`docs/tunnel-setup.md` are open in another tab — you'll need them right after this.

---

## 1. Back up all PVC data (before anything destructive)

k3s stores local-path PVC data under `/var/lib/rancher/k3s/storage/`. Copy it out,
preserving ownership/permissions:

```bash
sudo cp -a /var/lib/rancher/k3s/storage/ ~/homelab_migration_backup/
```

### Identify which directory is which

The subdirectories are named
`pvc-<uuid>_<namespace>_<pvc-name>`, so the PVC name is in the directory name:

```bash
sudo ls -la /var/lib/rancher/k3s/storage/
sudo du -sh /var/lib/rancher/k3s/storage/*
```

- The **Home Assistant** volume is the one whose name contains the HA PVC
  (from the old `infrastructure/home-assistant/pvc.yaml`) — it holds
  `configuration.yaml`, `.storage/`, `home-assistant_v2.db`, etc. (~small, MBs).
- The **registry** volume contains a `docker/registry/v2/` tree (can be larger).

Note the two full paths — you'll need them in `docs/data-migration.md`.

## 2. VERIFY the backup — **STOP here**

```bash
ls -la ~/homelab_migration_backup/storage/
sudo du -sh ~/homelab_migration_backup/storage/*
```

Confirm the backup exists, is non-empty, and both the HA and registry directories
are present with sane sizes.

> **Gate: do not continue past this point until the backup is real and verified.**
> Everything below is destructive or hard to undo.

## 3. Uninstall k3s

```bash
/usr/local/bin/k3s-uninstall.sh
```

This removes k3s, its bundled containerd, kubelet state, and the systemd unit. It
does **not** touch the PVC data on disk (that's why step 1 exists) and does **not**
touch anything on the Mac (that's step 5).

## 4. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

Log out and back in (or `newgrp docker`) so the group membership takes effect, then
confirm `docker ps` works without sudo.

## 4b. Trust the registry over HTTP on the box's own daemon

The registry serves plain HTTP over Tailscale, so the box — now a Docker host that
pulls its own images (e.g. duri) — must treat it as insecure. This mirrors the
setting the Mac and ThinkPad already have. Edit `/etc/docker/daemon.json`:

```json
{ "insecure-registries": ["100.65.77.63:30500"] }
```

(The literal IP is required here — daemon.json can't read env vars. It's the same
value as `REGISTRY_HOST` in `.env`.) Then:

```bash
sudo systemctl restart docker
```

## 5. Clean the Mac's kubeconfig (run on the Mac, not the box)

```bash
kubectl config delete-context homeserver
kubectl config delete-cluster <cluster-name>   # find it via: kubectl config get-clusters
```

Then remove the k3s-config merge line from `~/.zshrc` (keep the orbstack context).
Nothing else on the Mac changes.

---

## Next

1. `docs/data-migration.md` — restore HA data into the named Docker volume.
2. `docs/tunnel-setup.md` — create the new cloudflared tunnel (required before the
   cloudflared service will start).
3. Then, from the repo on the box: `git pull && docker compose up -d`.
