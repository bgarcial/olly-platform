# OpenTelemetry Demo

The OpenTelemetry Demo is a microservices-based e-commerce application that demonstrates OpenTelemetry instrumentation across multiple programming languages. This deployment is configured to send all telemetry to the existing `olly-collector` DaemonSet.

## Architecture

```
                                    ┌─────────────────┐
                                    │  Load Generator │
                                    │  (Python/Locust)│
                                    └────────┬────────┘
                                             │
                                             ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                          Frontend Proxy (Envoy)                             │
│                              Port: 8080                                     │
└────────────────────────────────────────────────────────────────────────────┘
         │                    │                    │                    │
         ▼                    ▼                    ▼                    ▼
┌─────────────┐      ┌─────────────┐      ┌─────────────┐      ┌─────────────┐
│  Frontend   │      │   Flagd-UI  │      │   Grafana   │      │   Jaeger    │
│  (Next.js)  │      │  (Elixir)   │      │ (disabled)  │      │ (disabled)  │
└──────┬──────┘      └─────────────┘      └─────────────┘      └─────────────┘
       │
       ├──────────────┬──────────────┬──────────────┬──────────────┐
       ▼              ▼              ▼              ▼              ▼
┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐
│    Ad     │  │   Cart    │  │ Checkout  │  │ Currency  │  │  Recom.   │
│  (Java)   │  │  (.NET)   │  │   (Go)    │  │   (C++)   │  │ (Python)  │
└───────────┘  └─────┬─────┘  └─────┬─────┘  └───────────┘  └─────┬─────┘
                     │              │                              │
                     ▼              ▼                              ▼
              ┌───────────┐  ┌─────────────────────────────┐  ┌───────────┐
              │  Valkey   │  │  Email, Payment, Shipping,  │  │  Product  │
              │  (Cache)  │  │  Product Catalog, Kafka     │  │  Catalog  │
              └───────────┘  └─────────────────────────────┘  └───────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    ▼                    ▼                    ▼
             ┌───────────┐        ┌───────────┐        ┌───────────┐
             │Accounting │        │  Fraud    │        │  Email    │
             │  (.NET)   │        │ Detection │        │  (Ruby)   │
             └───────────┘        │ (Kotlin)  │        └───────────┘
                                  └───────────┘

                         All services send telemetry via OTLP to:
┌────────────────────────────────────────────────────────────────────────────┐
│                    olly-collector DaemonSet                                 │
│         olly-collector-opentelemetry-collector.olly-collector              │
│                    gRPC: 4317 | HTTP: 4318                                 │
└────────────────────────────────────────────────────────────────────────────┘
```

## Services

| Service | Language | Description |
|---------|----------|-------------|
| accounting | .NET | Consumes orders from Kafka, maintains financial records |
| ad | Java | Serves contextual advertisements based on context |
| cart | .NET | Shopping cart with Valkey/Redis backend |
| checkout | Go | Orchestrates the checkout flow across services |
| currency | C++ | Currency conversion between different currencies |
| email | Ruby | Sends order confirmation emails |
| flagd | Go | OpenFeature-compatible feature flag service |
| flagd-ui | Elixir | Web UI for managing feature flags |
| fraud-detection | Kotlin | Analyzes orders from Kafka for fraud patterns |
| frontend | TypeScript | Next.js web application |
| frontend-proxy | Envoy | API gateway and reverse proxy |
| image-provider | nginx | Serves product images |
| kafka | Java | Message broker for async events (checkout → accounting, fraud) |
| llm | Python | Mock LLM service for product review summaries |
| load-generator | Python | Locust-based synthetic traffic generator |
| payment | JavaScript | Payment processing simulation |
| postgresql | PostgreSQL | Database for catalog, accounting, reviews |
| product-catalog | Go | Product information and inventory |
| product-reviews | Python | Product review management with LLM integration |
| quote | PHP | Shipping quote generation |
| recommendation | Python | Product recommendation engine |
| shipping | Rust | Shipping cost calculation |
| valkey-cart | Valkey | Redis-compatible session cache for cart |

## Telemetry

Each service demonstrates different instrumentation patterns:

- **Automatic instrumentation**: Language agents auto-instrument frameworks
- **Instrumentation libraries**: Explicit library instrumentation
- **Manual instrumentation**: Custom spans and attributes

### Telemetry Flow

```
Services → OTLP (gRPC/HTTP) → olly-collector → Backend (Tempo, Prometheus, Loki)
```

All services export:
- **Traces**: Distributed tracing with context propagation
- **Metrics**: Service-level metrics (requests, latency, errors)
- **Logs**: Correlated logs with trace context

## Prerequisites

- Kubernetes 1.24+
- 6 GB available RAM
- Helm 3.14+
- `olly-collector` deployed in `olly-collector` namespace

## Installation

### 1. Add Helm repository

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

### 2. Verify collector endpoint

```bash
kubectl get svc -n olly-collector | grep collector
```

Expected output:
```
olly-collector-opentelemetry-collector   ClusterIP   10.x.x.x   <none>   4317/TCP,4318/TCP
```

