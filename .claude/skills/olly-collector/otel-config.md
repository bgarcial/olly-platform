# OpenTelemetry Collector Configuration

## Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    OpenTelemetry Collector                       │
├─────────────────────────────────────────────────────────────────┤
│  RECEIVERS          PROCESSORS              EXPORTERS           │
│  ──────────         ──────────              ─────────           │
│  otlp (grpc:4317)   memory_limiter          debug (testing) ───►│
│  otlp (http:4318)   filter/drop_noisy       otlphttp (TODO)    │
│                     k8sattributes                               │
│                     batch                                       │
│                     resource                                    │
└─────────────────────────────────────────────────────────────────┘
```

**Current state**: The `debug` exporter is used while no OTLP backend is configured. Switch to `otlphttp` by setting `global.opentelemetry.endpoint` and uncommenting the `otlphttp` exporter in `values.yaml`.

### Pipeline Differences: Traces vs Metrics

Both pipelines share the same receivers and exporters but differ in processors:

```yaml
# Traces pipeline — includes noisy URL filter
traces:
  receivers: [otlp]
  processors: [memory_limiter, filter/drop_noisy_trace_urls, k8sattributes, batch, resource]
  exporters: [debug]  # Will become [otlphttp]

# Metrics pipeline — NO filter processor
metrics:
  receivers: [otlp]
  processors: [memory_limiter, k8sattributes, batch, resource]
  exporters: [debug]  # Will become [otlphttp]
```

## Key Processors

### memory_limiter
Prevents OOM kills on the collector DaemonSet. Must be **first** in every pipeline.

```yaml
memory_limiter:
  check_interval: 1s
  limit_percentage: 80
  spike_limit_percentage: 25
```

### k8sattributes
Enriches telemetry with Kubernetes metadata. Uses `KUBE_NODE_NAME` env var (injected via `fieldRef: spec.nodeName`) to filter pods on the same node.

```yaml
k8sattributes:
  extract:
    metadata:
      - k8s.pod.name
      - k8s.pod.uid
      - k8s.deployment.name
      - k8s.namespace.name
      - k8s.node.name
      - k8s.pod.start_time
      - k8s.statefulset.name
      - k8s.cronjob.name
      - k8s.daemonset.name
      - k8s.job.name
      - k8s.container.name
  filter:
    node_from_env_var: KUBE_NODE_NAME
  pod_association:
    - sources:
        - from: resource_attribute
          name: k8s.pod.ip
    - sources:
        - from: resource_attribute
          name: k8s.pod.uid
    - sources:
        - from: connection
```

### resource
Injects cluster name into all telemetry. Uses template interpolation from `global.cluster`.

```yaml
resource:
  attributes:
    - key: k8s.cluster.name
      value: "{{ .Values.global.cluster }}"
      action: insert
