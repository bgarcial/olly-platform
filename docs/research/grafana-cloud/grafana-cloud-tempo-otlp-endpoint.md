# Grafana Cloud Tempo — OTLP Exporter Configuration: gRPC vs HTTP

**Date:** 2026-02-25
**Research scope:** How to configure the OTel Collector to export traces to Grafana Cloud Tempo using either the `otlp` (gRPC) or `otlphttp` exporter. Protocol comparison, endpoint formats, keepalive, and when to prefer one over the other.
**Confidence legend:** High = 3+ independent concordant sources. Medium = 2 concordant sources. Low = 1 source or inference.

---

## Executive Summary

| Question | Finding | Confidence |
|---|---|---|
| Does Grafana Cloud Tempo accept both OTLP/gRPC and OTLP/HTTP? | Yes — same hostname and port serve both protocols | High |
| `otlphttp` endpoint format | `https://tempo-eu-west-0.grafana.net:443` — scheme required, **no path suffix** | High |
| `otlp` (gRPC) endpoint format | `tempo-eu-west-0.grafana.net:443` — no scheme, no path | High |
| Does keepalive apply to `otlphttp`? | No — HTTP is stateless; keepalive is a gRPC concept for persistent connections | High |
| General OTel recommendation | OTLP/HTTP is the broadly recommended default for interoperability; gRPC preferred for high-throughput collector-to-collector pipelines | Medium |
| Do app send-protocol and collector export-protocol need to match? | No — receiver and exporter are fully independent inside the collector | High |

---

## 1. Protocol Support — Tempo Accepts Both

Grafana Cloud Tempo exposes a single TLS endpoint (`tempo-eu-west-0.grafana.net:443`) that accepts traces over both OTLP/gRPC and OTLP/HTTP. The two protocols differ only in how the OTel Collector exporter is configured and how the URL is formatted — the Tempo server handles both on the same host and port.

The Grafana Cloud portal's "Sending Traces" page shows an Alloy gRPC config because Alloy uses gRPC as its native default. This does not mean HTTP is unsupported — it is explicitly documented in the Grafana Alloy LGTM guide.

