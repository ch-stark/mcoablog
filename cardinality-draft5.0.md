# Cardinality: see fleet series growth without taking the hub down

**Audience:** Platform engineers and SREs who own ACM Observability cost and hub stability.  
**Applies to:** MultiCluster Observability Addon (MCOA) collection plus cardinality dashboards in ACM 5.0. Perses dashboards are generally available.  
**Status:** Draft 5.0

Cardinality is not a dashboard problem. It is the number of unique time series you agreed to store. On a fleet, that number is (metrics) × (labels) × (clusters). One extra label with a request ID, times a few hundred clusters, is enough to make Thanos Receive and the query path expensive.

MCOA gives you two levers that the legacy allowlist did not:

1. **Stop shipping the explosion** — narrow `ScrapeConfig` matchers, drop labels at scrape time, record aggregates on the spoke.
2. **See who is exploding** — cardinality dashboards that read **pre-computed** series, not a live `count({__name__=~".+"})` across the fleet.

This post covers both. Collection control is MCOA configuration. Cardinality views in Perses read the pre-computed series.

## Why a live cardinality query hurts

Counting unique series across every managed cluster in one query walks a large index. The hub loads it into memory, CPU spikes, and the dashboard you opened either is late or never returns.

Cardinality also changes slowly. You do not need a five-second view of “how many series does cluster 47 have.” You need a trend: which cluster, namespace, or metric name grew this week.

So ACM does not count on click. Recording rules run on a longer interval (30 minutes in the sharded-dashboard design). The dashboard reads those small recorded series.

The remaining trap is the pre-compute itself. **One** rule that covers the whole fleet still produces a sharp CPU and memory peak every half hour. Sharding splits that work.

## Control cardinality at collection (do this first)

Dashboards without collection hygiene only tell you the hub is already in trouble. Cut series before they remote-write.

### Narrow the `match[]`

Federation is explicit. If a name is not in a `ScrapeConfig`, MCOA does not ship it. Prefer a named metric over `{__name__=~".*"}`. Prefer one extra `ScrapeConfig` per concern (API server, virtualization, one app) so you can shard federation and delete one job without touching the others.

See [Add a ScrapeConfig via Git](add-scrape-config-via-git-draft5.0.md).

### Drop labels before they hit the WAL

User-workload metrics often carry `session_id`, `transaction_id`, `user_agent`, or a raw URI. Those labels are the usual explosion.

`metricRelabelings` on the `ScrapeConfig` run at scrape time. Dropped labels never enter the Agent’s WAL, so you save spoke disk and hub ingest.

```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: cardinal-controlled-app-metrics
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/component: user-workload-metrics-collector
spec:
  jobName: high-cardinality-app-scrape
  metricsPath: /federate
  params:
    match[]:
      - '{__name__=~"http_server_.*"}'
  metricRelabelings:
    - action: labeldrop
      regex: ^(session_id|transaction_id|client_ip_address|user_agent)$
    - action: drop
      regex: ^(/healthz|/metrics|/readyz)$
      sourceLabels:
        - uri
```

Register the object on the `ClusterManagementAddOn` like any other custom scrape job.

Use `writeRelabelConfigs` on the `PrometheusAgent` remote-write when you still want the series **on the spoke** (local dashboards) but not on the hub. That is destination filtering, not a WAL saving.

### Pre-aggregate on the spoke

If you need a signal but not every series, record a lower-cardinality name on the managed cluster, then scrape **only** that name.

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
        - record: container_memory_rss:sum
          expr: sum(container_memory_rss) by (container, namespace)
---
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
      - '{__name__="container_memory_rss:sum"}'
```

Add both objects to the CMA (`scrapeconfigs` in group `monitoring.rhobs`, `prometheusrules` in group `monitoring.coreos.com`). Optional annotation `observability.open-cluster-management.io/target-namespace` pins a rule to a workload namespace.

This is the same idea product docs describe when they tell you to use `PrometheusRule` to limit cardinality of collected metrics.

## See cardinality without a hub incident

Cardinality dashboards read compact recorded series, for example:

- Cardinality per cluster
- Cardinality per cluster and namespace
- Cardinality per metric name

Thanos Ruler evaluates **sharded** recording rules so the half-hour job is not one giant query.

Instead of one rule that counts every cluster at once, ACM splits the fleet into groups. Each group is its own rule. Ruler runs them in sequence. The dashboard queries the small outputs. The expensive work already happened, and it did not all hit at once.

**Shard count:** use a **power of two** (2, 4, 8, 16, 32, …) near your managed-cluster count. On a demo hub with **8** managed clusters, **8** shards is the closest power of two and about one shard per cluster. Peak work for that job is spread across eight rules instead of concentrated in one. Empty shards cost almost nothing; a few extra shards are safer than too few.

Sharding keys off the OpenShift `clusterID` (a UUID). Other Kubernetes distributions may use IDs that do not split evenly. If you mix cluster types, read the generated matchers before you apply them.

### Enable the sharded rules

You need ACM Observability running and permission to edit `open-cluster-management-observability`.

1. Count managed clusters. Pick a power-of-two shard factor.

2. Generate rules from [multicluster-observability-operator/tools](https://github.com/stolostron/multicluster-observability-operator/tree/main/tools):

   ```bash
   ./generate-cardinality-sharded-rules.sh 8 > thanos-ruler-custom-rules.yaml
   ```

3. Apply on the hub:

   ```bash
   oc apply -f thanos-ruler-custom-rules.yaml
   ```

If `thanos-ruler-custom-rules` already holds other custom rules, **merge** the generated groups. Replacing the whole ConfigMap drops those rules.

Thanos Ruler reloads on its own. After the first 30-minute run, the cardinality dashboards in Perses start to fill.

Try the sharded rules on a non-production hub first. Compare ruler CPU and memory around the 30-minute mark with and without sharding.

What you should see after the first interval:

- Which clusters or namespaces dominate series count
- Which metric names produce the most series
- A trend, not a one-off scrape

You still get a detailed breakdown. The difference is *when* the heavy work runs, and *how* it is divided.

## Raw collection makes cardinality worse on purpose

[Raw metrics collection](raw-metrics-collection-draft5.0.md) ships native scrape resolution instead of five-minute federation. That is more points per series, not more series—unless you also widen `match[]`. Do not annotate the default platform allowlist as `raw` while you are still hunting cardinality outliers. Fix the series set first.

High-availability Prometheus (two replicas) also **doubles ingest** of whatever you collect. Thanos Compactor later drops redundant samples from object storage; Receive still processes both streams.

## Try it

1. Find one high-cardinality name (container memory with pod UID, HTTP with session ID). Drop or record-sum it on a `ScrapeConfig` / `PrometheusRule` in Git.
2. Confirm hub ingest and dashboard queries still answer the operational question you needed.
3. On a lab hub, generate sharded cardinality rules and watch ruler CPU at the 30-minute mark.

Product docs:

- [ACM Observability](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/)
