# System Context (C4 Level 1)

Where `olly-collector` sits in the broader observability ecosystem — the relationship between the chart, the applications it instruments, the backends it feeds, and the people who operate it.

## Diagram

```mermaid
C4Context
    title System Context — olly-collector

    Person(dev, "Application Developer", "Annotates pods to opt in to auto-instrumentation. Queries traces, metrics, and logs in Grafana.")
    Person(platformOp, "Platform Operator", "Installs and upgrades the olly-collector chart. Configures backends and manages Kyverno policies.")

    System(ollyCollector, "olly-collector", "Helm chart deploying OTel Collector (DaemonSet) + OTel Operator. Collects traces, metrics, and logs from instrumented applications.")

    System_Ext(appWorkloads, "Application Workloads", "Java, Node.js, Python, Go, nginx, Apache apps running in the cluster. Use OTel SDK manually or get auto-instrumented.")

    System_Ext(certManager, "cert-manager", "Manages TLS certificates for OTel Operator admission webhooks. Must be pre-installed.")
    System_Ext(kyverno, "Kyverno", "Policy engine. Required for auto-instrumentation CR propagation across namespaces. Must be pre-installed.")

    System_Ext(tempo, "Tempo", "Distributed trace storage and query. Receives OTLP HTTP traces from collector.")
    System_Ext(mimir, "Mimir", "Metrics storage (Prometheus-compatible). Receives OTLP HTTP metrics from kubeletstats receiver and otel-demo apps.")
    System_Ext(loki, "Loki", "Log aggregation. Receives logs from Otel filelog receiver via otlphttp/logs exporter.")
    System_Ext(grafana, "Grafana", "Dashboards, alerts, and exploration for all three signal types.")

    Rel(platformOp, ollyCollector, "Installs / configures", "helm install / helm upgrade")
    Rel(dev, appWorkloads, "Deploys and annotates", "kubectl / GitOps")
    Rel(dev, grafana, "Queries", "HTTP / browser")

    Rel(appWorkloads, ollyCollector, "Sends telemetry", "OTLP gRPC :4317 / HTTP :4318")
    Rel(ollyCollector, appWorkloads, "Injects OTel SDK agents", "Admission webhook (via OTel Operator)")

    Rel(ollyCollector, tempo, "Exports traces", "OTLP HTTP")
    Rel(ollyCollector, mimir, "Exports metrics", "OTLP HTTP")
    Rel(ollyCollector, loki, "Export logs", "OTLP HTTP")

    Rel(tempo, grafana, "Trace data source")
    Rel(mimir, grafana, "Metrics data source")
    Rel(loki, grafana, "Log data source")

    Rel(ollyCollector, certManager, "Requires", "TLS certs for webhooks")
    Rel(ollyCollector, kyverno, "Requires", "ClusterPolicy API")
```

## System Boundaries

| System | Owner | Managed by this chart? |
|--------|-------|----------------------|
| OTel Collector DaemonSet | Platform team | **Yes** |
| OTel Operator | Platform team | **Yes** (as dependency) |
| cert-manager | Platform team | No — pre-requisite |
| Kyverno | Platform team | No — pre-requisite |
| Tempo | Grafana Cloud | No — SaaS |
| Mimir | Grafana Cloud | No — SaaS |
| Loki | Grafana Cloud | No — SaaS |
| Grafana | Grafana Cloud | No — SaaS |
| Application workloads | Development teams - otel-demo for now. | No — consumers of this chart |

## Prerequisites (Must Pre-Exist)

```bash
# cert-manager (required for OTel Operator admission webhooks)
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true

# Kyverno (required for ClusterPolicy CR propagation)
helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace
```
