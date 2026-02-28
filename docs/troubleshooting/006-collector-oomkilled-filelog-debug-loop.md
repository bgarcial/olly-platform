# 006 — Collector pods OOMKilled after enabling filelog receiver

**Component:** `filelog` receiver + `debug` exporter (logs pipeline)
**Signal:** Logs
**Date first seen:** 2026-02-28
**Status:** Fixed

---

## Symptom

All collector pods (one per node, DaemonSet) are repeatedly OOMKilled within 3–5 minutes
of startup. Increasing the memory limit to 1 Gi does not help — pods die just as fast.

```bash
kubectl get pods -n olly-collector \
  -l app.kubernetes.io/component=opentelemetry-collector \
  -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,LAST_STATE:.status.containerStatuses[0].lastState.terminated.reason,MEM_LIMIT:.spec.containers[0].resources.limits.memory"
```

```
NAME                                           STATUS    RESTARTS   LAST_STATE   MEM_LIMIT
olly-collector-opentelemetry-collector-4t5s4   Running   3          OOMKilled    1Gi
olly-collector-opentelemetry-collector-66fxb   Running   3          OOMKilled    1Gi
olly-collector-opentelemetry-collector-6sdj7   Running   2          OOMKilled    1Gi
olly-collector-opentelemetry-collector-87hl7   Running   3          OOMKilled    1Gi
olly-collector-opentelemetry-collector-bvg7t   Running   3          OOMKilled    1Gi
olly-collector-opentelemetry-collector-h7689   Running   3          OOMKilled    1Gi
olly-collector-opentelemetry-collector-l4jrq   Running   3          OOMKilled    1Gi
```

Confirmed OOMKill (exit code 137):

```bash
kubectl describe pod -n olly-collector \
  -l app.kubernetes.io/component=opentelemetry-collector \
  | grep -A5 "Last State:"
```

```
Last State:  Terminated
  Reason:    OOMKilled
  Exit Code: 137
  Started:   Sat, 28 Feb 2026 05:52:28 +0100
  Finished:  Sat, 28 Feb 2026 05:57:06 +0100
```

---

## How to Surface It

```bash
# Quick check: any OOMKilled collectors?
kubectl get pods -n olly-collector \
  -l app.kubernetes.io/component=opentelemetry-collector \
  --no-headers \
  | awk '$4 ~ /OOM/ || $5 ~ /OOM/ {print}'

# Confirm exit code 137 = OOMKill
kubectl describe pods -n olly-collector \
  -l app.kubernetes.io/component=opentelemetry-collector \
  | grep -E "OOMKilled|Exit Code"

# Check memory pressure via self-telemetry (while pod is alive)
kubectl port-forward -n olly-collector <pod-name> 8888:8888
curl -s http://localhost:8888/metrics \
  | grep -E "otelcol_process_memory|process_resident_memory"
```

---

## Root Cause

Three causes compound each other. The first two are independent problems; the third
makes recovery impossible even with a higher memory limit.

### Cause 1 — `debug` exporter with `verbosity: detailed` on the logs pipeline

The `debug` exporter at `verbosity: detailed` buffers the **full body** of every log record
in memory during the batch window before flushing it to stdout. Container logs from
20–40 files per node (all pods running on that node) accumulate for 10 seconds per batch
cycle. Unlike traces and metrics — which have `sampling_initial` / `sampling_thereafter`
to cap detailed output — the volume of raw log data per batch is proportional to the
number of containers on the node and their log rate.

### Cause 2 — filelog receiver with no `exclude:` watching the collector's own log files

The filelog receiver is configured to watch `/var/log/pods/**/*.log`. This glob matches
every pod on the node, including the collector pods themselves:

```
/var/log/pods/olly-collector_olly-collector-opentelemetry-collector-*/otc-container/*.log
```

The collector writes its own output to stdout/stderr. The container runtime writes that
stdout to the log file above. The filelog receiver picks it up and sends it into the
logs pipeline.

### Cause 3 — Self-collection feedback loop (the amplifier)

Causes 1 and 2 together create a runaway loop:

```
filelog reads /var/log/pods/olly-collector_.../otc-container/N.log
  → batch processor buffers record
    → debug exporter writes full record body to stdout (verbosity: detailed)
      → container runtime writes that stdout to /var/log/pods/olly-collector_.../otc-container/N.log
        → filelog reads it again → loop
```

Each iteration produces a larger record (the debug output from the previous iteration is
now in the body), which produces an even larger debug output on the next iteration. Memory
grows exponentially. The `memory_limiter` processor checks every 1 second but the loop
can generate records faster than it can drop them. No memory limit is large enough to
survive this loop at `verbosity: detailed`.

**Why traces and metrics are not affected:**
Traces and metrics enter the collector through the OTLP receiver (ports 4317/4318) — they
are pushed over the network by applications. The debug exporter output for those signals
goes to stdout, but the filelog receiver only reads log files on disk, not the OTLP
receiver's input. There is no feedback path for traces or metrics.

---

## Fix Applied

Two changes to `values.yaml`.

### 1. Remove `debug` from the logs pipeline

The debug exporter serves no purpose in the logs pipeline once a real exporter (Loki) is
in use. Removing it eliminates Cause 1 and breaks the feedback loop:

```yaml
service:
  pipelines:
    logs:
      receivers:
        - filelog
      processors:
        - memory_limiter
        - k8sattributes
        - batch
        - resource
      exporters:
        - otlphttp/logs   # debug removed — no detailed stdout for log records
```

The `debug` exporter is **kept** on the `traces` and `metrics` pipelines. Those pipelines
are safe because:
- No feedback loop (OTLP receiver, not filelog)
- `sampling_initial: 5` + `sampling_thereafter: 200` caps detailed output volume

### 2. Exclude the collector's own namespace from the filelog `include` glob

Even without the debug exporter, collecting the collector's own logs is wasteful and
creates unnecessary cardinality in Loki. Exclude it permanently:

```yaml
filelog:
  include:
    - /var/log/pods/**/*.log
  exclude:
    - /var/log/pods/olly-collector_*/**   # never tail the collector's own pod logs
  include_file_path: true
  start_at: end
  operators:
    - id: container-parser
      type: container
```

The `exclude:` glob matches the Kubernetes log path format:
`/var/log/pods/<namespace>_<pod-name>_<uid>/<container>/<N>.log`

Prefixing with `olly-collector_` matches any pod in the `olly-collector` namespace
regardless of pod name or UID.

---

## Why Increasing the Memory Limit Does Not Help

The feedback loop's memory growth is unbounded — each cycle produces more data than the
last. A higher limit only delays the OOMKill by a few minutes. The only fix is breaking
the loop by removing the debug exporter from the logs pipeline or excluding self-collection
(or both, which is the recommended approach).

---

## Values Location

[charts/olly-collector/values.yaml](../../charts/olly-collector/values.yaml) —
`filelog:` under `receivers:`, `debug:` under `exporters:`, `logs:` under
`service.pipelines:`.
