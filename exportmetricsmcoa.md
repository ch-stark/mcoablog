# Export metrics with the multicluster observability add-on

Export from the managed cluster. With the multicluster observability add-on (MCOA), each cluster’s Prometheus Agent remote-writes straight to your endpoint. The hub store is not in that path.

This is the Red Hat Advanced Cluster Management for Kubernetes 2.16 procedure in [Exporting metrics to external endpoints for the multicluster observability add-on](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/observability/observing-environments-intro#exporting-metrics-to-external-endpoints-for-the-multicluster-observability-add-on). Metrics collection through the add-on is the supported path. Do not install the add-on by hand. Enable it on `MultiClusterObservability.spec.capabilities`.

There is a second, older export on the hub: `spec.storageConfig.writeStorage` forwards series that have already arrived in the hub. Use that only when you want a copy of what the hub already stored. It does not help when a managed cluster cannot reach the hub. The steps below are the add-on path.

## What you are changing

The add-on creates one `PrometheusAgent` per placement in `open-cluster-management-observability`. That object already has a remote-write entry that sends fleet metrics to the hub. You append a second entry. The agent on each managed cluster then writes to both places.

`ScrapeConfig` decides which series the agent collects. `writeRelabelConfigs` on the new remote-write entry decides which of those series leave for your endpoint. Put the filter on the new entry. The hub entry keeps the cluster name and cluster ID labels the add-on adds.

The agent can keep sending to your endpoint during a partition between the managed cluster and the hub for up to two hours. That limit is the one stated in the 2.16 add-on docs.

## Before you start

- The observability service is already running on the hub.
- Platform metrics are enabled:

```bash
oc patch multiclusterobservability observability --type=merge \
  -p '{"spec":{"capabilities":{"platform":{"metrics":{"default":{"enabled": true}}}}}}'
```

- You know the remote-write URL. The documented shape is `https://<endpoint>/api/v1/receive`.
- Use this remote-write configuration as written. Do not turn on Prometheus remote-write 2.0.

Find the agent for the placement you want to export from:

```bash
oc get prometheusagents -n open-cluster-management-observability
```

For the default global placement the platform agent name in the docs is `mcoa-default-platform-metrics-collector-global`. User-workload metrics use the user-workload agent. Repeat the same edit on that agent if those series must be exported too.

## 1. Create the TLS secrets on the hub

Create them in `open-cluster-management-observability`. The file names have to match the paths the agent mounts.

The CA secret key is `ca.crt`. The client secret keys are `tls.crt` and `tls.key`.

```bash
oc create secret generic custom-endpoint-ca \
  -n open-cluster-management-observability \
  --from-file=ca.crt=./ca.crt

oc create secret tls custom-endpoint-cert \
  -n open-cluster-management-observability \
  --cert=./tls.crt --key=./tls.key
```

Skip this step only when the endpoint is plain HTTP inside a network you already trust. Drop `secrets` and `tlsConfig` from the agent in that case.

## 2. Append a remote-write entry

Edit the platform agent:

```bash
oc edit prometheusagent mcoa-default-platform-metrics-collector-global \
  -n open-cluster-management-observability
```

Add the secret names and a new `remoteWrite` item. Leave the existing hub item in place. In the docs that item is named `acm-observability`. If you delete it, the add-on can no longer reconcile the collector, and the hub stops receiving metrics from that placement.

```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: PrometheusAgent
metadata:
  name: mcoa-default-platform-metrics-collector-global
  namespace: open-cluster-management-observability
spec:
  secrets:
    - custom-endpoint-ca
    - custom-endpoint-cert
  remoteWrite:
    - name: custom-endpoint
      url: https://my-custom-remote-write-endpoint.io/api/v1/receive
      tlsConfig:
        caFile: /etc/prometheus/secrets/custom-endpoint-ca/ca.crt
        certFile: /etc/prometheus/secrets/custom-endpoint-cert/tls.crt
        keyFile: /etc/prometheus/secrets/custom-endpoint-cert/tls.key
      writeRelabelConfigs:
        - action: keep
          sourceLabels: [__name__]
          regex: ^up$
    - name: acm-observability
      # existing hub remote write; do not remove
```

`regex: ^up$` is the documented sample. It exports only the `up` series. Replace it with the series you actually want, still as a keep rule, so a full platform scrape does not land in the external store.

```yaml
writeRelabelConfigs:
  - action: keep
    sourceLabels: [__name__]
    regex: ^(up|namespace:netobserv_.*:rate5m)$
```

The agent adds `cluster` and `clusterID` on its hub remote write. If the external system needs those labels too, add the same labels with a `replace` action on the custom entry, using values you already know for that fleet. Do not copy the hub entry’s relabel block over by hand. The add-on owns that block and rewrites it per cluster.

## 3. Confirm a spoke is writing

On one managed cluster, the agent runs in `open-cluster-management-agent-addon` unless you changed `agentInstallNamespace`.

```bash
oc get prometheusagent -n open-cluster-management-agent-addon
oc get pods -n open-cluster-management-agent-addon -l app.kubernetes.io/component=platform-metrics-collector
```

The spoke `PrometheusAgent` should list `custom-endpoint` under `remoteWrite`. The pod should be `Running`. If it stays pending because `custom-endpoint-ca` or `custom-endpoint-cert` is missing, create those same secrets in `open-cluster-management-agent-addon` on that cluster. The mount path is `/etc/prometheus/secrets/<secret-name>/`.

Then check the external store for series tagged with that cluster. On the managed cluster, failed writes for this target show up as remote-write errors in the agent log and as `MetricsCollectorRemoteWriteFailures` if the failure rate stays high.

`acm_remote_write_requests_total` on the hub measures the other export, `storageConfig.writeStorage`. It does not tell you whether the spoke agent reached your endpoint.

## What to watch

- A keep rule that matches nothing looks like a successful export with no data. Query one kept metric name in the external store before you widen the regex.
- Every extra series is stored again outside the hub. The hub sizing table still applies to what you federate to Advanced Cluster Management. The external store has its own cardinality bill.
- `AddonDeploymentConfig` wins over later hand edits to node placement, namespace, and proxy. Put those in the deployment config. Put the extra remote write on the `PrometheusAgent`.
- User-workload export is the same edit on the user-workload `PrometheusAgent`. Platform and user-workload collectors do not share one remote-write list.
