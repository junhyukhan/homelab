### homelab configs
---

1. Architecture
Goal: A headless K3s server that is only accessible via the secure Tailscale network. It does not listen on the public internet or the local Wi-Fi LAN (preventing IP shift crashes).  

2. Server Setup

On the server,  
```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --node-ip <tailscale ip address> \
  --flannel-iface tailscale0 \
  --tls-san <tailscale ip address>" sh -
```

- `--node-ip`: Anchors the node to the stable VPN IP.
- `--flannel-iface`: Forces internal pod traffic through the tunnel. May not be `tailscale0`, should be checked.
- `--tls-san`: Authorizes remote clients (your Mac) to connect via the VPN IP.

3. Client Setup

Copy `/etc/rancher/k3s/k3s.yaml` from the server,
Paste into `~/.kube/config`.


Change the ip address in `server: https://127.0.0.1:6443` to the tailscale ip address.

Test using `kubectl get nodes`.  

4. Core Concepts

**A. Namespace vs. Contexts**
- Namespaces are the 'rooms': folders on the server to isolate resources
    - They exist on the server.
    - example:
        - networking: For Cloudflared, Traefik, MetalLB.
        - dev-tools: For Registry, CI/CD.
        - apps: personal apps
        - default: For temporary junk.
- Contexts are the 'ID badge' for entering the 'rooms':
    - Which Building you are entering (Cluster) + Who you are (User) + Which Room you go to automatically (Default Namespace)
    - They exist on the client.

**Labels in deployment.yaml**
- The label app: name is repeated three times.
    1. Deployment Metadata: Labels the manager (optional but good).
    1. Spec Selector: The "Hiring Criteria" the manager looks for.
    1. Template Metadata: The "Stamp" put on new workers (pods).
- Rule: #2 and #3 MUST match, #1 should also match (doesn't have to)

5. Cheatsheet

**basic**
```bash
# Switch default namespace view (requires kubectx)
kubens networking
# Rename the awkward default context name
kubectl config rename-context default homeserver
# Create a namespace
kubectl create namespace dev-tools
```

**Debugging**
```bash
# List pods (in current namespace)
kubectl get pods
# List pods (in ALL namespaces)
kubectl get pods -A
# See why a pod crashed (Startup logs)
kubectl logs <pod-name>
# deep dive into config/errors (Events & Status)
kubectl describe pod <pod-name>
```

**Secrets**
```bash
# Create a secret manually (Imperative)
kubectl create secret generic my-secret --from-literal=key=value -n networking
# View the DECODED password (without this, you see base64 gibberish)
kubectl get secret <secret-name> -o jsonpath='{.data.token}' | base64 --decode
```