# Add a ScrapeConfig via Git: fleet metrics without hub `oc apply`

**Audience:** Platform engineers and GitOps owners who already manage ACM from Git.  
**Applies to:** MultiCluster Observability Addon (MCOA) custom metrics in ACM 5.0.  
**Status:** Draft 5.0

A custom metric that exists only because someone ran `oc apply` on the hub will disappear the next time that person is on leave. MCOA is built around Kubernetes APIs (`ScrapeConfig`, `PrometheusRule`, `ClusterManagementAddOn`). Those objects belong in Git, the same way you already store `Placement` and other hub config.

This post is the GitOps path for [MCOA core and configuration](mcoa-core-and-configuration-draft5.0.md). You author a `ScrapeConfig` in a repo, sync it to the hub, then **register** it on the addon so MCOA ships it to managed clusters.

Creating the CR is not the rollout. The `ClusterManagementAddOn` reference is.

## Why Git, not a one-off apply

MCOA custom metrics are not a ConfigMap snippet anymore. Each extra federation job is a `ScrapeConfig` in `open-cluster-management-observability`. The addon manager copies **named** configs from the hub `ClusterManagementAddOn` (CMA) into a `ManifestWork` per placement.

That split is useful:

- Git holds the metric selectors you actually want (`match[]`, relabeling).
- The CMA says **which placements** receive that job.
- Spokes never get a scrape job that is not in Git and not in the CMA.

Review, revert, and promotion then look like every other ACM config: pull request, sync, placement.

Do **not** GitOps-replace the entire `multicluster-observability-addon` CMA with a file that only lists your custom config. MCOA already registered default `PrometheusAgent` and platform `ScrapeConfig` names. A full replace drops them and breaks the default dashboards.

## Repo layout

```text
mcoa-metrics/
  scrapeconfigs/
    kustomization.yaml
    platform-custom-apiserver-up.yaml
  cma/
    README.md                 # how to patch, not a full CMA
    cma-scrapeconfig-patch.json
  gitops/
    application.yaml
```

## 1. Commit the `ScrapeConfig`

Keep it in `open-cluster-management-observability`. Set `app.kubernetes.io/component` to `platform-metrics-collector` or `user-workload-metrics-collector`. Required fields: `jobName`, `metricsPath: /federate`, `params.match[]`.

```yaml
# scrapeconfigs/platform-custom-apiserver-up.yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: platform-custom-apiserver-up
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/component: platform-metrics-collector
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

## 3. Register the config on the CMA

Reference the object **after** GitOps has created it. If the name is missing, the add-on status stays `Deploying`.

Store the patch in Git. Apply it from CI (or a one-line Job) so humans are not editing the live CMA:

```json
[
  {
    "op": "add",
    "path": "/spec/installStrategy/placements/0/configs/-",
    "value": {
      "group": "monitoring.rhobs",
      "resource": "scrapeconfigs",
      "name": "platform-custom-apiserver-up",
      "namespace": "open-cluster-management-observability"
    }
  }
]
```

```bash
oc patch clustermanagementaddon multicluster-observability-addon \
  --type=json \
  --patch-file=cma/cma-scrapeconfig-patch.json
```

`placements/0` is the first placement (often `global`). Confirm the index before you patch:

```bash
oc get cma multicluster-observability-addon -o yaml | yq '.spec.installStrategy.placements'
```

If you maintain several placements (prod vs. edge), add the same config entry only where you want that job.

Equivalent YAML on the CMA (fragment, not a full object):

```yaml
spec:
  installStrategy:
    type: Placements
    placements:
      - name: global
        namespace: open-cluster-management-global-set
        configs:
          # defaults already present — do not delete them
          - group: monitoring.rhobs
            resource: scrapeconfigs
            name: platform-custom-apiserver-up
            namespace: open-cluster-management-observability
```

API group for MCOA scrape configs in the CMA is `monitoring.rhobs`. Recording rules use `monitoring.coreos.com` / `prometheusrules`.

## 4. Verify hub, ManifestWork, spoke

```bash
# Hub object from Git
oc get scrapeconfig platform-custom-apiserver-up -n open-cluster-management-observability

# CMA lists it
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
| CMA reference before the CR exists | Add-on `Deploying` | Sync the `ScrapeConfig` first, then patch the CMA |
| GitOps prune of default scrape configs | Default dashboards empty | Separate Application; `prune: false`; never list MCOA defaults in your overlay |
| Full CMA replace from Git | Defaults gone, Agents mismatched | Patch `configs/-` only |
| Wrong `app.kubernetes.io/component` | Object exists, Agent ignores it | `platform-metrics-collector` or `user-workload-metrics-collector` |
| User-workload config, UWM off | Empty federation | Enable UWM on the spoke and on the MCO CR |
| Wide `match[]` | Receive CPU and storage climb | Narrow matchers; pre-aggregate with `PrometheusRule` |

## Try it

1. Enable MCOA ([core post](mcoa-core-and-configuration-draft5.0.md)).
2. Commit one small `ScrapeConfig`. Sync it. Patch the CMA.
3. Confirm `ManifestWork` and the series in Perses.
4. Only then add more matchers or a second file.

If you still have a legacy `observability-metrics-custom-allowlist`, convert it with the `allowlist-migration` CLI (Fleet Management console, **Help > Command Line Tools**), commit the generated YAML, and register those names the same way.

Product docs:

- [ACM Observability](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/)
