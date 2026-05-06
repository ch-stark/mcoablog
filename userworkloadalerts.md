# How to Test Your MCOA Alert Forwarding Pipeline End-to-End (Without Breaking Anything)
 
 
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
- The `observability-alertmanager-accessor-<hubName>` **bearer token Secret** exists on the
  target managed cluster (provisioned automatically by the Observability operator).
- The `hub-alertmanager-router-ca-<hubName>` **CA cert ConfigMap** exists on the target
  managed cluster (also provisioned by the Observability operator).
- A `Placement` resource named `global` exists in `open-cluster-management-global-set` on the
  Hub (this is the standard RHACM global placement targeting all managed clusters).
- `enableUserWorkload: true` is set in the `cluster-monitoring-config` ConfigMap on each
  target managed cluster.
---
 
## Step 1: Deploy the Dynamic Forwarding Policy (Hub Cluster)
 
Apply the following policy to your **Hub cluster**. It dynamically looks up the Hub's domain,
reads the existing User Workload Monitoring config from the spoke, and merges in the alert
forwarding payload — without overwriting any existing configuration.
 
> **Note:** `remediationAction: enforce` means this policy configures the spoke immediately
> upon binding. Change to `inform` if you want to preview before applying.
 
```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: mcoa-alert-forward-uwl
  namespace: open-cluster-management-global-set
spec:
  disabled: false
  remediationAction: enforce
  policy-templates:
  - objectDefinition:
      apiVersion: policy.open-cluster-management.io/v1
      kind: ConfigurationPolicy
      metadata:
        name: mcoa-alert-forward-uwl
      spec:
        namespaceSelector:
          include: ["openshift-user-workload-monitoring"]
        object-templates-raw: |
          {{/* 1. Fetch Hub Domain and ID on the HUB cluster */}}
          {{- $hubBaseDomain := (hub (lookup "config.openshift.io/v1" "Ingress" "" "cluster").spec.domain hub) -}}
          {{- $hubName := (split "." $hubBaseDomain)._0 -}}
 
          {{/* 2. Get existing UWM config from the SPOKE cluster */}}
          {{- $cmo := (lookup "v1" "ConfigMap" "openshift-user-workload-monitoring" "user-workload-monitoring-config") -}}
          {{- $currentConfig := dict -}}
          {{- if and $cmo $cmo.data -}}
            {{- $currentConfig = (index $cmo "data" "config.yaml") | fromYaml -}}
          {{- end -}}
 
          {{/* 3. Define the alert forwarding payload */}}
          {{- $forwardingConfig := dict "prometheus" (dict
            "additionalAlertmanagerConfigs" (list (dict
              "apiVersion" "v2"
              "bearerToken" (dict "key" "token" "name" (printf "observability-alertmanager-accessor-%s" $hubName))
              "scheme" "https"
              "staticConfigs" (list (printf "alertmanager-open-cluster-management-observability.apps.%s" $hubBaseDomain))
              "tlsConfig" (dict
                "ca" (dict "key" "service-ca.crt" "name" (printf "hub-alertmanager-router-ca-%s" $hubName))
                "insecureSkipVerify" false
              )
            ))
            "externalLabels" (dict "managed_cluster" (fromClusterClaim "id.openshift.io"))
          ) -}}
 
          {{/* 4. Merge and Output */}}
          - complianceType: musthave
            objectDefinition:
              apiVersion: v1
              kind: ConfigMap
              metadata:
                name: user-workload-monitoring-config
                namespace: openshift-user-workload-monitoring
              data:
                config.yaml: |
                  {{ mustMergeOverwrite $currentConfig $forwardingConfig | toYaml | autoindent }}
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: mcoa-alert-forward-uwl-placement
  namespace: open-cluster-management-global-set
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: global
subjects:
- apiGroup: policy.open-cluster-management.io
  kind: Policy
  name: mcoa-alert-forward-uwl
```
 
### What this policy does
 
| Step | Action |
|------|--------|
| **1** | Looks up the Hub's Ingress domain and derives a short name (first segment) |
| **2** | Reads the spoke's existing `user-workload-monitoring-config` to avoid overwriting it |
| **3** | Constructs the `additionalAlertmanagerConfigs` payload with mTLS and bearer token auth |
| **4** | Merges the forwarding config into the existing one (forwarding config wins on conflicts) and writes it back |
 
