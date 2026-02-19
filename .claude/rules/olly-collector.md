---
paths:
  - "charts/olly-collector/**"
---

# Olly Collector Helm Chart - Quick Reference

## Chart Overview

Helm chart at `charts/olly-collector/` deploying OTel Collector (DaemonSet), OTel Operator, and Promtail to Kubernetes clusters. All components disabled by default. Current version in `Chart.yaml` (v0.0.1 — early stage).

**Current exporter**: `debug` (no backend configured yet; `otlphttp` is commented out in `values.yaml`).

## Required Before Commit

1. **Bump `version:` in `Chart.yaml`** for ANY change to templates, values, or dependencies
2. **Add `CHANGELOG.md` entry** (create the file if it doesn't exist yet) with format: `## [vX.Y.Z] - YYYY-MM-DD`
3. **Run `./charts/olly-collector/helm-validate.sh`** or `helm lint` to verify

Breaking changes require `#### BREAKING CHANGES`, `#### Impact`, and `##### Mitigation Action` sections in CHANGELOG.

## Key Patterns

- **Template interpolation**: `{{ tpl (toYaml .Values.opentelemetryCollector.config) . | nindent 4 }}` — enables Helm templating inside YAML values
- **Whitespace**: `{{-` trims leading whitespace; `nindent` adds newline then indents, `indent` does not
- **API version guards**: `{{- if .Capabilities.APIVersions.Has "kyverno.io/v1" }}` — conditionally include resources
- **DNS limit**: Names truncated to 63 chars (`trunc 63 | trimSuffix "-"`)
- **Kyverno escaping**: Kyverno `{{ }}` inside generate blocks must be escaped with `{{ print "{{ ... }}" | quote }}`

## Two Pipelines, Different Processors

- **Traces**: `memory_limiter` → `filter/drop_noisy_trace_urls` → `k8sattributes` → `batch` → `resource` → `debug`
- **Metrics**: `memory_limiter` → `k8sattributes` → `batch` → `resource` → `debug` (NO filter)

`memory_limiter` must always be first.

## Two Instrumentation CRs

- **`olly-collector`** (default): `OTEL_METRICS_EXPORTER=none` — traces only
- **`olly-collector-full`**: Metrics enabled — opt-in for teams that need auto-instrumented metrics

## Protocol Differences by Language

- HTTP (4318): Java, Python, Go
- gRPC (4317): Node.js, nginx, Apache HTTPD

## Known Issues in clusterpolicy.yaml

1. **Endpoint URL typo**: Extra period in `.svc.cluster.local.:4318` — should be `.svc.cluster.local:4318`
2. **Go missing**: Go instrumentation not in ClusterPolicy despite operator having `autoInstrumentation.go.enabled: true`
3. **Python missing from full CR**: `sync-instrumentation-full` doesn't include Python section

## Common Gotchas

1. **cert-manager required**: OTel Operator admission webhooks need cert-manager pre-installed
2. **Kyverno required**: ClusterPolicy only renders when `kyverno.io/v1` API is present
3. **Semantic convention breakage**: OTel Operator upgrades can rename metrics/attributes. Java is most affected.
4. **Three HTTP attributes**: Filter checks `http.route`, `http.target`, AND `url.path` — different OTel versions use different names
5. **Debug exporter**: Current exporter logs to stdout only — switch to `otlphttp` when backend is available

## Quick Commands

```bash
./charts/olly-collector/helm-validate.sh                    # Validate chart
helm template test charts/olly-collector \
  --set opentelemetryCollector.enabled=true                  # Dry-run render
helm lint charts/olly-collector                              # Syntax check
helm template test charts/olly-collector \
  --set opentelemetryCollector.enabled=true \
  --show-only templates/opentelemetry-collector/opentelemetry-collector.yaml  # Single template
helm dependency update charts/olly-collector                 # Update deps
```

## File Map

| File | What It Does |
|------|-------------|
| `values.yaml` | Full production config (debug exporter, placeholder Loki endpoint) |
| `values.default.yaml` | Minimal example with just the required fields |
| `templates/_helpers.tpl` | name, fullname, labels, selectorLabels |
| `templates/opentelemetry-collector/opentelemetry-collector.yaml` | OTelCollector CR (DaemonSet) |
| `templates/opentelemetry-collector/clusterpolicy.yaml` | Kyverno auto-instrumentation sync (2 CRs) |
| `templates/opentelemetry-collector/vpa.yaml` | VPA for collector (200Mi min, 4Gi max) |
| `templates/opentelemetry-collector/clusterrole.yaml` | RBAC for k8sattributes processor |
| `templates/opentelemetry-collector/serviceaccount.yaml` | ServiceAccount for the collector |
