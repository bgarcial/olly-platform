#!/bin/bash
set -e

echo "==> Updating dependencies..."
helm dependency update

echo "==> Linting chart..."
helm lint .

echo "==> Linting with values..."
helm lint . \
  --set opentelemetry-operator.enabled=true \
  --set opentelemetryCollector.enabled=true

echo "==> Rendering all templates..."
helm template test . \
  --set opentelemetry-operator.enabled=true \
  --set opentelemetryCollector.enabled=true > /dev/null

echo "==> Checking individual templates..."
for tpl in serviceaccount clusterrole clusterrolebinding opentelemetry-collector; do
  echo "    - templates/opentelemetry-collector/${tpl}.yaml"
  helm template test . \
    --set opentelemetryCollector.enabled=true \
    --show-only "templates/opentelemetry-collector/${tpl}.yaml" > /dev/null
done

# Skip dry-run if no cluster available
if kubectl cluster-info &> /dev/null; then
  echo "==> Dry-run install..."
  helm install test . \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --set opentelemetry-operator.enabled=true \
    --set opentelemetryCollector.enabled=true \
    --dry-run
else
  echo "==> Skipping dry-run (no cluster connection)"
fi

echo ""
echo "✅ All validations passed!"