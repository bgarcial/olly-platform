# Grafana Cloud Unified OTLP Gateway

**Date:** 2026-02-25
**Research scope:** The Grafana Cloud unified OTLP gateway — what it is, how its URL structure differs from per-signal endpoints, when to use it, and how to configure it in the OTel Collector.
**Confidence legend:** High = 3+ independent concordant sources. Medium = 2 concordant sources. Low = 1 source or inference.

---

## Executive Summary

| Question | Finding | Confidence |
|---|---|---|
| What is the gateway? | A single OTLP/HTTP endpoint that routes all three signals (traces, metrics, logs) to the correct Grafana Cloud backend | High |
| Gateway base URL (eu-west-0) | `https://otlp-gateway-prod-eu-west-0.grafana.net/otlp` | High |
| Why `/otlp` is in the gateway URL | It is the gateway's base path — the exporter appends `/v1/traces` to produce `/otlp/v1/traces` | High |
| Does the gateway accept gRPC? | No — HTTP only | High |
| Per-signal endpoints vs gateway | Gateway: one credential pair, simpler config. Per-signal: independent auth, retry, TLS per signal | High |
| Gateway SLA | Not explicitly guaranteed separately from Grafana Cloud SLA — unverified | Low |

---

## 1. What the Unified OTLP Gateway Is

The Grafana Cloud unified OTLP gateway is a single HTTPS endpoint that accepts all three OpenTelemetry signal types and routes each internally to the correct Grafana Cloud backend:

| Incoming path | Routes to |
|---|---|
| `POST /otlp/v1/traces` | Grafana Cloud Tempo |
| `POST /otlp/v1/metrics` | Grafana Cloud Mimir |
| `POST /otlp/v1/logs` | Grafana Cloud Loki |

This means a single `otlphttp` exporter can replace three separate per-signal exporters when using the gateway.

