# Add a ScrapeConfig via Git: fleet metrics without hub `oc apply`

**Audience:** Platform engineers and GitOps owners who already manage ACM from Git.  
**Applies to:** MultiCluster Observability Addon (MCOA) custom metrics in ACM 5.0.  
**Status:** Draft 5.0

A custom metric that exists only because someone ran `oc apply` on the hub will disappear the next time that person is on leave. MCOA is built around Kubernetes APIs (`ScrapeConfig`, `PrometheusRule`). Those objects belong in Git, the same way you already store other hub config.

This post is the GitOps path for [MCOA core and configuration](mcoa-core-and-configuration-draft5.0.md). You author a `ScrapeConfig` (or `PrometheusRule`) in a repo and sync it to the hub. The MCOA controller auto-discovers those objects from labels plus a **placement annotation**, then registers them on the `ClusterManagementAddOn`. The addon ships them to managed clusters.

You do not patch the `ClusterManagementAddOn`. The controller owns that list.

## Why Git, not a one-off apply

Each extra federation job is a `ScrapeConfig` in `open-cluster-management-observability`. The controller picks it up when **all** of the following are set:

- `app.kubernetes.io/part-of: multicluster-observability-addon`
- `app.kubernetes.io/component: platform-metrics-collector` **or** `user-workload-metrics-collector`
- Annotation `observability.open-cluster-management.io/placements` listing `namespace/placement` pairs (comma-separated). Use an annotation, not a label: placement names plus namespaces can exceed the 63-character label limit.

Example: `observability.open-cluster-management.io/placements: "open-cluster-management-global-set/global"`

The controller adds those names to the hub `ClusterManagementAddOn` (CMA). The addon manager then copies them into a `ManifestWork` per placement. Remove the annotation, set it to `none`, or delete the object and the controller drops the CMA entry (user-defined objects only; defaults stay under addon ownership).

That split is useful:

- Git holds the metric selectors you actually want (`match[]`, relabeling).
- The controller keeps the CMA in sync with those objects.
- Spokes receive scrape jobs that exist in Git and that the controller has registered.

Review, revert, and promotion then look like every other ACM config: pull request, sync.

Do **not** GitOps-replace the entire `multicluster-observability-addon` CMA. The controller and the addon already write default `PrometheusAgent` and platform `ScrapeConfig` names there. A full replace drops them and breaks the default dashboards.

## Repo layout

```text
mcoa-metrics/
  scrapeconfigs/
    kustomization.yaml
    platform-custom-apiserver-up.yaml
  gitops/
    application.yaml
```

## 1. Commit the `ScrapeConfig`

Keep it in `open-cluster-management-observability`. Set the `part-of` and collector labels, plus the placements annotation. Required spec fields: `jobName`, `metricsPath: /federate`, `params.match[]`.

```yaml
# scrapeconfigs/platform-custom-apiserver-up.yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: platform-custom-apiserver-up
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/part-of: multicluster-observability-addon
    app.kubernetes.io/component: platform-metrics-collector
  annotations:
    observability.open-cluster-management.io/placements: "open-cluster-management-global-set/global"
spec:
  jobName: platform-custom-apiserver-up
  metricsPath: /federate
  params:
    match[]:
      - 'up{job="apiserver"}'
```

For user-workload series, enable user-workload monitoring on the managed clusters **and** `spec.capabilities.userWorkloads.metrics.default.enabled: true` on the MCO CR. You may need `scrapeClass` and `staticConfigs` (user-workload Prometheus or a Cluster Observability Operator `MonitoringStack`).

```yaml
# scrapeconfigs/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: open-cluster-management-observability
resources:
  - platform-custom-apiserver-up.yaml
```

Start with a **short** `match[]`. A wide regex on a high-cardinality name is how you fill Thanos Receive. Pair this with [Cardinality](cardinality-draft5.0.md).

## 2. Sync it with OpenShift GitOps

Point an `Application` at that path. Destination namespace must match the `ScrapeConfig`.

```yaml
# gitops/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mcoa-custom-scrapeconfigs
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://git.example.com/platform/mcoa-metrics.git
    targetRevision: main
    path: scrapeconfigs
  destination:
    server: https://kubernetes.default.svc
    namespace: open-cluster-management-observability
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

Leave `prune: false` until you are sure Git is the only writer of these objects. MCOA-generated defaults should **not** live in this Application.

After sync, the controller registers the new `ScrapeConfig` on the CMA. You do not add a JSON patch or edit the CMA by hand.

## 3. Verify hub, ManifestWork, spoke

```bash
# Hub object from Git
oc get scrapeconfig platform-custom-apiserver-up -n open-cluster-management-observability

# Controller registered it on the CMA
oc get cma multicluster-observability-addon -o yaml | grep platform-custom-apiserver-up

# Spoke rollout
oc get manifestworks -n <managed-cluster-namespace> | grep -i observ

# Spoke copy (default install namespace)
oc get scrapeconfig -n open-cluster-management-agent-addon
```

Query Perses for `up{job="apiserver"}` and expect `cluster` / `clusterID`. If the series is missing, check add-on status, Agent logs, and whether you queried at a five-minute step instead of native resolution.

## Ordering and failure modes

| Mistake | What you see | Fix |
| :--- | :--- | :--- |
| Wrong collector or missing `part-of` label | Object exists, controller ignores it | `part-of: multicluster-observability-addon` plus `platform-metrics-collector` or `user-workload-metrics-collector` |
| Missing placements annotation | Object exists, never appears on the CMA | `observability.open-cluster-management.io/placements: "namespace/placement"` |
| GitOps prune of default scrape configs | Default dashboards empty | Separate Application; `prune: false`; never list MCOA defaults in your overlay |
| Full CMA replace from Git | Defaults gone, Agents mismatched | Leave the CMA to the controller |
| User-workload config, UWM off | Empty federation | Enable UWM on the spoke and on the MCO CR |
| Wide `match[]` | Receive CPU and storage climb | Narrow matchers; pre-aggregate with `PrometheusRule` |

## Try it

1. Enable MCOA ([core post](mcoa-core-and-configuration-draft5.0.md)).
2. Commit one small `ScrapeConfig` with the collector label. Sync it.
3. Confirm the CMA lists the name, a `ManifestWork` exists, and the series shows in Perses.
4. Only then add more matchers or a second file.

If you still have a legacy `observability-metrics-custom-allowlist`, convert it with the `allowlist-migration` CLI (Fleet Management console, **Help > Command Line Tools**), commit the generated YAML, and let the controller register those objects the same way.

Product docs:

- [ACM Observability](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/)
