# Auto-Instrumentation Sequence

Shows the timeline of events from pod creation to telemetry flowing through the collector. Covers both the one-time setup phase and the per-pod runtime phase.

## Setup Phase (One Time — Helm Install)

```mermaid
sequenceDiagram
    actor Operator as Platform Operator
    participant Helm as Helm
    participant K8s as Kubernetes API
    participant Kyverno as Kyverno
    participant OtelOp as OTel Operator
    participant Collector as OTel Collector DaemonSet

    Operator->>Helm: helm install olly-collector charts/olly-collector
    Helm->>K8s: Create OpenTelemetryCollector CR (DaemonSet mode)
    Helm->>K8s: Create ClusterPolicy (sync-instrumentation + sync-instrumentation-full)
    Helm->>K8s: Deploy OTel Operator (2 replicas)

    K8s->>OtelOp: Reconcile OpenTelemetryCollector CR
    OtelOp->>K8s: Create Collector DaemonSet + Service + RBAC
    K8s->>Collector: Schedule one pod per node

    Note over Kyverno,K8s: For every existing and new namespace<br/>(except default, kube-system, kube-node-lease, kube-public)

    Kyverno->>K8s: Generate Instrumentation CR: olly-collector (traces only)
    Kyverno->>K8s: Generate Instrumentation CR: olly-collector-full (traces + metrics)
```

## Runtime Phase (Per Pod)

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant K8s as Kubernetes API
    participant Webhook as Admission Webhook<br/>(OTel Operator)
    participant OtelOp as OTel Operator
    participant Pod as Application Pod
    participant Collector as OTel Collector<br/>(same node)
    participant Tempo as Tempo (TBD)
    participant Mimir as Mimir (TBD)

    Dev->>K8s: kubectl apply pod.yaml
    Note over Dev,K8s: Pod spec includes annotation:<br/>instrumentation.opentelemetry.io/inject-java: "olly-collector"

    K8s->>Webhook: Admission request (MutatingWebhook)
    Webhook->>OtelOp: Forward for mutation

    OtelOp->>K8s: Fetch Instrumentation CR "olly-collector" from pod's namespace
    Note over OtelOp: CR specifies:<br/>- exporter endpoint: :4318 (HTTP)<br/>- OTEL_METRICS_EXPORTER=none<br/>- Java image: autoinstrumentation-java:2.21.0

    OtelOp->>Webhook: Return mutated pod spec
    Note over OtelOp,Webhook: Mutations added:<br/>1. Init container (copies Java agent JAR)<br/>2. OTEL_* env vars set<br/>3. JAVA_TOOL_OPTIONS=-javaagent:/otel-auto-instrumentation/javaagent.jar

    Webhook->>K8s: Admission response (allow + patch)
    K8s->>Pod: Schedule mutated pod on a node

    Pod->>Pod: Init container runs → copies agent JAR
    Pod->>Pod: App container starts with Java agent attached
    Pod->>Collector: OTLP HTTP :4318 — Traces (Metrics disabled by default CR)

    Collector->>Collector: memory_limiter → filter/drop_noisy → k8sattributes → batch → resource
    Collector->>Tempo: OTLP HTTP — Traces (when backend configured)
```

## Switching to Full Instrumentation (Traces + Metrics)

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant K8s as Kubernetes API
    participant OtelOp as OTel Operator
    participant Pod as Java Pod
    participant Collector as OTel Collector
    participant Mimir as Mimir

    Note over Dev: Change annotation value from<br/>"olly-collector" → "olly-collector-full"
    Dev->>K8s: kubectl rollout restart deployment/java-app

    K8s->>OtelOp: Admission webhook (new pod)
    OtelOp->>K8s: Fetch Instrumentation CR "olly-collector-full"
    Note over OtelOp: Full CR: OTEL_METRICS_EXPORTER NOT set<br/>→ metrics flow through

    OtelOp->>Pod: Inject agent (metrics enabled)
    Pod->>Collector: OTLP HTTP :4318 — Traces + Metrics
    Collector->>Mimir: OTLP HTTP — Metrics (JVM, HTTP, DB pool)
```

## Key Timing Notes

| Event | Trigger | Latency |
|-------|---------|---------|
| ClusterPolicy generates Instrumentation CRs | Namespace creation | ~1-5s |
| OTel Operator mutates pod | Pod admission | ~100-500ms |
| Collector starts receiving spans | App container starts | Seconds |
| k8sattributes enriches spans | After pod IP registered | ~5-30s (kube-state-sync) |
| VPA recommends resource adjustments | After ~30min of traffic | 30+ minutes |
