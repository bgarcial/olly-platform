# Working with Metrics

## Metrics Collection Overview

The olly-collector chart collects metrics via the OpenTelemetry Collector DaemonSet. Metrics follow a **push-only model** — applications must actively send metrics via OTLP. There is no Prometheus scraping, remote_write, or Grafana Alloy in this chart.

```
┌──────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                      │
│                                                           │
│  App (OTel SDK / auto-instrumented)                      │
│  │                                                        │
│  ├─→ OTLP-GRPC (:4317) ──┐                              │
│  └─→ OTLP-HTTP (:4318) ───┤                              │
│                             │                             │
│              ┌──────────────▼──────────────┐              │
│              │   OTel Collector DaemonSet  │              │
│              │                             │              │
│              │ metrics pipeline:           │              │
│              │  otlp receiver              │              │
│              │  → memory_limiter           │              │
│              │  → k8sattributes            │              │
│              │  → batch                    │              │
│              │  → resource (cluster name)  │              │
│              │  → debug / otlphttp         │              │
│              └──────────────┬──────────────┘              │
│                             │                             │
│  (future: ServiceMonitor    │ OTLP-HTTP                  │
│   :8888 for self-metrics)   │                             │
└─────────────────────────────┼─────────────────────────────┘
                              │
               ┌──────────────▼──────────────┐
               │     Observability Backend   │
               │     (TBD - Mimir/Tempo)     │
               └─────────────────────────────┘
```

## Metrics Pipeline vs Traces Pipeline

| Aspect | Metrics Pipeline | Traces Pipeline |
|--------|-----------------|-----------------|
| Receivers | `otlp` (gRPC + HTTP) | `otlp` (gRPC + HTTP) |
| Processors | `memory_limiter` → `k8sattributes` → `batch` → `resource` | Same + `filter/drop_noisy_trace_urls` |
| Exporters | `debug` (→ `otlphttp` when configured) | `debug` (→ `otlphttp` when configured) |
| Filter | **None** | Drops health checks, favicon |

The metrics pipeline does NOT include the noisy URL filter because metrics don't suffer from the same span-name cardinality issue.

## How Applications Send Metrics

Applications must use the OpenTelemetry SDK to push metrics to the collector:

**Endpoint (from within the cluster)**:
```
# gRPC (preferred for metrics)
http://olly-collector-opentelemetry-collector.<namespace>.svc.cluster.local:4317

# HTTP
http://olly-collector-opentelemetry-collector.<namespace>.svc.cluster.local:4318
```

**SDK configuration example** (env vars):
```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://olly-collector-opentelemetry-collector.<ns>.svc.cluster.local:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_METRICS_EXPORTER=otlp
```

## Auto-Instrumentation and Metrics

The chart deploys **two Kyverno-managed Instrumentation CRs** with different metrics behavior:

### Default Instrumentation (`olly-collector`)

```yaml
env:
  - name: OTEL_METRICS_EXPORTER
    value: none    # Metrics DISABLED
```

**Metrics are disabled by default.** Auto-instrumented pods using the default CR only produce traces. This is intentional — auto-instrumented metrics can cause unexpected cardinality and storage costs before understanding what's being emitted.

### Full Instrumentation (`olly-collector-full`)

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_METRICS_DEFAULT_HISTOGRAM_AGGREGATION
    value: base2_exponential_bucket_histogram
  # OTEL_METRICS_EXPORTER is NOT set — metrics flow through
```

**Metrics are enabled.** Teams opt in by annotating pods with the `-full` instrumentation CR name. The `base2_exponential_bucket_histogram` aggregation reduces histogram bucket cardinality compared to explicit boundaries.

### Which Languages Generate Metrics via Auto-Instrumentation?

| Language | Metrics Support | Notes |
|----------|----------------|-------|
| **Java** | Full | Most mature. Bridges Micrometer metrics. Generates JVM, HTTP, DB pool metrics. Pinned image. |
| **Node.js** | Partial | HTTP and runtime metrics. Less mature than Java. Uses gRPC endpoint. |
| **Python** | Explicit disable | Default CR explicitly sets `OTEL_METRICS_EXPORTER: none`. Less stable. |
| **Go** | Experimental | eBPF-based. Operator flag `autoInstrumentation.go.enabled: true`. |
| **nginx** | Limited | Basic HTTP request metrics. Uses gRPC endpoint. |
| **Apache HTTPD** | Limited | Basic HTTP metrics. Uses gRPC endpoint. |

**Note**: Go is enabled in the operator config but not yet configured in `clusterpolicy.yaml`. See [auto-instrumentation.md](auto-instrumentation.md) for details.

### Semantic Convention Breakage Risk

**Known pain point.** When the OTel Operator is upgraded, auto-instrumentation agent images update too. New versions may adopt updated semantic conventions, changing metric names, attribute names, and values.

**What breaks**:
- Dashboards querying specific metric names
- Alert rules referencing old attribute names
- Recording rules aggregating on changed label names

**Languages most affected**:
- **Java**: Most impactful — produces the most metrics, closely tracks OTel semantic conventions
- **Node.js**: HTTP semantic conventions affect request/response metrics

**Mitigation**:
1. Pin auto-instrumentation images in `clusterpolicy.yaml` (Java image already pinned)
2. Test OTel Operator upgrades in non-production first
3. Check OTel semantic conventions changelog before upgrading
4. Use the default CR (metrics disabled) unless explicitly needed

## Collector Self-Monitoring

The OTel Collector exposes its own operational metrics on port 8888 in Prometheus format:

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

**ServiceMonitor** (configured in `values.yaml`, template not yet created):
```yaml
opentelemetryCollector:
  serviceMonitor:
    labels:
      prometheus: main-prometheus  # Targets Prometheus instance
```

**Key internal metrics**:
- `otelcol_receiver_accepted_metric_points` — metrics successfully received
- `otelcol_receiver_refused_metric_points` — metrics rejected
- `otelcol_exporter_sent_metric_points` — metrics successfully exported
- `otelcol_exporter_send_failed_metric_points` — export failures
- `otelcol_processor_batch_batch_send_size` — batch sizes
- `otelcol_process_memory_rss` — collector memory usage

## VPA and Resource Sizing

The collector has VPA enabled:

```yaml
vpa.yaml:
  targetRef:
    kind: OpenTelemetryCollector
  resourcePolicy:
    containerPolicies:
      - containerName: otc-container
        minAllowed:
          memory: 200Mi
        maxAllowed:
          cpu: 2
          memory: 4Gi
```

**Default resource requests** (without VPA adjustment):
- CPU: 250m requests, no limit
- Memory: 500Mi requests, 500Mi limit

**When to adjust**:
- If collector pods are frequently OOMKilled → increase `maxAllowed.memory` in VPA
- If `memory_limiter` triggers frequently → collector is overwhelmed, increase resources or add sampling
- High-traffic clusters may need more than the default 500Mi

## What's NOT in This Chart

| Capability | Status | Where It Happens |
|------------|--------|------------------|
| Prometheus scraping | Not here | Deploy Prometheus separately or use Alloy |
| remote_write | Not here | Alloy/Prometheus → Mimir |
| Span metrics (metrics from traces) | Not here | Backend-side (Tempo span metrics connector) |
| Grafana Alloy | Not here | Separate deployment for Prometheus-style scraping |
| Metric filtering/dropping | Not here | Controlled at SDK level or backend ingestion limits |