The `externalLabels` block is particularly important — it stamps every forwarded alert with a
`managed_cluster` label derived from the spoke's cluster ID claim, so you always know which
cluster an alert originated from.
 

## Step 2: Deploy the Test Alert (Managed Cluster)
 
Log in to your **managed cluster** and apply the following YAML. This creates a dedicated test
namespace and a `PrometheusRule` that fires immediately.
 
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcoa-alert-test
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: force-test-alert
  namespace: mcoa-alert-test
  labels:
    # Required: routes this rule to the local UWL Prometheus, bypassing Thanos Ruler
    openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus
spec:
  groups:
  - name: test-group
    rules:
    - alert: MCOA_Pipeline_Test_Alert
      # vector(1) always evaluates to true — the alert fires unconditionally
      expr: vector(1)
      for: 1m
      labels:
        severity: critical
        testing_mcoa: "true"
      annotations:
        summary: "MCOA UWL Alert Forwarding is Working"
        description: >
          This test alert successfully traversed from the spoke's user-workload
          Prometheus to the Hub Alertmanager.
```
 
### Two things worth noting
 
**The `leaf-prometheus` label is mandatory.**  
Without it, the rule is evaluated by the Thanos Ruler instead of the local User Workload
Prometheus. The MCOA forwarding path is specific to the local Prometheus, so the label is
required for this test to reflect a real forwarding scenario.
 
**`for: 1m` introduces a deliberate delay.**  
Prometheus won't transition the alert to `Firing` until the condition has been true for one
continuous minute. This mirrors real-world alert behaviour. If you want an instant fire for
rapid iteration, change `for: 1m` to `for: 0m` — but be aware this isn't representative of
how most production alerts are configured.
 
 
## Step 3: Verify the Pipeline
 
Allow up to two minutes after applying the `PrometheusRule`, then check both ends of the
pipeline.
 
### On the Managed Cluster
 
1. Open the **OpenShift Web Console**.
2. Navigate to **Observe → Alerting**.
3. You should see `MCOA_Pipeline_Test_Alert` in a **Firing** state.
This confirms the local User Workload Prometheus evaluated the rule correctly.
 
### On the Hub Cluster
 
1. Open the **RHACM Grafana instance**.
2. Navigate to the **Alerts** dashboard or the **Alert Analysis** view.
3. You should see `MCOA_Pipeline_Test_Alert` actively firing.
4. Expand the alert details — confirm it carries the `managed_cluster` label with the spoke's
   cluster ID.
If the alert appears on the Hub with the correct label, your entire forwarding pipeline is
working: rule evaluation → local Prometheus → TLS-authenticated forwarding → Hub
Alertmanager → Grafana.
 

## Step 4: Clean Up
 
Once you've verified the pipeline, remove the test resources to stop the alert from firing.
 
```bash
kubectl delete namespace mcoa-alert-test
```
 
Deleting the namespace removes both the `PrometheusRule` and the test namespace. The alert
will resolve in Alertmanager within a few minutes.
 
 
## Troubleshooting Quick Reference
 
| Symptom | Likely Cause |
|---------|--------------|
| Alert not firing on spoke | `enableUserWorkload: true` not set, or `leaf-prometheus` label missing |
| Alert fires on spoke but not Hub | Secret or CA ConfigMap missing on spoke; check `additionalAlertmanagerConfigs` |
| Alert on Hub missing `managed_cluster` label | `fromClusterClaim "id.openshift.io"` not resolving; verify cluster claim exists |
| Policy not applying | `Placement` named `global` doesn't exist; check PlacementBinding |
 
 
## Wrapping Up
 
Using `vector(1)` as a test expression is one of those small tricks that makes a big
difference when validating observability pipelines. It gives you a deterministic, repeatable
signal that exercises every part of the stack — authentication, TLS, routing, and label
propagation — without any application scaffolding.
 
Once you've confirmed the pipeline is healthy, swap out the test rule for your real alerting
rules with confidence.
 
