=======
# How to Test Your MCOA (User) Alert Forwarding Pipeline End-to-End 
 
One of the trickiest parts of setting up Multi-Cluster Observability Architecture (MCOA) alert
forwarding isn't writing the policy — it's verifying that the whole pipeline actually works.
Do you deploy a real application, misconfigure it on purpose, and hope an alert fires? That's
messy, unpredictable, and hard to clean up.

There's a better way. By using the PromQL expression `vector(1)`, you can create a
**guaranteed always-firing alert** that lets you validate every hop in the pipeline — from the
spoke's User Workload Prometheus, through network authentication, all the way to the Hub
Alertmanager — without any application code at all.

Here's a complete, step-by-step walkthrough.


## Prerequisites

Before you begin, make sure the following are in place:

- **RHACM Observability** is installed and running on your Hub cluster.
- The `observability-alertmanager-accessor-*` **bearer token Secret** and
  `hub-alertmanager-router-ca-*` **CA cert ConfigMap** exist on the target managed cluster
  (both are provisioned automatically by the Observability operator).
- A `Placement` resource named `global` exists in `open-cluster-management-global-set` on the
  Hub (this is the standard RHACM global placement targeting all managed clusters).

> **Note:** The policy below enables User Workload Monitoring and deploys the test alert
> automatically — you don't need to configure those manually.

---

## Step 1: Deploy the RBAC Resources (Hub Cluster)

