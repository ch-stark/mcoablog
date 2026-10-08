# ACM hub to Kafka

1. ACM hub already has MCOA. Confirm the fleet series you will export.
2. A separate OpenShift cluster deploys Kafka.
3. The ACM hub remote-writes those metrics to that cluster.

MCOA **platform metrics** are GA. ACM has no Kafka API. Kafka does not accept Prometheus remote-write, so step 3 puts a small bridge between the hub export and the broker. That bridge is the community project [prometheus-kafka-adapter](https://github.com/Telefonica/prometheus-kafka-adapter) 1.9.1. It is not a Red Hat component. MCOA **logs, traces, and OpenTelemetry** stay off. This is a lab integration, not a production design and not a substitute for the RFE.

Use **Prometheus remote-write 1.0** on the hub export URL. Leave Remote-Write 2.0 off. The [2.0 spec is experimental](https://prometheus.io/docs/specs/prw/remote_write_spec_2_0/). Check series in **Observe → Metrics** or **Observe → Dashboards (Perses)**. Do not use Grafana.

Kafka runs on a **separate OpenShift cluster**. The hub cannot resolve `*.svc` names there. Brokers stay on the Kafka cluster network. The hub reaches one HTTPS route on that cluster, and a bridge next to the brokers turns remote-write into Kafka records. Alerts and logs are out of scope.

```
ACM hub
  spokes → MCOA PrometheusAgent → Thanos
  writeStorage remote-write 1.0
        |
        |  HTTPS  POST /receive
        v
Kafka OpenShift cluster
  prometheus-kafka-adapter
        → my-cluster-kafka-bootstrap.kafka.svc:9092
        → topic acm-platform-metrics
```

Use two kubeconfig contexts for the rest of this procedure. `hub` is the ACM hub. `kafka` is the OpenShift cluster that will run Kafka.

```bash
oc config get-contexts
```

The same steps are the two scripts. Run the Kafka script on the Kafka cluster first. It writes a handoff directory. Run the hub script second. The hub script does not install MCOA and does not change `spec.capabilities`.

```bash
./openshift-kafka.sh --context kafka --out-dir ./kafka-handoff
./acm-kafka-export.sh --context hub --handoff ./kafka-handoff
```

---

## Step 1 — ACM hub

MCOA is already deployed. Do not install it again, and do not change `spec.capabilities` unless a check below shows platform metrics disabled. This step only records the objects step 3 will use.

### 1.1 Confirm the running addon

On the hub:

```bash
oc --context hub whoami
oc --context hub get mco observability
oc --context hub get cma multicluster-observability-addon
oc --context hub get pods -n open-cluster-management-observability | grep thanos
```

`MultiClusterObservability/observability` is the observability stack. `ClusterManagementAddOn/multicluster-observability-addon` is MCOA. Thanos pods must be running. That is the store the spokes already remote-write into.

Read the capabilities that are on today:

```bash
oc --context hub get mco observability -o jsonpath='{.spec.capabilities}' ; echo
```

Platform metrics (`capabilities.platform.metrics.default.enabled: true`) are the GA path this procedure exports. Leave logs, traces, instrumentation, and `openTelemetryCollector` as they are. This Kafka path does not use them.

### 1.2 Record the collector stanza

MCOA already created the hub `PrometheusAgent` and copied it to managed clusters.

```bash
oc --context hub get prometheusagent,scrapeconfig -n open-cluster-management-observability
oc --context hub get cma multicluster-observability-addon -o yaml | yq '.spec.installStrategy.placements'
```

Write down two facts:

- The placement name and its index. `global` at index `0` is typical.
- The `prometheusagents` entry. ACM 2.17’s export example uses a name like `mcoa-default-platform-metrics-collector-global`. Use the name printed here.

`placements[].configs` lists that agent and the platform `ScrapeConfig`. Step 3 does not edit this agent. The hub `writeStorage` export sits in front of the stream these agents already send.

### 1.3 Confirm a managed cluster is collecting

Pick one spoke. The addon object for that cluster lives on the hub, in the spoke’s namespace:

```bash
oc --context hub get managedclusters
oc --context hub get managedclusteraddon -n <spoke> multicluster-observability-addon
```

Healthy status is `Available`. Degraded with `MetricsCollectorNotIngestingSamples` or `MetricsCollectorRemoteWriteFailures` means that spoke is not delivering samples. Fix that before Kafka.

On the spoke, the copied agent is in `open-cluster-management-agent-addon`:

```bash
oc --context hub get prometheusagent,scrapeconfig -n open-cluster-management-agent-addon
```

MCOA federates on a 300s interval by default. Kafka will see new samples on that cadence.

### 1.4 Prove the series are on the hub

```bash
oc --context hub get svc -n open-cluster-management-observability | grep thanos-query
oc --context hub -n open-cluster-management-observability port-forward svc/observability-thanos-query-frontend 9090:9090
```

Leave that port-forward running. In another shell:

```bash
curl -sG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=node_cpu_seconds_total' | head -c 2000
echo
```

You want a non-empty `result` array. One label on those series is the managed cluster. Record the label key (`cluster`, or whatever this hub actually set). Consumers will use that key. MCOA adds it in the collector remote-write relabel.

Hardware metrics are not in the default dashboard set. On a bare-metal spoke whose cluster monitoring already scrapes the Ironic Prometheus Exporter, the names are `baremetal_*` and the job is usually `metal3-state`. Check the spoke **Observe → Metrics** for `baremetal_power_status` before you federate it. If it is absent, enable the exporter and its `ServiceMonitor` on the spoke first. MCOA can only federate series the spoke Prometheus already has.

On the hub:

```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: platform-metrics-baremetal
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/component: platform-metrics-collector
spec:
  jobName: baremetal
  metricsPath: /federate
  scheme: HTTPS
  scrapeClass: not-configurable
  params:
    'match[]':
      - '{job="metal3-state"}'
  staticConfigs:
    - targets:
        - not-configurable
```

`scrapeClass` and `targets` stay `not-configurable`. MCOA rewrites them to the spoke platform Prometheus. Change `match[]` if the spoke job name is different. Do not use `{__name__=~".+"}`.

Attach it to the placement index from section 1.2:

```bash
oc --context hub patch clustermanagementaddon multicluster-observability-addon --type=json -p='[
  {
    "op": "add",
    "path": "/spec/installStrategy/placements/0/configs/-",
    "value": {
      "group": "monitoring.rhobs",
      "resource": "scrapeconfigs",
      "name": "platform-metrics-baremetal",
      "namespace": "open-cluster-management-observability"
    }
  }
]'
```

After the next federation interval:

```bash
curl -sG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=baremetal_power_status'
```

Related names from the same exporter: `baremetal_fan_status`, `baremetal_drive_status`, `baremetal_temperature_status`, `baremetal_temp_*_celsius`.

OS series such as `node_*` come from the default platform `ScrapeConfig` when they are part of that set. Query the hub for each name you need. Add another `ScrapeConfig` only for names that are missing.

Step 1 is done when the hub query returns the series you intend to put on Kafka.

---

## Step 2 — Separate OpenShift cluster deploys Kafka

Every command in this step uses `--context kafka`. Deploy [Streams for Apache Kafka](https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/2.9/html/deploying_and_managing_streams_for_apache_kafka_on_openshift/deploy-tasks_str) 2.9 there, not on the hub. One combined KRaft node is enough for the lab. Production needs a larger pool and a storage class you trust.

The hub will not dial the brokers. Brokers keep the cluster-internal listener. Section 2.6 publishes only the remote-write bridge.

### 2.1 Project and storage

```bash
oc --context kafka new-project kafka
oc --context kafka get storageclass
```

The Kafka volume below uses the default `StorageClass`. If none is marked default, set `class` on the persistent claim to a class that exists.

### 2.2 Install the operator

In the OpenShift console, **Operators → OperatorHub**, search for **Red Hat Streams for Apache Kafka**, and install it into the `kafka` namespace (or into `openshift-operators` if you want it cluster-wide). Use the default channel the catalog offers.

From the CLI, the catalog package name is `amq-streams` in `redhat-operators`. Confirm the channel in OperatorHub before applying this, then install into `openshift-operators` so the operator can watch the `kafka` namespace:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: amq-streams
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: amq-streams
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

```bash
oc --context kafka get csv -n openshift-operators | grep amqstreams
oc --context kafka get pods -n openshift-operators | grep strimzi-cluster-operator
```

Wait until the CSV is `Succeeded` and `strimzi-cluster-operator` is `Running`.

### 2.3 Kafka cluster

`version: 3.9.0` matches the Kafka version shown for Streams for Apache Kafka 2.9. If the operator rejects it, the status condition names the versions it accepts. Change `spec.kafka.version` and `metadataVersion` to that pair.

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  replicas: 1
  roles:
    - controller
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 100Gi
        kraftMetadata: shared
        deleteClaim: false
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 3.9.0
    metadataVersion: 3.9-IV0
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

The `plain` listener is plaintext and cluster-internal. The lab adapter uses it. The replication settings are 1 because this pool has one node. Do not copy those replication numbers onto a multi-broker cluster.

```bash
oc --context kafka apply -f kafka-cluster.yaml
oc --context kafka get kafka -n kafka my-cluster
oc --context kafka wait -n kafka kafka/my-cluster --for=condition=Ready --timeout=600s
oc --context kafka get pods -n kafka
```

Ready looks like this:

```text
NAME                     READY   STATUS
my-cluster-dual-role-0   1/1     Running
my-cluster-entity-operator  2/2  Running
```

Inside the Kafka cluster the plain listener is:

```text
my-cluster-kafka-bootstrap.kafka.svc:9092
```

That name resolves only on this cluster. The hub never uses it.

```bash
oc --context kafka get kafka my-cluster -n kafka -o jsonpath='{.status.listeners}' ; echo
oc --context kafka get svc -n kafka
```

`status.listeners` for `plain` should list that bootstrap host and port 9092. `status.clusterId` is set once the controller has formed.

### 2.4 Topic

The Topic Operator creates this because `entityOperator.topicOperator` is set. The label binds the topic to `my-cluster`. `replicas` must be 1 on this single-node pool.

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: acm-platform-metrics
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 3
  replicas: 1
  config:
    retention.ms: 604800000
```

```bash
oc --context kafka apply -f kafka-topic.yaml
oc --context kafka wait -n kafka kafkatopic/acm-platform-metrics --for=condition=Ready --timeout=180s
oc --context kafka get kafkatopic -n kafka acm-platform-metrics
```

`retention.ms` of 604800000 keeps records for 7 days.

### 2.5 Prove produce and consume

From inside the broker pod the plain listener is `localhost:9092`:

```bash
echo 'hub-to-kafka-ok' | oc --context kafka exec -i -n kafka my-cluster-dual-role-0 -c kafka -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic acm-platform-metrics

oc --context kafka exec -n kafka my-cluster-dual-role-0 -c kafka -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic acm-platform-metrics \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 20000
```

The consumer prints `hub-to-kafka-ok`.

### 2.6 Publish the bridge on the Kafka cluster

The adapter runs here, beside the brokers, so `KAFKA_BROKER_LIST` can stay on the in-cluster Service. The hub will call an edge Route. Basic auth is required because that Route is reachable wherever the apps wildcard resolves.

Generate a password and keep it for the hub Secret in step 3. The same value goes in `BASIC_AUTH_PASSWORD` below.

```bash
openssl rand -base64 24
```

Mirror `telefonica/prometheus-kafka-adapter:1.9.1` if this cluster cannot pull from Docker Hub. `KAFKA_BATCH_NUM_MESSAGES=1` makes the first samples visible without waiting for a 10000-message batch.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kafka-adapter
---
apiVersion: v1
kind: Secret
metadata:
  name: kafka-adapter-config
  namespace: kafka-adapter
stringData:
  KAFKA_BROKER_LIST: "my-cluster-kafka-bootstrap.kafka.svc:9092"
  KAFKA_TOPIC: "acm-platform-metrics"
  KAFKA_COMPRESSION: "none"
  KAFKA_BATCH_NUM_MESSAGES: "1"
  SERIALIZATION_FORMAT: "json"
  LOG_LEVEL: "info"
  GIN_MODE: "release"
  BASIC_AUTH_USERNAME: "acm-export"
  BASIC_AUTH_PASSWORD: "<password>"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-kafka-adapter
  namespace: kafka-adapter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus-kafka-adapter
  template:
    metadata:
      labels:
        app: prometheus-kafka-adapter
    spec:
      containers:
        - name: adapter
          image: telefonica/prometheus-kafka-adapter:1.9.1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - secretRef:
                name: kafka-adapter-config
          readinessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus-kafka-adapter
  namespace: kafka-adapter
spec:
  selector:
    app: prometheus-kafka-adapter
  ports:
    - name: http
      port: 8080
      targetPort: http
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: prometheus-kafka-adapter
  namespace: kafka-adapter
spec:
  to:
    kind: Service
    name: prometheus-kafka-adapter
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

| Variable | This lab | Meaning |
|---|---|---|
| `KAFKA_BROKER_LIST` | `my-cluster-kafka-bootstrap.kafka.svc:9092` | Plain listener from step 2.3. Resolves only inside this cluster. |
| `KAFKA_TOPIC` | `acm-platform-metrics` | Topic from step 2.4. The adapter does not create it. |
| `KAFKA_BATCH_NUM_MESSAGES` | `1` | Flush often so a lab consumer sees records. Default upstream is 10000. |
| `SERIALIZATION_FORMAT` | `json` | One JSON object per sample. `avro-json` is the other adapter format. |
| `BASIC_AUTH_USERNAME` / `BASIC_AUTH_PASSWORD` | `acm-export` and the generated password | Required on `/receive`. Step 3 repeats both values on the hub. |
| `LOG_LEVEL` | `info` | `debug` while you are chasing a refused produce. |
| `PORT` | unset (8080) | HTTP listen port behind the Route. |
| `MATCH` | unset | Optional allow-list. Empty means every sample the hub sends is produced. |

```bash
oc --context kafka apply -f kafka-adapter.yaml
oc --context kafka -n kafka-adapter rollout status deploy/prometheus-kafka-adapter
oc --context kafka -n kafka-adapter logs deploy/prometheus-kafka-adapter --tail=30
```

The pod stays up and logs a connection to `my-cluster-kafka-bootstrap.kafka.svc:9092`. A broker error shows up here as a crash loop. Fix it before you point the hub at the Route.

Read the hostname the hub will call:

```bash
oc --context kafka get route prometheus-kafka-adapter -n kafka-adapter -o jsonpath='{.spec.host}' ; echo
oc --context kafka get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' ; echo
```

The Route host looks like `prometheus-kafka-adapter-kafka-adapter.apps.<domain>`. Write it down. The hub cluster must resolve that name and reach port 443. DNS and the firewall between the two clusters are part of this step.

Copy the ingress CA that signs that Route. The default OpenShift router CA is `router-ca` in `openshift-ingress-operator`. You will load this file onto the hub in step 3.

```bash
oc --context kafka get secret router-ca -n openshift-ingress-operator \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > kafka-ingress-ca.crt
openssl x509 -in kafka-ingress-ca.crt -noout -subject -issuer
```

Step 2 is done when the probe message is on the topic, the adapter pod is Running, and you have the Route host plus `kafka-ingress-ca.crt`.

---

## Step 3 — ACM hub sends to Kafka

The hub already accepts remote-write from MCOA and can copy that live stream to another remote-write URL. That feature is [Exporting metrics to external endpoints](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html/observability/observing-environments-intro#exporting-metrics-to-external-endpoints). The URL has to speak Prometheus remote-write 1.0. The adapter does. It listens on `/receive` and produces one JSON record per sample:

```json
{
  "timestamp": "2026-10-08T12:00:00Z",
  "value": "0",
  "name": "baremetal_power_status",
  "labels": {
    "__name__": "baremetal_power_status",
    "job": "metal3-state",
    "node_name": "worker-0"
  }
}
```

`timestamp` and `value` are reserved. The metric name is copied to `name` and also kept as the `__name__` label. Other labels, including the managed-cluster label from step 1.4, are passed through.

What this export is:

- Live samples, as the hub receives them from MCOA. Object-storage blocks already in Thanos are not replayed.
- The fleet series MCOA delivered (platform, plus `baremetal_*` if step 1.4 is in place).
- Remote-write 1.0 over HTTPS to the Route from step 2.6. The path is `/receive`.

What it is not:

- A Kafka client inside ACM. Nothing in `MultiClusterObservability` has `bootstrap.servers`, and the hub does not get a broker address.
- Remote-Write 2.0. Do not set a v2 protobuf message on this endpoint.
- An OpenTelemetry collector. The 3.11 Prometheus Remote Write receiver is Technology Preview and accepts only remote-write 2.0. Thanos has no `/federate` endpoint to scrape.
- Alertmanager notifications, and not logs.

Commands in this step use `--context hub`, except the consumer, which stays on `--context kafka`.

### 3.1 Trust the Kafka cluster ingress

The Route certificate is signed by the Kafka cluster router CA saved as `kafka-ingress-ca.crt` in step 2.6. Load that CA into the hub observability namespace. `ca.crt` is the key step 3.2 points at.

```bash
oc --context hub create secret generic kafka-ingress-ca \
  -n open-cluster-management-observability \
  --from-file=ca.crt=kafka-ingress-ca.crt
```

From a host that uses the hub network path, confirm the certificate chains to that CA. Replace the host with the value from step 2.6.

```bash
echo | openssl s_client \
  -connect prometheus-kafka-adapter-kafka-adapter.apps.<kafka-domain>:443 \
  -servername prometheus-kafka-adapter-kafka-adapter.apps.<kafka-domain> \
  -CAfile kafka-ingress-ca.crt
```

`Verify return code: 0` means the hub can use this CA. A timeout means DNS or port 443 from the hub network to the Kafka cluster apps domain is blocked. Fix that before the `MultiClusterObservability` patch.

### 3.2 Endpoint Secret

ACM reads a Secret in `open-cluster-management-observability`. The data key **must** be `ep.yaml`. The Secret name is the export name you will see on `acm_remote_write_requests_total`.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: kafka-adapter
  namespace: open-cluster-management-observability
type: Opaque
stringData:
  ep.yaml: |
    url: https://prometheus-kafka-adapter-kafka-adapter.apps.<kafka-domain>/receive
    http_client_config:
      basic_auth:
        username: acm-export
        password: "<password>"
      tls_config:
        secret_name: kafka-ingress-ca
        ca_file_key: ca.crt
```

Replace the host with the Route host from step 2.6. `password` is the same value as `BASIC_AUTH_PASSWORD` on the Kafka cluster. `secret_name` is the CA Secret from step 3.1, in this same namespace. `ca_file_key` is the file key inside it, `ca.crt`.

```bash
oc --context hub apply -f kafka-endpoint-secret.yaml
oc --context hub get secret kafka-adapter -n open-cluster-management-observability -o jsonpath='{.data.ep\.yaml}' | base64 -d
echo
```

| Key | Required | This lab |
|---|---|---|
| `url` | yes | `https://<route-host>/receive`. Scheme is `https` because the Route terminates TLS. |
| `http_client_config.basic_auth.username` | yes here | `acm-export`, matching the adapter. |
| `http_client_config.basic_auth.password` | yes here | The generated password from step 2.6. |
| `tls_config.secret_name` | yes here | `kafka-ingress-ca`. |
| `tls_config.ca_file_key` | yes here | `ca.crt`. |
| `tls_config.cert_file_key` / `key_file_key` | mutual TLS only | Unused. The Route uses the default ingress certificate, not a client certificate. |
| `tls_config.insecure_skip_verify` | no | Leave it unset. The CA from step 3.1 is the trust anchor. |

`url` is a remote-write 1.0 endpoint. There is no second field for protocol version. A hub Service DNS name will not resolve on this cluster; the host has to be the Kafka cluster Route.

### 3.3 Attach it to the hub

Read the current storage stanza first so you do not drop object storage:

```bash
oc --context hub get mco observability -o jsonpath='{.spec.storageConfig}' ; echo
```

You should already see `metricObjectStorage`. Add `writeStorage` beside it.

If `writeStorage` is absent:

```bash
oc --context hub patch mco observability --type=json -p='[
  {"op":"add","path":"/spec/storageConfig/writeStorage","value":[
    {"name":"kafka-adapter","key":"ep.yaml"}
  ]}
]'
```

If `writeStorage` is already a list, append instead of replacing it:

```bash
oc --context hub patch mco observability --type=json -p='[
  {"op":"add","path":"/spec/storageConfig/writeStorage/-","value":{"name":"kafka-adapter","key":"ep.yaml"}}
]'
```

`name` is the Secret name. `key` is `ep.yaml`. More than one list item exports the same samples to more than one URL.

Confirm the object:

```bash
oc --context hub get mco observability -o yaml | yq '.spec.storageConfig'
```

Expected shape:

```yaml
storageConfig:
  metricObjectStorage:
    name: thanos-object-storage
    key: thanos.yaml
  writeStorage:
    - name: kafka-adapter
      key: ep.yaml
```

`metricObjectStorage.name` on your hub may differ. It must still be there after the patch.

The observability service reloads this list. You do not restart MCOA, and you do not edit the spoke `PrometheusAgent` for this path. Spoke agents keep remote-writing to the hub. The hub opens HTTPS to the Kafka cluster Route and the adapter there produces to the local broker.

### 3.4 Watch the export

Keep the Thanos port-forward from step 1.4. The counter `acm_remote_write_requests_total` is one series per endpoint per HTTP status, on the observatorium API.

```bash
curl -sG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=acm_remote_write_requests_total{name="kafka-adapter"}'
```

| `code` | Meaning |
|---|---|
| `200` or `204` | The adapter accepted the remote-write request. |
| `404` | URL path is wrong. It must end in `/receive`. |
| `401` or `403` | Basic auth on the hub Secret does not match `BASIC_AUTH_*` on the adapter. |
| `500` and above | Adapter or broker error. Read the adapter log. |
| no series yet | The hub has not completed a send. Wait past one 300s federation interval. Historical Thanos data is not backfilled. |

Then the adapter and the topic:

```bash
oc --context kafka -n kafka-adapter logs deploy/prometheus-kafka-adapter --tail=50

oc --context kafka exec -n kafka my-cluster-dual-role-0 -c kafka -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic acm-platform-metrics \
  --from-beginning \
  --max-messages 5 \
  --timeout-ms 20000
```

The first line may still be the `hub-to-kafka-ok` probe from step 2.5. Later lines are JSON. Check:

- `name` is a metric you queried on the hub in step 1, such as `node_cpu_seconds_total` or `baremetal_power_status`.
- `labels` contains the managed-cluster label you wrote down in step 1.4.
- `value` is a number encoded as a string. That is the adapter’s JSON schema.

In the OpenShift console on the hub, **Observe → Metrics**, the same counter is `acm_remote_write_requests_total{name="kafka-adapter"}`.

### 3.5 When the topic stays on the probe message

Work down the path. Stop at the first break.

1. Hub query for `node_cpu_seconds_total` is empty. Collection is broken. Stay in step 1. Kafka is not involved.
2. `oc --context hub get mco observability -o yaml` has no `writeStorage` entry, or `name` / `key` does not match the Secret. Re-apply section 3.3.
3. `ep.yaml` uses a `*.svc` host, the wrong Route host, or a password that differs from the adapter. Re-apply section 3.2. From the hub network, `curl -u acm-export:<password> -o /dev/null -w '%{http_code}\n' https://<route-host>/receive` should be `400` or `405` (the path exists and auth succeeded) rather than `401` or a timeout.
4. `acm_remote_write_requests_total` shows a non-2xx `code`. The hub is sending and the adapter or the Route is refusing. Read `oc --context kafka -n kafka-adapter logs`. A TLS error with no adapter log line means the hub does not trust `kafka-ingress-ca`.
5. The counter is 2xx and the adapter log shows produces, but the consumer is quiet. `KAFKA_TOPIC` and the `KafkaTopic` name differ. Both are `acm-platform-metrics`. The consumer runs on `--context kafka`.
6. The counter is 2xx but records appear only after a long wait. `KAFKA_BATCH_NUM_MESSAGES` is still at the upstream default. Set it to `1` on the Kafka cluster and restart the adapter.
7. 2xx, and the consumer shows JSON, but not `baremetal_*`. The hardware `ScrapeConfig` is not on the placement, or the spoke Prometheus has no `job="metal3-state"`. That is step 1.4, not the Kafka hop.

---

## Cleanup

```bash
oc --context hub patch mco observability --type=json -p='[
  {"op":"remove","path":"/spec/storageConfig/writeStorage"}
]'
oc --context hub delete secret kafka-adapter kafka-ingress-ca -n open-cluster-management-observability
oc --context kafka delete namespace kafka-adapter
oc --context kafka delete kafkatopic acm-platform-metrics -n kafka
oc --context kafka delete kafka my-cluster -n kafka
oc --context kafka delete kafkanodepool dual-role -n kafka
```

Deleting the `Kafka` object deletes the brokers. `deleteClaim: false` leaves the PVC. Remove the baremetal `ScrapeConfig` and its placement entry if you added it only for this export. Leave the existing MCOA capabilities in place.

---

## Spoke-direct export

Skip this unless samples must leave the managed cluster without the hub. The RFE path is step 3. Spoke-direct is [Exporting metrics to external endpoints for the multicluster observability add-on](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html/observability/observing-environments-intro#exporting-metrics-to-external-endpoints-for-the-multicluster-observability-add-on).

The extra `remoteWrite` runs on the spoke. Spokes use the same Route host, username, and password as step 3.2. They must resolve the Kafka cluster apps domain. The in-cluster broker name does not resolve on a spoke.

On the hub, edit the platform `PrometheusAgent` named in step 1.2. Keep the `acm-observability` entry. Append one entry. Replacing the list removes the hub target.

```yaml
spec:
  secrets:
    - kafka-adapter-basic
  remoteWrite:
    - name: acm-observability
      # existing hub URL, TLS, and relabel stay as they are
    - name: kafka
      url: https://prometheus-kafka-adapter-kafka-adapter.apps.<kafka-domain>/receive
      basicAuth:
        username:
          name: kafka-adapter-basic
          key: username
        password:
          name: kafka-adapter-basic
          key: password
      writeRelabelConfigs:
        - action: keep
          sourceLabels: [__name__]
          regex: 'baremetal_.+|node_cpu_seconds_total|node_memory_MemAvailable_bytes'
```

Create Secret `kafka-adapter-basic` in `open-cluster-management-observability` and list it under `spec.secrets` so the spoke agent can mount it. `MetricsCollectorRemoteWriteFailures` on the spoke covers this target.

---

## Takeaways

1. Step 1 uses the MCOA platform-metrics path that is already deployed. Do not reinstall the addon.
2. Step 2 is Streams for Apache Kafka on a separate OpenShift cluster. Brokers stay on `my-cluster-kafka-bootstrap.kafka.svc:9092`. The hub-facing address is the adapter Route.
3. Step 3 is hub `writeStorage` remote-write 1.0 to `https://<route-host>/receive`, with the router CA and basic auth. Remote-Write 2.0 stays off.
4. Logs, traces, the OpenTelemetry collector, and Alertmanager stay out of this path.
5. A native Kafka sink is what RFE-9556 asks ACM to build. This is the integration the current hub export can run.
