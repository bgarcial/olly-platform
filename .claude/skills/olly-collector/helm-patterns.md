# Helm Patterns & Go Template Reference

## Global Settings (Required)

```yaml
global:
  cluster: "my-cluster-name"  # REQUIRED: Injected as k8s.cluster.name attribute
                               # Format: ${platform}-${team}-${environment}
  promtail:
    endpoint: "https://loki.example.com/loki/api/v1/push"
  opentelemetry:
    endpoint: "https://otel.example.com"  # Currently not configured (debug exporter in use)
```

## Enabling Components

```yaml
# OpenTelemetry Collector (DaemonSet)
opentelemetryCollector:
  enabled: true
  instrumentation:
    enabled: true        # Auto-instrumentation via Kyverno
    namespaces: []       # Empty = all namespaces

# OpenTelemetry Operator
opentelemetry-operator:
  enabled: true

# Promtail (logs)
promtail:
  enabled: true
```

## Go Template Language Reference

### Core Functions Used

```go
// String manipulation
{{ .Values.name | trunc 63 | trimSuffix "-" }}
{{ printf "%s-%s" .Release.Name .Chart.Name }}
{{ replace "+" "_" .Chart.Version }}
{{ lower .Values.name }}
{{ quote .Values.string }}

// Conditionals
{{- if .Values.feature.enabled }}
{{- if and .Values.a .Values.b }}
{{- if or .Values.a .Values.b }}
{{- with .Values.config }}  # Sets context + skips if nil

// Loops
{{- range .Values.items }}
  - {{ . }}
{{- end }}
{{- range $key, $value := .Values.map }}
  {{ $key }}: {{ $value }}
{{- end }}

// Default values
{{ default "fallback" .Values.optional }}
{{ .Values.name | default .Chart.Name }}

// YAML conversion
{{ toYaml .Values.config | nindent 4 }}
{{ .Values.config | toYaml | indent 2 }}

// Include named templates
{{ include "olly-collector.fullname" . }}
{{- include "olly-collector.labels" . | nindent 4 }}

// Template within values (critical pattern)
{{ tpl (toYaml .Values.config) . | nindent 4 }}
```

### Whitespace Control

```go
{{- /* Trim leading whitespace */ -}}
{{  /* Preserve whitespace */  }}

# nindent vs indent
{{ toYaml .data | nindent 4 }}  # Adds newline then indents
{{ toYaml .data | indent 4 }}   # Indents without newline
```

### API Version Detection

```go
{{- if .Capabilities.APIVersions.Has "kyverno.io/v1" }}
# Kyverno-specific resources
{{- end }}

{{- if .Capabilities.APIVersions.Has "autoscaling.k8s.io/v1" }}
# VPA resources
{{- end }}
```

### Helper Template Patterns

**_helpers.tpl standard functions**:

```go
{{/* Chart name (max 63 chars for DNS) */}}
{{- define "olly-collector.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Full name with release */}}
{{- define "olly-collector.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Standard Kubernetes labels */}}
{{- define "olly-collector.labels" -}}
helm.sh/chart: {{ include "olly-collector.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
```

### Template Interpolation in Values

The chart uses `tpl` to allow Helm templating inside YAML values:

```yaml
# In values.yaml
opentelemetryCollector:
  config:
    processors:
      resource:
        attributes:
          - key: k8s.cluster.name
            value: "{{ .Values.global.cluster }}"
            action: insert
    exporters:
      otlphttp:
        endpoint: "{{ .Values.global.opentelemetry.endpoint }}"
```

```go
# In template (opentelemetry-collector.yaml)
config: {{ tpl (toYaml .Values.opentelemetryCollector.config) . | nindent 4 }}
```

This enables dynamic endpoint configuration without hardcoding.

### Kyverno ClusterPolicy Template Escaping

Inside the Kyverno `generate` block, `{{ }}` must be escaped to avoid Helm interpreting them as template directives:

```go
# Kyverno uses {{ }} for its own templating — escape with print
namespace: {{ print "{{ request.object.metadata.name }}" | quote }}
```
