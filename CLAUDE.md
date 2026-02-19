# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Before You Edit Anything

Read the relevant skill file first. The `.claude/skills/olly-collector/` directory contains deep reference material Claude must use when working with this chart:

| Skill File | Use When |
|------------|----------|
| [SKILL.md](.claude/skills/olly-collector/SKILL.md) | Starting any work — chart overview and index |
| [helm-patterns.md](.claude/skills/olly-collector/helm-patterns.md) | Editing any template (`*.yaml`, `_helpers.tpl`) |
| [otel-config.md](.claude/skills/olly-collector/otel-config.md) | Editing the collector config (processors, pipelines, filters) |
| [promtail.md](.claude/skills/olly-collector/promtail.md) | Editing Promtail config or relabeling rules |
| [working-with-metrics.md](.claude/skills/olly-collector/working-with-metrics.md) | Anything involving metrics, VPA, or auto-instrumented metrics |
| [auto-instrumentation.md](.claude/skills/olly-collector/auto-instrumentation.md) | Editing `clusterpolicy.yaml` or Instrumentation CRs |
| [versioning-and-debugging.md](.claude/skills/olly-collector/versioning-and-debugging.md) | Debugging issues, bumping versions, writing CHANGELOG entries |

The `.claude/rules/olly-collector.md` rule is auto-loaded when editing any file under `charts/olly-collector/`.

---

## Before You Commit

Every change to `charts/olly-collector/` requires:

1. **Bump `version:` in `Chart.yaml`** — any template, values, or dependency change
2. **Add a `CHANGELOG.md` entry** — create `charts/olly-collector/CHANGELOG.md` if it doesn't exist yet
3. **Validate** — `./charts/olly-collector/helm-validate.sh` or `helm lint charts/olly-collector`

Breaking changes need `#### BREAKING CHANGES`, `#### Impact`, and `##### Mitigation Action` sections in the changelog entry.

---

## Current Project Status (v0.0.1)

| Item | Status | Action needed |
|------|--------|---------------|
| OTel exporter | `debug` (stdout only) | Set `global.opentelemetry.endpoint` + switch to `otlphttp` |
| Loki endpoint | placeholder `http://loki-not-configured:3100` | Set `global.promtail.endpoint` when Loki is available |
| CHANGELOG.md | Does not exist yet | Create on first version bump |
| ServiceMonitor template | Not yet created | `serviceMonitor.labels` configured in values but no template |
| Go instrumentation | Not in `clusterpolicy.yaml` | Add `go:` section to both rules |

---

## Known Issues in `charts/olly-collector/`

These bugs exist in the current codebase. Do not repeat them in new code:

1. **Endpoint URL typo** — `clusterpolicy.yaml` has an extra period: `.svc.cluster.local.:4318` → correct form is `.svc.cluster.local:4318`
2. **Go missing from ClusterPolicy** — The operator has `autoInstrumentation.go.enabled: true` but `clusterpolicy.yaml` has no `go:` section in either rule
3. **Python missing from full CR** — `sync-instrumentation-full` rule has no `python:` section; the default CR correctly disables Python metrics but the full CR doesn't enable them

---

## Project Overview

The `olly-collector` Helm chart deploys three telemetry collection agents to Kubernetes clusters as DaemonSets:

| Component | Purpose | Dependency |
|-----------|---------|------------|
| OpenTelemetry Collector | Receives traces + metrics via OTLP, enriches with K8s metadata, exports to backends | `opentelemetry-operator` v0.99.0 |
| OpenTelemetry Operator | Manages Collector CRDs and injects OTel SDKs into application pods | Sub-chart |
| Promtail | Collects container logs from host paths, forwards to Loki | `promtail` v6.17.1 |

**Prerequisites (must be installed before this chart):**
- cert-manager — required for OTel Operator admission webhook TLS
- Kyverno — required for `ClusterPolicy` CR propagation across namespaces

---

## Why These Design Choices

**Why DaemonSet (not Deployment)?**
Each collector pod must be co-located with the application pods it collects from. The `k8sattributes` processor uses `KUBE_NODE_NAME` to scope Kubernetes metadata lookups to its own node — this only works if the collector is on the same node as the apps sending telemetry.

**Why two Instrumentation CRs (`olly-collector` and `olly-collector-full`)?**
Auto-instrumented metrics can cause unexpected cardinality and cost before teams understand what's being emitted. The default CR disables metrics (`OTEL_METRICS_EXPORTER=none`). Teams opt in to metrics by using the `-full` CR. This is a deliberate protection against runaway metric costs.

**Why is the filter only on traces, not metrics?**
Health-check spans (`/healthz`, `/readyz`, `/metrics`) have constant, high-cardinality span names that pollute trace data. Metric cardinality is controlled at the SDK level and at backend ingestion limits — there is no equivalent "noisy metric URL" problem.

**Why `debug` exporter now?**
No OTLP backend is configured yet. The debug exporter logs telemetry to stdout for local verification that instrumentation is working. It is a temporary placeholder — see "Current Project Status" above.

