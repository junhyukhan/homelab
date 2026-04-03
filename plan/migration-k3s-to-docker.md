# Architecture Migration: k3s to Docker Compose

## Context
We are migrating this homelab repository from a Kubernetes (k3s) architecture to a streamlined Docker Compose setup. The new architecture uses Caddy for Layer 7 reverse proxy routing via a custom domain, a standard Docker bridge network for isolation, and a `.env` file to manage secrets and host-OS context (like PUID/PGID for volume permissions). 

Please read the Current State context carefully, then execute the migration steps in exact order.

## Current State (k3s)

### Architecture
`Internet → Cloudflare Tunnel → k3s cluster ← Tailscale ← Mac`
- Single-node k3s bound to Tailscale IP
- Deployed via `kustomize build --enable-helm . | kubectl apply -f -`

### Directory Structure
```
homelab/
├── kustomization.yaml              # Root aggregator (resources: infrastructure, operations, observability)
├── infrastructure/                 # Namespace: infrastructure
│   ├── kustomization.yaml          #   resources: cloudflared, gitea
│   ├── cloudflared/
│   │   ├── deployment.yaml         #   Image: cloudflare/cloudflared:latest
│   │   ├── kustomization.yaml      #   SecretGenerator from .env (TUNNEL_TOKEN)
│   │   ├── .env / .env.copy        #   TUNNEL_TOKEN=...
│   │   └── README.md
│   └── gitea/
│       ├── kustomization.yaml      #   Helm chart (gitea, dl.gitea.com/charts/)
│       ├── gitea-values.yaml       #   SQLite, disabled pg/valkey, 10Gi PVC, registration disabled
│       ├── .env / .env.copy        #   GITEA__server__DOMAIN, SSH_DOMAIN, ROOT_URL (MagicDNS)
│       └── charts/                 #   Vendored Helm chart (gitea + postgresql subchart)
├── operations/                     # Namespace: operations
│   ├── kustomization.yaml          #   resources: registry
│   └── registry/
│       ├── deployment.yaml         #   Image: registry:2, mounts PVC at /var/lib/registry
│       ├── service.yaml            #   NodePort 30500 → 5000
│       ├── pvc.yaml                #   20Gi ReadWriteOnce
│       ├── kustomization.yaml
│       └── README.md
├── observability/                  # Namespace: observability
│   ├── kustomization.yaml          #   resources: k3s-dashboard
│   └── k3s-dashboard/
│       ├── deployment.yaml         #   Image: localhost:30500/k3s-dashboard:latest (custom app)
│       ├── service.yaml            #   NodePort 30800 → 8000
│       ├── rbac.yaml               #   ServiceAccount + ClusterRole (read pods/svc/ns/pvc/events/nodes/deploy/rs)
│       └── kustomization.yaml
├── .gitignore                      #   .env, .DS_Store, charts/
├── .env                            #   Root-level (gitignored)
└── README.md                       #   Full setup guide, debugging cheatsheet
```

### Services & Ports (current)
| Service           | Image                            | Namespace      | Ports                  | Storage         |
|-------------------|----------------------------------|----------------|------------------------|-----------------|
| cloudflared       | cloudflare/cloudflared:latest    | infrastructure | 2000 (metrics)         | none            |
| gitea             | gitea (Helm chart, SQLite mode)  | infrastructure | 3000 (HTTP), 2222 (SSH)| 10Gi PVC        |
| docker-registry   | registry:2                       | operations     | 30500 → 5000 (NodePort)| 20Gi PVC        |
| k3s-dashboard     | localhost:30500/k3s-dashboard    | observability  | 30800 → 8000 (NodePort)| none            |

### Secrets Management (current)
- **cloudflared**: `TUNNEL_TOKEN` via Kustomize SecretGenerator.
- **gitea**: `GITEA__server__DOMAIN`, `GITEA__server__SSH_DOMAIN`, `GITEA__server__ROOT_URL` via SecretGenerator, injected as `envFrom`.

### Migration Notes
- **k3s-dashboard** is deprecated. Do not carry this service over.
- **cloudflared metrics** endpoint (port 2000) was consumed by k3s-dashboard. Drop the `--metrics` flag in Docker Compose.
- **gitea** Docker Compose version should use the plain `gitea/gitea:latest` image directly.
- **registry** needs `REGISTRY_STORAGE_DELETE_ENABLED=true` added.

