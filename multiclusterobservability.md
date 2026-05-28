# MultiClusterObservability (MCO) Configuration Summary
 
## Overview

The `MultiClusterObservability` custom resource 

```yaml
apiVersion: observability.open-cluster-management.io/v1beta2
kind: MultiClusterObservability
```

configures the full observability stack in Red Hat Advanced Cluster Management (ACM). It covers sizing, metric collection, storage, and external export.


## 1. T-Shirt Sizing (`instanceSize`)
 
Instead of manually tuning CPU/memory limits per component, you pick a profile:
 
| Profile | Use Case |
|---|---|
| `minimal`, `default`, `small` | Small fleets / low time-series volume |
| `medium`, `large` | Mid-sized environments |
| `xlarge`, `2xlarge`, `4xlarge` | Large-scale deployments |
 
```yaml
spec:
  instanceSize: large
```
 
> ⚠️ **Warning:** Any manual CPU/memory/replica overrides in the `advanced` block will **completely override** the `instanceSize` settings for that component.
 
 
## 2. MCOA & Right-Sizing (`capabilities`)
 
Enables the MultiCluster Observability Addon (MCOA) architecture using **Prometheus Agents** for metric collection, plus optional right-sizing recommendation engines.
 
```yaml
capabilities:
  platform:
    metrics:
      default:
        enabled: true
    analytics:
      namespaceRightSizingRecommendation:
        enabled: true
      virtualizationRightSizingRecommendation:
        enabled: true
  userWorkloads:
    metrics:
      default:
        enabled: true
```
 

## 3. Observability Addon Global Settings (`observabilityAddonSpec`)
 
Configures the data collection agents on all managed clusters.
 
```yaml
observabilityAddonSpec:
  enableMetrics: true
  interval: 300       # scrape interval in seconds
  workers: 4          # parallel shards for federated requests
```
 

## 4. Storage & External Export (`storageConfig`)
 
Defines persistent volume sizes for Thanos components and optional forwarding to external endpoints.
 
```yaml
storageConfig:
  storageClass: gp2
  metricObjectStorage:
    name: thanos-object-storage
    key: thanos.yaml
  receiveStorageSize: 100Gi    # highest storage need
  compactStorageSize: 100Gi   # highest storage need
  storeStorageSize: 10Gi
  alertmanagerStorageSize: 1Gi
  ruleStorageSize: 1Gi
  writeStorage:
    - name: external-endpoint-secret
      key: ep.yaml
```
 
### `ep.yaml` Secret (External Export)
 
Must be created in the `open-cluster-management-observability` namespace.
 
**Basic Auth (e.g. Grafana Cloud):**
```yaml
stringData:
  ep.yaml: |
    url: https://your-endpoint.com/api/v1/write
    http_client_config:
      basic_auth:
        username: <username>
        password: <password>
```
 
**TLS Auth:**
```yaml
stringData:
  ep.yaml: |
    url: https://your-secure-endpoint.com/api/v1/write
    http_client_config:
      tls_config:
        secret_name: <cert-secret-name>
        ca_file_key: ca.crt
        cert_file_key: tls.crt
        key_file_key: tls.key
        insecure_skip_verify: false
```
 
> ⚠️ `writeStorage` forwards **all** metrics to external endpoints without filtering.
 
 
## 5. Retention & Downsampling (`advanced`)
 
Controls how long data is kept at each resolution.
 
```yaml
enableDownsampling: true
advanced:
  retentionConfig:
    retentionResolutionRaw: 30d
    retentionResolution5m: 180d
    retentionResolution1h: 365d
    retentionInLocal: 48h
    blockDuration: 2h
    deleteDelay: 48h
```
 
 
## Key Takeaways
 
- Use `instanceSize` to simplify scaling — avoid manual overrides unless necessary.
- Enable `capabilities` to activate MCOA and right-sizing recommendation rules.
- `writeStorage` + `ep.yaml` enables hub-side metric forwarding to external systems (e.g. Grafana Cloud, VictoriaMetrics).
- Thanos `Receive` and `Compact` typically require the most storage.