**Why Kyverno instead of manually creating Instrumentation CRs?**
The Instrumentation CR must exist in every namespace where pods want auto-instrumentation. Maintaining copies manually across many namespaces is error-prone. Kyverno's `generate` rule with `synchronize: true` ensures all namespaces always have up-to-date copies from the single source of truth in `default`.

---

## Commands Reference

```bash
# Validate chart (lint + template render)
./charts/olly-collector/helm-validate.sh

# Update dependencies (run after changing Chart.yaml dependencies)
helm dependency update charts/olly-collector

# Lint the chart
helm lint charts/olly-collector

# Render all templates locally
helm template test charts/olly-collector \
  --set opentelemetry-operator.enabled=true \
  --set opentelemetryCollector.enabled=true

# Render a specific template
helm template test charts/olly-collector \
  --set opentelemetryCollector.enabled=true \
  --show-only "templates/opentelemetry-collector/opentelemetry-collector.yaml"

# Render clusterpolicy only (needs Kyverno API — use --api-versions flag without cluster)
helm template test charts/olly-collector \
  --set opentelemetryCollector.enabled=true \
  --set opentelemetryCollector.instrumentation.enabled=true \
  --api-versions kyverno.io/v1 \
  --show-only "templates/opentelemetry-collector/clusterpolicy.yaml"

# Dry-run install (requires cluster connection)
helm install test charts/olly-collector \
  --namespace observability \
  --create-namespace \
  --set opentelemetry-operator.enabled=true \
  --set opentelemetryCollector.enabled=true \
  --dry-run
```

---

## Architecture

### Telemetry Pipelines

**Traces** — includes noisy-URL filter (metrics does not):
```
OTLP receivers (4317/4318)
  → memory_limiter          [must be first]
  → filter/drop_noisy_trace_urls  [health checks, /metrics, /favicon.ico]
  → k8sattributes           [pod/namespace/deployment/node metadata]
  → batch
  → resource                [injects k8s.cluster.name]
  → debug / otlphttp → Tempo
```

**Metrics** — no filter processor:
```
OTLP receivers (4317/4318)
  → memory_limiter
  → k8sattributes
  → batch
  → resource
  → debug / otlphttp → Mimir
```

**Logs** — Promtail reads host paths directly:
```
/var/log/pods (host path)
  → CRI log parsing
  → relabeling (instance label fallback)
  → labeldrop (filename)
  → HTTP push → Loki
```

### Key Configuration Values

```yaml
global:
  cluster: "platform-team-environment"   # REQUIRED — becomes k8s.cluster.name in all telemetry
  opentelemetry:
    endpoint: ""                          # OTLP HTTP backend — empty until backend is ready
  promtail:
    endpoint: "http://loki-not-configured:3100/..."  # Loki push URL — placeholder

opentelemetryCollector:
  enabled: true
  instrumentation:
    enabled: true                         # Deploys Kyverno ClusterPolicy
    namespaces: []                        # [] = all namespaces; restrict by listing patterns
```

### File Map

| File | Purpose |
|------|---------|
| `charts/olly-collector/Chart.yaml` | Chart metadata, version, dependencies |
| `charts/olly-collector/values.yaml` | Full production config (source of truth) |
| `charts/olly-collector/values.default.yaml` | Minimal example with only required fields |
| `templates/_helpers.tpl` | `name`, `fullname`, `labels`, `selectorLabels` helpers |
| `templates/opentelemetry-collector/opentelemetry-collector.yaml` | `OpenTelemetryCollector` CR (DaemonSet mode) |
| `templates/opentelemetry-collector/clusterpolicy.yaml` | Kyverno policy — syncs Instrumentation CRs to all namespaces |
| `templates/opentelemetry-collector/vpa.yaml` | VPA for collector (200Mi min, 4Gi max) |
| `templates/opentelemetry-collector/clusterrole.yaml` | RBAC for `k8sattributes` processor |
| `templates/opentelemetry-collector/serviceaccount.yaml` | ServiceAccount for collector pods |

---

## Architecture Diagrams

Mermaid diagrams in `docs/architecture/diagrams/`:

| Diagram | Description |
|---------|-------------|
| [system-context.md](docs/architecture/diagrams/system-context.md) | C4 L1 — olly-collector in the broader observability ecosystem |
| [telemetry-data-flow.md](docs/architecture/diagrams/telemetry-data-flow.md) | App → OTel Collector → Loki / Mimir / Tempo / Grafana |
| [daemonset-node-topology.md](docs/architecture/diagrams/daemonset-node-topology.md) | One collector + Promtail per node, KUBE_NODE_NAME scoping |
| [otel-collector-pipeline.md](docs/architecture/diagrams/otel-collector-pipeline.md) | Internal processor chains: traces vs metrics |
| [kyverno-cr-propagation.md](docs/architecture/diagrams/kyverno-cr-propagation.md) | ClusterPolicy → Instrumentation CR sync across namespaces |
| [auto-instrumentation-sequence.md](docs/architecture/diagrams/auto-instrumentation-sequence.md) | Sequence: pod admission → OTel Operator → SDK injection |
