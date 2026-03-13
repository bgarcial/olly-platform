# How to Deploy `olly-collector`

**Why not `helm upgrade`?**
The `opentelemetry-operator` sub-chart embeds its CRDs inside `conf/crds/` (924 KB uncompressed). Helm serialises the full chart source into a Kubernetes Secret per release; once the Secret exceeds the 1 MB Kubernetes limit, `helm upgrade` fails permanently. See [this issue](https://github.com/bgarcial/olly-platform/issues/3)

---

## Prerequisites

### VPA (Vertical Pod Autoscaler)

The collector uses a VPA resource to right-size pod memory. VPA (and its dependency, Metrics Server) must be installed before deploying the chart. See [VPA setup instructions](../VPA.md).

### Kyverno

The chart includes a `ClusterPolicy` that propagates `Instrumentation` CRs to application namespaces. Kyverno must be installed before deploying the chart, otherwise the `ClusterPolicy` resource will fail to apply.

Install Kyverno using the [kyverno Helm chart](https://artifacthub.io/packages/helm/kyverno/kyverno) with the custom values in [`infrastructure/kyverno/values.yaml`](../../infrastructure/kyverno/values.yaml):

```bash
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  -f infrastructure/kyverno/values.yaml
```

The custom values grant the admission and background controllers RBAC permissions on `opentelemetry.io/instrumentations` so Kyverno can generate and synchronize the Instrumentation CRs across namespaces.

### Grafana Cloud credentials secret

The collector pods mount credentials from a Kubernetes Secret named `grafana-cloud-credentials`.
This secret must exist in the `olly-collector` namespace **before** the pods start — they will
crash on startup if it is missing.

Create it once manually (values come from your Grafana Cloud stack page):

```bash
kubectl create secret generic grafana-cloud-credentials \
  --namespace olly-collector \
  --from-literal=GRAFANA_CLOUD_TEMPO_USER='<tempo-datasource-id>' \
  --from-literal=GRAFANA_CLOUD_MIMIR_USER='<mimir-datasource-id>' \
  --from-literal=GRAFANA_CLOUD_LOKI_USER='<loki-datasource-id>' \
  --from-literal=GRAFANA_CLOUD_TOKEN='<grafana-cloud-api-token>'
```

Where to find each value in Grafana Cloud:

| Key | Where to find it |
|-----|-----------------|
| `GRAFANA_CLOUD_TEMPO_USER` | Stack page → Tempo → Username (numeric ID, e.g. `153770`) |
| `GRAFANA_CLOUD_MIMIR_USER` | Stack page → Prometheus → Username (numeric ID, e.g. `316580`) |
| `GRAFANA_CLOUD_LOKI_USER` | Stack page → Loki → Username (numeric ID) |
| `GRAFANA_CLOUD_TOKEN` | Stack page → Access Policies → create a token with `metrics:write`, `traces:write`, `logs:write` scopes |

**Create the secrets before deploying the collector**

**Secret management roadmap:**
This secret is currently created manually and is not managed by Helm. The plan is to:
1. Add it as a Helm-managed `Secret` template (so it is declared alongside the chart)
2. Migrate to [External Secrets Operator](https://external-secrets.io/) backed by a cloud
   KeyVault (e.g. Azure Key Vault, AWS Secrets Manager) so the actual credential values
   are never stored in the cluster or in Git.

---

## Standard deploy (every change)

> **Working directory**: all commands below must be run from the **repository root**
> (`~/workspace/personal/o11y-platform`), not from inside `charts/olly-collector/`.
> The path `charts/olly-collector` in the commands is relative to the repo root.

Run both steps in order. Step 1 handles all Kubernetes resources. Step 2 force-overwrites the OpenTelemetryCollector CR to avoid three-way merge artefacts.

### Step 1 — apply everything

```bash
helm template olly-collector charts/olly-collector \
  --namespace olly-collector \
  --set opentelemetry-operator.enabled=true \
  --set opentelemetryCollector.enabled=true \
  | kubectl apply -n olly-collector -f -
```

This idempotently creates or updates: CRDs, RBAC, the Operator Deployment, VPA, ServiceAccounts, Certificates, and the OpenTelemetryCollector CR.

### Step 2 — replace the CR (conditional)

```bash
helm template olly-collector charts/olly-collector \
  --namespace olly-collector \
  --set opentelemetryCollector.enabled=true \
  --show-only templates/opentelemetry-collector/opentelemetry-collector.yaml \
  | kubectl replace -n olly-collector -f -
```

**When you need this step:**

`kubectl apply` uses a three-way merge tracked via the `last-applied-configuration` annotation. It correctly adds new keys and removes old ones — *as long as* the annotation is current. The annotation goes stale whenever the CR is touched by a tool that does not set it: `helm upgrade`, `kubectl replace`, or `kubectl edit`.

| Change type | Step 2 needed? |
|-------------|---------------|
| Changing a value (timeout, endpoint, batch size) | No — Step 1 is enough |
| Adding a new exporter or processor | No — Step 1 is enough |
| **Renaming a component** (e.g. `otlp/traces` → `otlphttp/traces`) | **Yes** — `kubectl apply` cannot remove the old key if it was not in the last annotation |
| **Removing a component entirely** | **Yes** — same reason |
| After any `kubectl replace` or `kubectl edit` on the CR | **Yes** — those tools overwrite the annotation |

`kubectl replace` overwrites the entire spec with no merge, guaranteeing the live CR matches exactly what is in `values.yaml`.

> **First install only**: `kubectl replace` fails if the resource does not exist yet. Step 1's `kubectl apply` creates it, so Step 2 succeeds from the second deploy onwards.

---

## Updating CRDs when bumping the operator version

CRDs must be applied with `--server-side` to handle large objects (the OTel CRDs exceed the client-side apply annotation limit).

```bash
helm template olly-collector charts/olly-collector \
  --set opentelemetry-operator.enabled=true \
  --set opentelemetry-operator.crds.create=true \
  --show-only charts/opentelemetry-operator/templates/admission-webhooks/operator-webhook.yaml \
| kubectl apply --server-side -f -
```

Run this before the standard deploy when `opentelemetry-operator.version` changes in `Chart.yaml`.