---

## Step 1: Data Extraction & Backup Plan
Before modifying the repository, write out a brief text instruction guide for me (the user) on how to manually extract the data from my running k3s cluster. 
Provide the exact `kubectl cp` commands to copy the `gitea` pod's data and the `docker-registry` pod's data to a local `~/homelab_migration_backup/gitea` and `~/homelab_migration_backup/registry` directory on the host. Pause and ask me to confirm I have secured the data before proceeding to Step 2.

## Step 2: Archive Legacy Configurations
1. Create a new branch named `legacy-k3s` and commit the current repository state to preserve history.
2. Switch back to the working branch (e.g., `main`).
3. Delete the following directories and files entirely: `infrastructure/`, `operations/`, `observability/`, `plan/` (if it exists), and `kustomization.yaml`.

## Step 3: Generate docker-compose.yml
Create a `docker-compose.yml` in the root directory containing the following services attached to a custom bridge network named `homelab_net`:

1. **caddy:** Image `caddy:2-alpine`. Publish port `"80:80"`. Mount `./Caddyfile:/etc/caddy/Caddyfile` and named volumes `caddy_data` and `caddy_config`.
2. **cloudflared:** Image `cloudflare/cloudflared:latest`. Command: `tunnel --no-autoupdate run`. Inject the `TUNNEL_TOKEN` environment variable.
3. **gitea:** Image `gitea/gitea:latest`. Publish port `"2222:2222"` for SSH (Caddy only handles HTTP/S). Inject `USER_UID=${PUID}`, `USER_GID=${PGID}`, and `TZ=${TZ}`. Inject explicit Gitea vars: `GITEA__server__DOMAIN=${BASE_DOMAIN}`, `GITEA__server__ROOT_URL=https://gitea.${BASE_DOMAIN}/`, `GITEA__server__SSH_PORT=2222`, `GITEA__server__SSH_LISTEN_PORT=2222`, `GITEA__service__DISABLE_REGISTRATION=true`. Mount named volume `gitea_data`.
4. **registry:** Image `registry:2`. Inject `REGISTRY_STORAGE_DELETE_ENABLED=true`. Mount named volume `registry_data`. Do not publish ports to the host; Caddy will route to it.

## Step 4: Generate Caddyfile
Create a `Caddyfile` in the root directory. To prevent Caddy from attempting ACME HTTP challenges (since Cloudflare handles public TLS), you MUST prefix the sites with `http://`.
- Route `http://gitea.{$BASE_DOMAIN}` to `reverse_proxy gitea:3000`
- Route `http://registry.{$BASE_DOMAIN}` to `reverse_proxy registry:5000`

## Step 5: Generate .env.example
Create an `.env.example` file in the root directory with the following keys:
- `PUID=1000`
- `PGID=1000`
- `TZ=Asia/Seoul`
- `BASE_DOMAIN=yourdomain.com`
- `TUNNEL_TOKEN=your_cloudflare_token_here`

## Step 6: Update .gitignore
Ensure `.env` is explicitly ignored.

## Step 7: Data Injection & Setup Instructions
Output clear instructions for me on how to migrate the extracted data into the Docker named volumes using a temporary Alpine container to avoid host permission errors. 
Example approach to provide to me: 
`docker run --rm -v gitea_data:/dest -v ~/homelab_migration_backup/gitea:/src alpine cp -a /src/. /dest/`
Ensure you instruct me to do this for both Gitea and the Registry, and remind me to verify file ownership matches the `PUID`/`PGID` set in the `.env` file.

## Step 8: Rewrite README.md
Completely rewrite the `README.md`. 
- Remove all mentions of k3s, `kubectl`, `kustomize`, NodePorts, and PVCs.
- Document the new architecture: Internet -> Cloudflare Tunnel -> Docker -> Caddy -> Services.
- Add an explicit operational step: "Update the Cloudflare Zero Trust Dashboard to point `gitea.yourdomain.com` and `registry.yourdomain.com` to the internal Caddy origin: `http://caddy:80`."
- Provide a quick-start guide for spinning up the stack and using `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile` for zero-downtime routing updates.
