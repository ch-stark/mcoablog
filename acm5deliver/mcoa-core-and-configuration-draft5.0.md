# MCOA core and configuration: how ACM collects fleet metrics now

**Audience:** Platform engineers, SREs, and architects who run Red Hat Advanced Cluster Management for Kubernetes (ACM) Observability.  
**Applies to:** MultiCluster Observability Addon (MCOA) metrics collection in ACM 5.0.  
**Status:** Draft 5.0

You do not need a second observability stack to watch a fleet. You need a collector that speaks the same APIs as OpenShift monitoring, survives a network blip, and lets you change *what* is collected without rewriting a custom allowlist.

That is the job of the **multicluster observability add-on (MCOA)**. It replaces the legacy endpoint operator and metrics collector with the Prometheus Operator and Prometheus Agent from the Red Hat OpenShift Cluster Observability Operator. Configuration moves from a single allowlist ConfigMap to standard `PrometheusAgent`, `ScrapeConfig`, and `PrometheusRule` objects.

This post is the core of the series. It covers what MCOA is, how you turn it on, which objects you actually edit, and what the addon manager will overwrite if you fight it.

## The problem the legacy collector hit

The older ACM metrics collector worked. It also owned the whole path: scrape, filter, ship. Custom metrics lived in `observability-metrics-custom-allowlist`. Recording rules lived in the same ConfigMap. Federation ran as one large pull.

That model does not age well:

- High-cardinality jobs share a single federation request with everything else.
- Custom allowlists are not Git-native Kubernetes APIs.
- Remote-write tuning, relabeling, and extra destinations are awkward.
- A partition between spoke and hub drops samples that the in-cluster Prometheus already had.

MCOA keeps the hub-side Thanos / Observatorium store. It changes **how managed clusters collect and send**.

## What changes

| Concern | Legacy add-on | MCOA |
| :--- | :--- | :--- |
| Spoke collector | Endpoint operator and custom metrics collector | Prometheus Agent, reconciled by Prometheus Operator |
| Workload config | Fields on the `MultiClusterObservability` (MCO) CR | `PrometheusAgent` CR |
| Metric selection | Allowlist ConfigMap | `ScrapeConfig` CRs |
| Recording and alerting rules | Allowlist ConfigMap | `PrometheusRule` CRs |
| Deployment | ManifestWorks from the MCO operator | Addon manager (`addon-framework`) and `ClusterManagementAddOn` |

Platform metrics still federate from in-cluster Prometheus (on OpenShift, that is Cluster Monitoring Operator). User-workload metrics federate from user-workload Prometheus, or from a Cluster Observability Operator `MonitoringStack` if you point a `ScrapeConfig` at it.

The Agent then **remote-writes** to the hub. It buffers in a local write-ahead log (WAL), so a short partition does not empty the queue. Product documentation describes that window as on the order of **up to two hours**, and it is configuration-dependent—not a hard SLO.

## Enable MCOA from the MCO CR

You still enable Observability with a `MultiClusterObservability` resource. MCOA is the `capabilities` block. Platform metrics are required. User-workload metrics, alert metrics, and right-sizing analytics are optional.

In ACM 5.0, **Perses** is the generally available dashboard for hub and managed-cluster metrics. Query series there after collection is up.

```yaml
apiVersion: observability.open-cluster-management.io/v1beta2
kind: MultiClusterObservability
metadata:
  name: observability
spec:
  instanceSize: small   # small, medium, large, … — hub-side Thanos sizing
  capabilities:
    platform:
      analytics:
        namespaceRightSizingRecommendation:
          enabled: true
        virtualizationRightSizingRecommendation:
          enabled: true
      metrics:
        alerts:
          enabled: false
        default:
          enabled: true
    userWorkloads:
      metrics:
        alerts:
          enabled: false
        default:
          enabled: true
  storageConfig:
    metricObjectStorage:
      name: thanos-object-storage
      key: thanos.yaml
```

| Field | What it does |
| :--- | :--- |
| `platform.metrics.default` | Required for MCOA. Federates the default platform metric set. |
| `userWorkloads.metrics.default` | Optional. Federates user-workload metrics. |
| `platform.metrics.alerts` / `userWorkloads.metrics.alerts` | Optional. Set `enabled: true` to collect alert-rule metrics (`ALERTS`) for that stack. The example above leaves both off. |
| `platform.analytics.namespaceRightSizingRecommendation` | Optional. Namespace right-sizing recommendations. |
| `platform.analytics.virtualizationRightSizingRecommendation` | Optional. OpenShift Virtualization right-sizing recommendations. |

