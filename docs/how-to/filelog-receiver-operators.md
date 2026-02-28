# Filelog Receiver Operators

How the filelog receiver works, what operators do, and how to configure them correctly for
Kubernetes container logs — including mixed-format logs from the OpenTelemetry Demo.

---

## What the Filelog Receiver Does

The `filelog` receiver tails files on disk (like `/var/log/pods/**/*.log`) and emits one
log record per line. That raw line is the `body` of the record. Without operators, every
record arrives as an unstructured string — no timestamp, no severity, no Kubernetes metadata.

**Operators** are the transformation pipeline that runs on each record as it is read, before
it reaches the collector's processor pipeline. They parse, enrich, filter, and reshape the
record in place.

```
disk file line
  → filelog receiver reads it → body = raw string
      → operator 1 (container) → strips or remove the CRI wrapper, extracts k8s metadata
      → operator 2 (json_parser) → parses body if JSON, promotes fields
      → operator 3 (severity_parser) → maps level/severity field → LogRecord.SeverityText
      → ...
  → log record enters processor pipeline (batch, resource, etc.)
  → exporter sends to Loki
```

Operators run **inside the receiver**, not in the processor pipeline. They see one record at
a time and can read/write any field.

---

## What Operators Are Available

Operators are grouped by function:

### Parsers — interpret raw bytes into structured fields

| Operator | What it does |
|---|---|
| `container` | Parses Kubernetes CRI / Docker log wrapper; extracts k8s metadata from file path |
| `json_parser` | Parses body (or any field) as JSON, promotes keys into attributes |
| `regex_parser` | Extracts named groups from a string using a regex |
| `key_value_parser` | Parses `key=value key2=value2` style logs |
| `csv_parser` | Parses comma-separated values |
| `syslog_parser` | Parses RFC 3164 / RFC 5424 syslog format |
| `uri_parser` | Parses URI components from a field |
| `severity_parser` | Reads a field and maps it to `LogRecord.SeverityText` + `SeverityNumber` |
| `time_parser` | Reads a field and maps it to `LogRecord.Timestamp` |
| `trace_parser` | Reads `trace_id` / `span_id` fields and maps to log record trace context |
| `scope_name_parser` | Extracts instrumentation scope name |

### Transformers (general purpose on the docs) — mutate fields without parsing

| Operator | What it does |
|---|---|
| `add` | Inserts a new field with a fixed or expression value |
| `copy` | Duplicates a field to another path |
| `move` | Renames / relocates a field |
| `remove` | Deletes a field |
| `retain` | Keeps only specified fields, drops everything else |
| `flatten` | Flattens a nested map into dot-separated keys |
| `unquote` | Strips surrounding quotes from a string field |
| `regex_replace` | Substitutes content within a field using a regex |
| `sanitize_utf8` | Replaces invalid UTF-8 bytes |
| `assign_keys` | Assigns names to positional array values |

### Routing and control (also general purpose on the docs)

| Operator | What it does |
|---|---|
| `router` | Sends records to different downstream operators based on a condition |
| `filter` | Drops records that match a condition |
| `recombine` | Merges fragmented multi-line entries into one record |
| `noop` | Pass-through, useful for testing pipelines |

Every operator accepts an `if:` expression that makes it conditional — the operator only
runs when the expression evaluates to true for the current record.

---

## The Kubernetes Container Log Problem

Every log line produced by a container in Kubernetes is wrapped by the container runtime
before it reaches `/var/log/pods/`. The raw bytes on disk are **not** the application log —
they include a runtime-specific envelope.

### CRI format (containerd / CRI-O — what most clusters use)

```
2026-02-27T05:11:02.123456789Z stdout F {"level":"info","msg":"processing request","trace_id":"abc123"}
```

Fields from left to right:
1. **Timestamp** — RFC 3339 nanosecond precision
2. **Stream** — `stdout` or `stderr`
3. **Log tag** — `F` = full line, `P` = partial (line was split, more chunks follow)
4. **Actual log body** — whatever the application wrote

### Docker format

```json
{"log":"starting server\n","stream":"stdout","time":"2026-02-27T05:11:02.123456789Z"}
```

A JSON object with three keys: `log`, `stream`, `time`.

### What happens without a CRI parser

If you run `json_parser` on the raw CRI line:

```
2026-02-27T05:11:02.123456789Z stdout F {"level":"info",...}
```

