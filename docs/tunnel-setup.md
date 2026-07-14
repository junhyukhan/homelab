# Runbook: Create the cloudflared tunnel

The Compose stack uses a **locally-managed** tunnel (routes in git, no
`TUNNEL_TOKEN`). This is a **new tunnel**, not a reconfig of the old k3s one — the
old remote-managed `TUNNEL_TOKEN` is discarded. Run on the box.

This uses the same pattern as the ThinkPad dev gateway — see
`plan/thinkpad-dev-gateway.md` for the fuller walkthrough and the wildcard-CNAME
variant.

> The `cloudflared` service won't start until `tunnel` and `credentials-file` in
> `cloudflared/config.yml` point at a real tunnel, so do this before
> `docker compose up -d`.

## 1. Authenticate (one-time)

Install cloudflared on the box (or run these in a throwaway container with the
`~/.cloudflared` dir mounted), then:

```bash
cloudflared tunnel login        # opens a browser link; authorize your zone
```

## 2. Create the tunnel

```bash
cloudflared tunnel create homelab
```

This prints a **tunnel ID** and writes a credentials JSON to
`~/.cloudflared/<tunnel-id>.json`. Note the ID.

## 3. Place the credentials JSON where compose mounts it

`compose.yaml` mounts `./cloudflared` (in the repo on the box) read-only at
`/etc/cloudflared`. Put the creds file there:

```bash
cp ~/.cloudflared/<tunnel-id>.json <repo>/cloudflared/<tunnel-id>.json
```

It's gitignored (`cloudflared/*.json`) — it must never be committed.

## 4. Fill in `cloudflared/config.yml`

Replace the placeholders (the path is the in-container path):

```yaml
tunnel: <tunnel-id>            # the ID (or name "homelab")
credentials-file: /etc/cloudflared/<tunnel-id>.json
```

Leave the `ingress:` list as-is — no real routes at migration time, just the
commented example and the `http_status:404` catch-all. Commit this file (the
config is meant to live in git; only the JSON is secret).

## 5. DNS CNAMEs — only when you add a public route

At migration there are **no public hostnames**, so no DNS record is needed yet; the
tunnel runs with just the 404 catch-all. When you later expose a service
(`docs/add-a-service.md`), add a CNAME per hostname:

- **Type:** CNAME
- **Name:** `myapp` (→ `myapp.<domain>`)
- **Target:** `<tunnel-id>.cfargotunnel.com`
- **Proxy:** on (orange cloud)

...and pair it with a Cloudflare Access policy.

## 6. Start it

```bash
docker compose up -d cloudflared
docker compose logs -f cloudflared     # expect "Registered tunnel connection"
```

## Re-pointing DNS from the old tunnel

Any CNAMEs that pointed at the *old* k3s tunnel must be re-pointed to this new
tunnel's ID (or deleted if that hostname is now Tailscale-private). At migration
there are none to carry over — the old public routes (gitea, registry, dashboard)
are all gone or intentionally private now. The old tunnel can be deleted from the
Cloudflare dashboard once nothing references it.
