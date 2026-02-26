# How to Deploy `olly-collector`

**Why not `helm upgrade`?**
The `opentelemetry-operator` sub-chart embeds its CRDs inside `conf/crds/` (924 KB uncompressed). Helm serialises the full chart source into a Kubernetes Secret per release; once the Secret exceeds the 1 MB Kubernetes limit, `helm upgrade` fails permanently. See [troubleshooting/helm/001](../troubleshooting/helm/001-helm-release-secret-too-large.md) for the full root-cause analysis.

The fix is to mimic what ArgoCD does: render with `helm template`, apply with `kubectl`. No `sh.helm.release.v1.*` Secrets are created, so the 1 MB limit is never hit.

---

## Prerequisites

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
  --from-literal=GRAFANA_CLOUD_TOKEN='<grafana-cloud-api-token>'
```

Where to find each value in Grafana Cloud:

| Key | Where to find it |
|-----|-----------------|
| `GRAFANA_CLOUD_TEMPO_USER` | Stack page → Tempo → Username (numeric ID, e.g. `153770`) |
| `GRAFANA_CLOUD_MIMIR_USER` | Stack page → Prometheus → Username (numeric ID, e.g. `316580`) |
| `GRAFANA_CLOUD_TOKEN` | Stack page → Access Policies → create a token with `metrics:write`, `traces:write` scopes |

**What happens if the secret is missing or wrong:**

| Scenario | Behaviour |
|----------|-----------|
| Secret does not exist | Pods fail at container creation with `CreateContainerConfigError` — they never start. Kubernetes refuses to inject the env vars. |
| Secret exists, wrong credentials | Pods start and the collector runs, but every export to Tempo/Mimir fails with HTTP `401 Unauthorized`. |

To verify the secret exists before deploying:

```bash
kubectl get secret grafana-cloud-credentials -n olly-collector
```

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

This idempotently creates or updates: CRDs, RBAC, the Operator Deployment, Promtail DaemonSet, VPA, ServiceAccounts, Certificates, and the OpenTelemetryCollector CR.

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

## Does the DaemonSet restart automatically?

**Yes.** You do not need `kubectl rollout restart` after a deploy.

When the CR spec changes, the OTel Operator reconciles immediately:

1. Operator detects the CR update.
2. Operator writes a new ConfigMap containing the rendered collector config.
3. Operator updates the DaemonSet pod template annotation with the new ConfigMap hash.
4. The DaemonSet controller triggers a rolling update automatically.

To monitor (not trigger) the rollout:

```bash
kubectl rollout status daemonset/olly-collector-opentelemetry-collector \
  -n olly-collector
```

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

---

## Quick reference

| Scenario | Command |
|----------|---------|
| Config change (values, processors, exporters) | Step 1 + Step 2 |
| First install | Step 1 only (CR does not exist yet for Step 2) |
| Operator version bump | CRD update, then Step 1 + Step 2 |
| Monitor rollout | `kubectl rollout status daemonset/...` |
| Verify no errors | `kubectl logs -l app.kubernetes.io/name=olly-collector-opentelemetry-collector -n olly-collector --since=2m \| grep '"level":"error"'` |
