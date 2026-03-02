# Changelog

## [1.0.0] - 20226-03-02

### Added

- **OpenTelemetry Collector filelog receiver** as promtail is deprecated.
  - Container parser operator was added.
- **`otlphttp/logs`** exporter to send logs to Loki.
- **`basicauth/loki`** entry to authenticate to Loki Grafana Cloud endpoint.
- `GRAFANA_CLOUD_LOKI_USER` env var and key to the `grafana-cloud-credentials` secret.
- Mounting `/var/log/pods` volume on Open telemetry collector template.
- Documentation about filelog receiver and its operators used.

### Removed

- Promtail daemonset was decomissioned.

## [0.0.4] - 2026-02-25

### Changed

- **`otlphttp/traces` → `otlp/traces` exporter (revert)**: Switched back from OTLP/HTTP to OTLP/gRPC for sending traces to Grafana Cloud Tempo.
  - `global.tempo.endpoint` reverted from `https://host:port` HTTP format back to bare `host:port` gRPC format.
  - `otlphttp/traces` was returning HTTP 404 on `/v1/traces`: `tempo-eu-west-0.grafana.net:443` only exposes a gRPC endpoint; no OTLP/HTTP listener exists at that hostname for this Grafana Cloud stack.
  - Re-added `keepalive.client_parameters` (`time: 30s`, `timeout: 10s`, `permit_without_stream: true`) — required to prevent `DeadlineExceeded` / `connection reset by peer` errors from intermediate load balancers closing idle gRPC connections.
  - Removed `compression: gzip` (was HTTP-specific); removed `tls.insecure: false` duplicate comment.
  - Pipeline `traces.exporters` updated from `otlphttp/traces` back to `otlp/traces`.

---

## [0.0.3] - 2026-02-25

### Changed

- **`otlp/traces` → `otlphttp/traces` exporter**: Switched from OTLP/gRPC to OTLP/HTTP for sending traces to Grafana Cloud Tempo.
  - `global.tempo.endpoint` updated from bare `host:port` gRPC format to `https://host:port` HTTP format.
  - Removed `keepalive` block — keepalive is a gRPC concept for persistent connections; OTLP/HTTP uses stateless requests and does not require it.
  - Added `compression: gzip` to reduce egress bandwidth.
  - Added explicit `tls.insecure: false`.
  - Pipeline `traces.exporters` updated from `otlp/traces` to `otlphttp/traces`.

---

## [0.0.2] - 2026-02-25

### Fixed

- **`otlp/traces` exporter**: Added `keepalive` settings (`time: 30s`, `timeout: 10s`, `permit_without_stream: true`) to fix `DeadlineExceeded` and `connection reset by peer` errors when exporting traces to Grafana Cloud Tempo. These errors were caused by intermediate load balancers closing idle gRPC connections; keepalive probes keep the connection alive between batches.
- **`otlp/traces` exporter**: Removed redundant `tls.insecure: false` — the `otlp` gRPC exporter requires TLS by default; the explicit setting was a no-op.