```

### batch
Standard batching for export efficiency. Uses defaults (empty config `{}`).

## Noisy Trace URL Filter - Deep Dive

The `filter/drop_noisy_trace_urls` processor controls cardinality and storage costs. It only applies to the **traces pipeline**, not metrics.

### Why This Filter Exists

| Impact | Consequence |
|--------|-------------|
| Traces backend | Excessive storage, slow trace retrieval |
| Span metrics | High cardinality if span names contain variable parts |

### What Gets Filtered (Health Checks & Infra Endpoints)

These endpoints are called constantly and provide no business value in traces:

| Pattern | Caller | Frequency |
|---------|--------|-----------|
| `/healthz`, `/readyz` | Kubernetes probes | Every 5-30s per pod |
| `/metrics`, `/prometheus` | Prometheus scraper | Every 15-60s per pod |
| `/actuator/*` | Spring Boot health/metrics | Same as above |
| `isReady`, `isAlive` | Custom health endpoints | Same as above |
| `/internal/health/*` | Internal health checks | Varies |
| `/favicon.ico` | Browser auto-requests | On every page load |

**Volume example**: 100 pods x 3 probes x 12 calls/minute = 3,600 spans/minute just for health checks.

### Why Check Three HTTP Attributes?

Different instrumentation libraries use different attribute names:
- `http.route` - Standard OpenTelemetry semantic convention
- `http.target` - Older convention, includes query string
- `url.path` - Newer semantic convention (OTel 1.21+)

### Full Filter Configuration

```yaml
filter/drop_noisy_trace_urls:
  error_mode: ignore
  traces:
    span:
      # Health checks and metrics endpoints (universal)
      - |
        (attributes["http.method"] == "GET" or attributes["http.request.method"] == "GET") and (
              attributes["http.route"] == "/favicon.ico"               or attributes["http.target"] == "/favicon.ico"                 or attributes["url.path"] == "/favicon.ico"
          or IsMatch(attributes["http.route"], ".*[iI]s_?[rR]eady")    or IsMatch(attributes["http.target"], ".*[iI]s_?[rR]eady")     or IsMatch(attributes["url.path"], ".*[iI]s[rR]eady")
          or IsMatch(attributes["http.route"], ".*[iI]s_?[aA]live")    or IsMatch(attributes["http.target"], ".*[iI]s_?[aA]live")     or IsMatch(attributes["url.path"], ".*[iI]s[aA]live")
          or IsMatch(attributes["http.route"], ".*prometheus")         or IsMatch(attributes["http.target"], ".*prometheus")          or IsMatch(attributes["url.path"], ".*prometheus")
          or IsMatch(attributes["http.route"], ".*metrics")            or IsMatch(attributes["http.target"], ".*metrics")             or IsMatch(attributes["url.path"], ".*metrics")
          or IsMatch(attributes["http.route"], ".*actuator.*")         or IsMatch(attributes["http.target"], ".*actuator.*")          or IsMatch(attributes["url.path"], ".*actuator.*")
          or IsMatch(attributes["http.route"], ".*internal/health.*")  or IsMatch(attributes["http.target"], ".*internal/health.*")   or IsMatch(attributes["url.path"], ".*internal/health.*")
          or IsMatch(attributes["http.route"], ".*internal/status.*")  or IsMatch(attributes["http.target"], ".*internal/status.*")   or IsMatch(attributes["url.path"], ".*internal/status.*")
          or IsMatch(attributes["http.route"], ".*/readyz?")           or IsMatch(attributes["http.target"], ".*/readyz?")            or IsMatch(attributes["url.path"], ".*/readyz?")
          or IsMatch(attributes["http.route"], ".*/healthz?")          or IsMatch(attributes["http.target"], ".*/healthz?")           or IsMatch(attributes["url.path"], ".*/healthz?")
        )
```

To add a GraphQL high-cardinality filter (if applications use GraphQL with array-indexed resolver spans):

```yaml
      # GraphQL high-cardinality resolver spans (add if needed)
      - IsMatch(name, "graphql.resolve .+\\.\\d.+")
```

## Switching from Debug to OTLP Exporter

When an OTLP backend is available:

1. Set `global.opentelemetry.endpoint` in values
2. In `values.yaml`, replace the debug exporter with otlphttp:

```yaml
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

## Common Tasks

### Adding a New Trace Filter

Edit `values.yaml` under `filter/drop_noisy_trace_urls`:

```yaml
filter/drop_noisy_trace_urls:
  traces:
    span:
      - 'attributes["http.route"] == "/my-noisy-endpoint"'
```

### Changing Resource Limits

```yaml
opentelemetryCollector:
  resources:
    limits:
      memory: 1Gi
    requests:
      cpu: 500m
      memory: 500Mi
```

### Adding Custom Resource Attributes

Use the `resource` processor:

```yaml
resource:
  attributes:
    - key: custom.attribute
      value: "my-value"
      action: insert
```

### Adding a New Processor

1. Add processor config under `opentelemetryCollector.config.processors`
2. Add it to the relevant pipeline under `service.pipelines.{traces,metrics}.processors`
3. Processor order matters: `memory_limiter` should always be first
