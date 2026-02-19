# OTel Collector Internal Pipeline

Shows the processor chains inside the OpenTelemetry Collector for traces and metrics, and why they differ.

## Diagram

```mermaid
flowchart LR
    subgraph Receivers["Receivers"]
        gRPC["OTLP gRPC\n:4317"]
        HTTP["OTLP HTTP\n:4318"]
    end

    subgraph TracePipeline["Traces Pipeline"]
        direction LR
        T1["memory_limiter\n—\ncheck_interval: 1s\nlimit: 80%\nspike: 25%"]
        T2["filter/drop_noisy_trace_urls\n—\nDrops: /healthz /readyz\n/metrics /prometheus\n/actuator/* /favicon.ico\n/internal/health/*"]
        T3["k8sattributes\n—\nExtracts: pod.name, pod.uid\ndeployment.name, namespace\nnode.name, container.name\n+ 5 more\nScoped to: KUBE_NODE_NAME"]
        T4["batch\n—\n(defaults)"]
        T5["resource\n—\nInserts:\nk8s.cluster.name\n= global.cluster value"]
        T1 --> T2 --> T3 --> T4 --> T5
    end

    subgraph MetricsPipeline["Metrics Pipeline"]
        direction LR
        M1["memory_limiter\n(same config)"]
        M2["k8sattributes\n(same config)"]
        M3["batch\n(defaults)"]
        M4["resource\n(same config)"]
        M1 --> M2 --> M3 --> M4
    end

    subgraph Exporters["Exporters"]
        Debug["debug\n(current)\n—\nverbosity: detailed\nsampling_initial: 5\nsampling_thereafter: 200"]
        OtlpHTTP["otlphttp\n(TODO — when backend ready)\n—\nendpoint: global.opentelemetry.endpoint"]
    end

    subgraph SelfObs["Self-Observability"]
        Prom["Prometheus scrape\n:8888/metrics\n—\nCollector internal metrics:\nreceiver_accepted_*\nexporter_sent_*\nprocessor_refused_*\nprocess_memory_rss"]
    end

    gRPC & HTTP --> T1
    gRPC & HTTP --> M1

    T5 --> Debug
    M4 --> Debug

    T5 -.->|"when configured"| OtlpHTTP
    M4 -.->|"when configured"| OtlpHTTP

    style T2 fill:#fce4ec,stroke:#E91E63
    style Debug fill:#fff9c4,stroke:#FBC02D
    style OtlpHTTP fill:#e8f5e9,stroke:#4CAF50,stroke-dasharray: 5 5
    style Prom fill:#f3e5f5,stroke:#9C27B0
```

## Why Traces Have an Extra Processor

The `filter/drop_noisy_trace_urls` processor only exists in the **traces** pipeline because:

- Health checks (`/healthz`, `/readyz`) and Prometheus scrapes (`/metrics`) generate **constant high-frequency spans**
- 100 pods × 3 probes × 12 calls/min = **3,600 spans/min** of zero-value data
- These span names have **low cardinality** so they don't cause metric cardinality problems in the metrics pipeline

The metrics pipeline has no equivalent filter — metric cardinality is controlled at the SDK level.

## Processor Order Rationale

| Position | Processor | Why Here |
|----------|-----------|----------|
| 1st | `memory_limiter` | Must be first — prevents OOM before any work is done |
| 2nd (traces) | `filter/drop_noisy_trace_urls` | Drop before enrichment — no point enriching spans we'll discard |
| 2nd/3rd | `k8sattributes` | Enrich with K8s metadata before batching |
| 3rd/4th | `batch` | Group after enrichment to reduce export calls |
| Last | `resource` | Insert cluster name as final step before export |

## Health Check Extension

```yaml
extensions:
  health_check:
    endpoint: "0.0.0.0:13133"

service:
  extensions: [health_check]
```

Used by Kubernetes liveness/readiness probes on the collector pod itself.

## Filter OTTL Expressions Reference

The filter uses OpenTelemetry Transformation Language (OTTL):

```yaml
filter/drop_noisy_trace_urls:
  error_mode: ignore        # Don't fail pipeline on OTTL evaluation errors
  traces:
    span:
      - |                   # Drop span if expression is TRUE
        (attributes["http.method"] == "GET" or attributes["http.request.method"] == "GET") and (
          attributes["http.route"] == "/favicon.ico"   or ...
        )
```

`error_mode: ignore` is important — if an attribute doesn't exist, the expression returns an error rather than false. Ignoring means the span is kept (safe default).
