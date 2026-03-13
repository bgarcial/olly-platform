# Telemetry Data Flow

End-to-end flow from instrumented applications through the olly-collector to the Grafana Cloud observability backends (Loki, Mimir, Tempo) and Grafana.

## Diagram

```mermaid
flowchart TD
    subgraph Cluster["Kubernetes Cluster (olly-do-nonprd)"]
        subgraph DemoNS["opentelemetry-demo namespace"]
            Demo["OTel Demo Services\n(manual instrumentation)\nTraces + Metrics"]
        end

        subgraph AppNS["Application Namespaces (team-a, team-b, ...)"]
            AppJava["Java Pod\nauto-instrumented (OTel Java agent)"]
            AppNode["Node.js Pod\nauto-instrumented (OTel Node agent)"]
            AppManual["Any Pod\nmanual OTel SDK"]
        end

        subgraph ObsNS["observability namespace"]
            Collector["OTel Collector DaemonSet\notel/opentelemetry-collector-k8s:0.134.1\n—\nPort 4317 (gRPC)\nPort 4318 (HTTP)\nPort 8888 (self-metrics/Prometheus)"]
            OtelOp["OTel Operator\n(2 replicas, HA)\nManages Instrumentation CRs\nand OpenTelemetryCollector CR"]
        end

        Kubelet["Kubelet\n(port 10250)\nNode/Pod/Container/Volume stats"]
    end

    subgraph Backends["Grafana Cloud Backends"]
        Loki["Loki\nLog aggregation\nlogs-prod-eu-west-0.grafana.net"]
        Mimir["Mimir\nMetrics storage\nprometheus-prod-01-eu-west-0.grafana.net"]
        Tempo["Tempo\nDistributed tracing\ntempo-eu-west-0.grafana.net"]
        Grafana["Grafana\nDashboards\nLogs · Metrics · Traces"]
    end

    Demo -->|"OTLP gRPC :4317 / HTTP :4318\nTraces + Metrics"| Collector
    AppJava  -->|"OTLP HTTP :4318\nTraces + Metrics"| Collector
    AppNode  -->|"OTLP gRPC :4317\nTraces"| Collector
    AppManual-->|"OTLP gRPC :4317 or HTTP :4318\nTraces + Metrics"| Collector

    Kubelet -.->|"kubeletstats receiver\nhttps :10250\nNode/Pod/Container/Volume metrics"| Collector

    Collector-->|"OTLP gRPC (basicauth)\nTraces → traces pipeline"| Tempo
    Collector-->|"OTLP HTTP (basicauth)\nMetrics → metrics pipeline"| Mimir
    Collector-->|"OTLP HTTP (basicauth)\nLogs → logs pipeline"| Loki
    Collector-.->|"Port :8888\nCollector self-metrics (Prometheus format)"| Mimir

    Loki  --> Grafana
    Mimir --> Grafana
    Tempo --> Grafana

    OtelOp -.->|"Manages"| Collector

    style Collector fill:#e8f4f8,stroke:#2196F3
    style OtelOp fill:#e8f4f8,stroke:#2196F3
    style Demo fill:#e0f2e0,stroke:#4CAF50
    style Kubelet fill:#f3e8ff,stroke:#9C27B0
    style Loki fill:#fff3e0,stroke:#FF9800
    style Mimir fill:#fff3e0,stroke:#FF9800
    style Tempo fill:#fff3e0,stroke:#FF9800
    style Grafana fill:#fff3e0,stroke:#FF9800
```

## Signal Types

| Signal | Source | Receiver | Processor Chain | Exporter | Backend |
|--------|--------|----------|-----------------|----------|---------|
| Traces | App pods, OTel Demo | `otlp` (4317 gRPC / 4318 HTTP) | `memory_limiter` → `filter/drop_noisy_trace_urls` → `k8sattributes` → `batch` → `resource` | `otlp/traces` (gRPC, basicauth) | Tempo |
| Metrics | App pods, OTel Demo, kubelet | `otlp` + `kubeletstats` (60s interval) | `memory_limiter` → `k8sattributes` → `batch` → `resource` → `transform/promote_node_name` | `otlphttp/metrics` (basicauth) | Mimir |
| Logs | Container log files | `filelog` (/var/log/pods/**/*.log) | `memory_limiter` → `k8sattributes` → `batch` → `resource` | `otlphttp/logs` (basicauth) | Loki |
| Collector self-metrics | Collector internal | :8888 Prometheus scrape | N/A (pulled by Prometheus/ServiceMonitor) | — | Mimir |

## Backend Configuration

Each backend uses basicauth extensions with Grafana Cloud credentials stored as environment variables (`GRAFANA_CLOUD_TOKEN`, per-service user vars).

```yaml
global:
  tempo:
    endpoint: "tempo-eu-west-0.grafana.net:443"          # OTLP gRPC (bare host:port)
  mimir:
    endpoint: "https://prometheus-prod-01-eu-west-0.grafana.net/otlp"  # OTLP HTTP
  loki:
    endpoint: "https://logs-prod-eu-west-0.grafana.net/otlp"           # OTLP HTTP
```
