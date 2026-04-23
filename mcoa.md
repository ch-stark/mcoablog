# A Guide to the New Era of Observability in Red Hat Advanced Cluster Management

We heard you: Observability is evolving in Red Hat Advanced Cluster Management for Kubernetes (RHACM). As with everything we build at Red Hat, this evolution is about staying aligned with the latest community best practices while also meeting the most pressing needs of our enterprise customers.

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

* **Improved Configurability:** You can now directly configure custom resources deployed on your spokes using standard upstream Prometheus operator APIs.
* **Sharded Metrics Federation:** By using distinct `ScrapeConfigs`, metrics can be federated independently from the in-cluster Prometheus, drastically increasing scalability as cardinality grows.
* **Standard Remote Write:** MCOA utilizes the standard Prometheus remote-write protocol to send metrics from the spokes to the hub, offering much better payload management and performance under high load.
* **Unmatched Network Resiliency:** The new Prometheus Agent uses a local Write Ahead Log (WAL) to securely buffer federated metric samples on the managed cluster's disk. This provides robust resiliency against network partitions, allowing the system to survive outages of up to one hour without any data loss before re-syncing with the hub.

## How to Migrate & Enable User-Workload Monitoring

If you are using the legacy stack, adopting MCOA is straightforward. Apply the following configuration to your `MultiClusterObservability` custom resource to enable both the platform and user-workload stacks simultaneously:

```yaml
apiVersion: observability.open-cluster-management.io/v1beta2
kind: MultiClusterObservability
metadata:
  name: observability
spec:
  capabilities:
    platform:
      metrics:
        default:
          enabled: true # <-- required for platform metrics
    userWorkloads:
      metrics:
        collection:
          enabled: true # <-- enables the user-workload monitoring pipeline
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
