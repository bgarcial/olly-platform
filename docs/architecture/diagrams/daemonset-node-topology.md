# DaemonSet Node Topology

Shows how exactly one OTel Collector pod and one Promtail pod are scheduled on **every** node, and why each collector only processes telemetry from pods on its own node.

## Diagram

```mermaid
flowchart TD
    subgraph Node1["Kubernetes Node 1"]
        direction TB
        subgraph AppPods1["Application Pods"]
            A1["Pod: java-app-7f9b\nNamespace: team-a"]
            A2["Pod: node-api-4d2c\nNamespace: team-b"]
        end
        subgraph DaemonPods1["DaemonSet Pods (one per node)"]
            C1["olly-collector-opentelemetry-collector-xxxxx\nOTel Collector\nPorts: 4317, 4318, 8888\nENV: KUBE_NODE_NAME=node-1"]
            P1["olly-collector-promtail-yyyyy\nPromtail\nMounts: /var/log/pods, /run/promtail/olly-collector"]
        end
    end

    subgraph Node2["Kubernetes Node 2"]
        direction TB
        subgraph AppPods2["Application Pods"]
            A3["Pod: python-worker-2a1f\nNamespace: team-a"]
        end
        subgraph DaemonPods2["DaemonSet Pods (one per node)"]
            C2["olly-collector-opentelemetry-collector-zzzzz\nOTel Collector\nPorts: 4317, 4318, 8888\nENV: KUBE_NODE_NAME=node-2"]
            P2["olly-collector-promtail-wwwww\nPromtail\nMounts: /var/log/pods, /run/promtail/olly-collector"]
        end
    end

    subgraph Backends["Backends (TBD)"]
        Tempo["Tempo\n(Traces)"]
        Mimir["Mimir\n(Metrics)"]
        Loki["Loki\n(Logs)"]
    end

    A1 & A2 -->|"OTLP :4317/:4318\n(in-cluster DNS)"| C1
    A3       -->|"OTLP :4317/:4318\n(in-cluster DNS)"| C2

    C1 -->|"k8sattributes filters\nnode_from_env_var: KUBE_NODE_NAME\n→ only enriches node-1 pods"| Tempo
    C1 --> Mimir
    C2 -->|"k8sattributes filters\nnode_from_env_var: KUBE_NODE_NAME\n→ only enriches node-2 pods"| Tempo
    C2 --> Mimir

    P1 -->|"Reads /var/log/pods\nof node-1 containers"| Loki
    P2 -->|"Reads /var/log/pods\nof node-2 containers"| Loki

    style C1 fill:#e8f4f8,stroke:#2196F3
    style C2 fill:#e8f4f8,stroke:#2196F3
    style P1 fill:#e8f5e9,stroke:#4CAF50
    style P2 fill:#e8f5e9,stroke:#4CAF50
```

## Why DaemonSet?

| Property | Benefit |
|----------|---------|
| One pod per node | No cross-node network hops for OTLP data |
| `KUBE_NODE_NAME` env var | `k8sattributes` processor scopes pod metadata lookup to its own node |
| Host path mounts (Promtail) | Direct access to `/var/log/pods` without network overhead |
| `tolerations: [{operator: Exists}]` (Promtail) | Runs on tainted nodes too (system nodes, GPU nodes, etc.) |

## In-Cluster OTLP Endpoint

Applications send telemetry to the collector using the Service DNS name (not the DaemonSet pod IP). Kubernetes routes each request to the collector pod on the **same node** via topology-aware routing (when configured) or standard kube-proxy:

```
# gRPC
http://olly-collector-opentelemetry-collector.<namespace>.svc.cluster.local:4317

# HTTP
http://olly-collector-opentelemetry-collector.<namespace>.svc.cluster.local:4318
```

For auto-instrumented pods, this endpoint is set automatically via the Instrumentation CR.

## Promtail Host Paths

```yaml
defaultVolumes:
  - name: run
    hostPath:
      path: /run/promtail/olly-collector   # State (positions file)
  - name: containers
    hostPath:
      path: /var/lib/docker/containers     # Docker container log files
  - name: pods
    hostPath:
      path: /var/log/pods                  # Kubernetes symlinked log paths
```

The `/run/promtail/olly-collector` path (instead of the default `/run/promtail`) prevents conflicts if another Promtail instance runs on the same node.
