### Infrastructure Layer

**Namespace:** `infrastructure`

This directory contains the services required for the cluster to function. If these services go down, external access to the cluster is lost.

#### Components

| App | Description | Status |
| :--- | :--- | :--- |
| **Cloudflared** | Creates a secure tunnel to expose internal services to the web without opening ports. | Active |
| **Gitea** | Self-hosted Git service (SQLite, Helm chart via Kustomize). | Active |


#### Usage

To deploy or update all infrastructure components:

```bash
# Required: --enable-helm because Gitea uses a helmCharts entry in kustomization.yaml
kustomize build --enable-helm infrastructure/ | kubectl apply -f -
```