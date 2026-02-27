# Discover Kubernetes Log Paths for the Filelog Receiver

How to identify the correct host paths for collecting container logs
using the OpenTelemetry filelog receiver or Promtail.

## Why this matters

When configuring a log collector (filelog receiver, Promtail, Fluentd) on Kubernetes,
you need to know **where the kubelet writes container logs on the node filesystem**.
The collector runs as a DaemonSet with the host's `/var/log` mounted,
so it reads from the node — not from inside containers.

Getting the path wrong means the collector silently collects nothing.

## Debug a node to find the log paths

Use `kubectl debug` to get a shell on the node's host filesystem:

```bash
kubectl debug node/<node-name> -it --image=busybox -- chroot /host /bin/sh
```

Once inside, list `/var/log`:

```
/host/var/log # ls
alternatives.log    containers    pods
```

Two directories hold container logs: `containers/` and `pods/`.

### `/var/log/pods/` — the real log files

This is where the kubelet writes container stdout/stderr. The structure is:

```
/var/log/pods/<namespace>_<pod-name>_<pod-uid>/<container-name>/<restart-count>.log
```

Example listing:

```
/var/log/pods # ls
default_node-debugger-k8s-test-cluster-worker2-xr6z5_5980b7fd-9bad-47b7-885a-f48322a995c6
kube-system_kindnet-8rq54_058bbc81-65c9-4d78-b61b-60f8a5b3daaa
kube-system_kube-proxy-w6mjx_72a1402c-5b15-466b-bddb-21634970a086
kyverno_kyverno-admission-controller-fc7dfbd96-vvtcm_7f341632-1391-4546-8c29-cfcab8e977ea
kyverno_kyverno-background-controller-77dd9bf74f-6d2x2_c505843b-8072-4288-bd14-5857aafe8ea6
kyverno_kyverno-cleanup-controller-6bbc664866-qlhk7_cb324401-c28e-467c-bf59-19232eb307ac
olly-collector_olly-collector-opentelemetry-collector-jlmg4_0a49af1f-23fe-40e6-a52d-8e4844fd1f07
olly-collector_olly-collector-promtail-rm72r_2ea15c87-27a1-4b3c-8c51-35b49029b4f1
olly-collector_opentelemetry-operator-5bbd967979-nhgvx_f46eccd3-ef90-4492-9158-11af67088e01
olly-collector_opentelemetry-operator-cert-manager_c68aa0ba-5b15-409a-9447-21b9e9c4bde5
otel-demo_fraud-detection-56b8958754-psk5q_2faf71db-b643-4a9a-80f5-f6a4b09dc498
otel-demo_load-generator-845894f7d9-n5mwx_fcb2bf50-6d5f-4d9b-8f6f-7cdf58f6f9ac
```

Each directory contains one subdirectory per container, and inside that
the log file named by restart count (usually `0.log`):

```
/var/log/pods/otel-demo_fraud-detection-56b8958754-psk5q_.../fraud-detection/0.log
```

### `/var/log/containers/` — symlinks only

This directory contains a flat list of symlinks pointing back to `/var/log/pods/`.
The naming convention is:

```
<pod-name>_<namespace>_<container-name>-<container-id>.log
  → /var/log/pods/<namespace>_<pod-name>_<uid>/<container-name>/<restart>.log
```

Example:

```
fraud-detection-56b8958754-psk5q_otel_demo_fraud-detection-2706715...afa.log
  → ../../pods/otel-demo_fraud-detection-56b8958754-psk5q_.../fraud-detection/0.log
```

This directory exists for backward compatibility. The real data lives under `pods/`.

## Correct path for the filelog receiver

Use the `pods/` path with a recursive glob:

```yaml
receivers:
  filelog:
    include:
      - /var/log/pods/**/*.log
```

This matches all `.log` files under any depth inside `/var/log/pods/`,
covering the `<namespace>_<pod>_<uid>/<container>/<restart>.log` structure.

### Why not `/var/log/containers/*.log`?

It works (the symlinks resolve), but:

- Symlinks add an extra layer of indirection
- Some collectors handle symlink rotation differently, which can cause missed or duplicated lines
- `/var/log/pods/` is the canonical source

### Why not `/var/log/*/*/*.log`?

The `/var/log/` directory contains other files (`alternatives.log`, etc.)
and only two relevant subdirectories (`containers/`, `pods/`).
A broad glob like `/var/log/*/*/*.log` would try to match against non-container
log files and miss the correct depth under `pods/` (which needs `**` to recurse
through `<pod-dir>/<container-dir>/`).

## DaemonSet volume mount

The collector DaemonSet must mount the host's `/var/log` as a `hostPath` volume:

```yaml
volumes:
  - name: varlog
    hostPath:
      path: /var/log
      type: Directory
volumeMounts:
  - name: varlog
    mountPath: /var/log
    readOnly: true
```

This gives the collector access to the node's log directory where the kubelet
writes pod logs, regardless of what `/var/log` looks like inside individual containers.
