# Olly collector

This chart contains agents that scrape and collect telemetry (logs, metrics, traces) and sends them to signals backend.


# Prerequisites

1. cert-manager (Required) - <https://cert-manager.io/docs/installation/helm/#installing-from-the-oci-registry>

The operator uses admission webhooks that require cert-manager:

```
helm install \
  cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.19.2 \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

2. Install Kyverno - <https://kyverno.io/docs/installation/methods/#high-availability-installation>

- Add the helm chart repository

```sh
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
```

- High Availability Installation

```sh
helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
--set admissionController.replicas=3 \
--set backgroundController.replicas=2 \
--set cleanupController.replicas=2 \
--set reportsController.replicas=2
```

When trying to deploy the Instrumentation resource through the kyverno policy I got this issue

```sh
 helm upgrade olly-collector . \
--namespace olly-collector   
level=WARN msg="upgrade failed" name=olly-collector error="failed to create resource: admission webhook \"validate-policy.kyverno.svc\" denied the request: path: spec.rules[0].generate..: system:serviceaccount:kyverno:kyverno-admission-controller requires permissions list,get for resource opentelemetry.io/v1alpha1/Instrumentation in namespace {{ request.object.metadata.name }}"
Error: UPGRADE FAILED: failed to create resource: admission webhook "validate-policy.kyverno.svc" denied the request: path: spec.rules[0].generate..: system:serviceaccount:kyverno:kyverno-admission-controller requires permissions list,get for resource opentelemetry.io/v1alpha1/Instrumentation in namespace {{ request.object.metadata.name }
```

This is happening because Kyverno admission controller service account need to get to know about the `Instrumentation` Resource and need to get granted access to that CRD, otherwise when the cluster policy tries to generate the Instrumentation resource  kyverno says it does not have permissions

The cleanest way is to add those permissions via the kyverno helm chart itself
<https://github.com/kyverno/kyverno/blob/main/charts/kyverno/templates/admission-controller/clusterrole.yaml>
<https://github.com/kyverno/kyverno/blob/main/charts/kyverno/values.yaml#L797-L858>

- I created a values.yaml file to override that clusterrole definition on the upstream helm chart

```sh
 helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  -f infrastructure/kyverno/values.yaml
Release "kyverno" has been upgraded. Happy Helming!
NAME: kyverno
LAST DEPLOYED: Mon Jan 26 23:43:24 2026
NAMESPACE: kyverno
STATUS: deployed
REVISION: 2
DESCRIPTION: Upgrade complete
NOTES:
Chart version: 3.6.2
Kyverno version: v1.16.2

Thank you for installing kyverno! Your release is named kyverno.

The following components have been installed in your cluster:
- CRDs
- Admission controller
- Reports controller
- Cleanup controller
- Background controller
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




