### Infrastructure Layer

**Namespace:** `infrastructure`

This directory contains the services required for the cluster to function. If these services go down, external access to the cluster is lost.

#### Components

| App | Description | Status |
| :--- | :--- | :--- |
| **Cloudflared** | Creates a secure tunnel to expose internal services to the web without opening ports. | Active |


#### Usage

To deploy or update all infrastructure components:

```bash
kubectl apply -k infrastructure/
```