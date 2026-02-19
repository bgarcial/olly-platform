# Kyverno CR Propagation Flow

Shows how the Kyverno ClusterPolicy automatically syncs `Instrumentation` CRs into every namespace so applications can opt in to auto-instrumentation with a single pod annotation.

## Diagram

```mermaid
flowchart TD
    subgraph Bootstrap["Chart Deployment (helm install)"]
        HelmChart["olly-collector Helm Chart"]
        HelmChart -->|"generates"| ClusterPolicy["Kyverno ClusterPolicy\nName: olly-collector\n—\nRule 1: sync-instrumentation\nRule 2: sync-instrumentation-full"]
        HelmChart -->|"deploys"| OtelOp["OTel Operator\n(2 replicas)"]
        HelmChart -->|"deploys"| Collector["OTel Collector DaemonSet"]
    end

    subgraph DefaultNS["default namespace (source of truth)"]
        IR_Default["Instrumentation CR\nName: olly-collector\n—\nMetrics: DISABLED\nTraces: enabled\nAll languages: HTTP :4318\n(Node.js, nginx, Apache: gRPC :4317)"]
        IR_Full["Instrumentation CR\nName: olly-collector-full\n—\nMetrics: ENABLED\nTraces: enabled\nHistogram: base2_exponential"]
    end

    subgraph NSCreation["Namespace lifecycle event"]
        NewNS["New Namespace created\n(e.g. team-a, team-b)"]
    end

    subgraph TargetNS_A["team-a namespace (synced)"]
        IR_A1["Instrumentation CR\nolly-collector (copy)"]
        IR_A2["Instrumentation CR\nolly-collector-full (copy)"]
        Pod_A["Java Pod\nannotation: inject-java: olly-collector"]
        InitC_A["Init container injected\nOTel Java agent JAR\n+ OTEL_* env vars set"]
    end

    subgraph TargetNS_B["team-b namespace (synced)"]
        IR_B1["Instrumentation CR\nolly-collector (copy)"]
        IR_B2["Instrumentation CR\nolly-collector-full (copy)"]
        Pod_B["Node.js Pod\nannotation: inject-nodejs: olly-collector-full"]
        InitC_B["Init container injected\nOTel Node.js agent\nMetrics ENABLED\nEndpoint: gRPC :4317"]
    end

    ClusterPolicy -->|"watches Namespace CREATE/UPDATE\n(generateExisting: true)"| NewNS
    NewNS -->|"triggers generate rule"| IR_A1 & IR_A2
    NewNS -->|"triggers generate rule"| IR_B1 & IR_B2

    ClusterPolicy -.->|"synchronize: true\n(updates propagate)"| IR_A1 & IR_A2
    ClusterPolicy -.->|"synchronize: true\n(updates propagate)"| IR_B1 & IR_B2

    Pod_A -->|"admission webhook\n(OTel Operator)"| OtelOp
    OtelOp -->|"reads"| IR_A1
    OtelOp -->|"injects"| InitC_A
    InitC_A -->|"OTLP HTTP :4318\nTraces only"| Collector

    Pod_B -->|"admission webhook\n(OTel Operator)"| OtelOp
    OtelOp -->|"reads"| IR_B2
    OtelOp -->|"injects"| InitC_B
    InitC_B -->|"OTLP gRPC :4317\nTraces + Metrics"| Collector

    style ClusterPolicy fill:#fce4ec,stroke:#E91E63
    style IR_Default fill:#f3e5f5,stroke:#9C27B0
    style IR_Full fill:#f3e5f5,stroke:#9C27B0
    style OtelOp fill:#e8f4f8,stroke:#2196F3
    style Collector fill:#e8f4f8,stroke:#2196F3
```

## Namespace Exclusions

The ClusterPolicy explicitly skips these namespaces (no Instrumentation CRs synced):

```yaml
exclude:
  any:
    - resources:
        namespaces:
          - default         # Source namespace — CRs live here
          - kube-system     # System components
          - kube-node-lease # Node heartbeats
          - kube-public     # Public cluster info
```

## Opting In — Pod Annotation Reference

| Language | Annotation | CR to use | Result |
|----------|------------|-----------|--------|
| Java | `instrumentation.opentelemetry.io/inject-java: "olly-collector"` | Default | Traces only |
| Java | `instrumentation.opentelemetry.io/inject-java: "olly-collector-full"` | Full | Traces + JVM/HTTP metrics |
| Node.js | `instrumentation.opentelemetry.io/inject-nodejs: "olly-collector"` | Default | Traces only (gRPC :4317) |
| Python | `instrumentation.opentelemetry.io/inject-python: "olly-collector"` | Default | Traces only |
| nginx | `instrumentation.opentelemetry.io/inject-nginx: "olly-collector"` | Default | Traces only (gRPC :4317) |
| Apache | `instrumentation.opentelemetry.io/inject-apache-httpd: "olly-collector"` | Default | Traces only (gRPC :4317) |

## Known Issues

| Issue | Location | Fix |
|-------|----------|-----|
| Extra period in endpoint URL | `clusterpolicy.yaml` lines ~50, ~68–76 | Remove trailing `.` from `.svc.cluster.local.:4318` |
| Go not configured | `clusterpolicy.yaml` | Add `go:` section to both rules |
| Python missing from full CR | `sync-instrumentation-full` rule | Add `python:` section with `OTEL_METRICS_EXPORTER: otlp` |

## Synchronization Behaviour

`synchronize: true` in the generate rule means:
- When the source Instrumentation CR in `default` is **updated** → all copies in every namespace are updated automatically
- When a namespace is **deleted** → its copies are removed
- When the ClusterPolicy is **deleted** → all generated resources are removed
