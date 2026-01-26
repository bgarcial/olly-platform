# Deploying VPA 

VPA needs metrics server to pulls resource usage data to generate its recommendations.
I might want to explore in the future Prometheus Adapter.

## Deploying Metrics Server

I am deploying it using [this helm chart](https://artifacthub.io/packages/helm/metrics-server/metrics-server)

```sh
helm upgrade --install metrics-server --namespace kube-system metrics-server/metrics-server
```

Got this error
```sh
│ rtificate for 10.89.0.19 because it doesn't contain any IP SANs" node="k8s-test-cluster-worker4"                                                                                          │
│ E0125 17:08:50.272174       1 scraper.go:149] "Failed to scrape node" err="Get \"https://10.89.0.16:10250/metrics/resource\": tls: failed to verify certificate: x509: cannot validate ce │
│ rtificate for 10.89.0.16 because it doesn't contain any IP SANs" node="k8s-test-cluster-worker6"                                                                                          │
│ I0125 17:08:50.781642       1 server.go:192] "Failed probe" probe="metric-storage-ready" err="no metrics to serve"                                                                        │
│ I0125 17:09:00.783773       1 server.go:192] "Failed probe" probe="metric-storage-ready" err="no metrics to serve" 
```

Metrics Server connects to each kubelet over HTTPS (port 10250) to scrape resource metrics. My kubelets' TLS certificates don't include their IP addresses in the Subject Alternative Names (SANs). This is extremely common in Kind K8s clusters. Add the `--kubelet-insecure-tls` flag to skip certificate validation when talking to kubelets.

```sh
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args={--kubelet-insecure-tls}
```

Consider [hardening the metrics server with cert manager](https://github.com/kubernetes-sigs/metrics-server/tree/master/charts/metrics-server#hardening-metrics-server)

## Deploying Vertical Pod Autoscaler

I am using [this helm chart](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler/charts/vertical-pod-autoscaler#helm-installation--upgrade)

```sh
helm upgrade -i vertical-pod-autoscaler autoscalers/vertical-pod-autoscaler \
  --namespace vpa \
  --create-namespace
```

