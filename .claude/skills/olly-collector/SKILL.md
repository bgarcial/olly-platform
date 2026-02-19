---
name: olly-collector
description: Guidance for working with the olly-collector Helm chart, including Helm patterns, OpenTelemetry Collector configuration, Promtail, auto-instrumentation, and metrics collection. Use when editing or discussing charts/olly-collector/.
---

# Olly Collector Helm Chart

The olly-collector is a Helm chart that deploys telemetry collection agents to Kubernetes clusters. It enables collection of metrics, logs, and traces from instrumented applications and forwards them to observability backends via OTLP.

**Chart Location**: `charts/olly-collector/`
**Current Version**: See `Chart.yaml` (v0.0.1 — early development stage)

## Components

| Component | Purpose | Dependency Chart |
|-----------|---------|------------------|
| OpenTelemetry Collector | Traces and metrics collection (DaemonSet) | Custom resource via otel-operator |
| OpenTelemetry Operator | Auto-instrumentation and collector management | `opentelemetry-operator` (v0.99.0) |
| Promtail | Log collection and forwarding to Loki | `promtail` (v6.17.1) |

All components are **disabled by default** and must be explicitly enabled.

## Chart Structure

```
charts/olly-collector/
├── Chart.yaml                    # Chart metadata and dependencies
├── Chart.lock                    # Locked dependency versions
├── values.yaml                   # Production-ready config (currently debug exporter)
├── values.default.yaml           # Minimal example config
├── helm-validate.sh              # Validate chart (lint + template + optional dry-run)
├── templates/
│   ├── opentelemetry-collector/
│   │   ├── _helpers.tpl              # Reusable template functions
│   │   ├── opentelemetry-collector.yaml  # OpenTelemetryCollector CR (DaemonSet)
│   │   ├── clusterpolicy.yaml        # Kyverno auto-instrumentation sync
│   │   ├── clusterrole.yaml
│   │   ├── clusterrolebinding.yaml
│   │   ├── serviceaccount.yaml
│   │   └── vpa.yaml                  # Vertical Pod Autoscaler
└── charts/                       # Downloaded dependencies
```

## Current Status (v0.0.1)

| Item | Status |
|------|--------|
| OTel exporter | **debug** (no backend configured yet; `otlphttp` commented out) |
| Loki endpoint | **placeholder** (`http://loki-not-configured:3100`) |
| CHANGELOG.md | Not yet created |
| ServiceMonitor template | Not yet created (labels configured in values) |
| Go instrumentation | Not in clusterpolicy (only Java, Node.js, nginx, Apache HTTPD, Python) |

## Validation

```bash
# Validate chart (lint + template render)
./charts/olly-collector/helm-validate.sh

# Render templates locally
helm template test charts/olly-collector \
  --set opentelemetry-operator.enabled=true \
  --set opentelemetryCollector.enabled=true

# Render specific template
helm template test charts/olly-collector \
  --set opentelemetryCollector.enabled=true \
  --show-only "templates/opentelemetry-collector/opentelemetry-collector.yaml"

# Validate syntax
helm lint charts/olly-collector
```

## Updating Dependencies

```bash
helm dependency update charts/olly-collector
```

## Supporting Files

For detailed reference on specific topics, see:

- **[helm-patterns.md](helm-patterns.md)** - Go template language, values configuration, helper functions, whitespace control, API version detection
- **[otel-config.md](otel-config.md)** - OpenTelemetry Collector pipeline architecture, processors, noisy trace URL filter deep-dive, common tasks
- **[promtail.md](promtail.md)** - Promtail relabel configurations, pipeline stages, instance label fallback, adding custom labels
- **[working-with-metrics.md](working-with-metrics.md)** - Metrics pipeline, collector self-monitoring, VPA sizing, auto-instrumentation metrics impact
- **[auto-instrumentation.md](auto-instrumentation.md)** - Kyverno ClusterPolicy, language-specific instrumentation, known issues, semantic convention risks on OTel upgrades
- **[versioning-and-debugging.md](versioning-and-debugging.md)** - Version bump rules, CHANGELOG format, breaking changes, debug commands
