# Test user workload alert forwarding to the RHACM hub

Before relying on centralized alerts, verify that an alert can travel from a managed cluster's User Workload Prometheus to the Red Hat Advanced Cluster Management for Kubernetes (RHACM) hub Alertmanager.

This tutorial uses the PromQL expression `vector(1)` to generate a predictable test condition without deploying or breaking an application. You will verify local rule evaluation, confirm arrival at the hub with the expected cluster identity, and remove the test cleanly.

The test covers this path:

```text
Managed cluster: User Workload Prometheus
    -> HTTPS connection with bearer-token authentication
    -> Hub: Observability Alertmanager
```

It verifies alert delivery to the hub Alertmanager. It does not validate metrics collection, Thanos storage, the new MCOA Gateway, or delivery to an email, webhook, or other notification receiver. Receiver delivery is an additional test.

<!-- Publication note: Record the exact RHACM and OpenShift versions used to validate these commands and configuration examples before publication. This revised draft has not been executed against a cluster. -->

## Prerequisites

Use one designated OpenShift test cluster for this procedure. Before you begin:

- Enable RHACM Observability and the multicluster observability add-on (MCOA) for the intended managed cluster.
- Enable user workload monitoring through the hub `MultiClusterObservability` CR, as shown below.
- Enable user workload alert forwarding separately through the CR. Metrics collection and alert forwarding are distinct capabilities.
- Install `oc` and `jq` on your workstation.
- Obtain permission to create a namespace and `PrometheusRule` on the managed cluster, inspect monitoring configuration, and access the hub Alertmanager pod. The configuration steps require administrator permissions.
- Agree how test alerts will be routed. Use a test receiver or a narrow silence if production responders must not receive the test. A silence still permits checking arrival at Alertmanager, but does not test notification delivery.

Keep the hub and managed cluster contexts explicit throughout the procedure:

```bash
export HUB_CONTEXT='<hub-kubeconfig-context>'
export SPOKE_CONTEXT='<managed-cluster-kubeconfig-context>'

oc --context="$HUB_CONTEXT" whoami
oc --context="$SPOKE_CONTEXT" whoami
```

Read the cluster ID on the managed cluster and retain it for verification:

```bash
export EXPECTED_CLUSTER_ID="$(oc --context="$SPOKE_CONTEXT" \
  get clusterclaim id.openshift.io -o jsonpath='{.spec.value}')"

printf 'Expected cluster ID: %s\n' "$EXPECTED_CLUSTER_ID"
```

Stop if the claim is missing or empty. This guide expects forwarding to add the `managed_cluster` external label using this ID.

## Enable user workload monitoring and alert forwarding in ACM 5.0

In ACM 5.0, configure user workload monitoring centrally through the **`MultiClusterObservability` CR on the hub**. A separate policy that sets `enableUserWorkload: true` in every managed cluster's monitoring ConfigMap is not required for this workflow.

Keep two settings distinct:

| CR setting | Purpose |
|---|---|
| `spec.capabilities.userWorkloads.metrics.default.enabled` | Enable the user workload metrics capability. |
| `spec.capabilities.userWorkloads.metrics.alerts.enabled` | Enable forwarding of user workload alerts to the hub Alertmanager. |

