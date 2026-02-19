# Versioning and Debugging

## Version Bump Rules

**Version bump required when**:
- Any template file changes
- `values.yaml` changes
- `Chart.yaml` changes (except comments)
- Dependency updates

**Current workflow** (v0.0.1 — no validation script yet):

```bash
# 1. Bump version in Chart.yaml
# 2. Add entry to CHANGELOG.md (create it if it doesn't exist)
# 3. Validate with helm lint + helm template
./charts/olly-collector/helm-validate.sh
```

## CHANGELOG Format

Create `charts/olly-collector/CHANGELOG.md` on the first version bump:

```markdown
## [v0.1.0] - YYYY-MM-DD

### Added
- New feature description

### Changed
- Modification description

### Fixed
- Bug fix description

### Removed
- Removed feature description
```

### Breaking Changes

Breaking changes **must** include these additional sections:

```markdown
## [vX.Y.Z] - YYYY-MM-DD

### Changed
- Description of the breaking change

#### BREAKING CHANGES
Explain what changed and why.

#### Impact
What happens to existing deployments. What breaks.

##### Mitigation Action
Concrete steps users must take:
1. Step one
2. Step two
```

## Debugging

### View Rendered Manifests

```bash
# Full render
helm template test charts/olly-collector \
  --set opentelemetry-operator.enabled=true \
  --set opentelemetryCollector.enabled=true

# Full render with debug info
helm template test charts/olly-collector \
  --set opentelemetryCollector.enabled=true \
  --debug

# Specific template only
helm template test charts/olly-collector \
  --set opentelemetryCollector.enabled=true \
  --show-only "templates/opentelemetry-collector/opentelemetry-collector.yaml"

# ClusterPolicy template
helm template test charts/olly-collector \
  --set opentelemetryCollector.enabled=true \
  --set opentelemetryCollector.instrumentation.enabled=true \
  --show-only "templates/opentelemetry-collector/clusterpolicy.yaml"
```

### Check Collector Logs

```bash
kubectl logs -l app.kubernetes.io/name=opentelemetry-collector -n observability -f
```

### Verify Pipeline Config

```bash
kubectl get opentelemetrycollector -n observability -o yaml
```

### Check Kyverno Policy Status

```bash
kubectl get clusterpolicy -l app.kubernetes.io/name=olly-collector
kubectl describe clusterpolicy <policy-name>
```

### Verify Instrumentation CRs

```bash
# Check if synced to a namespace
kubectl get instrumentation -n <namespace>

# Full CR content
kubectl get instrumentation olly-collector -n <namespace> -o yaml
kubectl get instrumentation olly-collector-full -n <namespace> -o yaml
```

### Validate Syntax

```bash
helm lint charts/olly-collector
```

### Validate with helm-validate.sh

```bash
./charts/olly-collector/helm-validate.sh
```

### Debug Auto-Instrumentation Injection

```bash
# Check if pod got instrumented (look for init containers)
kubectl describe pod <pod-name> -n <namespace>

# Check operator logs
kubectl logs -l app.kubernetes.io/name=opentelemetry-operator -n observability -f

# Verify the Instrumentation CR the pod resolved
kubectl get instrumentation -n <namespace>
```

### Check Collector Self-Metrics (Port 8888)

```bash
# Port-forward to the collector's Prometheus endpoint
kubectl port-forward -n observability ds/olly-collector-opentelemetry-collector 8888:8888

# Then in another terminal:
curl -s localhost:8888/metrics | grep otelcol_receiver_accepted
curl -s localhost:8888/metrics | grep otelcol_exporter_sent
```

### Verify VPA Status

```bash
kubectl get vpa -n observability
kubectl describe vpa olly-collector -n observability
```

## Dependency Management

```bash
# Update all dependencies
helm dependency update charts/olly-collector

# List current dependencies
helm dependency list charts/olly-collector
```

## Dry-Run Install (Requires Cluster Connection)

```bash
helm install test charts/olly-collector \
  --namespace observability \
  --create-namespace \
  --set opentelemetry-operator.enabled=true \
  --set opentelemetryCollector.enabled=true \
  --dry-run
```
