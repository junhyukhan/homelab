### cloudflared deployment.yaml
---
```yaml
metadata:
  name: cloudflared-tunnel-deployment
  namespace: networking
  labels:
    app: cloudflared-tunnel
```

#### secrets:

```bash
kubectl get secrets
kubectl create secret generic cloudflare-tunnel-token --from-literal=token='...' --namespace=networking
```