The parser sees `2026-02-27T...` — not valid JSON. It errors on every line. You lose
all your logs.

If you run `json_parser` on a raw Docker line, it succeeds but you get the outer Docker
object (`log`, `stream`, `time`) rather than the application fields inside `log`.

**You must strip the runtime wrapper first.**

---

## The `container` Operator

The `container` operator was introduced specifically to solve this. It:

1. **Auto-detects** the runtime format (Docker JSON vs CRI-O vs containerd) per line
2. **Strips the wrapper** and sets `body` to the application log content only
3. **Extracts the timestamp** from the wrapper into `LogRecord.Timestamp`
4. **Extracts the stream** (`stdout`/`stderr`) into `attributes["log.iostream"]`
5. **Reassembles partial logs** — CRI splits lines longer than ~16 KB across multiple
   records with tag `P`; `container` buffers and recombines them into one record
6. **Extracts Kubernetes metadata from the file path** when `include_file_path: true` is set

From the file path `/var/log/pods/otel-demo_frontend-7d9b8c4f9-xkj2p_abc123/frontend/0.log`
the operator extracts:
- `k8s.namespace.name` = `otel-demo`
- `k8s.pod.name` = `frontend-7d9b8c4f9-xkj2p`
- `k8s.pod.uid` = `abc123`
- `k8s.container.name` = `frontend`
- `k8s.container.restart_count` = `0`

These become **resource attributes** on the log record, alongside whatever the `k8sattributes`
processor will later add in the processor pipeline.

### Required host path volume mounts

The filelog receiver runs inside a container. `/var/log/pods` is on the **node's
filesystem**, not inside the container. Without explicitly mounting it, the receiver looks
for files at a path that does not exist from its perspective and emits:

```
"msg":"finding files","error":"no files match the configured criteria"
```

Two host paths must be mounted:

```yaml
volumeMounts:
  - name: varlogpods
    mountPath: /var/log/pods
    readOnly: true
  - name: varlibdockercontainers
    mountPath: /var/lib/docker/containers
    readOnly: true
volumes:
  - name: varlogpods
    hostPath:
      path: /var/log/pods
  - name: varlibdockercontainers
    hostPath:
      path: /var/lib/docker/containers
```

**Why two mounts and not just one?**

The relationship between them is a symlink indirection:

```
/var/log/pods/
  otel-demo_frontend-abc123/
    frontend/
      0.log  →  symlink  →  /var/lib/docker/containers/<container-id>/<container-id>-json.log
```

`/var/log/pods` holds the Kubernetes-organized directory structure and log file names, but
on nodes that use the Docker runtime those files are **symlinks** pointing into
`/var/lib/docker/containers`. If only `/var/log/pods` is mounted, the collector can
enumerate the path and read the symlink, but when it tries to open the target file the
resolved path (`/var/lib/docker/containers/...`) does not exist inside the container —
the open call fails silently and no log lines are read.

Mounting both paths gives the collector access to the Kubernetes directory structure
**and** the actual bytes the symlinks resolve to.

```
container filesystem after both mounts:
  /var/log/pods/           ← host path mounted here
    otel-demo_frontend-.../
      frontend/
        0.log              ← symlink target is /var/lib/docker/containers/...
  /var/lib/docker/containers/   ← host path mounted here
    <container-id>/
      <container-id>-json.log   ← actual bytes, now reachable
```

**On pure containerd clusters (no Docker shim)** the log files under `/var/log/pods` are
real files, not symlinks — `/var/lib/docker/containers` does not exist on the node.
Mounting it is harmless (Kubernetes tolerates missing hostPath sources on the node) but
unnecessary. Keeping both mounts makes the configuration portable across Docker and
containerd nodes without changes.

### Minimal configuration (covers all runtimes)

```yaml
filelog:
  include:
    - /var/log/pods/**/*.log
  include_file_path: true          # required for k8s metadata extraction
  start_at: end
  operators:
    - type: container
```

`include_file_path: true` is required. Without it the operator has no path to parse and
silently skips metadata extraction.

### What `container` produces after parsing

Before (raw CRI line in `body`):
```
2026-02-27T05:11:02.123456789Z stdout F {"level":"info","msg":"request received"}
```

