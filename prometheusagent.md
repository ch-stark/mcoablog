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

### How COO Integration Works: Federation Model

When you deploy a `MonitoringStack` custom resource via COO, it automatically provisions a service endpoint named exactly after the stack. You can tap into this endpoint by creating a `ScrapeConfig` resource on the managed cluster.

#### Understanding the Architecture

The `ScrapeConfig` resource configures the **targets from which the Prometheus Agent will scrape and federate metrics**. This is distinct from the remote write destination (which is always the Hub). Think of it as:

```
[User Workload Prometheus] --[ScrapeConfig targets]--> [Prometheus Agent] --[remoteWrite]--> [Hub]
```

Key points:
- **Platform metrics**: Enforced by MCOA with standard platform scrapeConfigs
- **User Workload (UWL) metrics**: Configurable by users via custom ScrapeConfig resources
- **Default behavior**: If no custom ScrapeConfig is specified, MCOA automatically uses the in-cluster UWL Prometheus as the target
- **Flexible targets**: You can point ScrapeConfig targets to **any endpoint** — not just COO MonitoringStacks

#### Target Options

You can configure targets to point to:
- ✅ COO-provisioned `MonitoringStack` endpoints
- ✅ External Prometheus instances
- ✅ Other observability systems that expose Prometheus-compatible endpoints
- ✅ In-cluster services on any port
- ✅ Remote endpoints outside the cluster (with proper networking)

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

---

## Understanding Complexity vs. Simplicity

### Default Behavior (No Configuration Required)

If you **do not configure any custom ScrapeConfig**, MCOA handles the common case automatically:
- The Prometheus Agent discovers and scrapes the **default in-cluster UWL Prometheus endpoint**
- Metrics are automatically federated to the Hub
- No additional setup is required for basic UWL monitoring

### When to Configure Custom ScrapeConfig

You only need to create a custom `ScrapeConfig` if you want to:
- 📌 **Use a different endpoint** — Point to a COO MonitoringStack, external Prometheus, or custom endpoint
- 🔐 **Apply custom TLS settings** — Add client certificates, CA certs, or server verification
- 🌐 **Use a proxy** — Route scrape traffic through a proxy server
- 🎯 **Scrape multiple endpoints** — Configure multiple targets
- 🏷️ **Apply custom relabeling** — Transform metrics before federation

### Future Simplifications

The MCOA team is actively working to reduce complexity:
- **Annotation-based auto-discovery** — Resources tagged with specific annotations could automatically be added to CMAO (Central Metric Aggregation)
- **Higher-level abstractions** — Similar to the `MultiClusterObservability` CR approach, simplified CRs for common UWL patterns

For now, the recommendation is: **start simple**. Use defaults first; add custom `ScrapeConfig` only when needed.

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

### Alternative Target Configurations

Since `ScrapeConfig` targets can point **anywhere**, here are practical examples:

**Example 1: Multiple COO MonitoringStacks**
```yaml
staticConfigs:
- targets:
  - monitoring-stack-prod.prod-monitoring.svc:9090
  - monitoring-stack-staging.staging-monitoring.svc:9090
  - monitoring-stack-qa.qa-monitoring.svc:9090
```

**Example 2: External Prometheus Instance**
```yaml
scheme: HTTPS
staticConfigs:
- targets:
  - external-prometheus.example.com:9443
tlsConfig:
  serverName: external-prometheus.example.com
  insecureSkipVerify: false  # Validate certificate
```

**Example 3: Custom Application Metrics Exporter**
```yaml
# Can scrape any Prometheus-compatible endpoint
staticConfigs:
- targets:
  - custom-metrics-exporter.app-namespace.svc:8080
  - app-metrics-sidecar.app-namespace.svc:8081
relabelConfigs:
  - source_labels: [__address__]
    target_label: job
    replacement: "app-metrics"
```

**Example 4: Service Discovery via DNS SRV**
```yaml
dnsSDConfigs:
- names:
  - _prometheus._tcp.my-monitoring-ns.svc.cluster.local
  type: SRV
  port: 9090
relabelConfigs:
  - source_labels: [__meta_srv_name]
    target_label: monitoring_instance
```

---

## Clarification: ScrapeConfig vs. MultiClusterObservability Remote Write

### Common Confusion

You may wonder: *"If MultiClusterObservability CR already configures remote write, how does ScrapeConfig fit in?"*

### The Distinction

| Component | Responsibility | Configured By |
|-----------|-----------------|---------------|
| **MultiClusterObservability CR** | **Where** metrics are sent (remote destination) | Hub platform administrator |
| **ScrapeConfig** | **What** endpoints the agent scrapes from | Managed cluster administrator |

They work together, not in conflict:

```
┌─────────────────────────────────────────────────────────┐
│ Managed Cluster                                         │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  [UWL Prometheus] ◄──[ScrapeConfig]                    │
│       ▲                                                 │
│       │ (scrape targets for federation)                │
│       │                                                 │
│  [Prometheus Agent]                                     │
│       │                                                 │
│       │ remoteWrite (enforced by MCOA from MultiClusterObservability) │
│       ▼                                                 │
│    [Hub] ────────────────────►                         │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### What MCOA Enforces

MCOA automatically configures and enforces:
- ✅ The Hub's remote write endpoint
- ✅ Base TLS configurations to the Hub
- ✅ Remote write timeout settings

### What You Can Customize

You have full control over:
- ✅ Which endpoints to scrape (ScrapeConfig targets)
- ✅ TLS settings for scraping (tlsConfig)
- ✅ Relabeling rules (writeRelabelConfigs)
- ✅ Custom scrapeClass definitions

**No conflicts** — The platform controls destination; you control sources.

---

## Key Takeaways
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

---

**Last Updated**: June 2026  
**Version**: 1.0
