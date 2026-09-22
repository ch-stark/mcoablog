# Add a ScrapeConfig via Git: fleet metrics without hub `oc apply`

**Audience:** Platform engineers and GitOps owners who already manage ACM from Git.  
**Applies to:** MultiCluster Observability Addon (MCOA) custom metrics in ACM 5.0.  
**Status:** Draft 5.0  
**Shipped in:** [ACM-34753](https://issues.redhat.com/browse/ACM-34753) / [stolostron/multicluster-observability-addon#509](https://github.com/stolostron/multicluster-observability-addon/pull/509)

GitOps for ACM Observability used to be two commits that hated each other. First you created a `ScrapeConfig` or `PrometheusRule` on the hub. Then you patched the singleton `ClusterManagementAddOn` (`multicluster-observability-addon`) so that name appeared under `spec.installStrategy.placements[].configs[]`. Two writers, one list, merge conflicts every time someone added a matcher.

ACM 5.0 ends that second step. You put the object in Git. You label it and annotate the target placements. The MCOA controller watches those objects, registers them on the `ClusterManagementAddOn` (CMA), and the addon manager copies them to spokes. You never edit the CMA by hand.

This post is the GitOps path for [MCOA core and configuration](mcoa-core-and-configuration-draft5.0.md).

## Why Git, not a one-off apply

A custom metric that exists only because someone ran `oc apply` on the hub will disappear the next time that person is on leave. MCOA is built around Kubernetes APIs. Those objects belong in Git, the same way you already store other hub config.

The controller discovers **user-defined** `ScrapeConfig` and `PrometheusRule` objects in `open-cluster-management-observability` when **all** of the following are set:

- `app.kubernetes.io/part-of: multicluster-observability-addon`
- `app.kubernetes.io/component: platform-metrics-collector` **or** `user-workload-metrics-collector` (hosted-control-plane collectors use their own component labels when HCPs exist)
- Annotation `observability.open-cluster-management.io/placements` listing `namespace/name` placement pairs, **comma-separated with no spaces**

Use an annotation, not a label: namespace plus placement name can exceed the 63-character label limit.

```yaml
observability.open-cluster-management.io/placements: "open-cluster-management-global-set/global"
```

Two placements:

```yaml
observability.open-cluster-management.io/placements: "open-cluster-management-global-set/global,observability/edge"
```

Format is `namespace/name`. A missing `/`, an empty part, or a value like `none` is invalid and fails reconciliation.

That split is useful:

- Git holds the metric selectors you actually want (`match[]`, relabeling, recording rules).
- The controller keeps the CMA in sync with objects that still exist.
- Spokes receive jobs that exist in Git and that the controller has registered.

Review, revert, and promotion then look like every other ACM config: pull request, sync.

Do **not** GitOps-replace the entire `multicluster-observability-addon` CMA. The controller already writes default `PrometheusAgent` and platform `ScrapeConfig` names there. A full replace drops them and breaks the default dashboards.

## How auto-discovery actually works

The resource controller ([PR 509](https://github.com/stolostron/multicluster-observability-addon/pull/509)) splits hub objects into two buckets:

| Kind of object | How the controller treats it |
| :--- | :--- |
| **MCO-owned** (controller owner is the `MultiClusterObservability` UID) | Fan-out to **every** placement already on the CMA. You do not annotate these. |
| **User-defined** (`part-of: multicluster-observability-addon`, not MCO-owned) | Fan-out only to placements in the annotation. Missing annotation: ignored (not registered). |
| Neither MCO-owned nor `part-of` | Ignored. |

For user-defined objects the controller then:

1. Parses the placements annotation into `PlacementRef` values.
2. Appends each object to `spec.installStrategy.placements[].configs[]` on the matching CMA placements.
3. On delete of the hub object, drops that CMA entry (stale-config cleanup). The addon manager removes the spoke copy.

Defaults stay under addon ownership. Your Git Application must not prune them.

**Off-ramp is delete, not a magic annotation value.** Clearing the annotation or changing it from placement A to B does not reliably remove the old CMA row while the object still exists. Delete the hub object (Git prune on *this* Application, or `oc delete`), let the CMA drop the stale name, then sync again if you are moving placements.

## Repo layout

```text
mcoa-metrics/
  scrapeconfigs/
    kustomization.yaml
    platform-custom-apiserver-up.yaml
    platform-custom-recording.yaml
  gitops/
    application.yaml
```

## 1. Commit the `ScrapeConfig`

Keep it in `open-cluster-management-observability`. Set the `part-of` and collector labels, plus the placements annotation. Required spec fields for a federation job: `jobName`, `metricsPath: /federate`, `params.match[]`.

Do **not** set `scrapeClass`, `scheme`, or `staticConfigs` on a **platform** `ScrapeConfig`. The controller server-side-applies those to `not-configurable` / `HTTPS` so spoke rendering can fill them per cluster. If Git keeps those fields, OpenShift GitOps will fight the controller. User-workload jobs are different: you may need `scrapeClass` and `staticConfigs` (user-workload Prometheus or a Cluster Observability Operator `MonitoringStack`).

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

For user-workload series, enable user-workload monitoring on the managed clusters **and** `spec.capabilities.userWorkloads.metrics.default.enabled: true` on the MCO CR. Switch the component label to `user-workload-metrics-collector`.

The same labels and annotation work for a `PrometheusRule`. Recording rules belong here when you want to pre-aggregate before federation, not after Thanos Receive is already full. Pair with [Cardinality](cardinality-draft5.0.md).

```yaml
# scrapeconfigs/platform-custom-recording.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-custom-recording
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/part-of: multicluster-observability-addon
    app.kubernetes.io/component: platform-metrics-collector
  annotations:
    observability.open-cluster-management.io/placements: "open-cluster-management-global-set/global"
spec:
  groups:
    - name: mcoa-custom.rules
      rules:
        - record: cluster:apiserver_up:sum
          expr: sum by (cluster) (up{job="apiserver"})
```

```yaml
# scrapeconfigs/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: open-cluster-management-observability
resources:
  - platform-custom-apiserver-up.yaml
  - platform-custom-recording.yaml
```

Start with a **short** `match[]`. A wide regex on a high-cardinality name is how you fill Thanos Receive.

## 2. Sync it with OpenShift GitOps

Point an `Application` at that path. Destination namespace must match the objects (`open-cluster-management-observability`).

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

Leave `prune: false` until you are sure Git is the only writer of *these* objects. Then turn prune on for this Application so a Git delete actually removes the hub object and the controller can drop the CMA entry. MCOA-generated defaults must **not** live in this Application.

After sync, the controller registers the new objects on the CMA. You do not add a JSON patch or edit the CMA by hand.

## 3. Verify hub, ManifestWork, spoke

```bash
# Hub objects from Git
oc get scrapeconfig platform-custom-apiserver-up -n open-cluster-management-observability
oc get prometheusrule platform-custom-recording -n open-cluster-management-observability

# Controller registered them on the CMA (per placement configs[])
oc get clustermanagementaddon multicluster-observability-addon \
  -o jsonpath='{range .spec.installStrategy.placements[*]}{.placementRef.namespace}/{.placementRef.name}{"\n"}{range .configs[*]}{.name}{"\n"}{end}{end}'

# Spoke rollout
oc get manifestworks -n <managed-cluster-namespace> | grep -i observ

# Spoke copy (default install namespace)
oc get scrapeconfig,prometheusrule -n open-cluster-management-agent-addon
```

Query Perses for `up{job="apiserver"}` and expect `cluster` / `clusterID`. If the series is missing, check add-on status, Agent logs, and whether you queried at a five-minute step instead of native resolution.

## Ordering and failure modes

| Mistake | What you see | Fix |
| :--- | :--- | :--- |
| Wrong collector or missing `part-of` label | Object exists, controller ignores it | `part-of: multicluster-observability-addon` plus `platform-metrics-collector` or `user-workload-metrics-collector` |
| Missing placements annotation | Object exists, never appears on the CMA | `observability.open-cluster-management.io/placements: "namespace/name"` |
| Spaces after commas, or `none` / no `/` | Reconcile error, or a placement name that never matches | Exact `namespace/name,namespace/name` with no spaces |
| Annotation changed, object still on hub | Old CMA row can remain | Delete the hub object, wait for CMA cleanup, sync the new annotation |
| GitOps prune of default scrape configs | Default dashboards empty | Separate Application; never list MCOA defaults in your overlay |
| Full CMA replace from Git | Defaults gone, Agents mismatched | Leave the CMA to the controller |
| `scrapeClass` / `staticConfigs` in a platform `ScrapeConfig` | GitOps OutOfSync; controller overwrites to `not-configurable` | Omit those fields on platform jobs; set them only on user-workload jobs |
| User-workload config, UWM off | Empty federation | Enable UWM on the spoke and on the MCO CR |
| Wide `match[]` | Receive CPU and storage climb | Narrow matchers; pre-aggregate with `PrometheusRule` |

## Try it

1. Enable MCOA ([core post](mcoa-core-and-configuration-draft5.0.md)).
2. Commit one small `ScrapeConfig` with the collector label **and** the placements annotation. Sync it.
3. Confirm the CMA lists the name under that placement, a `ManifestWork` exists, and the series shows in Perses.
4. Only then add more matchers, a second placement, or a `PrometheusRule`.

If you still have a legacy `observability-metrics-custom-allowlist`, convert it with the `allowlist-migration` CLI (Fleet Management console, **Help > Command Line Tools**), commit the generated YAML with the same labels and annotation, and let the controller register those objects the same way.

Product docs:

- [ACM Observability](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/)
- [ACM-34753](https://issues.redhat.com/browse/ACM-34753) Auto-discovery of observability configurations for placements
- [PR 509](https://github.com/stolostron/multicluster-observability-addon/pull/509) implementation
