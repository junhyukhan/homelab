# Runbook: Add a service (steady state)

The everyday workflow once the homelab is on Compose. See SPEC.md §Access planes
for the private/public model this checklist encodes.

## 1. Build on a dev machine (not the box)

The box runs artifacts, it doesn't build them (Pattern A, SPEC.md). Build on the
Mac (`apple/container`) or ThinkPad (Docker), tagged with a **version or git-SHA
tag — never `:latest`** (`:latest` won't re-pull reliably on `up -d`):

```bash
docker build -t 100.65.77.63:30500/myapp:v1 .
```

`100.65.77.63:30500` is `${REGISTRY_HOST}` — the one canonical registry address
(see SPEC.md). There is no `registry.homelab` hostname.

## 2. Push to the registry

```bash
docker push 100.65.77.63:30500/myapp:v1
```

(The dev machine needs `100.65.77.63:30500` in its Docker `insecure-registries` —
Mac and ThinkPad already do.)

## 3. Add a compose block

In `compose.yaml`, referencing the pushed image:

```yaml
  myapp:
    image: ${REGISTRY_HOST}/myapp:v1
    restart: unless-stopped
    depends_on:
      - registry            # only if it pulls from the local registry
    networks:
      - homelab_net
    # ports / environment as needed
```

## 4. Decide the access plane — **explicit checklist, not an afterthought**

Ask one question: *do I need to reach this from a device that isn't on my tailnet,
or share it with someone?*

- [ ] **No → Tailscale-private (the default).** Do nothing extra. It's reachable at
      `100.65.77.63:<published-port>` for anyone on the tailnet. Stop here.
- [ ] **Yes → add a public route (additive; it stays Tailscale-reachable too):**
  - [ ] Add an ingress rule in `cloudflared/config.yml`, *above* the 404 catch-all:
        ```yaml
          - hostname: myapp.${BASE_DOMAIN}
            service: http://myapp:PORT   # cloudflared is on homelab_net, so it
                                         # resolves other bridge services by name
        ```
  - [ ] Add a DNS CNAME `myapp.<domain>` → `<tunnel-id>.cfargotunnel.com`
        (Cloudflare dashboard).
  - [ ] Confirm a Cloudflare Access policy covers `myapp.<domain>` (email OTP or
        your chosen method).
  - [ ] Restart cloudflared so it reloads the config:
        `docker compose restart cloudflared`.

> Registry is the standing exception: **never** give it a public route — Cloudflare
> Access breaks `docker push`. See SPEC.md.

## 5. Deploy

```bash
docker compose up -d myapp      # or `up -d` for the whole stack
```

Update SPEC.md's Services table if this is a permanent addition — SPEC changes
first, code follows.
