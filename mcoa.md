# A Guide to the New Era of Observability in Red Hat Advanced Cluster Management

Observability is evolving in Red Hat Advanced Cluster Management for Kubernetes (RHACM). As with everything we build at Red Hat, this evolution is about staying aligned with the latest community best practices while also meeting the most pressing needs of our enterprise customers.

There's no complex migration or heavy lifting required. This blog walks through what has changed with the transition to the MultiCluster Observability Addon (MCOA), how you can seamlessly monitor user workloads, optimize your metrics to control costs, and immediately benefit from built-in network observability.

## What is changing, and why?

RHACM 2.15 is rearchitecting its MultiCluster Observability add-on, which controls metrics collection across the entire managed fleet. The new MCOA replaces custom endpoints and components with established upstream open-source alternatives.

Here is a quick comparison of the architectural changes:

| Feature | Legacy Add-on | New MCOA Add-on |
| :--- | :--- | :--- |
| **Spoke Workloads** | Endpoint Operator & Metrics Collector | Prometheus Agent & Prometheus Operator |
| **Workloads Configuration** | MCO CR | Prometheus Agent CR |
| **Metrics Configuration** | Allow list ConfigMap | ScrapeConfig CRs |
| **Recording Rules** | Allow list ConfigMap | PrometheusRule CRs |
| **Addon Deployment** | MCO with ManifestWorks | Addon Manager (addon framework) |

## Main Benefits of MCOA

**Improved Configurability**
MCOA shifts away from relying on custom legacy components, such as the endpoint operator and metrics collector, in favor of established upstream open-source alternatives. 
* **Standard Kubernetes APIs:** Instead of managing a single monolithic custom resource, configuration is now handled directly using standard Kubernetes APIs such as **`PrometheusAgent`**, **`ScrapeConfig`**, and **`PrometheusRule`**. 
* **Targeted and Safe Customization:** The `multicluster-observability-addon-manager` automatically creates these configurations for each placement referenced in your `ClusterManagementAddOn`  The manager utilizes Kubernetes server-side apply to strictly enforce critical system invariants (like remote write routing), while safely allowing administrators to customize other operational fields, such as the `scrapeInterval` or `logLevel`, without their changes being constantly overwritten.

**Sharded Metrics Federation**
As your fleet and metric cardinality grow, collecting all telemetry data in a single massive request becomes a significant performance bottleneck. 
* **Independent Extraction:** MCOA leverages the Federation API from the in-cluster Prometheus to downsample and extract necessary metric subsets. 
* **Parallel Workloads:** By defining metrics in distinct `ScrapeConfigs`, the workload is sharded. Metrics are federated independently and in parallel rather than in a single pull, which drastically increases scalability and system stability as cardinality grows .

**Standard Remote Write**
MCOA abandons custom payload delivery methods in favor of the industry-standard Prometheus `remoteWrite` protocol, optimizing how data is transmitted from the spoke clusters to the hub .
* **Performance Under Load:** This standard protocol natively offers much better payload management, ensuring that data is sent efficiently and reliably, even under extremely high metric loads.
* **Advanced Pipeline Tuning:** Platform engineers gain direct access to fine-tune the delivery pipeline. You can optimize throughput by adapting the **`queueConfig`** and **`remoteTimeout`**, or apply **`writeRelabelConfigs`** to drop unnecessary metrics before they consume network bandwidth. Additionally, it allows you to configure custom remote-write targets, enabling managed clusters to send metrics directly to external third-party endpoints in real time.

**Improved Network Resiliency**
Edge environments and distributed fleets are frequently prone to network instability. MCOA introduces robust mechanisms to maintain the integrity of your monitoring data during these disruptions.
* **Local Buffering:** The new Prometheus Agent leverages a local Write Ahead Log (WAL) to securely buffer federated metric samples directly onto the managed cluster's disk. 
* **Extended Outage Tolerance:** This architecture provides robust resiliency against network partitions. It allows the system to safely buffer data and survive outages of **up to 2 hours** between the spoke and hub clusters without any data loss before successfully re-syncing.

## How to Migrate & Enable User-Workload Monitoring

If you are using the legacy stack, adopting MCOA is straightforward. Apply the following configuration to your `MultiClusterObservability` custom resource to enable both the platform and user-workload stacks simultaneously:

```
apiVersion: observability.open-cluster-management.io/v1beta2
kind: MultiClusterObservability
metadata:
  name: observability
Spec:
  instanceSize: <size_value> # e.g., small, medium, large
  capabilities:
    platform:
      analytics:
        namespaceRightSizingRecommendation:
          enabled: true # <-- Enables namespace right-sizing
        virtualizationRightSizingRecommendation:
          enabled: true # <-- Enables VM right-sizing
      metrics:
        default:
          enabled: true # <-- Required to enable MCOA for platform metrics
    userWorkloads:
      metrics:
        default:
          enabled: true # <-- Optional to enable MCOA for user workload metrics. . .
```

When executed, this removes the legacy stack and deploys the new `multicluster-observability-addon-manager`. The manager automatically generates the necessary default `PrometheusAgents` and `ScrapeConfigs` for both your platform and user workloads across your fleet.

## Optimizing Metrics and Managing Cardinality

As your fleet grows, managing metric data efficiently becomes key to maintaining performance and controlling your S3 object storage costs. High cardinality—the total number of unique timeseries—can cause performance bottlenecks if left unchecked.

MCOA introduces several ways to optimize your metrics:

* **Built-in Platform Optimization:** MCOA's default platform metrics have undergone a comprehensive review and optimization to enhance observability while minimizing cardinality and maximizing performance out-of-the-box.
* **Cardinality Dashboards (Dev Preview):** RHACM introduces new "Metrics Cardinality" dashboards that help administrators safely identify cardinality outliers, and see which metrics or clusters are driving up storage costs.
* **Pre-Aggregation on the Spoke:** If you have high-cardinality application metrics, you no longer need to send all that raw data to the hub. You can implement a `PrometheusRule` on the managed cluster to aggregate the data locally, and then use a `ScrapeConfig` to only send the aggregated result to the centralized Thanos storage.
* **Dropping Unnecessary Metrics:** If you need to drop specific default metrics (like the `Watchdog` alert) to save space, MCOA allows you to apply `writeRelabelConfigs` directly to the `PrometheusAgent`'s remote-write configuration, dropping the metric before it ever leaves the spoke cluster.

## Out-of-the-box Network Metrics

Previously, gathering deep networking insights across a fleet required heavy custom configuration. With MCOA, networking observability is integrated directly into the standard platform monitoring experience.

The updated default MCOA platform `ScrapeConfigs` automatically collect essential networking metrics and populate a new suite of dedicated network dashboards in your centralized Grafana instance. Without any custom allowlisting, you instantly gain access to:

* Kubernetes / Networking / Cluster
* Kubernetes / Networking / Namespace (Pods)
* Kubernetes / Networking / Node
* Kubernetes / Networking / Pod

## Migrating your Allow List and Custom Metrics

In the legacy architecture, custom metrics were defined in an `observability-metrics-custom-allowlist` ConfigMap. With MCOA, this translates to standard `ScrapeConfig` and `PrometheusRule` custom resources.

> **Note:** Standard platform metrics are collected automatically for the default dashboards, so you do not need to migrate platform metrics—this only applies to your custom allow-list.

To add custom metrics in MCOA, create a `ScrapeConfig` in the `open-cluster-management-observability` namespace and ensure you use the `app.kubernetes.io/component: platform-metrics-collector` (or `user-workload-metrics-collector`) label. To make this transition even easier, RHACM 2.16 introduces a GA `allowlist-migration` command-line utility that automatically converts your legacy ConfigMaps into these new API resources.

## Scaling Made Simple: T-Shirt Sizing

Managing an observability stack across a large hybrid cloud fleet requires right-sizing backend components. RHACM 2.16 addresses this directly by graduating T-Shirt Sizing for hub-side observability to General Availability.

Instead of manually tuning CPU and memory limits for every Thanos component, you can simply specify an `instanceSize` (e.g., `small`, `medium`, `large`) in your MCO CR based on the scale of your environment. This allows the platform to automatically pre-tune components for optimal scalability and efficiency based on your environment's footprint.

## Conclusion

This update to observability in Red Hat Advanced Cluster Management is all about giving you more flexibility, stronger performance, and a smoother experience across your clusters. By seamlessly integrating user-workload monitoring, out-of-the-box network visibility, and powerful tools for metric optimization, MCOA ensures you get the most value from your telemetry data without the operational overhead.