When platform (and, if you want it, user-workload) metrics default to `enabled: true`:

1. The MCO operator **stops** deploying the legacy metrics collectors.
2. It deploys `multicluster-observability-addon-manager` in `open-cluster-management-observability`.
3. That manager creates default `PrometheusAgent`, `ScrapeConfig`, and `PrometheusRule` objects and registers them on the `ClusterManagementAddOn` named `multicluster-observability-addon`.

Prerequisites from product docs: Observability is already enabled on the hub, and Cluster Observability Operator is installed.

```bash
oc patch mco observability --type=merge -p '{"spec":{"capabilities":{"platform":{"metrics":{"default":{"enabled": true}}},"userWorkloads":{"metrics":{"default":{"enabled": true}}}}}}'
```

That patch only enables default metric collection. Set `metrics.alerts` and `platform.analytics` in the CR (as in the YAML above) when you want alert metrics or right-sizing recommendations.

```bash
oc get prometheusagents -n open-cluster-management-observability
oc get cma multicluster-observability-addon -o yaml | yq '.spec.installStrategy.placements'
```

`observabilityAddonSpec` (interval, workers, `enableMetrics`) is the **legacy** collector. Do not use it to tune MCOA scrape interval. Change `spec.scrapeInterval` on the `PrometheusAgent` instead (default `300s`).

## The four objects you will actually touch

### 1. `ClusterManagementAddOn` — who gets which config

MCOA does not watch every `ScrapeConfig` in the cluster and push it everywhere. It deploys the objects **named in the placement `configs` list**.

```yaml
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ClusterManagementAddOn
metadata:
  name: multicluster-observability-addon
spec:
  installStrategy:
    type: Placements
    placements:
      - name: global
        namespace: open-cluster-management-global-set
        configs:
          - group: monitoring.rhobs
            resource: prometheusagents
            name: acm-platform-metrics-collector-default
            namespace: open-cluster-management-observability
          - group: monitoring.rhobs
            resource: scrapeconfigs
            name: platform-metrics-default
            namespace: open-cluster-management-observability
```

Default platform scrape configs that MCOA generates include:

- `platform-metrics-default` — base platform set
- `platform-metrics-hcp` — hosted control planes
- `platform-metrics-virtualization` — OpenShift Virtualization
- `platform-metrics-alerts` — alert-rule metrics, when `platform.metrics.alerts.enabled` is `true`

One `PrometheusAgent` is created **per placement**. Default `ScrapeConfig` and `PrometheusRule` objects are **shared** across placements unless you add your own.

Do not replace this object from Git with a stub that only lists your custom config. You will drop the defaults and break the default dashboards. Leave the CMA to the MCOA controller. See [Add a ScrapeConfig via Git](add-scrape-config-via-git-draft5.0.md).

### 2. `PrometheusAgent` — how the collector runs

This is the spoke collector: scrape interval, resources, remote-write URL, queue, and global `writeRelabelConfigs`.

The addon manager uses **server-side apply** to keep invariants: hub remote-write destination, TLS to the hub, timeout. You can still set `scrapeInterval`, `logLevel`, `resources`, `queueConfig`, and extra `writeRelabelConfigs` on the hub `acm-observability` remote-write entry. Removing that entry does not stick.

```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: PrometheusAgent
metadata:
  name: mcoa-default-platform-metrics-collector-global
  namespace: open-cluster-management-observability
spec:
  logLevel: warn
  scrapeInterval: 300s
  remoteWrite:
    - name: acm-observability
      remoteTimeout: 30s
      queueConfig:
        minShards: 2
        maxShards: 15
        capacity: 10000
        maxSamplesPerSend: 2000
        batchSendDeadline: 5s
```

`AddonDeploymentConfig` sets install namespace (default `open-cluster-management-agent-addon`), node placement, and proxy. Values there override ad-hoc edits of the same fields on other resources.

### 3. `ScrapeConfig` — what gets federated

