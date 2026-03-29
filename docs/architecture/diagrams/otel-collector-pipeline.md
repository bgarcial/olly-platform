# OTel Collector Components and Pipelines

Maps the olly-collector's OpenTelemetry Collector configuration to the four component categories defined by the [OTel Collector architecture](https://opentelemetry.io/docs/collector/).

## Components Overview

An OTel Collector is built from four component types. Three of them (receivers, processors, exporters) form **pipelines**. The fourth (extensions) operates outside pipelines but can be referenced by pipeline components.

```mermaid
block-beta
    columns 3

    block:Receivers:1
        columns 1
        r_title["Receivers"]
        r1["otlp\ngRPC :4317 / HTTP :4318"]
        r2["filelog\n/var/log/pods/**/*.log"]
        r3["kubeletstats\nhttps://${K8S_NODE_IP}:10250\n60s interval"]
    end

    block:Processors:1
        columns 1
        p_title["Processors"]
        p1["memory_limiter"]
        p2["filter/drop_noisy_trace_urls"]
        p3["k8sattributes"]
        p4["batch"]
        p5["resource"]
        p6["transform/promote_node_name"]
    end

    block:Exporters:1
        columns 1
        e_title["Exporters"]
        e1["otlp/traces → Tempo\ngRPC"]
        e2["otlphttp/metrics → Mimir"]
        e3["otlphttp/logs → Loki"]
        e4["debug\n(troubleshooting only)"]
    end

    block:Extensions:3
        columns 1
        ext_title["Extensions (outside pipelines)"]
        ext1["health_check :13133 — K8s liveness/readiness probes"]
        ext2["basicauth/tempo — credentials for otlp/traces exporter"]
        ext3["basicauth/mimir — credentials for otlphttp/metrics exporter"]
        ext4["basicauth/loki — credentials for otlphttp/logs exporter"]
    end

    style r_title fill:none,stroke:none
    style p_title fill:none,stroke:none
    style e_title fill:none,stroke:none
    style ext_title fill:none,stroke:none
```

### How extensions relate to pipelines

Extensions are **not** part of any pipeline — they don't process telemetry data. They provide supporting capabilities:

| Extension | Role | Used by |
|-----------|------|---------|
| `health_check` | Exposes `:13133` for K8s probes | Collector pod liveness/readiness — no pipeline connection |
| `basicauth/tempo` | Supplies Basic Auth credentials | `otlp/traces` exporter (via `auth.authenticator`) |
| `basicauth/mimir` | Supplies Basic Auth credentials | `otlphttp/metrics` exporter (via `auth.authenticator`) |
| `basicauth/loki` | Supplies Basic Auth credentials | `otlphttp/logs` exporter (via `auth.authenticator`) |

The `basicauth/*` extensions are referenced by exporters through the `auth.authenticator` field. The collector loads them as extensions and the exporter delegates authentication to them. This keeps auth concerns separated from export logic.

---

## Pipeline Diagrams

Each pipeline defines which receivers feed data in, which processors transform it (in order), and which exporters send it out.

### Traces Pipeline

Includes `filter/drop_noisy_trace_urls` — the only pipeline with a filter processor.

```mermaid
flowchart LR
    subgraph Receivers
        gRPC["otlp gRPC\n:4317"]
        HTTP["otlp HTTP\n:4318"]
    end

    subgraph Processors
        direction LR
        T1["memory_limiter\n—\ncheck_interval: 1s\nlimit: 80%\nspike: 25%"]
        T2["filter/drop_noisy_trace_urls\n—\nDrops: /healthz /readyz\n/metrics /prometheus\n/actuator/* /favicon.ico\n/internal/health/*\n/internal/status/*"]
        T3["k8sattributes\n—\nExtracts: pod.name, pod.uid\ndeployment.name, namespace\nnode.name, container.name\n+ 5 more\nScoped to: KUBE_NODE_NAME"]
        T4["batch\n—\nsize: 1000\ntimeout: 10s"]
        T5["resource\n—\nInserts:\nk8s.cluster.name"]
        T1 --> T2 --> T3 --> T4 --> T5
    end

    subgraph Exporter
        Tempo["otlp/traces\n→ Tempo (gRPC)\n—\nauth: basicauth/tempo\ntls: enabled\nkeepalive: 30s"]
    end

    gRPC & HTTP --> T1
    T5 --> Tempo

    style T2 fill:#fce4ec,stroke:#E91E63
    style Tempo fill:#e8f5e9,stroke:#4CAF50
```