The policy uses a hub template to look up the Hub's Ingress domain at render time. The policy
engine needs RBAC permission to read Ingress resources. Apply this to the **Hub cluster**:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hub-ingress-reader
  namespace: open-cluster-management-global-set
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hub-ingress-reader-role
rules:
  - apiGroups: ["config.openshift.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hub-ingress-reader-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hub-ingress-reader-role
subjects:
  - kind: ServiceAccount
    name: hub-ingress-reader
    namespace: open-cluster-management-global-set
```

## Step 2: Deploy the Policy (Hub Cluster)

Apply the following policy to your **Hub cluster**. It does four things in one shot:

1. Enables User Workload Monitoring on the spoke
2. Discovers the hub-provisioned secrets dynamically and configures alert forwarding
3. Creates a test namespace
4. Deploys an always-firing test alert

> **Note:** `remediationAction: enforce` means this policy configures the spoke immediately
> upon binding. Change to `inform` if you want to preview before applying.

```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: mcoa-uwm-full
  namespace: open-cluster-management-global-set
  annotations:
    policy.open-cluster-management.io/categories: CM Configuration Management
    policy.open-cluster-management.io/controls: CM-2 Baseline Configuration
    policy.open-cluster-management.io/standards: NIST SP 800-53
spec:
  disabled: false
  remediationAction: enforce
  hubTemplateOptions:
    serviceAccountName: hub-ingress-reader
  policy-templates:

    # 1. Enable User Workload Monitoring
    # ----------------------------------------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: enable-user-workload-monitoring
        spec:
          remediationAction: enforce
          severity: medium
          namespaceSelector:
            include: ["openshift-monitoring"]
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: ConfigMap
                metadata:
                  name: cluster-monitoring-config
                  namespace: openshift-monitoring
                data:
                  config.yaml: |
                    enableUserWorkload: true

    # 2. Configure Alert Forwarding (Dynamic Discovery)
    # ----------------------------------------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: mcoa-alert-forward-uwl
        spec:
          remediationAction: enforce
          severity: medium
          namespaceSelector:
            include: ["openshift-user-workload-monitoring"]
          object-templates-raw: |
            {{- /* Discover Hub-specific Secret names on the Spoke */ -}}
            {{- $tokenSecret := "" -}}
            {{- $caSecret := "" -}}
            {{- range (lookup "v1" "Secret" "openshift-user-workload-monitoring" "").items -}}
              {{- if hasPrefix "observability-alertmanager-accessor-" .metadata.name -}}
                {{- $tokenSecret = .metadata.name -}}
              {{- end -}}
              {{- if hasPrefix "hub-alertmanager-router-ca-" .metadata.name -}}
                {{- $caSecret = .metadata.name -}}
              {{- end -}}
            {{- end -}}
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: ConfigMap
                metadata:
                  name: user-workload-monitoring-config
                  namespace: openshift-user-workload-monitoring
                data:
                  config.yaml: |
                    prometheus:
            {{- if and $tokenSecret $caSecret }}
                      additionalAlertmanagerConfigs:
                      - apiVersion: v2
                        bearerToken:
                          key: token
                          name: {{ $tokenSecret }}
                        scheme: https
                        staticConfigs:
                        - alertmanager-open-cluster-management-observability.{{hub (lookup "config.openshift.io/v1" "Ingress" "" "cluster").spec.domain hub}}
                        tlsConfig:
                          ca:
                            key: service-ca.crt
                            name: {{ $caSecret }}
                          insecureSkipVerify: false
            {{- end }}
                      externalLabels:
                        managed_cluster: '{{ fromClusterClaim "id.openshift.io" }}'

    # 3. Create Test Infrastructure (Namespace)
    # ----------------------------------------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: mcoa-test-namespace
        spec:
          remediationAction: enforce
          severity: low
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Namespace
                metadata:
                  name: mcoa-alert-test
                  labels:
                    mcoa-test: "true"

    # 4. Deploy Always-Firing Test Alert
    # ----------------------------------------------------------
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: mcoa-test-alert-rule
        spec:
          remediationAction: enforce
          severity: low
          namespaceSelector:
            include: ["mcoa-alert-test"]
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: monitoring.coreos.com/v1
                kind: PrometheusRule
                metadata:
                  name: force-test-alert
                  namespace: mcoa-alert-test
                  labels:
                    openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus
                spec:
                  groups:
                    - name: mcoa-test-group
                      rules:
                        - alert: MCOA_Pipeline_Test_Alert
                          expr: vector(1)
                          for: 1m
                          labels:
                            severity: critical
                            testing_mcoa: "true"
                          annotations:
                            summary: "MCOA UWL Alert Forwarding is Working"
                            description: "Test alert traversing from spoke to Hub Alertmanager."

---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: mcoa-uwm-full-placement
  namespace: open-cluster-management-global-set
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: global
subjects:
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: mcoa-uwm-full
```

### What this policy does

| Template | Action |
|----------|--------|
| **enable-user-workload-monitoring** | Sets `enableUserWorkload: true` in `cluster-monitoring-config` on the spoke |
| **mcoa-alert-forward-uwl** | Discovers the hub-provisioned bearer token Secret and CA ConfigMap by prefix, then configures `additionalAlertmanagerConfigs` with TLS and the `managed_cluster` external label |
| **mcoa-test-namespace** | Creates the `mcoa-alert-test` namespace on the spoke |
| **mcoa-test-alert-rule** | Deploys a `PrometheusRule` with `vector(1)` that fires immediately |

The alert forwarding template uses **dynamic secret discovery** — it iterates over all Secrets
in `openshift-user-workload-monitoring` and matches by prefix rather than constructing names
from the Hub domain. This is more resilient to naming variations across environments. If the
secrets haven't been provisioned yet, the `additionalAlertmanagerConfigs` block is skipped
entirely, preventing a broken configuration.

The `externalLabels` block stamps every forwarded alert with a `managed_cluster` label derived
from the spoke's cluster ID claim, so you always know which cluster an alert originated from.

The Hub's Ingress domain is resolved at policy render time via a hub template
(`{{hub ... hub}}`), which requires the `hub-ingress-reader` ServiceAccount created in Step 1.


## Step 3: Verify the Pipeline

Allow up to two minutes after the policy is applied, then check both ends of the pipeline.

### On the Managed Cluster

1. Open the **OpenShift Web Console**.
2. Navigate to **Observe -> Alerting**.
3. You should see `MCOA_Pipeline_Test_Alert` in a **Firing** state.

This confirms the local User Workload Prometheus evaluated the rule correctly.

### On the Hub Cluster

Red Hat Advanced Cluster Management includes the amtool (Alertmanager CLI) utility inside the pod specifically for this purpose

Run the following command to execute into the active Alertmanager pod on the Hub and list all currently firing alerts:

```bash
oc -n open-cluster-management-observability exec -it observability-alertmanager-0 -c alertmanager -- amtool alert --alertmanager.url="http://localhost:9093"
```
To filter specifically for your MCOA test alert and view the labels (which will prove the managed_cluster tag successfully traversed the network):

```bash
oc -n open-cluster-management-observability exec -it observability-alertmanager-0 -c alertmanager -- amtool alert query alertname="MCOA_Pipeline_Test_Alert" --alertmanager.url="http://localhost:9093"
```
If you prefer to see the raw JSON output to verify every label exactly as you were attempting to do with your Python snippet, you can use the local curl inside the pod, which is trusted and not blocked by the OAuth proxy:

```bash
oc -n open-cluster-management-observability exec -it observability-alertmanager-0 -c alertmanager -- curl -s http://localhost:9093/api/v2/alerts | grep -A 10 "MCOA_Pipeline_Test_Alert"
```

If the alert shows up in the amtool or curl output with the correct managed_cluster label, your entire forwarding pipeline is successfully configured.


## Step 4: Clean Up

Once you've verified the pipeline, remove the test resources to stop the alert from firing.

```bash
kubectl delete namespace mcoa-alert-test
```

Deleting the namespace removes both the `PrometheusRule` and the test namespace. The alert
will resolve in Alertmanager within a few minutes.

To remove the entire policy (including the forwarding configuration and UWM enablement):

```bash
kubectl delete policy mcoa-uwm-full -n open-cluster-management-global-set
kubectl delete placementbinding mcoa-uwm-full-placement -n open-cluster-management-global-set
```


## Things Worth Knowing

**The `leaf-prometheus` label is mandatory.**
Without it, the rule is evaluated by the Thanos Ruler instead of the local User Workload
Prometheus. The MCOA forwarding path is specific to the local Prometheus, so the label is
required for this test to reflect a real forwarding scenario.

**`for: 1m` introduces a deliberate delay.**
Prometheus won't transition the alert to `Firing` until the condition has been true for one
continuous minute. This mirrors real-world alert behaviour. If you want an instant fire for
rapid iteration, change `for: 1m` to `for: 0m` — but be aware this isn't representative of
how most production alerts are configured.

**The forwarding config is conditional.**
If the Observability operator hasn't provisioned the bearer token Secret and CA ConfigMap to
the spoke yet, the policy will still apply — it just won't include the
`additionalAlertmanagerConfigs` block. Once the secrets appear, the next policy evaluation
will pick them up and add the forwarding configuration.


## Troubleshooting Quick Reference

| Symptom | Likely Cause |
|---------|--------------|
| Alert not firing on spoke | `enableUserWorkload: true` not applied yet; check `enable-user-workload-monitoring` ConfigurationPolicy status |
| Alert fires on spoke but not Hub | Secret or CA ConfigMap not provisioned on spoke; verify Observability operator is running |
| Alert on Hub missing `managed_cluster` label | `fromClusterClaim "id.openshift.io"` not resolving; verify cluster claim exists |
| Policy not applying | `Placement` named `global` doesn't exist; check PlacementBinding |
| Policy compliant but no forwarding config | Secrets not yet provisioned — the conditional block was skipped; check `openshift-user-workload-monitoring` for `observability-alertmanager-accessor-*` |
| Hub template error | `hub-ingress-reader` ServiceAccount or RBAC not created; apply Step 1 |


## Alternative: ScrapeConfig-Based Alert Collection

The policy-based approach above uses `additionalAlertmanagerConfigs` to push alerts from the
spoke's Prometheus directly to the Hub Alertmanager. An alternative is to **pull** alerts via
federation using a `ScrapeConfig` resource.

The MCO operator already uses this pattern for platform alerts (see
[`platform-metrics-alerts`](https://github.com/stolostron/multicluster-observability-operator/blob/main/operators/multiclusterobservability/manifests/base/grafana/alerts/scrape-config.yaml)).
The same approach works for User Workload alerts.

### UWL Alerts ScrapeConfig

Apply the following `ScrapeConfig` to the **Hub cluster**. It federates the `ALERTS` metric
from each managed cluster's User Workload Prometheus:

```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  labels:
    app.kubernetes.io/component: uwl-metrics-collector
    app.kubernetes.io/part-of: multicluster-observability-addon
    app.kubernetes.io/managed-by: multicluster-observability-operator
  name: uwl-metrics-alerts
  namespace: open-cluster-management-observability
spec:
  jobName: uwl-alerts
  metricsPath: /federate
  params:
    match[]:
    - '{__name__="ALERTS"}'
  metricRelabelings:
  - action: labeldrop
    regex: managed_cluster|id
```

A ready-to-use copy is available at [`uwl-alerts-scrape-config.yaml`](uwl-alerts-scrape-config.yaml).

### AddonDeploymentConfig Integration

For the MCO addon agent to recognize and deploy this ScrapeConfig to managed clusters, it
must be registered in the `AddOnDeploymentConfig`. The addon agent reads the list of
ScrapeConfig resources from its configuration and deploys them as part of the
`PrometheusAgent` setup on each spoke.

If you are adding this ScrapeConfig outside the operator (i.e., not baked into the MCO
manifests), you need to ensure the addon picks it up. Check your
`AddOnDeploymentConfig` in `open-cluster-management-observability` and verify the
ScrapeConfig is included in the agent's resource list.

### When to Use Which Approach

| | Policy (`additionalAlertmanagerConfigs`) | ScrapeConfig (federation) |
|---|---|---|
| **How it works** | Spoke Prometheus pushes alerts to Hub Alertmanager | Hub federates `ALERTS` metric from spoke Prometheus |
| **Where alerts land** | Hub Alertmanager (native alerts) | Hub Thanos/Prometheus (as metrics) |
| **Grafana visibility** | No — Alertmanager only | Yes — queryable as metrics in Grafana dashboards |
| **Best for** | Real-time alert routing and notification | Dashboarding, trend analysis, cross-cluster alert views |
| **Requires** | Bearer token Secret + CA ConfigMap on spoke | ScrapeConfig registered in addon config |

You can use both approaches together — they are complementary, not mutually exclusive.


## Wrapping Up

Using `vector(1)` as a test expression is one of those small tricks that makes a big
difference when validating observability pipelines. It gives you a deterministic, repeatable
signal that exercises every part of the stack — authentication, TLS, routing, and label
propagation — without any application scaffolding.

Once you've confirmed the pipeline is healthy, swap out the test rule for your real alerting
rules with confidence.