### 3. Install the demo (first time)

```bash
helm install otel-demo open-telemetry/opentelemetry-demo \
  --namespace otel-demo \
  --create-namespace \
  -f charts/opentelemetry-demo/values.yaml
```

### 4. Upgrade the demo (after values.yaml changes)

```bash
helm upgrade -i otel-demo open-telemetry/opentelemetry-demo \
  --namespace otel-demo \
  --create-namespace \
  -f charts/opentelemetry-demo/values.yaml
```

The `-i` flag (short for `--install`) installs the release if it doesn't exist, or upgrades it if it does.

### 5. Verify deployment

```bash
kubectl get pods -n otel-demo
```

## Accessing the Demo

### Port-forward to frontend

```bash
kubectl port-forward -n otel-demo svc/otel-demo-frontend-proxy 8080:8080
```

Open http://localhost:8080

### Port-forward to load generator UI

```bash
kubectl port-forward -n otel-demo svc/otel-demo-load-generator 8089:8089
```

Open http://localhost:8089 to control traffic generation.

### Port-forward to Flagd UI

```bash
kubectl port-forward -n otel-demo svc/otel-demo-flagd-ui 4000:4000
```

Open http://localhost:4000 to manage feature flags.

## Configuration

### values.yaml

```yaml
# Disable sub-charts (using existing olly-collector)
opentelemetry-collector:
  enabled: false
jaeger:
  enabled: false
prometheus:
  enabled: false
grafana:
  enabled: false
opensearch:
  enabled: false

# Configure telemetry endpoint for all services
default:
  env:
    - name: OTEL_SERVICE_NAME
      valueFrom:
        fieldRef:
          apiVersion: v1
          fieldPath: metadata.labels['app.kubernetes.io/component']
    - name: OTEL_COLLECTOR_NAME
      value: "olly-collector-opentelemetry-collector.olly-collector.svc.cluster.local"
    - name: OTEL_EXPORTER_OTLP_ENDPOINT
      value: "http://olly-collector-opentelemetry-collector.olly-collector.svc.cluster.local:4317"
    - name: OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE
      value: cumulative
    - name: OTEL_RESOURCE_ATTRIBUTES
      value: "service.namespace=opentelemetry-demo"
```

### Key Environment Variables

| Variable | Description |
|----------|-------------|
| `OTEL_SERVICE_NAME` | Service identifier in telemetry (auto-set from pod label) |
| `OTEL_COLLECTOR_NAME` | Collector hostname for services using `$(OTEL_COLLECTOR_NAME)` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Full endpoint URL for OTLP export |
| `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` | `cumulative` (recommended) or `delta` |
| `OTEL_RESOURCE_ATTRIBUTES` | Additional resource attributes for all telemetry |

## Verification

### Check collector is receiving telemetry

```bash
kubectl logs -n olly-collector -l app.kubernetes.io/component=opentelemetry-collector --tail=100 -f
```

### Check a specific service

```bash
kubectl logs -n otel-demo -l app.kubernetes.io/component=frontend --tail=50
```

### Verify OTLP connectivity

```bash
kubectl exec -n otel-demo deploy/otel-demo-frontend -- \
  wget -qO- --spider http://olly-collector-opentelemetry-collector.olly-collector:4318/v1/traces
```

## Uninstall

```bash
helm uninstall otel-demo -n otel-demo
kubectl delete namespace otel-demo
```

## Feature Flags

The demo includes feature flags via Flagd that can trigger different behaviors:

| Flag | Effect |
|------|--------|
| `adServiceFailure` | Causes ad service to fail |
| `cartServiceFailure` | Causes cart service to fail |
| `paymentServiceFailure` | Causes payment to fail |
| `productCatalogFailure` | Causes product catalog errors |
| `recommendationServiceCacheFailure` | Disables recommendation cache |
| `kafkaQueueProblems` | Introduces Kafka delays |
| `llmInaccurateResponse` | LLM returns inaccurate summaries |

Access Flagd UI at http://localhost:4000 to toggle flags.

## Troubleshooting

### Pods not starting

Check resource availability:
```bash
kubectl describe pod -n otel-demo <pod-name>
kubectl top nodes
```

### No telemetry in collector

1. Verify collector service is reachable:
```bash
kubectl get svc -n olly-collector
```

2. Check service env vars:
```bash
kubectl get deploy -n otel-demo otel-demo-frontend -o jsonpath='{.spec.template.spec.containers[0].env}' | jq
```

3. Check collector logs for incoming data:
```bash
kubectl logs -n olly-collector -l app.kubernetes.io/component=opentelemetry-collector | grep -i "trace\|metric"
```

## References

- [OpenTelemetry Demo Documentation](https://opentelemetry.io/docs/demo/)
- [Demo Architecture](https://opentelemetry.io/docs/demo/architecture/)
- [Kubernetes Deployment Guide](https://opentelemetry.io/docs/demo/kubernetes-deployment/)
- [Service Documentation](https://opentelemetry.io/docs/demo/#service-documentation)
- [Helm Chart Source](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-demo)