After `container` operator:
```
body:        '{"level":"info","msg":"request received"}'
timestamp:   2026-02-27T05:11:02.123456789Z
attributes:
  log.iostream: stdout
  k8s.namespace.name: otel-demo          (from file path)
  k8s.pod.name:       frontend-7d9b8c4f9-xkj2p
  k8s.container.name: frontend
  k8s.container.restart_count: "0"
```

Now `body` is the clean application string — ready for the next operator.

---

## OTel Demo Log Formats: Why This Matters

The OpenTelemetry Demo runs ~20 microservices in different languages. Each has its own
logging library and format. After the `container` operator strips the CRI wrapper, the
`body` can be:

| Service | Language | Body format after CRI strip |
|---|---|---|
| `ad-service` | Java (Spring Boot) | JSON — `{"@timestamp":"...","level":"INFO","message":"..."}` |
| `cart-service` | .NET | JSON — `{"Level":"Information","MessageTemplate":"..."}` |
| `checkout-service` | Go | Structured text — `level=info msg="order placed" order_id=123` |
| `frontend` | TypeScript | JSON — `{"level":"info","message":"...","traceId":"..."}` |
| `recommendation-service` | Python | Plain text — `INFO:root:Generating recommendations` |
| `kafka` | JVM | Plain text with class prefix — `[2026-02-27 05:11:02,123] INFO ...` |
| `flagd` | Go | JSON |
| `otelcol` itself | Go | JSON (collector's own log output) |

There is no single format. Any operator applied unconditionally after `container` will
fail on some services and silently corrupt or drop their logs.

---

## Adding `json_parser` Safely: the `if:` Guard

After `container` strips the wrapper, `body` is the raw application string. `json_parser`
should only run when `body` is actually JSON.

```yaml
operators:
  - type: container

  - type: json_parser
    if: 'body matches "^\\s*\\{"'    # only when body starts with {
    parse_from: body
    parse_to: attributes
    on_error: send                   # pass the record through even if parse fails
```

### What `if: 'body matches "^\\s*\\{"'` does

- Evaluates an [Expr](https://expr-lang.org/) expression before running the operator
- `body matches "^\\s*\\{"` — true when body starts with optional whitespace then `{`
- If false: **operator is skipped entirely**, record passes untouched
- If true but JSON is malformed: `on_error: send` still passes the record through

This means:
- `checkout-service` plain text → `if` is false → skipped → body stays as-is
- `recommendation-service` plain text → skipped
- `ad-service` JSON → `if` is true → parsed → fields appear in attributes
- `frontend` JSON → parsed

### After `json_parser` runs on a JSON body

Before:
```
body: '{"level":"info","msg":"request received","trace_id":"abc123","span_id":"def456"}'
```

After:
```
body: '{"level":"info","msg":"request received","trace_id":"abc123","span_id":"def456"}'
attributes:
  level:    info
  msg:      request received
  trace_id: abc123
  span_id:  def456
```

`body` is preserved unchanged. Fields are **copied** into attributes.

---

## Promoting Fields to Log Record Metadata

Raw attributes are not the same as OTel log record fields. The severity and timestamp at
the top level of a `LogRecord` (`SeverityText`, `SeverityNumber`, `Timestamp`) need to be
explicitly populated from the parsed attributes.

```yaml
operators:
  - type: container

  - type: json_parser
    if: 'body matches "^\\s*\\{"'
    parse_from: body
    parse_to: attributes
    on_error: send

  # Promote severity — only when a severity field exists
  - type: severity_parser
    if: 'attributes.level != nil'
    parse_from: attributes.level
    # Maps "INFO" / "info" / "WARN" / "ERROR" → SeverityNumber automatically

  # Promote timestamp — only when a time field exists
  # (avoids overwriting the CRI timestamp the container operator already set)
  - type: time_parser
    if: 'attributes.time != nil'
    parse_from: attributes.time
    layout_type: iso8601

  # Promote trace context — wires logs to traces in Tempo
  - type: trace_parser
    if: 'attributes.trace_id != nil'
    trace_id:
      parse_from: attributes.trace_id
    span_id:
      parse_from: attributes.span_id
```

Why this ordering matters:
1. `container` must be **first** — everything else depends on its output
2. `json_parser` before severity/time/trace parsers — those parsers read `attributes.*`
   that `json_parser` just populated
3. `severity_parser` and `time_parser` are independent of each other — order between them
   does not matter

---

## How to check filelog receiver is working alongside the operators

- File log receiver running across all daemonset pods

```bash
# First got the pod names
kubectl get pods -n olly-collector \
-l app.kubernetes.io/component=opentelemetry-collector \
--no-headers \
| awk '{print $1}'

# Then looped over them counting two things:
# - how many times "Starting stanza receiver" appears (= 1 means receiver started)
# - how many "Started watching file" lines appear (= number of files being tailed)
for pod in \
olly-collector-opentelemetry-collector-<pod-id> \
olly-collector-opentelemetry-collector-<pod-id> \
olly-collector-opentelemetry-collector-<pod-id> \
olly-collector-opentelemetry-collector-<pod-id> \
olly-collector-opentelemetry-collector-<pod-id> \
olly-collector-opentelemetry-collector-<pod-id> \
olly-collector-opentelemetry-collector-<pod-id>; do
stanza=$(kubectl logs -n olly-collector $pod 2>/dev/null \
| grep "Starting stanza receiver" | wc -l)
count=$(kubectl logs -n olly-collector $pod 2>/dev/null \
| grep "Started watching file" | wc -l)
echo "$pod → stanza_started=$stanza  files_watched=$count"
done
```
Then I get this output:

```bash
olly-collector-opentelemetry-collector-2f7cd
olly-collector-opentelemetry-collector-46trq
olly-collector-opentelemetry-collector-9f5nc
olly-collector-opentelemetry-collector-gsgff
olly-collector-opentelemetry-collector-pnq8t
olly-collector-opentelemetry-collector-r9b94
olly-collector-opentelemetry-collector-zwnr7
olly-collector-opentelemetry-collector-48xt7 → stanza_started=0  files_watched=0
olly-collector-opentelemetry-collector-dkrjf → stanza_started=0  files_watched=0
olly-collector-opentelemetry-collector-dt5vd → stanza_started=0  files_watched=0
olly-collector-opentelemetry-collector-gbt4c → stanza_started=0  files_watched=0
olly-collector-opentelemetry-collector-h7fzr → stanza_started=0  files_watched=0
olly-collector-opentelemetry-collector-plkx6 → stanza_started=0  files_watched=0
olly-collector-opentelemetry-collector-wjn6b → stanza_started=0  files_watched=0
```

For the 7 pods shhowing `stanza_started=0` I checked them individually to confirm that they had started correctly — the startup message had just scrolled out of the log buffer:

```bash
kubectl logs -n olly-collector olly-collector-opentelemetry-collector-<pod-id> | grep -E "Starting stanza|filelog|no files" | head -10
```

- Debug exporter — receiving and flushing batches
See the resource logs and log records counters in each line

```bash
kubectl logs -n olly-collector -l app.kubernetes.io/component=opentelemetry-collector --tail=200 | grep '"otelcol.component.id":"debug"' | grep '"otelcol.signal":"logs"' | grep '"msg":"Logs"' | tail -10
{"level":"info","ts":"2026-02-28T04:47:07.251Z","msg":"Logs","resource":{"service.instance.id":"018def47-d1a7-4bde-a372-8aefa016358c","service.name":"otelcol-k8s","service.version":"0.134.0"},"otelcol.component.id":"debug","otelcol.component.kind":"exporter","otelcol.signal":"logs","resource logs":41,"log records":41}
```

### Container operator — working, k8s metadata extracted from file path SeverityText was empty

SeverityText:   (empty)
SeverityNumber: Unspecified(0)

The severity fields are empty. That's expected — you only have the container operator configured right now. The json_parser + severity_parser chain from the doc hasn't been added yet, so the JSON body is collected as a raw string but the level field inside it is never promoted to SeverityText. That's the next step when I add those operators.

\ResourceLog detail block + empty severity — both come from the same command

The debug exporter with verbosity: detailed emits two types of log entries per flush:

- A summary line: "msg":"Logs" with counts
- One or more detail lines: "msg":"ResourceLog #0\n..." with the full record

```bash
kubectl logs -n olly-collector \
-l app.kubernetes.io/component=opentelemetry-collector \
--tail=500 \
| grep '"otelcol.component.id":"debug"' \
| grep '"otelcol.signal":"logs"' \
| grep '"msg":"ResourceLog'
```

Each matching line is a single JSON object whose msg field contains the full multiline record as an escaped string. To render it readable:

```bash
kubectl logs -n olly-collector \
-l app.kubernetes.io/component=opentelemetry-collector \
--tail=500 \
| grep '"otelcol.component.id":"debug"' \
| grep '"otelcol.signal":"logs"' \
| grep '"msg":"ResourceLog' \
| head -1 \
| python3 -c "
import sys, json
line = sys.stdin.read().strip()
obj = json.loads(line)
print(obj['msg'])
"
```

That prints the msg field with its \n sequences expanded, giving you the full block:

```bash
ResourceLog #0
Resource SchemaURL:
Resource attributes:
-> k8s.container.name:          otc-container
-> k8s.namespace.name:          olly-collector
-> k8s.pod.name:                olly-collector-opentelemetry-collector-48xt7
-> k8s.container.restart_count: 3
-> k8s.pod.uid:                 f5519bdf-6afb-4570-87d4-c91915b8d4ef
-> k8s.daemonset.name:          olly-collector-opentelemetry-collector
-> k8s.node.name:               k8s-test-cluster-control-plane
-> k8s.cluster.name:            olly-personal-nonprd
ScopeLogs #0
InstrumentationScope
LogRecord #0
ObservedTimestamp: 2026-02-27 06:20:29.640363405 +0000 UTC
Timestamp:         2026-02-27 06:20:29.640274533 +0000 UTC
SeverityText:                          ← this field was empty in the output
SeverityNumber: Unspecified(0)         ← this field was 0
Body: Str({"level":"info","ts":"2026-02-27T06:20:29.640Z","msg":"Started watching file",...})
Attributes:
-> log.iostream:  stderr
-> logtag:        F
-> log.file.path: /var/log/pods/olly-collector_.../otc-container/3.log
-> log.file.name: 3.log
```

The SeverityText and SeverityNumber: Unspecified(0) fields are right there in the same block — they show up empty because json_parser and severity_parser aren't
in the operator chain yet, so the level field inside the JSON body is never read.

---

## Complete Operator Pipeline for This Project

```yaml
filelog:
  include:
    - /var/log/pods/**/*.log
  include_file_path: true
  start_at: end
  operators:
    # 1. Strip CRI/Docker wrapper, set body = application log, extract k8s metadata
    - type: container

    # 2. Parse JSON bodies — skips non-JSON lines entirely
    - type: json_parser
      if: 'body matches "^\\s*\\{"'
      parse_from: body
      parse_to: attributes
      on_error: send

    # 3. Map level/severity field → LogRecord.SeverityText + SeverityNumber
    - type: severity_parser
      if: 'attributes.level != nil'
      parse_from: attributes.level

    # 4. Map application timestamp → LogRecord.Timestamp
    #    (only if present; container operator already set a timestamp from the CRI layer)
    - type: time_parser
      if: 'attributes.time != nil'
      parse_from: attributes.time
      layout_type: iso8601

    # 5. Wire log → trace correlation (Loki → Tempo links in Grafana)
    - type: trace_parser
      if: 'attributes.trace_id != nil'
      trace_id:
        parse_from: attributes.trace_id
      span_id:
        parse_from: attributes.span_id
```

---

## What Happens per Service (After Full Pipeline)

| Service | `container` | `json_parser` | `severity_parser` | `trace_parser` |
|---|---|---|---|---|
| `ad-service` | strips CRI | parses JSON body | maps `level: INFO` | maps `trace_id` if present |
| `cart-service` | strips CRI | parses JSON body | maps `Level: Information` | maps `traceId` |
| `checkout-service` | strips CRI | **skipped** (not JSON) | **skipped** | **skipped** |
| `recommendation-service` | strips CRI | **skipped** | **skipped** | **skipped** |
| `kafka` | strips CRI | **skipped** | **skipped** | **skipped** |
| `frontend` | strips CRI | parses JSON body | maps `level` | maps `traceId` |

Non-JSON services still produce valid log records — they just have body as plain text with
no attribute promotion. Nothing is dropped.

---

## References

- [OTel blog: Container Log Parser (2024)](https://opentelemetry.io/blog/2024/otel-collector-container-log-parser/)
- [container operator reference](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/stanza/docs/operators/container.md)
- [All operators reference](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/stanza/docs/operators/README.md)
- [json_parser reference](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/stanza/docs/operators/json_parser.md)
- [dash0 filelog receiver guide](https://www.dash0.com/guides/opentelemetry-filelog-receiver)
- [filelog receiver README](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/filelogreceiver)