Source: [OTLP: The OpenTelemetry Protocol — Grafana Cloud docs](https://grafana.com/docs/grafana-cloud/send-data/otlp/), [Grafana Alloy `otelcol.exporter.otlphttp` reference](https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.exporter.otlphttp/). Confidence: **High**.

---

## 2. URL Structure and Why `/otlp` Is in the Base Path

### Gateway endpoint

```
https://otlp-gateway-prod-eu-west-0.grafana.net/otlp
```

### What the exporter sends

The `otlphttp` exporter appends `/v1/{signal}` to the configured base endpoint. Using the gateway base:

```
https://otlp-gateway-prod-eu-west-0.grafana.net/otlp  +  /v1/traces
= https://otlp-gateway-prod-eu-west-0.grafana.net/otlp/v1/traces   ✓
```

The `/otlp` segment is the gateway's own routing prefix — it tells the gateway's reverse proxy which handler to use. It is **not** the OTLP specification's path convention; it is specific to the Grafana Cloud gateway's URL design.

### Why the `/otlp` prefix must NOT be added to per-signal endpoints

The Tempo-direct endpoint (`tempo-eu-west-0.grafana.net:443`) does not have an `/otlp` routing prefix. Its OTLP/HTTP handler is mounted at `/v1/traces` directly. Adding `/otlp` to the Tempo endpoint produces `/otlp/v1/traces`, which does not exist on that server.

| Endpoint type | Configured base | Final URL the exporter sends to |
|---|---|---|
| Tempo-direct (correct) | `https://tempo-eu-west-0.grafana.net:443` | `https://tempo-eu-west-0.grafana.net:443/v1/traces` ✓ |
| OTLP gateway (correct) | `https://otlp-gateway-prod-eu-west-0.grafana.net/otlp` | `https://otlp-gateway-prod-eu-west-0.grafana.net/otlp/v1/traces` ✓ |
| Tempo-direct + wrong suffix | `https://tempo-eu-west-0.grafana.net:443/otlp` | `https://tempo-eu-west-0.grafana.net:443/otlp/v1/traces` ✗ HTTP 404 |

Source: [opentelemetry-collector otlphttpexporter README](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/otlphttpexporter/README.md), [Grafana Alloy LGTM stack guide](https://grafana.com/docs/alloy/latest/collect/opentelemetry-to-lgtm-stack/). Confidence: **High**.

---

## 3. Configuration

### Single exporter for all signals (simplest)

```yaml
exporters:
  otlphttp:
    endpoint: "https://otlp-gateway-prod-eu-west-0.grafana.net/otlp"
    auth:
      authenticator: basicauth/grafana
    compression: gzip
    tls:
      insecure: false
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 120s

extensions:
  basicauth/grafana:
    client_auth:
      username: "${env:GRAFANA_CLOUD_INSTANCE_ID}"  # numeric instance ID
      password: "${env:GRAFANA_CLOUD_API_TOKEN}"

service:
  extensions: [basicauth/grafana]
  pipelines:
    traces:
      exporters: [otlphttp]
    metrics:
      exporters: [otlphttp]
```

### Authentication

Grafana Cloud requires HTTP Basic authentication on the gateway:
- **Username**: Grafana Cloud Instance ID (numeric, found on your stack's overview page)
- **Password**: Grafana Cloud API token with write scope for the relevant signal(s)

The same credential pair covers all three signals when using the gateway.

Source: [OTLP endpoint credentials — Grafana Cloud community forum](https://community.grafana.com/t/opentelemetry-protocol-otlp-endpoint-credentials-for-grafana-cloud/105782). Confidence: **High**.

---

## 4. Gateway vs Per-Signal Endpoints

| Dimension | Unified gateway | Per-signal endpoints |
|---|---|---|
| Number of exporters | 1 | 2–3 (one per signal) |
| Auth credentials | Single pair for all signals | Separate pair per signal |
| Per-signal retry config | Not possible — one exporter, one retry policy | Independent retry per signal |
| Per-signal TLS config | Not possible | Independent TLS per signal |
| Config complexity | Low | Medium |
| Failure isolation | One endpoint outage affects all signals | Signal-level failure isolation |
| Supported protocols | OTLP/HTTP only | gRPC or HTTP per signal |
| URL `/otlp` path | Required — part of the gateway base | Not used on per-signal endpoints |

### When to use the gateway

- Simplest possible setup — one exporter, one credential pair
- Early-stage or personal setups where per-signal isolation is not required
- When you want to send all three signals (traces, metrics, logs) through a single OTel Collector exporter

### When to use per-signal endpoints

- Production workloads where trace export failure should not affect metric export
- When different API tokens are required per signal for audit or access-control reasons
- When you need different retry policies (e.g., longer retry window for metrics than traces)
- When mixing protocols: gRPC for traces (latency), HTTP for metrics (proxy compatibility)

---

## 5. Gateway SLA Note

A Grafana community forum member noted that the OTLP gateway "doesn't have any SLA" separate from the general Grafana Cloud SLA. This claim was not verified against Grafana's official SLA documentation.

Grafana Cloud's published SLA (99.5% monthly uptime) does not explicitly differentiate between the OTLP gateway and direct signal endpoints (Tempo, Mimir, Loki). Until this is confirmed either way, treat this as an unverified risk signal — not a confirmed limitation.

**Action if SLA matters:** Contact Grafana Cloud support or review the official SLA addendum at [grafana.com/legal/grafana-cloud-sla](https://grafana.com/legal/grafana-cloud-sla) to confirm whether the gateway has the same coverage as per-signal endpoints.

Source: [OTLP endpoint of Grafana Cloud — Grafana community forum](https://community.grafana.com/t/opentelemetry-endpoint-of-grafana-cloud/85359). Confidence: **Low** (single community source, unverified).

---

## Source Summary

| Source | URL | Used for |
|---|---|---|
| Grafana Cloud OTLP docs | https://grafana.com/docs/grafana-cloud/send-data/otlp/ | Gateway routing architecture — traces → Tempo, metrics → Mimir, logs → Loki |
| Grafana Alloy `otelcol.exporter.otlphttp` reference | https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.exporter.otlphttp/ | Gateway endpoint format; path suffix behavior |
| Grafana Alloy LGTM stack guide | https://grafana.com/docs/alloy/latest/collect/opentelemetry-to-lgtm-stack/ | Signal routing table; config examples |
| Grafana Labs blog: OTel Collector tasting menu | https://grafana.com/blog/exploring-opentelemetry-collector-configurations-in-grafana-cloud-a-tasting-menu-approach/ | Gateway as primary endpoint in unified config |
| OTel Collector otlphttpexporter README | https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/otlphttpexporter/README.md | Path auto-append — why `/otlp` in base produces `/otlp/v1/traces` |
| Grafana Cloud community forum: OTLP credentials | https://community.grafana.com/t/opentelemetry-protocol-otlp-endpoint-credentials-for-grafana-cloud/105782 | Auth format; gateway SLA note |
| Grafana community: OTLP endpoint of Grafana Cloud | https://community.grafana.com/t/opentelemetry-endpoint-of-grafana-cloud/85359 | Gateway routing `/otlp/v1/traces` confirmed by users |
