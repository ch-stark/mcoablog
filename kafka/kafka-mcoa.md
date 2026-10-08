# ACM hub to Kafka

Three steps for [RFE-9556](https://redhat.atlassian.net/browse/RFE-9556). MCOA is already deployed on the ACM hub. Kafka runs on a separate OpenShift cluster. The hub runs Red Hat build of OpenTelemetry, which is the bridge.

```
managed clusters
  MCOA PrometheusAgent
    remote-write 1.0  →  hub Thanos          (unchanged)
    remote-write 2.0  →  hub OpenTelemetry collector
                           prometheusremotewrite receiver
                           kafka exporter
                               |
                               |  TLS
                               v
Kafka OpenShift cluster
  route listener :443
  topic acm-platform-metrics
```

| Piece | Where it runs | Support |
|---|---|---|
| MCOA platform metrics | spokes, already deployed | GA |
| Prometheus remote-write 2.0 | extra target on the MCOA `PrometheusAgent` | [Experimental spec](https://prometheus.io/docs/specs/prw/remote_write_spec_2_0/) |
| Prometheus Remote Write receiver | hub collector | Technology Preview in [Red Hat build of OpenTelemetry 3.11](https://docs.redhat.com/en/documentation/red_hat_build_of_opentelemetry/3.11/html/configuring_the_collector/otel-collector-receivers_otel-configuration-of-otel-intro). It accepts only remote-write 2.0. |
| Kafka exporter | same hub collector | Red Hat build of OpenTelemetry. Records are OTLP protobuf. |
| Streams for Apache Kafka | the other OpenShift cluster | product Kafka |

This is a lab integration. It is not a native ACM Kafka sink, and it is not a production design. MCOA logs, traces, and the MCOA OpenTelemetry collector capability stay as they are. The collector in namespace `acm-otel` is installed with the OpenTelemetry operator and is **not** the hub stanza MCOA copies to spokes. Alerts stay on their existing path. Check series in **Observe → Metrics** or **Observe → Dashboards (Perses)**.

Scripts:

```bash
./openshift-kafka.sh --context kafka --out-dir ./kafka-handoff
./acm-kafka-export.sh --context hub --handoff ./kafka-handoff
```

`hub` and `kafka` are kubeconfig contexts. The Kafka script refuses to run on a context that already has `MultiClusterObservability/observability`.

---

## 1. ACM hub

MCOA is already there. Do not install it again and do not change `spec.capabilities`.

```bash
oc --context hub get cma multicluster-observability-addon
oc --context hub get mco observability -o jsonpath='{.spec.capabilities.platform.metrics.default.enabled}{"\n"}'
oc --context hub get prometheusagent -n open-cluster-management-observability
oc --context hub get managedclusteraddon -n <spoke> multicluster-observability-addon
```

Platform metrics must be `true`. The spoke addon should be `Available`. Note the platform `PrometheusAgent` name referenced by the addon placement. The hub script selects that object and keeps its `acm-observability` remote-write entry.

Prove the series you care about are already on the hub before you add Kafka:

```bash
oc --context hub -n open-cluster-management-observability port-forward svc/observability-thanos-query-frontend 9090:9090
curl -sG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=node_cpu_seconds_total'
```

Federation is every 300s. For Ironic hardware series, the spoke Prometheus must already scrape `job="metal3-state"`. The hub script adds that federate `ScrapeConfig` only when you pass `--with-baremetal`.

---

## 2. Kafka OpenShift cluster

`openshift-kafka.sh` installs Streams for Apache Kafka 2.9, one combined KRaft node, and topic `acm-platform-metrics` (3 partitions, replication 1, 7-day retention).

Listeners:

| Name | Type | Who uses it |
|---|---|---|
| `plain` port 9092 | internal, no TLS | the probe inside the broker pod |
| `external` port 9094 | `route`, TLS | the hub collector. Clients use the route on port 443. |

The script writes:

- `kafka-handoff/kafka-export.env` with `KAFKA_BOOTSTRAP` (`host:443`) and `KAFKA_TOPIC`
- `kafka-handoff/kafka-cluster-ca.crt` from Secret `my-cluster-cluster-ca-cert`

That CA signs the route listener certificates. The hub collector uses it as `tls.ca_file`. A plaintext probe on the internal listener confirms the topic before the handoff:

```bash
oc --context kafka exec -n kafka my-cluster-dual-role-0 -c kafka -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic acm-platform-metrics \
  --from-beginning --max-messages 1 --timeout-ms 20000
```

The first record is the text line `hub-to-kafka-ok`. Later records from the collector are OTLP protobuf, so a console consumer shows binary.

---

## 3. OpenTelemetry on the ACM hub

`acm-kafka-export.sh` installs the Red Hat build of OpenTelemetry operator if it is not already `Succeeded`, then applies `OpenTelemetryCollector/kafka-bridge` in namespace `acm-otel`.

`managementState: managed` so this collector runs on the hub. Name and namespace are deliberately not the MCOA stanza (`instance` in `open-cluster-management-observability`).

```yaml
receivers:
  prometheusremotewrite:
    endpoint: 0.0.0.0:9090
processors:
  batch: {}
exporters:
  debug:
    verbosity: basic
  kafka:
    brokers: ["<KAFKA_BOOTSTRAP>"]
    protocol_version: "2.0.0"
    metrics:
      topic: acm-platform-metrics
      encoding: otlp_proto
    tls:
      ca_file: /etc/kafka-ca/ca.crt
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true
service:
  pipelines:
    metrics:
      receivers: [prometheusremotewrite]
      processors: [batch]
      exporters: [kafka, debug]
```

The receiver listens for remote-write 2.0 on `/api/v1/write`. An edge Route `prometheus-rw` publishes that port with the hub ingress certificate. The script prints the URL:

```text
https://prometheus-rw-acm-otel.apps.<hub-domain>/api/v1/write
```

`debug` is on the same pipeline so `oc logs` shows batches while you are proving the path. Kafka records use `otlp_proto`. The Kafka exporter is used with the batch processor plus exporter retry and a sending queue, which is what the collector requires for that exporter.

The hub must resolve the Kafka route and reach port 443.

---

## 4. MCOA remote-write 2.0

The platform `PrometheusAgent` on the hub is the stanza MCOA copies to spokes. The script appends one remote-write entry and leaves `acm-observability` in place, still remote-write 1.0, so Thanos keeps the fleet series.

```yaml
remoteWrite:
  - name: acm-observability
    # existing URL, TLS, and relabel stay as they are
  - name: otel-kafka
    url: https://<hub-route>/api/v1/write
    protobufMessage: io.prometheus.write.v2.Request
    tlsConfig:
      caFile: /etc/prometheus/secrets/hub-ingress-ca/ca.crt
enableFeatures:
  - metadata-wal-records
  - native-histograms
secrets:
  - hub-ingress-ca
```

`protobufMessage` is what turns this one target onto remote-write 2.0. The OpenTelemetry receiver rejects remote-write 1.0. `metadata-wal-records` is required so the agent puts metric type, unit, and help into the WAL; without it the receiver cannot build OTLP. `native-histograms` is the other flag the 3.11 receiver prerequisites list. Both flags apply to the whole agent, including the existing Thanos remote write, and the spoke agent pods roll.

`hub-ingress-ca` is the hub router CA (`router-ca` in `openshift-ingress-operator`). It is created in `open-cluster-management-observability` and listed under `spec.secrets` so MCOA mounts it on the spoke at the `caFile` path above. Spokes must resolve the hub apps domain and reach port 443.

The script stops if the `acm-observability` entry is missing, so a patch cannot drop the hub target.

---

## 5. Check the path

On a spoke, after the agent rolls:

```bash
oc --context <spoke> get prometheusagent -n open-cluster-management-agent-addon
oc --context <spoke> logs -n open-cluster-management-agent-addon -l app.kubernetes.io/name=prometheus-agent --tail=40
```

`MetricsCollectorRemoteWriteFailures` covers the new target as well as Thanos.

On the hub:

```bash
oc --context hub -n acm-otel logs deploy/kafka-bridge-collector --tail=40
```

Debug lines show metric batches once a remote-write 2.0 request arrives. A TLS error to the broker is the Kafka CA or bootstrap. No requests at all means the spoke cannot reach the hub Route, or `protobufMessage` did not land on the agent:

```bash
oc --context hub get prometheusagent <platform-agent> -n open-cluster-management-observability -o jsonpath='{.spec.remoteWrite}' ; echo
```

You want two entries. `otel-kafka` has `protobufMessage` `io.prometheus.write.v2.Request`. `acm-observability` does not.

Then consume on the Kafka cluster. Skip the text probe and look for binary OTLP records after one federation interval. Historical Thanos blocks are not replayed; only new samples the agent remote-writes.

---

## Cleanup

Edit the platform `PrometheusAgent` and delete only the `otel-kafka` remote-write entry. Leave `acm-observability`. Remove `hub-ingress-ca` from `spec.secrets` when nothing else mounts it. Then:

```bash
oc --context hub delete opentelemetrycollector kafka-bridge -n acm-otel
oc --context hub delete route prometheus-rw -n acm-otel
oc --context hub delete namespace acm-otel
oc --context kafka delete kafka my-cluster -n kafka
oc --context kafka delete kafkanodepool dual-role -n kafka
oc --context kafka delete kafkatopic acm-platform-metrics -n kafka
```

Leave the existing MCOA capabilities in place.