The API defines metrics collection and alert forwarding independently. Enabling metrics does not replace the need to enable and verify the alert forwarding capability. See the [MultiClusterObservability API definitions](https://github.com/stolostron/multicluster-observability-operator/blob/main/operators/multiclusterobservability/api/v1beta2/multiclusterobservability_types.go).

### Update the existing CR

Find the name of your existing CR and record its current configuration before changing it:

```bash
oc --context="$HUB_CONTEXT" get multiclusterobservability
export MCO_NAME='<existing-multiclusterobservability-name>'

oc --context="$HUB_CONTEXT" get multiclusterobservability "$MCO_NAME" -o yaml \
  > multiclusterobservability.before.yaml
```

Save the following merge patch as `mco-user-workloads.patch.yaml`:

```yaml
spec:
  capabilities:
    platform:
      metrics:
        default:
          enabled: true
    userWorkloads:
      metrics:
        default:
          enabled: true
        alerts:
          enabled: true
```

Apply the patch on the hub:

```bash
oc --context="$HUB_CONTEXT" patch multiclusterobservability "$MCO_NAME" \
  --type=merge --patch-file=mco-user-workloads.patch.yaml
```

This updates the existing resource and preserves unrelated configuration such as storage settings. The example enables the platform metrics prerequisite as well as user workload metrics and alert forwarding. Review the MCOA placements first: these capabilities affect the clusters selected for the add-on, not just the cluster on which you will create the synthetic test alert.

If the CR is managed through GitOps, make the change in its source repository. Keep these ongoing capabilities separate from temporary test resources.

### Verify reconciliation before creating the test

Check the hub CR and the add-on status for the intended managed cluster:

```bash
oc --context="$HUB_CONTEXT" get multiclusterobservability "$MCO_NAME" -o yaml

oc --context="$HUB_CONTEXT" -n '<managed-cluster-name>' \
  get managedclusteraddon multicluster-observability-addon -o yaml

oc --context="$SPOKE_CONTEXT" -n openshift-user-workload-monitoring get pods
```

Wait for User Workload Monitoring and the add-on to become ready. Verify the resulting forwarding configuration as a diagnostic check; let ACM manage its configuration rather than introducing a second policy that replaces it:

```bash
oc --context="$SPOKE_CONTEXT" -n openshift-user-workload-monitoring \
  get configmap user-workload-monitoring-config \
  -o jsonpath='{.data.config\.yaml}'
```

Confirm that the destination is the intended hub Alertmanager and that the expected cluster identity is attached. The test below expects the external label `managed_cluster` to contain the managed cluster ID.

If authentication or TLS fails, inspect the referenced Secret names and key names without printing credential values. Common provisioned names start with `observability-alertmanager-accessor-` and `hub-alertmanager-router-ca-`. The `bearerToken` and `tlsConfig.ca` references in this monitoring configuration select **Secrets**, not ConfigMaps. Keep TLS certificate verification enabled.

A CR that requests a capability is not proof that the data path works. The following test checks actual rule evaluation and arrival at the hub.

## Step 1: create the temporary test alert

This main procedure creates the test directly on one managed cluster. If you want RHACM to distribute it, use the optional policy section below **instead**.

Confirm that `mcoa-alert-test` does not already exist. If it does, inspect its contents and choose a different dedicated test namespace rather than taking ownership of an existing project.

```bash
oc --context="$SPOKE_CONTEXT" get namespace mcoa-alert-test
```

For a new namespace, save this manifest as `mcoa-alert-test.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mcoa-alert-test
  labels:
    mcoa-test: "true"
---
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
        - alert: MCOAPipelineTestAlert
          expr: vector(1)
          for: 1m
          labels:
            severity: warning
            testing_mcoa: "true"
          annotations:
            summary: "Synthetic user workload alert forwarding test"
            description: "Test signal for verifying delivery from managed-cluster User Workload Prometheus to hub Alertmanager."
```

Apply it to the managed cluster:

```bash
oc --context="$SPOKE_CONTEXT" apply -f mcoa-alert-test.yaml
```

`vector(1)` returns a constant sample, so the expression remains active whenever the rule evaluates successfully. With `for: 1m`, the alert initially becomes pending and transitions to firing after the condition has remained active for the configured duration. Deployment, reconciliation, and evaluation intervals add time; do not use two minutes as a guaranteed completion deadline.

The `leaf-prometheus` label makes User Workload Prometheus evaluate this rule rather than Thanos Ruler. That matters because this test configures forwarding from Prometheus. It is not a blanket requirement for every user workload alerting architecture. See [OpenShift rule evaluation behavior](https://docs.redhat.com/en/documentation/monitoring_stack_for_red_hat_openshift/4.19/html-single/monitoring_key_concepts/).

## Step 2: verify local rule evaluation

On the managed cluster, open the OpenShift web console and navigate to **Observe > Alerting**. Locate `MCOAPipelineTestAlert` and confirm that it becomes **Firing**. Confirm that it belongs to the `mcoa-alert-test` namespace.

If the rule does not appear or remains pending unexpectedly, check the `PrometheusRule`, User Workload Monitoring readiness, and rule evaluation errors before investigating hub connectivity.

Local firing confirms rule evaluation. It does not yet confirm forwarding.

## Step 3: verify arrival at the hub

List the hub Alertmanager pods and choose a running pod. The example below uses `observability-alertmanager-0`; substitute the pod name if your deployment differs. Do not assume replica zero is a uniquely active instance in an HA deployment.

```bash
oc --context="$HUB_CONTEXT" -n open-cluster-management-observability get pods

oc --context="$HUB_CONTEXT" -n open-cluster-management-observability \
  exec observability-alertmanager-0 -c alertmanager -- \
  amtool alert query \
  --alertmanager.url=http://localhost:9093 \
  alertname=MCOAPipelineTestAlert \
  managed_cluster="$EXPECTED_CLUSTER_ID" \
  testing_mcoa=true
```

Confirm that the returned alert has the expected namespace and cluster ID. The `managed_cluster` value here is a cluster identifier, not necessarily the managed cluster's display name.

For structured inspection, forward the selected Alertmanager pod's local API to your workstation. This requires permission to port-forward to the pod:

```bash
oc --context="$HUB_CONTEXT" -n open-cluster-management-observability \
  port-forward pod/observability-alertmanager-0 19093:9093
```

Keep that command running. In another terminal, with `EXPECTED_CLUSTER_ID` set to the same value, inspect the matching alert:

```bash
curl --fail --silent --show-error http://127.0.0.1:19093/api/v2/alerts |
  jq --arg cluster "$EXPECTED_CLUSTER_ID" '
    .[]
    | select(.labels.alertname == "MCOAPipelineTestAlert")
    | select(.labels.managed_cluster == $cluster)
    | select(.labels.testing_mcoa == "true")
    | {labels, status, startsAt, endsAt}
  '
```

This uses `curl` and `jq` on your workstation and does not assume either tool is installed in the Alertmanager container. Stop port-forwarding when finished.

Seeing the matching alert at the hub confirms that it reached Alertmanager. A silence or inhibition can prevent notifications even when arrival succeeds. If notification delivery is part of your acceptance criteria, also confirm receipt at the agreed test receiver.

## Step 4: remove the test and verify resolution

For the direct deployment above, remove the test rule first:

```bash
oc --context="$SPOKE_CONTEXT" -n mcoa-alert-test \
  delete prometheusrule force-test-alert
```

Verify that the alert stops firing locally and is no longer active at hub Alertmanager. Allow time for reconciliation and alert expiry. Then remove the dedicated test namespace:

```bash
oc --context="$SPOKE_CONTEXT" delete namespace mcoa-alert-test
```

If you used a policy or GitOps controller to create these resources, stop that controller's enforcement of the test first. Otherwise, it can recreate the rule and namespace.

Keep the CR capabilities enabled if they are intended for ongoing use. If they were enabled only for this exercise, restore their previous values through the hub `MultiClusterObservability` CR or its GitOps source, after checking for other workloads and concurrent changes. Do not roll back ACM-managed configuration by deleting or replacing managed-cluster monitoring ConfigMaps. Remove the test-specific silence or receiver configuration when it is no longer needed.

## Optional: distribute the test with an RHACM policy

For repeatable fleet validation, RHACM can distribute the temporary rule. Keep the test policy separate from permanent monitoring and forwarding configuration.

1. Use a dedicated `Placement` selecting only the intended test cluster initially. Confirm its `PlacementDecision` and the required cluster-set binding. Do not assume a Placement named `global` exists or is appropriate for a synthetic test.
2. Create a `Policy` containing two `ConfigurationPolicy` templates: one for the dedicated namespace and one for the `PrometheusRule` from Step 1.
3. Bind that policy to the dedicated Placement using a `PlacementBinding` in the same hub namespace.
4. Begin with the parent policy's `remediationAction: inform`, review its results, then change it to `enforce` when ready. Inform mode reports differences; it does not create missing prerequisites or run the alert test.
5. Verify policy deployment on the managed cluster, then perform the local and hub checks above.

For cleanup, withdraw the test policy from the selected clusters and confirm that its propagated configuration policies are removed before manually deleting the rule and namespace. Deleting the namespace while the policy is enforcing is not sufficient.

Alternatively, configure `pruneObjectBehavior: DeleteIfCreated` on the temporary namespace and rule templates **when creating the policy**, and verify its behavior on your release. Do not use automatic deletion of shared monitoring ConfigMaps as a rollback strategy. By default, policy deletion does not remove managed objects. See [RHACM policy cleanup](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/governance/supported-policies).

## Troubleshooting

| Symptom | What to check |
|---|---|
| Test rule is absent | Verify the managed-cluster context, namespace, manifest application, or policy placement and compliance results. |
| Rule exists but does not fire | Check UWM readiness, rule selection, the `leaf-prometheus` label, evaluation errors, and the `for` duration. |
| Local alert fires but does not reach the hub | Check the configured destination, DNS and egress connectivity, route hostname, bearer-token validity, CA trust, and Prometheus notification errors. |
| Forwarding configuration is missing | Check `spec.capabilities.userWorkloads.metrics.alerts.enabled`, MCO reconciliation, add-on placement and status, and credential provisioning. Metrics enablement alone is not the alert-forwarding check. |
| Alert arrives without the expected cluster label | Inspect `prometheus.externalLabels`, the cluster claim, and any existing conflicting alert label or relabeling. |
| Alert arrives but no notification is received | Inspect Alertmanager routing, silences, inhibition, grouping delays, and receiver delivery errors. |
| Test resources reappear after deletion | Check enforcing policies and GitOps reconciliation. Withdraw the test from its source of configuration first. |

## Optional: collect alert-state metrics for dashboards

Prometheus exposes synthetic `ALERTS` time series for pending and firing alerts. Collecting those series can support dashboards and cross-cluster queries, but it is a different path from sending alerts to Alertmanager.

| Path | Data received at the hub | What it validates |
|---|---|---|
| Prometheus alert forwarding | Native alerts in Alertmanager | Alert delivery for routing and notifications |
| Federation and remote write | `ALERTS` time series in metrics storage | Collection of queryable alert-state data |

In the MCOA agent architecture, a managed-cluster agent federates from its local Prometheus and remote-writes collected metrics to the hub. Creating a ScrapeConfig on the hub is configuration distribution; it does not by itself make the hub directly scrape all managed clusters.

For a custom user workload ScrapeConfig:

- Use the documented `app.kubernetes.io/component: user-workload-metrics-collector` label.
- Select the `ALERTS` metric through the `/federate` endpoint.
- Add the ScrapeConfig reference to the intended placement configuration in the `ClusterManagementAddOn` resource.
- Verify target selection, authentication, label handling, and collection on your release. Do not assume an `AddOnDeploymentConfig` resource list registers a custom ScrapeConfig.

Follow the [ACM custom metrics configuration procedure](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/observability/observing-environments-intro) for the complete configuration. See [Prometheus alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/) for the meaning of the `ALERTS` series.

These paths can coexist. Success on one does not prove success on the other.

## Next steps

Use this synthetic alert as a repeatable check when enabling forwarding, changing certificates, or investigating delivery failures. Record local firing, hub arrival with the expected cluster identity, and clean resolution as separate results.

Once those checks pass, validate your real alert rules and notification routes. A successful synthetic test establishes a working delivery path; application-specific conditions and routing still need their own checks.
