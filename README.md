# homelab

Kubernetes manifests for my k3s homelab cluster, accessible only via Tailscale VPN.

## Architecture

```
Internet → Cloudflare Tunnel → k3s cluster ← Tailscale ← Mac
```

- **Cluster**: Single-node k3s bound to Tailscale IP (no public/LAN exposure)
- **External access**: Cloudflare Tunnel for public services
- **Internal access**: Tailscale VPN + NodePorts

## Directory Structure

```
homelab/
├── infrastructure/     # Critical services (cloudflared, gitea)
├── operations/         # Dev tools (registry)
├── observability/      # Monitoring (k3s-dashboard)
└── kustomization.yaml  # Root aggregator
```

## Quick Reference

### NodePorts (via `<tailscale-ip>:<port>`)

| Port  | Service             | Namespace      |
|-------|---------------------|----------------|
| 30500 | docker-registry     | operations     |
| 30800 | k3s-dashboard       | observability  |
| 3000  | gitea (HTTP)        | infrastructure |
| 2222  | gitea (SSH)         | infrastructure |
| 2000  | cloudflared metrics | infrastructure |

### Deploy Commands

```bash
# Deploy everything (--enable-helm required for Gitea's Helm chart)
kustomize build --enable-helm . | kubectl apply -f -

# Deploy a specific layer
kustomize build --enable-helm infrastructure/ | kubectl apply -f -
kubectl apply -k operations/
kubectl apply -k observability/

# Deploy a specific service
kubectl apply -k observability/k3s-dashboard/

# Restart a deployment
kubectl rollout restart deployment <name> -n <namespace>
```

### Common Operations

```bash
# Switch to k3s context
kubectl config use-context homeserver

# View all pods
kubectl get pods -A

# View pods in a namespace
kubectl get pods -n observability

# Check logs
kubectl logs -n <namespace> deployment/<name>
kubectl logs -n <namespace> <pod-name>

# Debug a pod
kubectl describe pod -n <namespace> <pod-name>

# Delete and recreate (when stuck)
kubectl delete deployment <name> -n <namespace>
kubectl apply -k <path>/
```

---

## Setup Guide

### 1. Server Setup (k3s node)

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --node-ip <tailscale-ip> \
  --flannel-iface tailscale0 \
  --tls-san <tailscale-ip>" sh -
```

| Flag | Purpose |
|------|---------|
| `--node-ip` | Bind to Tailscale IP (stable) |
| `--flannel-iface` | Route pod traffic through VPN |
| `--tls-san` | Allow remote kubectl via VPN IP |

### 2. Client Setup (Mac)

Copy `/etc/rancher/k3s/k3s.yaml` from server to `~/.kube/.k3s-config`.
Change `server: https://127.0.0.1:6443` to `server: https://<tailscale-ip>:6443`.

Add to `~/.zshrc`:
```bash
export KUBECONFIG=~/.kube/config:~/.kube/.k3s-config
```

Switch contexts:
```bash
kubectl config use-context orbstack     # local
kubectl config use-context homeserver   # k3s (rename from 'default')
kubectl config rename-context default homeserver
```

### 3. Registry Setup (for pushing images)

Add to Docker Desktop settings (Settings → Docker Engine):
```json
{
  "insecure-registries": ["<tailscale-ip>:30500"]
}
```

Push images:
```bash
docker build -t <tailscale-ip>:30500/myapp:latest .
docker push <tailscale-ip>:30500/myapp:latest
```

---

## Concepts

### Namespaces vs Contexts

| | Namespaces | Contexts |
|--|------------|----------|
| **Where** | Server (cluster) | Client (~/.kube/config) |
| **What** | Resource isolation | Cluster + user + default namespace |
| **Analogy** | Rooms in a building | ID badge for the building |

### Labels in deployment.yaml

```yaml
metadata:
  labels:
    app: myapp        # 1. Labels the Deployment (optional)
spec:
  selector:
    matchLabels:
      app: myapp      # 2. "Hiring criteria" (MUST match #3)
  template:
    metadata:
      labels:
        app: myapp    # 3. Pod label (MUST match #2)
```

---

## Debugging Cheatsheet

```bash
# Pod won't start?
kubectl describe pod -n <ns> <pod>    # Check Events section
kubectl logs -n <ns> <pod>            # Check startup logs

# Image pull issues?
kubectl get events -n <ns> --sort-by='.lastTimestamp'

# Service not reachable?
kubectl get svc -n <ns>               # Check ClusterIP/NodePort
kubectl get endpoints -n <ns>         # Check if pods are backing it

# Restart everything in a namespace
kubectl rollout restart deployment -n <ns> --all
```

## Secrets

```bash
# Create secret from literal
kubectl create secret generic my-secret \
  --from-literal=KEY=value \
  -n <namespace>

# Create secret from file
kubectl create secret generic my-secret \
  --from-file=.env \
  -n <namespace>

# View decoded secret
kubectl get secret <name> -n <ns> -o jsonpath='{.data.KEY}' | base64 -d
```
