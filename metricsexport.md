# Metrics Export: Legacy Collector vs. MCOA

Yes, there are major structural and operational differences in how metrics are exported to external endpoints (such as Grafana Cloud or VictoriaMetrics) between the two architectures:

## 1. Data Flow & Routing Topology

- **Legacy Metrics Collector**: Uses the `writeStorage` parameter configured in the central `MultiClusterObservability` (MCO) custom resource on the Hub. This establishes a **Hub-to-External** path: managed clusters send metrics to the Hub's `Observatorium API`, and the Hub then forwards/proxies those metrics to your third-party endpoints.
- **MCOA Metrics Collector**: Uses the `remoteWrite` block configured directly inside the `PrometheusAgent` custom resource. This establishes a **Spoke-Direct** path: the Prometheus Agent running on the managed spoke cluster bypasses the Hub entirely, remote-writing telemetry directly to the external destination.

## 2. Metrics Filtering and Relabeling (Configurability)

- **Legacy**: Lacks granular edge filtering, meaning you cannot easily customize what gets forwarded to external endpoints at the cluster level.
- **MCOA**: Highly configurable. Because the spoke runs a standard Prometheus Agent, you can declare standard `writeRelabelConfigs` (such as `keep` or `drop` rules) per external endpoint. This allows you to aggressively prune high-cardinality metrics at the edge before they consume external license/storage costs.

## 3. Edge Resiliency & Network Partitions

- **Legacy**: Extremely dependent on the Hub's continuous availability and networking to forward metrics.
- **MCOA**: Extremely resilient. The spoke-side Prometheus Agent uses a local, disk-backed Write-Ahead Log (WAL). If the connection between the managed cluster and your external target drops, the metrics are buffered on the spoke's local disk. Once the connection recovers, the agent flushes the queue, preserving data during partitions of up to two hours without sample loss.

## 4. Authentication & Security

- **Legacy**: The Hub acts as the security gateway and manages authentication to the external endpoints.
- **MCOA**: The Hub does not handle authentication on behalf of the spokes. Each individual spoke agent connects directly to the external system and manages its own handshake using Basic Auth (`basicAuth`) or mutual TLS (`tlsConfig`). Credentials (TLS secrets) declared centrally on the Hub are automatically propagated to the spokes via MCOA's secrets replication pipeline.

## 5. Multi-Cluster Naming Context

- **Legacy**: Relies on manual configuration to preserve cluster contexts when exporting.
- **MCOA**: Telemetry exported directly from the spokes automatically attaches standard `cluster` and `clusterID` labels (or the stable `id.k8s.io` claim for non-OpenShift clusters). Your external metrics store can cleanly organize and partition incoming metrics without any custom labeling work.
