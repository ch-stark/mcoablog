# Drop a default platform metric

The MultiCluster Observability operator owns the default platform `ScrapeConfig` and writes `spec.params.match[]` back to the built-in list. Deleting a name from that list does not stick. Federation keeps returning the series.

Drop the series on that same object with `spec.metricRelabelings`. The Agent still federates the samples from in-cluster Prometheus, then discards matches before the write-ahead log. They do not sit on spoke disk, and they do not remote-write.

The object is `ScrapeConfig/platform-metrics` in `open-cluster-management-observability`. It is shared by every placement, so a rule here applies to the whole fleet.

```bash
oc get scrapeconfig -n open-cluster-management-observability \
  -l app.kubernetes.io/managed-by=multicluster-observability-operator
```

## Keep the operator rule first

`platform-metrics` already labeldrops hub identity labels. On current builds that rule is:

```yaml
metricRelabelings:
  - action: labeldrop
    regex: managed_cluster|managed_cluster_name|id
```

Append custom rules after it. The operator leaves a longer `metricRelabelings` list in place when its own rules stay the prefix. Replacing the list, or inserting a rule above the operator rule, is rewritten back to the operator’s list on the next reconcile.

A release that changes this spec does that rewrite too. After an upgrade, read the live list and append the drop again if it is gone.

`labeldrop` still stores the series. `action: drop` is what keeps it out of the WAL.

## Drop by name

`container_memory_rss` and `container_cpu_cfs_periods_total` are in the default `match[]`. This appends a drop after the existing rules:

```bash
oc patch scrapeconfig platform-metrics \
  -n open-cluster-management-observability \
  --type=json \
  -p='[{"op":"add","path":"/spec/metricRelabelings/-","value":{"action":"drop","sourceLabels":["__name__"],"regex":"^(container_memory_rss|container_cpu_cfs_periods_total)$"}}]'
```

The live list then ends with the custom rule:

```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: platform-metrics
  namespace: open-cluster-management-observability
spec:
  jobName: platform
  metricsPath: /federate
  params:
    match[]:
      - '{__name__="container_memory_rss",container!="POD",container!=""}'
      - '{__name__="container_cpu_cfs_periods_total"}'
      # ...the rest of the default list stays...
  metricRelabelings:
    - action: labeldrop
      regex: managed_cluster|managed_cluster_name|id
    - action: drop
      sourceLabels: [__name__]
      regex: ^(container_memory_rss|container_cpu_cfs_periods_total)$
```

Leave `match[]` as the operator rendered it. A full `oc apply` of this object from Git will fight that list.

## Drop by another label

The default matcher for `container_memory_rss` is every non-POD container. To drop one namespace and keep the rest, append a rule that joins `__name__` and `namespace` (the default separator is `;`):

```bash
oc patch scrapeconfig platform-metrics \
  -n open-cluster-management-observability \
  --type=json \
  -p='[{"op":"add","path":"/spec/metricRelabelings/-","value":{"action":"drop","sourceLabels":["__name__","namespace"],"regex":"container_memory_rss;openshift-monitoring"}}]'
```

The same pattern applies to the other operator-owned jobs. `platform-metrics-alerts` federates `{__name__="ALERTS"}`. Append a drop there to discard one alert and keep the rest:

```bash
oc patch scrapeconfig platform-metrics-alerts \
  -n open-cluster-management-observability \
  --type=json \
  -p='[{"op":"add","path":"/spec/metricRelabelings/-","value":{"action":"drop","sourceLabels":["alertname"],"regex":"^Watchdog$"}}]'
```

Each job needs its own rule. A second `ScrapeConfig` filters only the series that job federates.

## What this saves

In-cluster Prometheus already stored the series, and the `/federate` response still includes them. `metricRelabelings` then drops them before the Agent WAL. Spoke disk, Agent memory, and hub ingest skip those series.

Default Perses dashboards are unchanged. A panel that queries a dropped name has no samples.

`writeRelabelConfigs` on `PrometheusAgent.spec.remoteWrite` runs later. Those samples are already in the Agent WAL. That rule only decides whether they leave the cluster.

## Metrics you add yourself

On a `ScrapeConfig` you created, leave the name out of `match[]` when the series should not be transferred. Use `metricRelabelings` when that matcher is wider than the series you want to keep. The operator does not reconcile `match[]` on those objects.
