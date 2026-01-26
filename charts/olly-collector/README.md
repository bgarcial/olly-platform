# Olly collector

This chart contains agents that scrape and collect telemetry (logs, metrics, traces) and sends them to signals backend.


# Prerequisites

1. cert-manager (Required)

The operator uses admission webhooks that require cert-manager:

```
# Add jetstack repo
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager with CRDs
helm install cert-manager jetstack/cert-manager \
--namespace cert-manager \
--create-namespace \
--set crds.enabled=true

Verify cert-manager is ready:
kubectl get pods -n cert-manager
# Wait for all pods to be Running
```

2. Installing OpenTelemetry Operator

Add the Helm Repository

```
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

# Agents

## opentelemetry-operator

When enabled, installs the opentelemetry-operator and its CRDs. Required if you want to enable the opentelemetry-collector, unless you install the operator in a different way.

## opentelemetry-collector

When enabled, installs an opentelemetry-collector daemonset with a Kubernetes Service. This Service can be configured as the opentelemetry endpoint in client otel instrumented applications.

The service is called `olly-collector-opentelemetry-collector` and is available on ports 4317 (OTLP-GRPC) and 4318 (OTLP-HTTP)

The `OpenTelemetryCollector` CRD is used as it is provided by the Otel Operator, which is installed first as a dependency of this olly-helm chart. 

<!-- Additionally, if Kyverno is installed in the cluster, enabling the opentelemetry-collector will also install a Kyverno ClusterPolicy. This ClusterPolicy will generate an `Instrumentation` resource in every Namespace. This `Instrumentation` can be used to auto-instrument your application with the opentelemetry SDK. Auto-instrumented applications' metrics and traces are automatically sent to the opentelemetry-collector daemonset, where they will be batched and shipped to upstream Otel collectors. For example, to enable auto-instrumentation for your Java application, annotate your pods as such: `instrumentation.opentelemetry.io/inject-java: olly-collector` -->

### Installation

- First install, disable the collector as it needs the `OpenTelemetryCollector` CRD provided by the Operator

```sh
helm install olly-collector . \
--namespace olly-collector \
--create-namespace \
--set opentelemetry-operator.enabled=true \
--set opentelemetryCollector.enabled=false 
```

- Then upgrade to enable the collector:

```sh
helm upgrade olly-collector . \
--namespace olly-collector \
--set opentelemetry-operator.enabled=true \
--set opentelemetryCollector.enabled=true 
```

# Configuration

## Examples

This same directory contains several example configurations for the olly-collector chart, named `values.*.yaml`.

The [values.default.yaml](values.default.yaml) file is for reference or starting point. Its configuration should be re-usable for almost all use-cases.

## Cluster label

`global.cluster`

Regardless of which agents you enable, you **must** always set this to a value that uniquely identifies your Kubernetes cluster. This value is manually chosen by the person managing the cluster, it is not derived automatically from Kubernetes.

<!-- In the case of logs collected by promtail, this will populate the Loki label called `cluster` -->

In the case of logs/metrics/traces collected by the opentelemetry-collector, this will populate the attribute/label `k8s.cluster.name`

The cluster label should look like this `${platform}-${team}-${environment}`. For example like this: `olly-personal-nonprd`




