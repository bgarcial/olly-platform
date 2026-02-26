# Grafana Cloud OTLP Endpoints Research

**Date:** 2026-02-20
**Research scope:** Grafana Cloud EU West-0 (eu-prod-01-eu-west-0, GCP europe-west1)
**Output of:** Nova / nw-researcher agent
**Confidence legend:** High = 3+ independent concordant sources. Medium = 2 concordant sources. Low = 1 source or inference.

---

## Executive Summary

| Question | Finding | Confidence |
|---|---|---|
| Can `endpoint` be omitted when signal-specific endpoints are set? | Yes — source code confirms: error only when ALL endpoints are empty | High |
| Does Mimir accept OTLP natively? | Yes — `/otlp` path, recommended over remote write | High |
| Correct `otlphttp` endpoint for Tempo | `https://tempo-eu-west-0.grafana.net:443` (no path suffix; exporter adds `/v1/traces`) | High |
| Grafana Cloud OTLP Gateway alternative | `https://otlp-gateway-prod-eu-west-0.grafana.net/otlp` — unified endpoint, routes all signals internally | High |
| Recommended values.yaml structure | Option A (signal-name keys) for clarity; requires 2-3 separate exporters | High |
| Single vs multi-exporter | Two separate exporters: `otlphttp/traces` + `otlphttp/metrics` — independent retry/TLS | High |

---

## Finding 1: `endpoint` Field — Required vs. Optional When Signal-Specific Endpoints Exist

### Claim
When all active signals have signal-specific endpoints (`traces_endpoint`, `metrics_endpoint`), the base `endpoint` field can be omitted entirely. The exporter does not error.

### Evidence

**Source 1 — otlphttpexporter source code `config.go` `Validate()` function:**

```go
func (cfg *Config) Validate() error {
    if cfg.ClientConfig.Endpoint == "" && cfg.TracesEndpoint == "" && cfg.MetricsEndpoint == "" && cfg.LogsEndpoint == "" && cfg.ProfilesEndpoint == "" {
        return errors.New("at least one endpoint must be specified")
    }
    return nil
}
```

