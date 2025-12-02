### Operations Layer

**Namespace:** `operations`

This directory contains tools used to build, maintain, and monitor the cluster. These are developer-facing tools, not end-user applications.

#### Components

| App | Description | Status |
| :--- | :--- | :--- |
| **Docker Registry** | Private container registry for hosting custom images. | Active |
| **Monitoring** | Prometheus/Grafana stack. | Pending |

#### Usage

To deploy or update all operational tools:

```bash
kubectl apply -k operations/
```