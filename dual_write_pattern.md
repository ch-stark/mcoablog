# Architectural Excellence: Mastering Multi-Hub Observability with the MCOA Dual-Write Pattern
 
Managing observability across a sprawling, multi-hub enterprise architecture often introduces two major pain points: metric duplication and historical data fragmentation.
 
Historically, organizations leveraging Red Hat Advanced Cluster Management (RHACM) alongside an external Enterprise Source of Truth (SoT)—like Grafana Enterprise Metrics (GEM) or a central Thanos cluster—had to deploy duplicate monitoring agents. This meant double the resource overhead on the edge and double the egress bandwidth. Furthermore, when dynamically migrating a spoke cluster from one regional ACM hub to another, the cluster would assume the new hub's tenant ID, instantly breaking the historical metric continuity in enterprise dashboards.
 
With the introduction of the MultiCluster Observability Addon (MCOA), these challenges are elegantly resolved through the **Dual-Write Pattern**.
 
Here is a deep dive into how MCOA's dual-write capability transforms fleet observability, eliminates duplication, and future-proofs your multi-hub architecture.
 
## What is the MCOA Dual-Write Pattern?
 
MCOA completely rearchitects RHACM's metric collection by replacing the legacy, custom endpoint operator with the standard upstream Prometheus Agent.
 
Because it leverages standard Prometheus APIs, the agent natively supports multiple `remoteWrite` destinations. The Dual-Write pattern takes advantage of this by splitting the telemetry stream right at the edge of the managed cluster:
 
- **Stream 1 (Local/Regional Health):** A lightweight, highly filtered set of platform metrics is sent to the regional ACM Hub to power out-of-the-box dashboards and Day-2 operational status.
- **Stream 2 (Enterprise SoT):** The complete, granular metrics payload is written directly to your central Enterprise data warehouse (e.g., GEM or a central Thanos instance).
## The Three Core Benefits
 
### 1. Eliminating Metric Duplication via Edge Relabeling
 
Instead of running resource-heavy legacy metrics collectors alongside your enterprise agents, MCOA deploys a single, highly optimized Prometheus Agent on the spoke. By utilizing `writeRelabelConfigs` within the `PrometheusAgent` custom resource, you can apply aggressive edge relabeling. This allows you to selectively drop or keep specific metrics for each destination, eliminating the need to process and transmit duplicate payloads across your network.
 
### 2. Solving the Spoke-Migration Continuity Gap
 
When you operate multiple independent ACM hubs, keeping track of historical telemetry during a cluster migration is a massive headache. The MCOA dual-write pattern solves this natively. Because the spoke clusters use native remote-write to send their long-term metrics directly to your central GEM or Thanos instance under a unified cluster identity, moving a managed cluster between regional ACM hubs no longer causes a loss of historical metrics in your primary dashboards. Your Enterprise SoT remains the unbroken, continuous record.
 
### 3. Unmatched Edge Network Resiliency
 
Edge environments and remote spoke clusters often face transient network instability. The new MCOA Prometheus Agent introduces a local, disk-backed Write-Ahead Log (WAL) on the spokes. If a spoke temporarily loses connection to either the ACM hub or your external GEM endpoint, it buffers the federated samples locally. Once the connection is restored, the agent seamlessly flushes the queue, preventing data loss for network partitions of up to one hour.
 
## How to Configure the Dual-Write Pattern
 
Configuring this pattern relies on the MCOA `PrometheusAgent` Custom Resource. You simply add the necessary TLS secrets to the `open-cluster-management-observability` namespace and define multiple targets in the `remoteWrite` block.
 
Here is an architectural example of what that configuration looks like:
 
```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: PrometheusAgent
metadata:
  name: mcoa-default-platform-metrics-collector-global
  namespace: open-cluster-management-observability
spec:
  secrets:
    - enterprise-sot-ca
    - enterprise-sot-cert
  remoteWrite:
    # Destination 1: The Central Enterprise SoT (e.g., GEM)
    - name: enterprise-sot-gem
      url: 'https://gem.enterprise.network.io/api/v1/receive'
      tlsConfig:
        caFile: /etc/prometheus/secrets/enterprise-sot-ca/ca.crt
        certFile: /etc/prometheus/secrets/enterprise-sot-cert/tls.crt
        keyFile: /etc/prometheus/secrets/enterprise-sot-cert/tls.key
 
    # Destination 2: The Regional ACM Hub (Filtered Stream)
    - name: acm-observability
      # URL is dynamically managed by MCOA
      writeRelabelConfigs:
        - action: drop
          regex: ^(container_memory_cache|container_memory_rss)$
          sourceLabels:
            - __name__
```
 
## The Bottom Line
 
You should not have to force ACM's embedded Thanos to act as your global, multi-hub data warehouse, nor should you have to sacrifice historical continuity when shifting workloads between regions.
 
By adopting the MCOA Dual-Write pattern, platform engineering teams can establish clear architectural boundaries: ACM Observability handles local fleet health and Day-2 operations, while your central metrics platform handles long-term enterprise SLAs and global querying. The result is a leaner edge, zero metric duplication, and a resilient, continuous stream of observability data.
 