Source: [otlphttpexporter config.go — open-telemetry/opentelemetry-collector](https://pkg.go.dev/go.opentelemetry.io/collector/exporter/otlphttpexporter) (Go package docs, validates against actual source).

The condition is `endpoint == "" AND traces_endpoint == "" AND metrics_endpoint == "" AND logs_endpoint == "" AND profiles_endpoint == ""`. If any one of these is non-empty, `Validate()` returns `nil`. Therefore, `endpoint` can be empty or absent when `traces_endpoint` and `metrics_endpoint` are both set.

**Source 2 — opentelemetry-collector README documentation:**

The README states: "If this setting is present the `endpoint` setting is ignored for [signal type]." This language implies signal-specific endpoints are overrides that make the base `endpoint` irrelevant for those signals, supporting the interpretation that the base is not mandatory when all active signals have their own endpoint.

Source: [opentelemetry-collector otlphttpexporter README](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/otlphttpexporter/README.md)

**Source 3 — Dash0 OTLP HTTP Exporter guide:**

Confirms that when signal-specific endpoints are configured, "the Collector does not append anything" to them — they are used as-is. The guide presents them as a complete alternative pattern to the base `endpoint`.

Source: [Mastering the OpenTelemetry OTLP HTTP Exporter — Dash0](https://www.dash0.com/guides/opentelemetry-otlp-http-exporter)

### Interpretation (analyst)
The README marks `endpoint` as "required (no default)" in its prose description, but the actual Go `Validate()` function tells the authoritative truth: only one of the five endpoint fields needs to be non-empty. The prose description is misleading but harmless — the runtime behavior is what matters for chart configuration.

### Practical impact for this chart
If you configure `traces_endpoint: "https://tempo-eu-west-0.grafana.net:443"` and `metrics_endpoint: "https://prometheus-prod-01-eu-west-0.grafana.net/api/prom/push"`, you can safely omit `endpoint: ""`. However, omitting it entirely (not setting the key at all) vs. setting it to empty string may behave differently depending on how the OTel Operator marshals the YAML. The safest pattern is: set `endpoint: ""` as a documented placeholder and rely on signal-specific overrides. This avoids any potential YAML marshalling issues.

---

## Finding 2: Mimir OTLP Native Ingestion

### Claim
Grafana Cloud Mimir accepts metrics via OTLP natively using an `otlphttp` exporter pointed at the `/otlp` path. This is now the **recommended** approach over `prometheusremotewrite`.

### Evidence

**Source 1 — Grafana Mimir official documentation, "Configure the OpenTelemetry Collector to write metrics into Mimir":**

```yaml
exporters:
  otlphttp:
    endpoint: http://<mimir-endpoint>/otlp
```

"It's recommended that you use the OpenTelemetry protocol" when choosing between the two approaches.

Source: [Configure the OTel Collector to write metrics into Mimir — Grafana Mimir docs](https://grafana.com/docs/mimir/latest/configure/configure-otel-collector/)

**Source 2 — Grafana Mimir HTTP API reference:**

The OTLP HTTP ingestion endpoint path is `POST /otlp/v1/metrics`. Accepts HTTP POST with Protocol Buffers body, optionally GZIP compressed.

Source: [Grafana Mimir HTTP API reference](https://grafana.com/docs/mimir/latest/references/http-api/)

**Source 3 — Grafana Cloud OTLP gateway search results (multiple community and official sources):**

The Grafana Cloud OTLP gateway (`otlp-gateway-prod-eu-west-0.grafana.net/otlp`) routes metrics to Mimir internally. Alternatively, for direct Mimir access, the pattern from the Mimir docs applies: the remote write URL is `https://prometheus-prod-01-eu-west-0.grafana.net/api/prom/push`, and the OTLP path would be `https://prometheus-prod-01-eu-west-0.grafana.net/otlp`.

Source: [OTLP: The OpenTelemetry Protocol — Grafana Cloud docs](https://grafana.com/docs/grafana-cloud/send-data/otlp/)

### Grafana Cloud Mimir OTLP endpoint — two valid approaches

**Approach A — Via Grafana Cloud OTLP Gateway (unified, recommended for simplicity):**
```
https://otlp-gateway-prod-eu-west-0.grafana.net/otlp
```
Routes traces → Tempo, metrics → Mimir, logs → Loki internally. Single endpoint, single credential pair.

**Approach B — Direct Mimir OTLP endpoint (confirmed pattern, not Grafana Cloud-specific documented URL):**
```
https://prometheus-prod-01-eu-west-0.grafana.net/otlp
```
This applies the `/otlp` path pattern from the Mimir HTTP API docs to the known Grafana Cloud Mimir hostname. Note: Grafana Cloud documentation does not explicitly publish this URL with the `/otlp` path — this is inferred from the Mimir HTTP API spec. Confidence for Approach B: Medium.

### Knowledge gap
Grafana Cloud's official documentation does not publish a region-specific direct Mimir OTLP URL (e.g., `https://prometheus-prod-01-eu-west-0.grafana.net/otlp`). The public documentation for Mimir OTLP shows `http://<mimir-endpoint>/otlp` for self-hosted deployments. The authoritative Grafana Cloud OTLP endpoint for metrics is the unified OTLP gateway. To confirm whether direct `/otlp` path works on the hosted Prometheus URL, check your Grafana Cloud stack OTLP info page at `https://grafana.com/orgs/{your-org}/stacks/{stack-id}/otlp-info`.

### OTLP vs `prometheusremotewrite` — Practical Comparison

| Dimension | `prometheusremotewrite` | `otlphttp/metrics` (OTLP) |
| --- | --- | --- |
| Protocol | Prometheus-native binary (protobuf) | OpenTelemetry native (protobuf) |
| Signal scope | Metrics only | Metrics, logs, traces (unified model) |
| Grafana recommendation | Alternative | **Preferred** when using OTel Collector |
| Error handling | Partial failure → HTTP 400 | Partial failure → HTTP 200 with error in body (OTLP spec) — failed samples silently dropped unless response body is inspected |
| Metric name translation | None | **Automatic at Mimir ingest — no Collector transform needed.** Dots/dashes → underscores: `http.server.request.duration` → `http_server_request_duration`. Collector passes names through unchanged. Query with underscores in PromQL. See note below. |
| Histogram support | Classic histograms | Exponential Histograms → Prometheus Native Histograms (requires enabling native histogram ingestion on Mimir) |
| Resource attributes | Not carried | OTel resource attributes (e.g. `service.name`) carried and promotable to Mimir labels — useful for cross-signal correlation with traces/logs |

#### Metric name translation — how it works end-to-end

No transformation is needed in the OTel Collector. The translation happens automatically at the Mimir OTLP ingestion layer, not the Collector layer.

What flows through each stage:

```
OTel SDK instruments app
  emits: http.server.request.duration   ← dot-notation (OTel semantic conventions)
         process.runtime.jvm.memory.used

OTel Collector (name unchanged in transit)
  sends: http.server.request.duration   ← OTLP protobuf, dot-notation preserved
  via:   POST /otlp/v1/metrics

Mimir OTLP ingest layer (auto-converts on store)
  stores: http_server_request_duration
          process_runtime_jvm_memory_used
```

PromQL queries use the underscore form:

```promql
rate(http_server_request_duration_bucket[5m])
histogram_quantile(0.99, rate(http_server_request_duration_bucket[5m]))
```

**Unit suffixes:** Some OTel SDKs append units to the metric name at the SDK level (e.g. `http.server.request.duration` in milliseconds may be stored as `http_server_request_duration_milliseconds`). Mimir follows Prometheus naming conventions when appending unit suffixes. Verify the actual stored name in Grafana Explore after the first ingest — do not assume the name until you've seen it.

**The only case where you add a Collector `transform` processor** is when you need to rename a metric to match a legacy Grafana dashboard that expects a Prometheus-style name. This is a one-off compatibility fix, not a general requirement for the OTel-to-Mimir path.

**When to use `prometheusremotewrite`:**

- Already running Prometheus scrapers and not adopting OTel Collector
- Need guaranteed error visibility (HTTP 400 on partial failures)

**When to use `otlphttp/metrics`:**

- Running OTel Collector or instrumenting with OTel SDKs (this chart's use case)
- Want unified protocol across traces, metrics, logs
- Need resource attributes (`service.name`, `k8s.namespace.name`) promoted to metric labels for cross-signal correlation in Grafana

**Silent drop risk with OTLP:** Unlike `prometheusremotewrite` which returns HTTP 400 on partial failures, the OTLP spec mandates HTTP 200 even when some samples fail — error details are in the response body. The OTel Collector's `retry_on_failure` won't trigger on a 200. Monitor the collector's own metrics (`otelcol_exporter_send_failed_metric_points`) to detect silent drops.

---

## Finding 3: Tempo Endpoint Format for `otlphttp` Exporter

### Claim
For the `otlphttp` exporter sending traces to Grafana Cloud Tempo, use `https://tempo-eu-west-0.grafana.net:443` without any path suffix. The exporter will append `/v1/traces` automatically.

### Evidence

**Source 1 — Grafana Alloy documentation, `otelcol.exporter.otlphttp` reference:**

The official Alloy component docs show the OTLP gateway format as the primary Grafana Cloud endpoint:
```
endpoint = "https://otlp-gateway-prod-gb-south-0.grafana.net/otlp"
```
Default behavior: appends `/v1/traces` to form `{endpoint}/v1/traces`.

Source: [otelcol.exporter.otlphttp — Grafana Alloy docs](https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.exporter.otlphttp/)

**Source 2 — Grafana Alloy LGTM stack guide:**

Tempo example via `otelcol.exporter.otlphttp`:
```
endpoint = "https://tempo-us-central1.grafana.net:443"
```
Note: `https://` prefix required for HTTP. Port 443 is HTTPS. No path suffix in the endpoint — the exporter adds `/v1/traces`.

Source: [Collect OpenTelemetry data and forward to Grafana — Grafana Alloy docs](https://grafana.com/docs/alloy/latest/collect/opentelemetry-to-lgtm-stack/)

**Source 3 — oneuptime.com OTel Collector to Grafana Cloud (February 2026):**

```yaml
otlphttp/tempo:
  endpoint: https://tempo-prod-04-eu-west-0.grafana.net:443
  headers:
    authorization: Basic ${GRAFANA_CLOUD_AUTH}
  compression: gzip
```
Source: [How to Configure the Grafana Cloud Connector in the OpenTelemetry Collector](https://oneuptime.com/blog/post/2026-02-06-grafana-cloud-connector-opentelemetry-collector/view)

### Current bug in values.yaml

The current `values.yaml` has:
```yaml
otlphttp/tempo:
  endpoint: "tempo-eu-west-0.grafana.net:443"
```

This is wrong for two reasons:
1. Missing `https://` prefix — the otlphttp exporter expects a full URL with scheme. Without `https://`, the exporter will fail to parse the endpoint.
2. The format `host:port` without scheme is the gRPC endpoint format used by the `otlp` (gRPC) exporter. The Grafana Cloud UI shows this format because the Alloy example uses `otelcol.exporter.otlp` (gRPC), not `otelcol.exporter.otlphttp` (HTTP).

### Correct format for eu-west-0:
```yaml
otlphttp/traces:
  endpoint: "https://tempo-eu-west-0.grafana.net:443"
  headers:
    authorization: "Basic ${env:GRAFANA_CLOUD_AUTH}"
  compression: gzip
```
The exporter will construct: `https://tempo-eu-west-0.grafana.net:443/v1/traces`

### Alternative: use the unified OTLP gateway for traces
```yaml
otlphttp/traces:
  traces_endpoint: "https://otlp-gateway-prod-eu-west-0.grafana.net/otlp/v1/traces"
  headers:
    authorization: "Basic ${env:GRAFANA_CLOUD_AUTH}"
```
This bypasses Tempo directly and routes through the gateway.

---

## Finding 4: Grafana Cloud OTLP Gateway — Unified vs. Per-Signal Architecture

### Two valid architectural approaches

**Approach A — Unified OTLP gateway (simplest):**

Single endpoint routes all signals to the correct backend:

| Signal | Goes to |
|---|---|
| traces (`/otlp/v1/traces`) | Tempo |
| metrics (`/otlp/v1/metrics`) | Mimir |
| logs (`/otlp/v1/logs`) | Loki |

```yaml
exporters:
  otlphttp:
    endpoint: "https://otlp-gateway-prod-eu-west-0.grafana.net/otlp"
    auth:
      authenticator: basicauth
```

Confirmed by: Grafana Alloy docs, Grafana blog, community forum. The gateway is available for all Grafana Cloud plans.

**Approach B — Per-signal direct endpoints (more control):**

| Signal | Endpoint |
|---|---|
| Traces | `https://tempo-eu-west-0.grafana.net:443` (otlphttp, appends `/v1/traces`) |
| Metrics | `https://prometheus-prod-01-eu-west-0.grafana.net/api/prom/push` (prometheusremotewrite) OR `https://prometheus-prod-01-eu-west-0.grafana.net/otlp` (otlphttp, unconfirmed for Cloud) |
| Logs | `https://logs-prod-eu-west-0.grafana.net/loki/api/v1/push` (Promtail native or loki exporter) |

### Gateway SLA note
A community forum post noted "OTLP gateway in Grafana Cloud doesn't have any SLA," suggesting the per-signal endpoints (Tempo, Mimir, Loki directly) may be preferable for production workloads where reliability guarantees matter. This claim was not independently verified against Grafana's official SLA documentation. Treat as Medium-confidence risk signal, not confirmed fact.

Source: [OTLP Endpoint Credentials for Grafana Cloud — community forum](https://community.grafana.com/t/opentelemetry-protocol-otlp-endpoint-credentials-for-grafana-cloud/105782)

---

## Finding 5: Recommended values.yaml Structure

### Context
The user wants a future-proof design allowing per-signal TLS config, retry config, and auth per signal. Two options were evaluated.

### Option A — Signal-name keys (recommended)

```yaml
global:
  cluster: "olly-personal-nonprd"
  tempo:
    endpoint: "https://tempo-eu-west-0.grafana.net:443"
  mimir:
    endpoint: "https://prometheus-prod-01-eu-west-0.grafana.net/api/prom/push"
  loki:
    endpoint: "https://logs-prod-eu-west-0.grafana.net/loki/api/v1/push"
```

**Advantages:**
- Maps semantically to backend service names, which users recognize from Grafana Cloud portal
- Naturally extends to per-signal auth: `tempo.auth`, `mimir.auth`, `loki.auth`
- Matches the Grafana Cloud portal UI naming (Tempo, Mimir, Loki)
- Clear when reading a values file — reader understands what each key controls

**Disadvantages:**
- Does not map 1:1 to otlphttp exporter field names (`traces_endpoint`, not `tempo.endpoint`)
- Requires template logic to map `global.tempo.endpoint` → `traces_endpoint` in the OTel Collector config

### Option B — Signal-type keys

```yaml
global:
  cluster: ""
  opentelemetry:
    tracesEndpoint: ""
    metricsEndpoint: ""
  promtail:
    endpoint: ""
```

**Advantages:**
- Maps directly to otlphttp exporter field names
- Slightly less template logic needed

**Disadvantages:**
- `opentelemetry.tracesEndpoint` and `opentelemetry.metricsEndpoint` under one key collapses Tempo and Mimir — can't add per-service TLS or auth without introducing sub-keys anyway (breaking the apparent simplicity)
- `promtail.endpoint` is a different protocol entirely (Loki push) — mixing it under `opentelemetry` would be wrong
- If user later adds per-signal TLS, they'd need `opentelemetry.traces.tls`, `opentelemetry.metrics.tls` — and at that point Option A's structure is cleaner anyway

### Recommendation: Option A with extended structure

```yaml
global:
  cluster: "olly-personal-nonprd"

  # Traces → Grafana Cloud Tempo
  tempo:
    endpoint: "https://tempo-eu-west-0.grafana.net:443"
    # auth:
    #   username: ""            # Grafana Cloud instance ID (numeric)
    #   password: ""            # API token — use secretKeyRef in production
    # tls:
    #   insecure: false

  # Metrics → Grafana Cloud Mimir
  mimir:
    endpoint: "https://prometheus-prod-01-eu-west-0.grafana.net/api/prom/push"
    # auth:
    #   username: ""
    #   password: ""

  # Logs → Grafana Cloud Loki (consumed by Promtail)
  loki:
    endpoint: "https://logs-prod-eu-west-0.grafana.net/loki/api/v1/push"
    # auth:
    #   username: ""
    #   password: ""
```

This structure is future-proof because:
- Each signal can have its own `auth`, `tls`, and `retry` block
- Matches the mental model of a Grafana Cloud user reading their stack details page
- Template can map `global.tempo.endpoint` → `traces_endpoint` in the OTel Collector config with simple Helm `tpl` functions

**Evidence for this preference:**
- Grafana Alloy docs use per-service component names (`grafana_cloud_traces`, `grafana_cloud_metrics`) — signal by backend, not by protocol
- The oneuptime.com practical guide names exporters `otlphttp/tempo`, `prometheusremotewrite` — aligning with backend service identity
- The Grafana Cloud portal UI surfaces Tempo/Mimir/Loki as the three distinct services
Sources: [Grafana Alloy LGTM guide](https://grafana.com/docs/alloy/latest/collect/opentelemetry-to-lgtm-stack/), [oneuptime OTel Collector to Grafana Cloud (Feb 2026)](https://oneuptime.com/blog/post/2026-02-06-grafana-cloud-connector-opentelemetry-collector/view)

---

## Finding 6: Single Exporter vs. Multiple Exporters

### Claim
Two separate exporters (`otlphttp/traces` and `otlphttp/metrics` or `prometheusremotewrite`) are preferable over a single `otlphttp` exporter with both `traces_endpoint` and `metrics_endpoint`.

### Analysis

#### Single `otlphttp` exporter with per-signal endpoints

```yaml
exporters:
  otlphttp:
    traces_endpoint: "https://tempo-eu-west-0.grafana.net:443/v1/traces"
    metrics_endpoint: "https://prometheus-prod-01-eu-west-0.grafana.net/otlp/v1/metrics"
    headers:
      authorization: "Basic ${env:GRAFANA_CLOUD_AUTH}"
    tls:
      insecure: false
    retry_on_failure:
      enabled: true
      initial_interval: 5s
```

**Limitations:**
- `tls` is **exporter-instance-scoped** — one TLS config for all signals. Source: Dash0 guide, Go package docs. If Tempo and Mimir ever use different TLS certificates or settings, a single exporter cannot express this.
- `retry_on_failure` is **exporter-instance-scoped** — same retry policy for traces and metrics. Traces and metrics have different tolerance for retry cost: retrying a large batch of metrics is more expensive than retrying traces.
- `headers` is also **exporter-instance-scoped** — if Tempo and Mimir ever require different auth tokens, single exporter cannot handle this.
- `compression` is **exporter-instance-scoped**.

#### Two separate exporters

```yaml
exporters:
  otlphttp/traces:
    endpoint: "https://tempo-eu-west-0.grafana.net:443"
    headers:
      authorization: "Basic ${env:GRAFANA_CLOUD_TRACES_AUTH}"
    compression: gzip
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_elapsed_time: 120s

  otlphttp/metrics:
    endpoint: "https://prometheus-prod-01-eu-west-0.grafana.net/otlp"
    # OR use prometheusremotewrite if direct Mimir OTLP URL is unavailable:
    # prometheusremotewrite:
    #   endpoint: "https://prometheus-prod-01-eu-west-0.grafana.net/api/prom/push"
    headers:
      authorization: "Basic ${env:GRAFANA_CLOUD_METRICS_AUTH}"
    compression: gzip
    retry_on_failure:
      enabled: true
      initial_interval: 10s
      max_elapsed_time: 300s
```

**Advantages:**
- Independent TLS config per signal — future-proof for different certs
- Independent retry policy per signal — metrics can retry longer without impacting trace latency
- Independent auth per signal — different API tokens possible
- Named exporters in pipelines are self-documenting: `exporters: [otlphttp/traces]` in the traces pipeline is clear

**Trade-offs:**
- Slightly more YAML to maintain
- Two exporter instances in collector memory (negligible cost)

### Recommendation: Two separate exporters

Evidence from three sources confirms the pattern of separate named exporters:
1. [oneuptime OTel Collector to Grafana Cloud (Feb 2026)](https://oneuptime.com/blog/post/2026-02-06-grafana-cloud-connector-opentelemetry-collector/view): Uses `otlphttp/tempo` + `prometheusremotewrite` as separate named exporters
2. [Grafana Alloy LGTM guide](https://grafana.com/docs/alloy/latest/collect/opentelemetry-to-lgtm-stack/): Uses separate components (`grafana_cloud_traces`, `grafana_cloud_metrics`) per signal
3. [Dash0 OTLP HTTP exporter guide](https://www.dash0.com/guides/opentelemetry-otlp-http-exporter): Documents that TLS and retry_on_failure are exporter-instance-scoped, not per-signal — making the two-exporter pattern the only way to achieve per-signal retry/TLS

### Mimir exporter choice: `otlphttp/metrics` vs `prometheusremotewrite`

| Factor | `otlphttp/metrics` | `prometheusremotewrite` |
|---|---|---|
| Protocol | OTLP native | Prometheus remote write |
| Grafana recommendation | Preferred ("recommended" per Mimir docs) | Alternative |
| Metric naming | Preserves OTel semantic conventions | Converts to Prometheus naming |
| Exemplars | Supported natively | Supported |
| Resource attributes | Preserved as labels (configurable) | Requires `resource_to_telemetry_conversion` |
| Grafana Cloud URL | `prometheus-prod-01-eu-west-0.grafana.net/otlp` (inferred, not published) OR via gateway | `prometheus-prod-01-eu-west-0.grafana.net/api/prom/push` (published, confirmed) |

**Recommendation:** Use `prometheusremotewrite` for Grafana Cloud until the direct Mimir OTLP endpoint for Cloud is confirmed in your stack's OTLP info page. The remote write URL is definitively known and tested. Switch to `otlphttp/metrics` when you verify the `/otlp` path works on your hosted Mimir.

---

## Proposed Collector Config (Synthesis)

The following is the recommended `exporters` and `pipelines` configuration for this chart, based on the research above.

```yaml
exporters:
  debug:
    verbosity: detailed
    sampling_initial: 5
    sampling_thereafter: 200

  otlphttp/traces:
    endpoint: "{{ .Values.global.tempo.endpoint }}"
    headers:
      authorization: "Basic ${env:GRAFANA_CLOUD_AUTH}"
    compression: gzip
    tls:
      insecure: false
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 120s

  prometheusremotewrite:
    endpoint: "{{ .Values.global.mimir.endpoint }}"
    headers:
      authorization: "Basic ${env:GRAFANA_CLOUD_AUTH}"
    resource_to_telemetry_conversion:
      enabled: true
    tls:
      insecure: false

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, filter/drop_noisy_trace_urls, k8sattributes, batch, resource]
      exporters: [debug, otlphttp/traces]

    metrics:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, batch, resource]
      exporters: [debug, prometheusremotewrite]
```

Notes:
- Keep `debug` exporter in both pipelines until backend connectivity is verified
- `GRAFANA_CLOUD_AUTH` should be a Kubernetes Secret mounted as env var: `base64(instanceID:apiToken)`
- Replace `prometheusremotewrite` with `otlphttp/metrics` (endpoint: `https://prometheus-prod-01-eu-west-0.grafana.net/otlp`) once confirmed working

---

## Authentication Pattern

All Grafana Cloud backends require HTTP Basic authentication:

- **Username**: Grafana Cloud Instance ID (numeric, found in stack details)
- **Password**: Grafana Cloud API token with `MetricsPublisher` / `Traces` / `Logs` write scope

In the OTel Collector:
```yaml
headers:
  authorization: "Basic ${env:GRAFANA_CLOUD_AUTH}"
```

Where `GRAFANA_CLOUD_AUTH` = `base64("instanceID:apiToken")`.

For the `basicauth` extension approach (cleanest):
```yaml
extensions:
  basicauth/grafana:
    client_auth:
      username: "${env:GRAFANA_CLOUD_INSTANCE_ID}"
      password: "${env:GRAFANA_CLOUD_API_TOKEN}"

exporters:
  otlphttp/traces:
    endpoint: "https://tempo-eu-west-0.grafana.net:443"
    auth:
      authenticator: basicauth/grafana
```

This requires the `basicauthextension` to be available in the collector distribution. The `otel/opentelemetry-collector-k8s` image (used in this chart) includes contrib components; verify `basicauthextension` is present in version `0.134.1`.

---

## Knowledge Gaps

### Gap 1: Direct Mimir OTLP endpoint URL for Grafana Cloud (Medium)
**Searched:** Grafana Cloud docs, Mimir HTTP API reference, community forums.
**Finding:** The Mimir HTTP API documents `/otlp/v1/metrics` as the OTLP path for self-hosted Mimir. Whether `https://prometheus-prod-01-eu-west-0.grafana.net/otlp` works for hosted Grafana Cloud Mimir is **not explicitly documented** in any public source found. The OTLP gateway (`otlp-gateway-prod-eu-west-0.grafana.net/otlp`) is the only officially published OTLP endpoint for Cloud metrics.
**Action needed:** Check `https://grafana.com/orgs/{org}/stacks/{stack-id}/otlp-info` for your specific stack's confirmed OTLP endpoint for metrics.

### Gap 2: `basicauthextension` availability in `otel/opentelemetry-collector-k8s:0.134.1` (Low)
**Searched:** Not specifically verified against the image contents.
**Action needed:** Run `docker run --rm otel/opentelemetry-collector-k8s:0.134.1 --version` or check the image's component manifest to confirm `basicauthextension` is included.

### Gap 3: OTLP gateway SLA guarantee (Low)
**Searched:** Community forum mention of "no SLA" for gateway, Grafana Cloud SLA page.
**Finding:** Grafana's official SLA page (99.5% monthly) does not explicitly differentiate between OTLP gateway and direct signal endpoints. The "no SLA" claim from a community member is unverified.
**Action needed:** Contact Grafana Cloud support or check the official Grafana Cloud SLA document for OTLP gateway coverage.

---

## Source Summary

| Source | URL | Used for |
|---|---|---|
| OTel Collector otlphttpexporter README | https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/otlphttpexporter/README.md | Endpoint field behavior, signal-specific overrides |
| otlphttpexporter Go package docs | https://pkg.go.dev/go.opentelemetry.io/collector/exporter/otlphttpexporter | Validate() function logic |
| Grafana Mimir OTel Collector config guide | https://grafana.com/docs/mimir/latest/configure/configure-otel-collector/ | Mimir OTLP native ingestion |
| Grafana Mimir HTTP API reference | https://grafana.com/docs/mimir/latest/references/http-api/ | OTLP endpoint path `/otlp/v1/metrics` |
| Grafana Cloud OTLP docs | https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/ | Unified gateway architecture |
| Grafana Alloy LGTM stack guide | https://grafana.com/docs/alloy/latest/collect/opentelemetry-to-lgtm-stack/ | Per-signal endpoint examples, Tempo HTTPS format |
| Grafana Alloy otelcol.exporter.otlphttp ref | https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.exporter.otlphttp/ | Gateway endpoint format, path suffix behavior |
| Grafana blog: OTel Collector + Grafana Cloud tasting menu | https://grafana.com/blog/exploring-opentelemetry-collector-configurations-in-grafana-cloud-a-tasting-menu-approach/ | Unified gateway single exporter example |
| oneuptime OTel Collector to Grafana Cloud (Feb 2026) | https://oneuptime.com/blog/post/2026-02-06-grafana-cloud-connector-opentelemetry-collector/view | Per-signal exporter config with eu-west-0 Tempo URL |
| Grafana Labs blog: Send traces to Tempo via OTel Collector | https://grafana.com/blog/2021/04/13/how-to-send-traces-to-grafana-clouds-tempo-service-with-opentelemetry-collector/ | gRPC vs HTTP distinction for Tempo endpoint format |
| Grafana Cloud community forum: OTLP endpoint credentials | https://community.grafana.com/t/opentelemetry-protocol-otlp-endpoint-credentials-for-grafana-cloud/105782 | Auth format, gateway SLA note |
| Grafana community: OTLP endpoint of Grafana Cloud | https://community.grafana.com/t/opentelemetry-endpoint-of-grafana-cloud/85359 | Gateway routing architecture, user-reported configs |
| Dash0: Mastering OTLP HTTP Exporter | https://www.dash0.com/guides/opentelemetry-otlp-http-exporter | TLS and retry_on_failure scope (exporter-level, not signal-level) |
| Grafana Tempo GitHub Issue #4590 | https://github.com/grafana/tempo/issues/4590 | Tempo endpoint path resolution, /otlp vs base endpoint |
