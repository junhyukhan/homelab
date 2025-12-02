### Private Docker Registry

**Namespace:** `operations`

A self-hosted Docker Registry (Distribution v2). This allows us to build images on a MacBook and push them directly to the cluster over Tailscale.

#### Configuration

* **Storage:** 20Gi Persistent Volume (PVC: `registry-pvc`).
* **Network:** Exposed via NodePort.
* **Address:** `<tailscale IP:PORT>`.

#### How to Push Images

Since this registry runs over a private VPN, it uses HTTP. The Docker client must be setup to trust it.

1.  **Configure Docker Desktop (Mac):**
    Add the following to the Docker Engine configuration:
    ```json
    "insecure-registries": ["<tailscale IP>"]
    ```

2.  **Tag & Push:**
    ```bash
    docker build -t <tailscale IP>/my-app:v1 .
    docker push <tailscale IP>/my-app:v1
    ```

#### Deployment

To update only the Registry:

```bash
kubectl apply -k operations/registry/
````

```
```