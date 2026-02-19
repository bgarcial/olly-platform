# Auto-Instrumentation

The chart uses Kyverno to sync OpenTelemetry `Instrumentation` CRs across namespaces, enabling zero-code telemetry injection for applications.

## How It Works

1. The OTel Operator is deployed with auto-instrumentation support
2. A Kyverno ClusterPolicy watches namespace creation/updates
3. The policy copies `Instrumentation` CRs into all namespaces (except `default`, `kube-system`, `kube-node-lease`, `kube-public`)
4. Pods with instrumentation annotations get auto-injected with the appropriate SDK at admission time

**Template**: `templates/opentelemetry-collector/clusterpolicy.yaml`
**Condition**: Requires `opentelemetryCollector.enabled`, `opentelemetryCollector.instrumentation.enabled`, and Kyverno installed (`kyverno.io/v1` API).

## Two Instrumentation Modes

The ClusterPolicy generates **two** Instrumentation CRs per namespace:

### Default: `olly-collector` (traces only)

```yaml
env:
  - name: OTEL_LOGS_EXPORTER
    value: none
  - name: OTEL_METRICS_EXPORTER
    value: none           # Metrics disabled
  - name: OTEL_EXPORTER_OTLP_METRICS_DEFAULT_HISTOGRAM_AGGREGATION
    value: base2_exponential_bucket_histogram
```

- **Use case**: Standard instrumentation — traces only
- **Annotation**: `instrumentation.opentelemetry.io/inject-<language>: "olly-collector"`

### Full: `olly-collector-full` (traces + metrics)

```yaml
env:
  - name: OTEL_LOGS_EXPORTER
    value: none
  - name: OTEL_EXPORTER_OTLP_METRICS_DEFAULT_HISTOGRAM_AGGREGATION
    value: base2_exponential_bucket_histogram
  # OTEL_METRICS_EXPORTER is NOT set — metrics flow through
```

- **Use case**: Teams that explicitly want auto-instrumented metrics
- **Annotation**: `instrumentation.opentelemetry.io/inject-<language>: "olly-collector-full"`

## Supported Languages

| Language | Annotation | Protocol | Notes |
|----------|------------|----------|-------|
| Java | `instrumentation.opentelemetry.io/inject-java: "<cr-name>"` | HTTP (4318) | Most mature. Pinned image in clusterpolicy.yaml. |
| Node.js | `instrumentation.opentelemetry.io/inject-nodejs: "<cr-name>"` | gRPC (4317) | Overrides endpoint to gRPC. |
| Python | `instrumentation.opentelemetry.io/inject-python: "<cr-name>"` | HTTP (4318) | Explicitly disables metrics even in default CR. |
| Go | `instrumentation.opentelemetry.io/inject-go: "<cr-name>"` | HTTP (4318) | eBPF-based. Operator flag enabled but **not yet in clusterpolicy**. |
| nginx | `instrumentation.opentelemetry.io/inject-nginx: "<cr-name>"` | gRPC (4317) | Enabled via `--enable-nginx-instrumentation=true`. |
| Apache HTTPD | `instrumentation.opentelemetry.io/inject-apache-httpd: "<cr-name>"` | gRPC (4317) | Basic HTTP metrics/traces. |

### Protocol Differences

- **Java, Python, Go**: Use HTTP endpoint (port 4318) — configured via `spec.exporter.endpoint`
- **Node.js, nginx, Apache HTTPD**: Override to gRPC endpoint (port 4317) — better performance with gRPC

## Known Issues in clusterpolicy.yaml

### 1. Endpoint URL Typo (Extra Period)

**Location**: `clusterpolicy.yaml`, lines 50 and 68-76 (approximately)

```yaml
# WRONG — extra period before :4318 / :4317
endpoint: http://{{ include "olly-collector.name" . }}-opentelemetry-collector.{{ .Release.Namespace }}.svc.cluster.local.:4318
#                                                                                                                             ^
# CORRECT
endpoint: http://{{ include "olly-collector.name" . }}-opentelemetry-collector.{{ .Release.Namespace }}.svc.cluster.local:4318
```