### Metrics Pipeline

No filter. Adds `kubeletstats` receiver and `transform/promote_node_name` processor.

```mermaid
flowchart LR
    subgraph Receivers
        gRPC["otlp gRPC\n:4317"]
        HTTP["otlp HTTP\n:4318"]
        KS["kubeletstats\n—\n:10250 (serviceAccount)\n60s interval\ngroups: container,\npod, node, volume"]
    end

    subgraph Processors
        direction LR
        M1["memory_limiter\n(same config)"]
        M2["k8sattributes\n(same config)"]
        M3["batch\n(same config)"]
        M4["resource\n(same config)"]
        M5["transform/\npromote_node_name\n—\nCopies k8s.node.name\nfrom resource attr\nto datapoint attr\n(Mimir label)"]
        M1 --> M2 --> M3 --> M4 --> M5
    end

    subgraph Exporter
        Mimir["otlphttp/metrics\n→ Mimir\n—\nauth: basicauth/mimir\ntls: enabled\ncompression: gzip"]
    end

    gRPC & HTTP & KS --> M1
    M5 --> Mimir

    style KS fill:#e3f2fd,stroke:#1565C0
    style M5 fill:#fff3e0,stroke:#EF6C00
    style Mimir fill:#e8f5e9,stroke:#4CAF50
```

### Logs Pipeline

Uses `filelog` receiver instead of OTLP. Reads container logs directly from the node filesystem.

```mermaid
flowchart LR
    subgraph Receiver
        FL["filelog\n—\n/var/log/pods/**/*.log\nstart_at: end\noperator: container-parser"]
    end

    subgraph Processors
        direction LR
        L1["memory_limiter\n(same config)"]
        L2["k8sattributes\n(same config)"]
        L3["batch\n(same config)"]
        L4["resource\n(same config)"]
        L1 --> L2 --> L3 --> L4
    end

    subgraph Exporter
        Loki["otlphttp/logs\n→ Loki\n—\nauth: basicauth/loki\ntls: enabled"]
    end

    FL --> L1
    L4 --> Loki

    style FL fill:#e3f2fd,stroke:#1565C0
    style Loki fill:#e8f5e9,stroke:#4CAF50
```

---

## Self-Observability

The collector exposes its own internal metrics for monitoring.

```yaml
service:
  telemetry:
    metrics:
      readers:
        - pull:
            exporter:
              prometheus:
                host: '0.0.0.0'
                port: 8888
```

Prometheus scrapes `:8888/metrics` for collector health signals: `otelcol_receiver_accepted_spans`, `otelcol_exporter_sent_metric_points`, `otelcol_processor_refused_spans`, `process_runtime_total_alloc_bytes`, etc.

This is configured through `service.telemetry`, not through a pipeline — it's the collector observing itself.

---

## Why Traces Have an Extra Processor

The `filter/drop_noisy_trace_urls` processor only exists in the **traces** pipeline because:

- Health checks (`/healthz`, `/readyz`) and Prometheus scrapes (`/metrics`) generate **constant high-frequency spans**
- 100 pods x 3 probes x 12 calls/min = **3,600 spans/min** of zero-value data
- These span names have **low cardinality** so they don't cause metric cardinality problems in the metrics pipeline

The metrics pipeline has no equivalent filter — metric cardinality is controlled at the SDK level.

## Processor Order Rationale

| Position | Processor | Why Here |
|----------|-----------|----------|
| 1st | `memory_limiter` | Must be first — prevents OOM before any work is done |
| 2nd (traces only) | `filter/drop_noisy_trace_urls` | Drop before enrichment — no point enriching spans we'll discard |
| 2nd/3rd | `k8sattributes` | Enrich with K8s metadata before batching |
| 3rd/4th | `batch` | Group after enrichment to reduce export calls |
| 4th/5th | `resource` | Insert cluster name before export |
| Last (metrics only) | `transform/promote_node_name` | Copy node name to datapoint attrs after resource processor sets it |

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
