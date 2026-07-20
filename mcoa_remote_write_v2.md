# MCOA Remote Write v2
 
## Independence from In-Cluster Prometheus
 
MCOA remote write capabilities operate independently from the in-cluster Prometheus stack:
 
- **Federation**: The MCOA Prometheus Agent uses pull-based HTTP federation (`/federate`) to collect metrics from the local in-cluster Prometheus.
- **Storage & Transmission**: The agent buffers scraped metrics into its own Write-Ahead Log (WAL) and initiates an outbound Remote Write 2.0 stream directly to the Hub.
- **Compatibility**: Managed clusters on older OpenShift versions without native Remote Write 2.0 support can still stream metrics using Remote Write 2.0, as long as MCOA is enabled.

## Monitoring & Alerts
 
- **Hub-Side Verification**: Query `acm_remote_write_requests_total` on the Hub to confirm inbound HTTP 2xx success statuses.
- **Spoke-Side Health**:
  - `MetricsCollectorRemoteWriteBehind`: Indicates delivery queue lagging (requires higher `maxShards` or `maxSamplesPerSend`).
  - `MetricsCollectorRemoteWriteFailures`: Indicates network drops or payloads exceeding request size limits.
## Example `PrometheusAgent` Manifest
 
```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: PrometheusAgent
metadata:
  name: mcoa-default-platform-metrics-collector-global
  namespace: open-cluster-management-observability
spec:
  logLevel: warn
  scrapeInterval: 300s
  resources:
    requests:
      cpu: 3m
      memory: 150Mi
  remoteWrite:
    - name: acm-observability
      remoteTimeout: 30s
      queueConfig:
        minShards: 2
        maxShards: 15
        capacity: 10000
        maxSamplesPerSend: 2000
        batchSendDeadline: 5s
        minBackoff: 500ms
        maxBackoff: 10s
```
 
---
 
# MCOA Remote Write v2 Independence
 
MCOA remote write capabilities operate independently from the in-cluster Prometheus stack:
 
- **Federation**: The MCOA Prometheus Agent uses pull-based HTTP federation (`/federate`) to collect metrics from the local in-cluster Prometheus.
- **Storage & Transmission**: The agent buffers scraped metrics into its own Write-Ahead Log (WAL) and initiates an outbound Remote Write 2.0 stream directly to the Hub.
- **Compatibility**: Managed clusters on older OpenShift versions without native Remote Write 2.0 support can still stream metrics using Remote Write 2.0 as long as MCOA is enabled.
## Performance Tuning (`queueConfig`)
 
You can customize the `spec.remoteWrite[].queueConfig` block within the `PrometheusAgent` custom resource to optimize throughput, memory usage, and delivery speed:
 
- **Concurrency** (`minShards`, `maxShards`): Defines the number of parallel threads sending metrics. Raising `maxShards` helps resolve backlogs caused by high network latency, though it increases CPU and connection usage.
- **Payload Size** (`maxSamplesPerSend`, `capacity`): Increasing samples per request reduces HTTP header overhead and improves bandwidth efficiency. `capacity` provides a memory buffer per shard to absorb ingestion spikes.
- **Delivery Latency** (`batchSendDeadline`): Sets the max buffer wait time. Lower values speed up dashboard updates, while higher values maximize data compression.
## Monitoring & Alerts
 
- **Hub-Side Verification**: Query `acm_remote_write_requests_total` on the Hub to confirm inbound HTTP 2xx success statuses.
- **Spoke-Side Health**:
  - `MetricsCollectorRemoteWriteBehind`: Indicates delivery queue lagging (requires higher `maxShards` or `maxSamplesPerSend`).
  - `MetricsCollectorRemoteWriteFailures`: Indicates network drops or payloads exceeding request size limits.
