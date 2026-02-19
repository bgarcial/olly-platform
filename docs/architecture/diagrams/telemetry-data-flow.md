# Telemetry Data Flow

End-to-end flow from instrumented applications through the olly-collector to the observability backends (Loki, Mimir, Tempo) and Grafana.

> **Current state**: The `otlphttp` exporter is commented out — the collector uses the `debug` exporter locally while backends are not yet connected. Replace `debug` with `otlphttp` once `global.opentelemetry.endpoint` is set.

## Diagram

```mermaid
flowchart TD
    subgraph Cluster["Kubernetes Cluster (olly-personal-nonprd)"]
        subgraph AppNS["Application Namespaces (team-a, team-b, ...)"]
            AppJava["Java Pod\nauto-instrumented (OTel Java agent)"]
            AppNode["Node.js Pod\nauto-instrumented (OTel Node agent)"]
            AppManual["Any Pod\nmanual OTel SDK"]
        end

        subgraph ObsNS["observability namespace"]
            Collector["OTel Collector DaemonSet\notel/opentelemetry-collector-k8s:0.133.0\n—\nPort 4317 (gRPC)\nPort 4318 (HTTP)\nPort 8888 (self-metrics/Prometheus)"]
            Promtail["Promtail DaemonSet\ngrafana/promtail\n—\nCollects container logs from\n/var/log/pods/**"]
            OtelOp["OTel Operator\n(2 replicas, HA)\nManages Instrumentation CRs\nand OpenTelemetryCollector CR"]
        end
    end

    subgraph Backends["Observability Backends (TBD — not yet connected)"]
        Loki["Loki\nLog aggregation\n(endpoint: TBD)"]
        Mimir["Mimir\nMetrics storage\n(endpoint: TBD)"]
        Tempo["Tempo\nDistributed tracing\n(endpoint: TBD)"]
        Grafana["Grafana\nDashboards\nLogs · Metrics · Traces"]
    end

    AppJava  -->|"OTLP HTTP :4318\nTraces + Metrics"| Collector
    AppNode  -->|"OTLP gRPC :4317\nTraces"| Collector
    AppManual-->|"OTLP gRPC :4317 or HTTP :4318\nTraces + Metrics"| Collector

    Collector-->|"OTLP HTTP\nTraces → traces pipeline"| Tempo
    Collector-->|"OTLP HTTP\nMetrics → metrics pipeline"| Mimir
    Collector-.->|"Port :8888\nCollector self-metrics (Prometheus format)"| Mimir

    Promtail -->|"HTTP Push\n/loki/api/v1/push"| Loki

    Loki  --> Grafana
    Mimir --> Grafana
    Tempo --> Grafana

    OtelOp -.->|"Manages"| Collector

    style Collector fill:#e8f4f8,stroke:#2196F3
    style Promtail fill:#e8f4f8,stroke:#2196F3
    style OtelOp fill:#e8f4f8,stroke:#2196F3
    style Loki fill:#fff3e0,stroke:#FF9800,stroke-dasharray: 5 5
    style Mimir fill:#fff3e0,stroke:#FF9800,stroke-dasharray: 5 5
    style Tempo fill:#fff3e0,stroke:#FF9800,stroke-dasharray: 5 5
    style Grafana fill:#fff3e0,stroke:#FF9800,stroke-dasharray: 5 5
```

## Signal Types

| Signal | Receiver Port | Processor Chain | Backend |
|--------|--------------|-----------------|---------|
| Traces | 4317 (gRPC) or 4318 (HTTP) | `memory_limiter` → `filter/drop_noisy_trace_urls` → `k8sattributes` → `batch` → `resource` | Tempo |
| Metrics | 4317 (gRPC) or 4318 (HTTP) | `memory_limiter` → `k8sattributes` → `batch` → `resource` | Mimir |
| Logs | /var/log/pods (host path) | CRI parsing → relabeling → labeldrop | Loki |
| Collector self-metrics | :8888 Prometheus scrape | N/A (pulled by Prometheus/ServiceMonitor) | Mimir |

## Switching from Debug to Real Backends

```yaml
# values.yaml — uncomment when backends are available
global:
  opentelemetry:
    endpoint: "https://otlp-http.your-backend.example.com"
  promtail:
    endpoint: "https://loki.your-backend.example.com/loki/api/v1/push"

opentelemetryCollector:
  config:
    exporters:
      otlphttp:
        endpoint: "{{ .Values.global.opentelemetry.endpoint }}"
    service:
      pipelines:
        traces:
          exporters: [otlphttp]
        metrics:
          exporters: [otlphttp]
```