A `ScrapeConfig` is a named federation job: `jobName`, `metricsPath: /federate`, and `params.match[]`. Label it so the right Agent picks it up:

- `app.kubernetes.io/part-of: multicluster-observability-addon`
- `app.kubernetes.io/component: platform-metrics-collector` **or** `user-workload-metrics-collector`
- Annotation `observability.open-cluster-management.io/placements: "namespace/name"` (comma-separated, no spaces)

For platform jobs, the controller server-side-applies `scrapeClass`, `scheme`, and `staticConfigs` to `not-configurable` so spoke rendering can fill them per cluster. Do not set those fields in Git. User-workload jobs often need `scrapeClass` and `staticConfigs` set yourself.

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
      - '{__name__="up"}'
```

Creating the object is enough. The MCOA controller auto-discovers it and registers it on the `ClusterManagementAddOn` ([PR 509](https://github.com/stolostron/multicluster-observability-addon/pull/509)). You do not patch the CMA by hand. GitOps walkthrough: [Add a ScrapeConfig via Git](add-scrape-config-via-git-draft5.0.md).

Independent `ScrapeConfig` objects are how MCOA **shards** federation: several smaller pulls instead of one huge allowlist. That is the main scalability change from the legacy collector.

### 4. `PrometheusRule` — aggregate before you ship

Use recording rules on the managed cluster when a raw metric is too expensive to store on the hub. Aggregate locally, then scrape only the recorded name. Use API group `monitoring.coreos.com`. The same `part-of` label, collector label, and placements annotation as `ScrapeConfig` make the controller register the rule on the CMA. Optional annotation `observability.open-cluster-management.io/target-namespace` pins the rule to a workload namespace. See [Cardinality](cardinality-draft5.0.md).

## Hub sizing is still `instanceSize`

MCOA changes spoke collection. Hub Thanos Receive, Store, Compactor, and so on still follow `spec.instanceSize` on the MCO CR (`minimal`, `default`, `small`, `medium`, `large`, `xlarge`, …).

If you set CPU, memory, or replicas in `spec.advanced`, those values **override** the t-shirt size for that component. Pick a size first. Override only what you measured.

## Health: the Agent can be up and still not sending

`ManagedClusterAddOn` is degraded if required resources are missing or the platform Agent is not running. That does not catch a live Agent that fails remote-write.

MCOA also ships spoke alerts:

- `MetricsCollectorNotIngestingSamples` — federation produced nothing
- `MetricsCollectorRemoteWriteFailures` — high remote-write error rate
- `MetricsCollectorRemoteWriteBehind` — the send queue is falling behind

Those close the gap between “pod is Running” and “the hub is actually ingesting.” They are separate from `spec.capabilities.*.metrics.alerts`, which controls whether **alert-rule metrics** (`ALERTS`) are collected from platform or user-workload Prometheus.

## What to customize, and what not to

| You configure | The addon manager enforces |
| :--- | :--- |
| Extra `ScrapeConfig` matchers (labeled for the controller) | Hub remote-write URL and TLS |
| `PrometheusRule` recording rules | Default platform scrape set for the included dashboards |
| `scrapeInterval`, `queueConfig`, resources | Reverting deletion of the `acm-observability` remote-write |
| `writeRelabelConfigs` / `metricRelabelings` | Placement-based rollout of named configs |
| Extra remote-write targets (enterprise store) | — |

Migrate a legacy allowlist with the `allowlist-migration` CLI from **Help > Command Line Tools** in the Fleet Management console. Apply the generated `ScrapeConfig` and `PrometheusRule`. The controller registers them on the `ClusterManagementAddOn`.

## Try it

1. Enable platform metrics (and user-workload if you need them) on the MCO CR.
2. Confirm Agents and CMA placements exist.
3. Leave defaults in place until Perses shows the usual platform series (`cluster`, `clusterID`).
4. Add **one** extra `ScrapeConfig` for a metric you already scrape locally. Confirm a `ManifestWork` on the spoke and the series on the hub.

Related drafts in this repo:

- [Add a ScrapeConfig via Git](add-scrape-config-via-git-draft5.0.md)
- [Cardinality](cardinality-draft5.0.md)
- [Raw metrics collection](raw-metrics-collection-draft5.0.md)

Product docs:

- [ACM Observability](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/)
