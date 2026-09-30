# Local scrape level

Apply drop rules on an individual `ScrapeConfig` so matching series never enter the Prometheus Agent write-ahead log on the spoke.

`metricRelabelings` runs while that scrape is handled. Samples that match `action: drop` are discarded before the Agent appends them. They do not sit on spoke disk, and they do not remote-write.

`writeRelabelConfigs` on `PrometheusAgent.spec.remoteWrite` runs later. Those samples are already in the Agent WAL. That rule only decides whether they leave the cluster.

## Where to put the rule

Add the drop to the `ScrapeConfig` that federates the series. A second `ScrapeConfig` does not filter another job. If `platform-metrics-default` still lists the name in `match[]`, that job still writes it to the WAL.

On the hub, in `open-cluster-management-observability`:

```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: add-custom-metrics
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/part-of: multicluster-observability-addon
    app.kubernetes.io/component: platform-metrics-collector
  annotations:
    observability.open-cluster-management.io/placements: "open-cluster-management-global-set/global"
spec:
  jobName: some-job-name
  metricsPath: /federate
  params:
    match[]:
      - '{__name__="container_memory_rss"}'
      - '{__name__="container_cpu_cfs_periods_total"}'
  metricRelabelings:
    - action: drop
      sourceLabels: [__name__]
      regex: ^(container_memory_rss|container_cpu_cfs_periods_total)$
```

The MCOA controller registers a labeled `ScrapeConfig` on the `ClusterManagementAddOn`. For a platform job, leave `scrapeClass`, `scheme`, and `staticConfigs` unset in Git. The controller fills those when it renders the spoke.

Use `user-workload-metrics-collector` when the target is user-workload Prometheus.

## What this saves

The in-cluster Prometheus already stored the series. Federation still returns them over HTTP. `metricRelabelings` then drops them before the Agent WAL. Spoke disk, Agent memory, and hub ingest all skip those series. The platform Prometheus WAL does not.

Omit the name from `match[]` when the series should not be transferred at all. That is earlier than a drop rule. Use `metricRelabelings` when the federate matcher is wider than what you want to keep: drop by name, drop by another label (`uri`, `alertname`), or `labeldrop` a high-cardinality label and keep the metric.

`labeldrop` still stores the series. Only `action: drop` keeps it out of the WAL.
