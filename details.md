YAML examples demonstrating how to implement these optimizations using the MultiCluster Observability Addon (MCOA) configurations:

## 1. Pre-Aggregation on the Spoke

To implement pre-aggregation, you define a `PrometheusRule` to calculate the aggregated metric locally on the managed cluster, and then you use a `ScrapeConfig` to collect only that newly aggregated metric.

### Step A: Create the PrometheusRule

This rule aggregates raw memory data into a new, lower-cardinality sum metric.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: custom-aggregation-rules
  namespace: open-cluster-management-observability
spec:
  groups:
  - name: my-rules-group
    rules:
      # Creates a new aggregated metric locally on the spoke
      - record: container_memory_rss:sum
        expr: sum(container_memory_rss) by (container, namespace)
```

### Step B: Create the ScrapeConfig

This configuration targets the new aggregated metric to be federated and sent to the hub. Be sure to include the proper `app.kubernetes.io/component` label so MCOA applies it to the correct Prometheus Agent.

```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: collect-aggregated-metric
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/component: user-workload-metrics-collector
spec:
  jobName: aggregated-metrics
  metricsPath: /federate
  params:
    match[]:
    # Collect ONLY the new pre-aggregated record, dropping the raw data
    - '{__name__="container_memory_rss:sum"}'
```

---

## 2. Dropping Unnecessary Metrics

If you want to prevent specific metrics (like the `Watchdog` alert) from consuming network bandwidth and hub storage, you can apply a `writeRelabelConfigs` block directly to the `PrometheusAgent`'s remote-write configuration. This drops the metric after it is federated, but before it is sent over the network to the hub.

```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: PrometheusAgent
metadata:
  # The name of your specific agent deployed by MCOA
  name: mcoa-default-platform-metrics-collector-global
  namespace: open-cluster-management-observability
spec:
  remoteWrite:
    - name: acm-observability
      # Other enforced fields like url and tlsConfig will remain intact via server-side apply
      writeRelabelConfigs:
        # Drop the Watchdog metric before it leaves the spoke cluster
        - action: drop
          regex: ^Watchdog$
          sourceLabels:
            - alertname
```

> **Note:** The closing triple backticks on the inner code blocks above have a space inserted to prevent them from terminating this outer block. Remove the space (`` ` `` `` ` `` `` ` `` → ` ``` `) in your actual `.md` file.
