# Mastering the Prometheus Agent in RHACM: Advanced Relabeling and COO Integration
 
## Overview
 
With the transition to the new **MultiCluster Observability Addon (MCOA)** in Red Hat Advanced Cluster Management (RHACM), metric collection has been vastly improved by replacing legacy custom collectors with the standard upstream **Prometheus Agent**.
 
While MCOA strictly enforces certain critical configurations (like base connection details to the Hub) using server-side apply, it deliberately leaves many fields open for user customization.
 
In this guide, we will explore two practical, advanced configurations for the Prometheus Agent:
1. Applying a global relabeling rule to filter out noisy default metrics
2. Configuring a ScrapeConfig to federate user workload metrics from a Cluster Observability Operator (COO) target
---
 
## Scenario 1: Filtering Out Default Metrics with Global Relabeling
 
### Overview
 
One of the most powerful ways to optimize network payload and reduce storage costs is to globally drop unwanted metrics before they leave the managed cluster. You can achieve this by adding a `writeRelabelConfigs` block to the default `acm-observability` remote-write destination in your `PrometheusAgent` resource.
 
### Key Benefits
 
Because this relabeling takes effect **after** the metric is federated from the local Prometheus instance but **before** it is transmitted to the Hub, it is highly efficient.
 
### Use Case: Dropping the Watchdog Alert
 
A classic example is dropping the perpetually firing **Watchdog alert metric**. Here is how you can configure your PrometheusAgent to filter it out:
 
```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: PrometheusAgent
metadata:
  name: mcoa-default-platform-metrics-collector-global
  namespace: open-cluster-management-observability
spec:
  # Other configurations (resources, scrapeInterval, etc.) remain here
  remoteWrite:
  - name: acm-observability
    # The timeout and TLS configurations are enforced by MCOA
    remoteTimeout: 30s
    writeRelabelConfigs:
      # Drop the Watchdog alert before sending to the Hub
      - action: drop
        regex: ^Watchdog$
        sourceLabels:
          - alertname
```
 
### Important Notes
 
⚠️ **MCOA Addon Manager Behavior**: MCOA's Addon Manager automatically reverts modifications to enforced fields (like removing the `acm-observability` remote write entirely), but adding custom relabeling rules is **fully supported and preserved**.
 
---
 
## Scenario 2: Federating User Workload Metrics from COO
 
### Overview
 
If your managed clusters are leveraging the **Cluster Observability Operator (COO)** for multi-tenant or advanced workload monitoring, you will need to tell the MCOA Prometheus Agent how to locate those metrics.
 
### Prerequisites
 
Before proceeding, ensure you have:
- ✅ Enabled user workload monitoring in your `MultiClusterObservability` CR on the Hub
- ✅ Deployed a `MonitoringStack` custom resource via COO on the managed cluster
### How COO Integration Works
 
When you deploy a `MonitoringStack` custom resource via COO, it automatically provisions a service endpoint named exactly after the stack. You can tap into this endpoint by creating a `ScrapeConfig` resource on the managed cluster.
 
### Configuration
 
Deploy the following `ScrapeConfig`, ensuring you apply the `app.kubernetes.io/component: user-workload-metrics-collector` label so the agent recognizes it:
 
```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: coo-uwl-metrics
  namespace: open-cluster-management-observability
  labels:
    # This label is critical for MCOA to pick up the configuration
    app.kubernetes.io/component: user-workload-metrics-collector
spec:
  scrapeClass: "" 
  scheme: HTTP
  staticConfigs:
  - targets:
    # Targets the service automatically created by the COO MonitoringStack
    # Format: <monitoring-stack-name>.<namespace>.svc:<port>
    - my-monitoring-stack.my-monitoring-ns.svc:9090
```
 
### Configuration Parameters
 
| Parameter | Description |
|-----------|-------------|
| `name` | Unique identifier for this ScrapeConfig |
| `namespace` | Must be `open-cluster-management-observability` |
| `app.kubernetes.io/component` | **Required label** for MCOA discovery: `user-workload-metrics-collector` |
| `scrapeClass` | Leave empty for standard HTTP; set if using custom Prometheus Agent class |
| `scheme` | HTTP or HTTPS depending on your setup |
| `targets` | Format: `<stack-name>.<namespace>.svc:<port>` |
 
### Advanced Configuration: TLS and Proxy Support
 
⚠️ **Important**: If your COO-provisioned Prometheus server utilizes a proxy or requires TLS, you must add the corresponding `tlsConfig` and a matching `scrapeClass` to your user workload `PrometheusAgent` before referencing it in the `ScrapeConfig`.
 
**Example with TLS:**
```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: coo-uwl-metrics-tls
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/component: user-workload-metrics-collector
spec:
  scrapeClass: "custom-prometheus-class"
  scheme: HTTPS
  tlsConfig:
    ca:
      secret:
        name: my-ca-cert
        key: ca.crt
    serverName: my-monitoring-stack.my-monitoring-ns.svc
  staticConfigs:
  - targets:
    - my-monitoring-stack.my-monitoring-ns.svc:9090
```
 
---
 
## Key Takeaways
 
| Feature | Benefit | Use Case |
|---------|---------|----------|
| **Global Relabeling** | Filters metrics at source before transmission | Reduce noise, lower storage costs |
| **writeRelabelConfigs** | Efficient, applied after federation | Selective metric dropping |
| **ScrapeConfig** | Standard Kubernetes API for scrape targets | Integrate with COO MonitoringStacks |
| **Label Discovery** | MCOA auto-discovers labeled resources | Simplified multi-cluster management |
 
---
 
## Best Practices
 
1. **Always label ScrapeConfigs** — Use `app.kubernetes.io/component: user-workload-metrics-collector` for automatic discovery
2. **Test relabeling rules** — Validate regex patterns before deploying to production
3. **Plan for scale** — Use filtering to reduce cardinality and storage footprint
4. **Document custom scrapeClass** — If using custom TLS or proxy configurations, document the corresponding PrometheusAgent settings
5. **Monitor MCOA reconciliation** — Check Addon Manager logs to verify enforced fields are not overridden
---
 
## Conclusion
 
The shift to the **Prometheus Agent** and standard Kubernetes APIs (like `PrometheusAgent` and `ScrapeConfig`) means platform administrators now have access to upstream, declarative methods for shaping observability.
 
Whether you are:
- **Stripping out high-cardinality noise** via `writeRelabelConfigs`
- **Seamlessly integrating with COO MonitoringStacks** via `ScrapeConfig`
MCOA provides the flexibility needed to scale your fleet monitoring intelligently.
 
---
 
## Additional Resources
 
- [Red Hat Advanced Cluster Management Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes)
- [Prometheus Operator Documentation](https://prometheus-operator.dev/)
- [Cluster Observability Operator (COO)](https://github.com/rhobs/observability-operator)
- [Prometheus Relabeling Guide](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config)
