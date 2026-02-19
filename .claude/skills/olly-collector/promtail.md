# Promtail Configuration

Promtail is deployed as a DaemonSet to collect logs from all nodes. The configuration uses relabeling to extract metadata from Kubernetes pod labels/annotations.

## Current Configuration (Minimal)

The olly-collector Promtail config is intentionally minimal — it keeps universally useful patterns and omits company-specific multi-tenancy features. This is the right starting point; add custom labels as your needs grow.

```yaml
promtail:
  enabled: true
  config:
    clients:
      - url: "{{ .Values.global.promtail.endpoint }}"
        external_labels:
          cluster: "{{ .Values.global.cluster }}"

    snippets:
      extraRelabelConfigs:
        # Instance label fallback (keep — useful for all Helm workloads)
        - source_labels:
            - __meta_kubernetes_pod_label_app_kubernetes_io_instance
            - __meta_kubernetes_pod_label_instance
            - __meta_kubernetes_pod_label_release
          regex: ^;*([^;]+)(;.*)?$
          action: replace
          target_label: instance

      pipelineStages:
        - cri: {}
        - labeldrop:
            - filename  # Remove high-cardinality path label
```

## Relabel Configurations Explained

Promtail uses `extraRelabelConfigs` to transform Kubernetes metadata into log labels. These run **before** logs are sent to Loki.

### Instance Label Fallback (Universal — Keep This)

```yaml
- source_labels:
    - __meta_kubernetes_pod_label_app_kubernetes_io_instance
    - __meta_kubernetes_pod_label_instance
    - __meta_kubernetes_pod_label_release
  regex: ^;*([^;]+)(;.*)?$
  action: replace
  target_label: instance
```

- **Purpose**: Backwards compatibility for older Helm charts
- **Background**: Modern Helm charts use `app.kubernetes.io/instance`, but older charts use `release` label
- **How the regex works**:
  1. Promtail concatenates source labels with `;` separator
  2. `^;*([^;]+)(;.*)?$` captures the **first non-empty value**
  3. Priority order: `app.kubernetes.io/instance` > `instance` > `release`

## Pipeline Stages Explained

```yaml
pipelineStages:
  - cri: {}           # Parse Container Runtime Interface log format (KEEP)
  - labeldrop:        # Remove temporary/high-cardinality labels
      - filename
```

| Stage | Purpose | Keep? |
|-------|---------|-------|
| `cri: {}` | Parse CRI log format (timestamps, stream, log content) | **Yes always** |
| `labeldrop: [filename]` | Remove high-cardinality path label to avoid Loki index bloat | **Yes** |

## Testing Without a Loki Backend

If you don't have a Loki endpoint yet, use the placeholder URL in `values.yaml`:

```yaml
global:
  promtail:
    endpoint: "http://loki-not-configured:3100/loki/api/v1/push"
```

**Behavior with placeholder**:
- Promtail starts successfully
- Collects logs from all pods
- Fails to send (DNS resolution failure)
- Keeps running and retrying with backoff
- Logs are buffered but eventually dropped if buffer fills

## Adding Custom Labels

When you need team ownership or environment labels, follow this pattern:

```yaml
extraRelabelConfigs:
  # Extract team label from pod annotation or label
  - action: replace
    source_labels:
      - __meta_kubernetes_pod_annotation_your_org_team
      - __meta_kubernetes_pod_label_your_org_team
    regex: ^;*([^;]+)(;.*)?$
    target_label: team

  # Extract environment label
  - action: replace
    source_labels:
      - __meta_kubernetes_pod_label_environment
      - __meta_kubernetes_pod_annotation_environment
    regex: ^;*([^;]+)(;.*)?$
    target_label: environment

# Then promote to indexed Loki labels in pipelineStages
pipelineStages:
  - cri: {}
  - labels:
      team:
      environment:
  - labeldrop:
      - filename
```

**Note**: Adding labels to Loki increases index cardinality. Only promote labels that you actively filter on in queries.

## Adding Pod Opt-Out Support

To let specific pods opt out of log collection (via annotation):

```yaml
extraRelabelConfigs:
  - action: drop
    source_labels:
      - __meta_kubernetes_pod_annotationpresent_olly_ignore
    regex: "true"
```

Pods with annotation `olly_ignore: "true"` (or any value) will be excluded.

## Loki Multi-Tenancy (Future)

If you add Loki multi-tenancy, you'll need:
1. A relabel rule to extract the tenant from a pod annotation → `tenant_id` label
2. A pipeline `match` stage to route logs based on `tenant_id`
3. A pipeline `tenant` stage to set the `X-Scope-OrgID` header

Example pattern:
```yaml
extraRelabelConfigs:
  - action: replace
    source_labels:
      - __meta_kubernetes_pod_annotation_olly_loki_tenant
    target_label: tenant_id

pipelineStages:
  - cri: {}
  - match:
      selector: '{tenant_id=~".+"}'
      stages:
        - template:
            source: tenant_id_lc
            template: "{{ ToLower .tenant_id }}"
        - tenant:
            source: tenant_id_lc
  - labeldrop:
      - filename
      - tenant_id
```

## Host Volume Paths

The DaemonSet mounts host paths to read container logs:

```yaml
defaultVolumes:
  - name: run
    hostPath:
      path: /run/promtail/olly-collector  # Promtail state directory
  - name: containers
    hostPath:
      path: /var/lib/docker/containers    # Docker container logs
  - name: pods
    hostPath:
      path: /var/log/pods                 # Kubernetes pod logs
```

The `/run/promtail/olly-collector` path (instead of `/run/promtail`) avoids conflicts if another Promtail instance runs on the same node.