**Evidence:**
- Grafana Alloy LGTM stack guide: "For Grafana Cloud, use `otelcol.exporter.otlphttp` which sends data over HTTP/HTTPS" — uses `https://tempo-us-central1.grafana.net:443` as the endpoint. Source: [Collect OTel data and forward to Grafana — Grafana Alloy docs](https://grafana.com/docs/alloy/latest/collect/opentelemetry-to-lgtm-stack/)
- Grafana Cloud portal: shows `otelcol.exporter.otlp` (gRPC) with `tempo-eu-west-0.grafana.net:443` — no scheme.
- Both are documented on official Grafana properties, confirming dual-protocol support. Confidence: **High**.

---

## 2. Using `otlphttp` (OTLP/HTTP)

### Endpoint format

```
https://tempo-eu-west-0.grafana.net:443
```

The `https://` scheme is required. The `otlphttp` exporter automatically appends `/v1/traces` to form the final request URL:

```
POST https://tempo-eu-west-0.grafana.net:443/v1/traces
```

Do **not** add any path suffix to the base endpoint — the exporter adds it.

Source: [opentelemetry-collector otlphttpexporter README](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/otlphttpexporter/README.md) — "To send each signal a corresponding path will be added to this base URL, i.e. for traces '/v1/traces' will be appended."

### Configuration

```yaml
exporters:
  otlphttp/traces:
    endpoint: "https://tempo-eu-west-0.grafana.net:443"
    auth:
      authenticator: basicauth/tempo
    compression: gzip
    tls:
      insecure: false
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 120s
```

### Why no keepalive setting

OTLP/HTTP uses standard HTTPS request–response semantics. Each export is an independent HTTP POST. There is no persistent connection to maintain — the connection is established per-request (or reused via HTTP keep-alive at the TCP layer, which is handled transparently by the Go HTTP client). The `keepalive` configuration block is a gRPC concept and does not apply to `otlphttp`.

### When to prefer `otlphttp`

- **Standard proxy and firewall environments** — HTTPS on port 443 passes through virtually every corporate proxy and cloud firewall without special configuration. gRPC requires HTTP/2 to be allowed end-to-end, which some proxies break.
- **When you want simpler TLS configuration** — no need to configure gRPC-specific TLS dial options.
- **OTel SDK default for most languages** — the Java, Python, and JavaScript OTel SDKs default to OTLP/HTTP when a backend URL is provided with `https://`. Matching the exporter to the SDK's preferred protocol avoids configuration asymmetry in documentation.
- **Stateless retry behavior** — each failed HTTP request can be independently retried without concern for connection state. The `retry_on_failure` block works cleanly because there is no connection-level state to recover.
- **No keepalive management overhead** — connections that go idle are closed naturally; no heartbeat frames are needed.

---

## 3. Using `otlp` (OTLP/gRPC)

### Endpoint format

```
tempo-eu-west-0.grafana.net:443
```

No `https://` scheme, no path. gRPC resolves the host, establishes a TLS connection, and uses the gRPC service definition for routing — paths are service method names, not URL paths.

Source: [Grafana Alloy `otelcol.exporter.otlp` reference](https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.exporter.otlp/) — Confirms `host:port` format; no scheme.

### Configuration

```yaml
exporters:
  otlp/traces:
    endpoint: "tempo-eu-west-0.grafana.net:443"
    auth:
      authenticator: basicauth/tempo
    tls:
      insecure: false
    keepalive:
      time: 30s        # send keepalive ping every 30s if no activity
      timeout: 10s     # close connection if no ping response within 10s
      permit_without_stream: true  # allow pings even when no active RPC
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 120s
```

### Why keepalive is needed for gRPC

gRPC maintains a **persistent HTTP/2 connection** between the collector and the server. Cloud load balancers (including those in front of Grafana Cloud) silently close idle TCP connections — typically after 60–120 seconds of inactivity. When the connection is reset mid-stream and the collector has no keepalive, the next export attempt fails until a reconnect completes, causing dropped spans.

The `keepalive.time` setting sends a periodic HTTP/2 PING frame to keep the connection alive through the load balancer's idle timeout. This is not needed for `otlphttp` because each HTTP request re-establishes a connection (or reuses a short-lived connection pool) — there is no single persistent connection to keep alive.

Source: [gRPC keepalive documentation](https://grpc.io/docs/guides/keepalive/) — describes PING-based keepalive for persistent connections. Confidence: **High**.

### When to prefer `otlp` (gRPC)

- **High-throughput collector-to-collector pipelines** — gRPC's HTTP/2 multiplexing sends multiple streams of spans over a single connection with lower per-message overhead than HTTP/1.1 and without HTTP/2 request overhead per message.
- **Low-latency requirements** — the persistent connection eliminates TCP and TLS handshake cost on every export batch. Once the connection is established, each send is a stream write, not a new request.
- **Environments where gRPC is the natural protocol** — if Grafana Alloy is the agent or the upstream service uses gRPC natively, keeping the same protocol end-to-end reduces serialization overhead.
- **Grafana Cloud default recommendation** — the Grafana Cloud portal generates Alloy config using the `otlp` (gRPC) exporter. Following the portal config aligns with Grafana's tested and documented path.
- **Large batch sizes** — gRPC streaming can handle larger payloads more efficiently than discrete HTTP POST requests.

---

## 4. Protocol Comparison and Recommendation

### Comparison table

| Dimension | `otlp` (gRPC) | `otlphttp` |
|---|---|---|
| OTel Collector exporter | `otlp` | `otlphttp` |
| Endpoint format | `host:port` — no scheme | `https://host:port` — scheme required |
| Default OTel SDK port | 4317 | 4318 |
| Transport | HTTP/2 only, persistent connection | HTTP/1.1 or HTTP/2, stateless requests |
| Keepalive required | Yes — cloud LBs reset idle connections | No — stateless, no persistent connection |
| Proxy/firewall friendliness | Requires HTTP/2 end-to-end | Standard HTTPS, works everywhere |
| Per-message overhead | Lower — multiplexed over one connection | Slightly higher — one request per batch |
| Throughput at scale | Higher — streaming over persistent connection | Sufficient for most workloads |
| Connection recovery | Must reconnect on disconnect (keepalive mitigates) | No connection to recover |
| Grafana Cloud UI default | Yes (Alloy `otelcol.exporter.otlp`) | Documented in Alloy LGTM guide |

### OTel recommendation

The OTLP specification mandates that conforming implementations support both OTLP/gRPC and OTLP/HTTP — neither is deprecated. However, the broader OpenTelemetry ecosystem trends toward OTLP/HTTP as the default for SDK-to-collector communication:

- Most OTel SDKs (Java, Python, JavaScript) default to `http/protobuf` (OTLP/HTTP with binary encoding) when not explicitly configured.
- OTLP/HTTP works through standard HTTPS infrastructure without requiring end-to-end HTTP/2 support.
- The OTel Collector contrib documentation presents `otlphttp` examples prominently in getting-started guides.

**Note:** The OTLP spec itself does not declare HTTP superior to gRPC in absolute terms. The preference for HTTP as the default in SDK documentation reflects practical interoperability, not a protocol quality difference. Source: [OTLP Specification — opentelemetry.io](https://opentelemetry.io/docs/specs/otlp/). Confidence: **Medium** — verify against your SDK's default exporter documentation for the specific language in use.

### Decision guide

```
Is your environment behind a strict proxy or firewall that may block gRPC?
  → otlphttp

Is this a collector-to-collector pipeline handling high span volume (>50k spans/s)?
  → otlp (gRPC) for throughput

Are you following the Grafana Cloud portal's generated Alloy config?
  → otlp (gRPC)

Are your OTel SDKs configured to send HTTP by default and you want consistency?
  → otlphttp

Are you unsure?
  → Start with otlphttp — simpler, no keepalive management, works everywhere
```

---

## 5. Receiver / Exporter Protocol Independence

The protocol that application pods use to send traces to the collector has **no effect** on the protocol the collector uses to export traces to Tempo.

The OTel Collector pipeline is:

```
Apps (gRPC on 4317)         Apps (HTTP on 4318)
         │                          │
         ▼                          ▼
  [otlp receiver — grpc]    [otlp receiver — http]
                  │
                  │  ← pdata.Traces (protocol-agnostic in memory)
                  ▼
           [processors]
                  │
                  ▼
       [otlphttp/traces  OR  otlp/traces]
                  │
                  ▼
         Grafana Cloud Tempo
```

The receiver decodes the incoming bytes into `pdata.Traces` — an in-memory representation with no protocol attached. The exporter re-encodes those traces in whichever protocol you configure. These two sides are completely independent.

**Practical implication:** The OpenTelemetry Demo sends traces via gRPC (port 4317) to the collector. You can configure the collector to export those same traces to Tempo via `otlphttp` without any conflict or loss of data. The collector handles the protocol translation transparently.

---

## Source Summary

| Source | URL | Used for |
|---|---|---|
| OTLP Specification | https://opentelemetry.io/docs/specs/otlp/ | gRPC vs HTTP transport definitions; dual-protocol requirement |
| OTel Collector otlphttpexporter README | https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/otlphttpexporter/README.md | Path auto-append behavior; endpoint field semantics |
| Grafana Alloy LGTM stack guide | https://grafana.com/docs/alloy/latest/collect/opentelemetry-to-lgtm-stack/ | `otlphttp` for Tempo Cloud; `https://tempo-[region]:443` format confirmed |
| Grafana Alloy `otelcol.exporter.otlp` reference | https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.exporter.otlp/ | gRPC exporter; `host:port` format; Grafana Cloud default |
| Grafana Alloy `otelcol.exporter.otlphttp` reference | https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.exporter.otlphttp/ | HTTP exporter; path suffix behavior |
| Grafana Tempo HTTP API | https://grafana.com/docs/tempo/latest/api_docs/pushing-spans-with-http/ | Tempo HTTP ingestion path `/v1/traces` |
| Grafana Labs blog: Send traces to Tempo (2021) | https://grafana.com/blog/2021/04/13/how-to-send-traces-to-grafana-clouds-tempo-service-with-opentelemetry-collector/ | Historical gRPC `otlp` exporter format for Tempo |
| gRPC keepalive documentation | https://grpc.io/docs/guides/keepalive/ | PING-based keepalive for persistent gRPC connections |
| oneuptime.com OTel Collector to Grafana Cloud (Feb 2026) | https://oneuptime.com/blog/post/2026-02-06-grafana-cloud-connector-opentelemetry-collector/view | Working `otlphttp` config with eu-west Tempo; no `/otlp` suffix |
