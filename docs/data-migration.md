# Runbook: Move backed-up data into Docker volumes

Run on the box, after `docs/cleanup-k3s.md` (Docker installed, backup verified) and
**before** `docker compose up -d` — so services start on top of restored data
instead of initializing empty.

## The volume-name gotcha

Compose prefixes volumes with the project name. This stack sets `name: homelab` in
`compose.yaml`, so the real volumes are **`homelab_ha_data`** and
**`homelab_registry_data`** — not bare `ha_data` / `registry_data`. Restore into
the prefixed names, or you'll populate a volume nothing uses.

To control the name, create the volume first (compose reuses an existing volume of
the same name):

```bash
docker volume create homelab_ha_data
```

## Home Assistant

Using the HA backup path you identified in cleanup step 1
(`~/homelab_migration_backup/storage/<pvc-...-home-assistant>`):

```bash
docker run --rm \
  -v homelab_ha_data:/dest \
  -v ~/homelab_migration_backup/storage/<HA_PVC_DIR>:/src:ro \
  alpine cp -a /src/. /dest/
```

Verify, and check ownership matches the identity HA runs as (see PUID/PGID in
`.env`; the HA image itself runs as root and owns `/config`):

```bash
docker run --rm -v homelab_ha_data:/data alpine sh -c 'ls -la /data | head; echo; \
  test -f /data/configuration.yaml && echo "configuration.yaml present" || echo "MISSING configuration.yaml"'
```

## Registry

**Decide first:** is every image in the old registry rebuildable from source (your
own projects)?

- **Yes → skip the restore.** Re-push from a dev machine instead
  (`docker push 100.65.77.63:30500/<name>:<tag>`). Cleaner than moving blobs.
- **No** (something can't be rebuilt) → restore it the same way as HA:

  ```bash
  docker volume create homelab_registry_data
  docker run --rm \
    -v homelab_registry_data:/dest \
    -v ~/homelab_migration_backup/storage/<REGISTRY_PVC_DIR>:/src:ro \
    alpine cp -a /src/. /dest/
  ```

## Then

Bring the stack up on top of the restored data:

```bash
cd <repo>            # the homelab repo on the box
docker compose up -d
```

Confirm HA at `http://100.65.77.63:8123` shows your existing config, and
(if restored) `curl http://100.65.77.63:30500/v2/_catalog` lists your images.
