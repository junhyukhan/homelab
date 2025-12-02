### cloudflared deployment.yaml

**Namespace:** `infrastructure`

This deployment runs the Cloudflare Tunnel daemon. It connects this cluster to the Cloudflare Edge, allowing us to expose services securely.  
This application requires a sensitive `TUNNEL_TOKEN`. We use a local `.env` file and **Kustomize SecretGenerator** to handle this.


#### secrets:

Originally used the imperative method for secrets.
```bash
kubectl get secrets
kubectl create secret generic cloudflare-tunnel-token --from-literal=token='...' --namespace=networking
```

Now, we keep a .env file in the same directory with the variable `TUNNEL_TOKEN`


#### Deployment

To update only the Cloudflare Tunnel:

```bash
kubectl apply -k infrastructure/cloudflared/
```
*Note: If the token changes, Kustomize will append a hash to the secret name and automatically restart the pods.*