This trailing period is technically valid DNS (fully-qualified domain name) but may cause connection issues in some environments. Remove the trailing period.

### 2. Go Instrumentation Not in ClusterPolicy

The OTel Operator is configured with `autoInstrumentation.go.enabled: true`, but the ClusterPolicy doesn't include a `go:` section. To add Go instrumentation to both CRs:

```yaml
# In the generate.data.spec section of both rules:
go:
  env:
    - name: OTEL_EXPORTER_OTLP_ENDPOINT
      value: http://{{ include "olly-collector.name" . }}-opentelemetry-collector.{{ .Release.Namespace }}.svc.cluster.local:4318
```

### 3. Python Missing from Full CR

The `sync-instrumentation-full` rule does not include a `python:` section with explicit environment override, unlike the default rule. If you want Python metrics in the full CR, add:

```yaml
python:
  env:
    - name: OTEL_METRICS_EXPORTER
      value: otlp   # Explicitly enable for full CR
```

## Namespace Scoping

```yaml
opentelemetryCollector:
  instrumentation:
    namespaces: []  # Empty = all namespaces
```

To restrict to specific namespaces:

```yaml
opentelemetryCollector:
  instrumentation:
    namespaces:
      - "team-a-*"
      - "team-b-production"
```

## Multi-Instrumentation Support

The operator is configured with `--enable-multi-instrumentation`, allowing a single pod to have multiple instrumentation annotations (e.g., both Java and nginx in the same pod).

## OTel Operator Configuration

```yaml
opentelemetry-operator:
  replicaCount: 2                    # HA deployment
  pdb:
    create: true
    maxUnavailable: 1
  manager:
    rolling: true
    collectorImage:
      repository: otel/opentelemetry-collector-k8s
    autoInstrumentation:
      go:
        enabled: true
    featureGates: ""
    extraArgs:
      - --enable-multi-instrumentation
      - --enable-nginx-instrumentation=true
    verticalPodAutoscaler:
      enabled: true
      minAllowed:
        cpu: 200m
        memory: 512Mi              # Needed for issue #2667
      updatePolicy:
        minReplicas: 1
        updateMode: Auto
```

**cert-manager is required** for admission webhooks:

```yaml
admissionWebhooks:
  certManager:
    enabled: true
```

## Semantic Convention Risks on Upgrades

When the operator is upgraded, it pulls new auto-instrumentation agent images. These may adopt updated OTel semantic conventions that **rename metrics and attributes**.

| What changes | Example | Impact |
|-------------|---------|--------|
| Metric names | `http.server.duration` → `http.server.request.duration` | Dashboards show no data |
| Attribute names | `http.method` → `http.request.method` | Queries/filters break |
| Attribute values | `HTTP` → `http` (case change) | Alert rules stop matching |

### Mitigation Strategies

1. **Pin images**: The Java auto-instrumentation image is pinned in `clusterpolicy.yaml` with a Renovate comment:
   ```yaml
   java:
     # renovate: datasource=docker depName=autoinstrumentation-java registryUrl=https://ghcr.io/open-telemetry/opentelemetry-operator
     image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.21.0
   ```

2. **Test upgrades first**: Always deploy operator upgrades to a test cluster and verify before production.

3. **Check changelogs before upgrading**:
   - OTel Semantic Conventions: https://opentelemetry.io/docs/specs/semconv/
   - Java agent releases: https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases
   - OTel Operator releases: https://github.com/open-telemetry/opentelemetry-operator/releases

4. **Use the default CR** (metrics disabled) unless teams explicitly need auto-instrumented metrics.

## Checking Kyverno Policy Status

```bash
# View policy
kubectl get clusterpolicy -l app.kubernetes.io/name=olly-collector

# Check if Instrumentation CRs were synced to a namespace
kubectl get instrumentation -n <namespace>

# Verify CR content
kubectl get instrumentation olly-collector -n <namespace> -o yaml
kubectl get instrumentation olly-collector-full -n <namespace> -o yaml

# Check Kyverno policy reports
kubectl get policyreport -n <namespace>
```
