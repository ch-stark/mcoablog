# See metric cardinality across your ACM fleet without overloading the hub

If you have ever opened a cardinality dashboard and watched Thanos or Prometheus struggle, you already know the problem. Counting unique time series across every managed cluster at once is one of the most expensive queries in a monitoring stack. The hub loads a large index into memory, CPU spikes, and the view you needed arrives late—or not at all.

Red Hat Advanced Cluster Management (ACM) Observability takes a different path. Cardinality dashboards do not count everything on demand. They read **pre-computed** results from recording rules that run every 30 minutes. Cardinality changes slowly, so that interval is enough to spot label growth, noisy metrics, and clusters that are contributing more series than they should.

The remaining challenge is the pre-compute itself. One rule that covers the whole fleet still creates a sharp peak every half hour. Sharding spreads that work.

## Why sharding matters to you

Instead of one rule that counts series for every cluster at the same time, ACM splits the fleet into smaller groups. Each group is a separate recording rule. Thanos Ruler evaluates them one after another, then writes compact series such as:

- Cardinality per cluster
- Cardinality per cluster and namespace
- Cardinality per metric name

The dashboard queries those small series. That is fast. The expensive work already happened in the background, and it did not all hit the hub at once.

On a hub with **8 managed clusters**, we used **8 shards**—the closest power of two, and roughly one shard per cluster. In that setup, peak CPU and memory for the cardinality job is spread across eight rules instead of concentrated in one. Empty shards cost almost nothing, so it is safer to have a few extra shards than too few.

## Enable it on your hub

You need ACM Observability running, and access to edit resources in `open-cluster-management-observability`.

1. Count your managed clusters. Choose a shard count that is a **power of two** (2, 4, 8, 16, 32, and so on) close to that number. For 8 clusters, use 8. For about 50 clusters, 32 or 64 is a good range.

2. Generate the rules with the script in [multicluster-observability-operator/tools](https://github.com/stolostron/multicluster-observability-operator/tree/main/tools):

   ```bash
   ./generate-cardinality-sharded-rules.sh 8 > thanos-ruler-custom-rules.yaml
   ```

3. Apply them on the hub:

   ```bash
   oc apply -f thanos-ruler-custom-rules.yaml
   ```

If `thanos-ruler-custom-rules` already contains other custom rules, merge the generated groups into the existing ConfigMap. Do not replace the whole object, or you will drop those rules.

Thanos Ruler reloads on its own. After the first 30-minute run, the cardinality dashboards begin to show data.

**Note:** Sharding uses the OpenShift `clusterID` (a UUID). Other Kubernetes distributions may use IDs that do not split evenly. If you mix cluster types, review the generated matchers before you apply them.

## What you should see

Platform and observability teams get a fleet view of series growth without turning a dashboard click into a hub incident. You can:

- Find clusters or namespaces that dominate cardinality
- See which metric names produce the most series
- Track the trend over time, not a one-off scrape

You still get the detailed breakdown. The difference is *when* the heavy work runs, and *how* it is divided.

## Try it

Use the steps above on a non-production hub first, then compare ruler CPU and memory around the 30-minute mark with and without sharding. For the design notes and shard guidance, see [Cardinality Dashboards (ACM 2.15)](https://github.com/stolostron/stolostron/tree/main/dev-preview#cardinality-dashboards-acm-215) in the ACM development preview docs.
