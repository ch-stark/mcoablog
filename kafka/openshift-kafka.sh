#!/usr/bin/env bash
# Deploy lab Kafka on the OpenShift cluster that is not the ACM hub.
#
# Creates namespace kafka:
#   Streams for Apache Kafka, one KRaft node, topic acm-platform-metrics
#   an external route listener on TLS port 443
#
# Brokers are not given a remote-write endpoint. The hub OpenTelemetry
# collector produces to this route. Handoff for acm-kafka-export.sh:
#   <out-dir>/kafka-export.env
#   <out-dir>/kafka-cluster-ca.crt
#
# Do not point this script at the ACM hub context.
#
# Usage:
#   ./openshift-kafka.sh --context kafka
#   ./openshift-kafka.sh --context kafka --out-dir ./kafka-handoff
#   ./openshift-kafka.sh --context kafka --channel stable

set -euo pipefail

OC="${OC:-oc}"
CONTEXT=""
OUT_DIR="./kafka-handoff"
KAFKA_NS="${KAFKA_NS:-kafka}"
CLUSTER_NAME="${CLUSTER_NAME:-my-cluster}"
POOL_NAME="${POOL_NAME:-dual-role}"
TOPIC="${TOPIC:-acm-platform-metrics}"
KAFKA_VERSION="${KAFKA_VERSION:-3.9.0}"
METADATA_VERSION="${METADATA_VERSION:-3.9-IV0}"
OPERATOR_NS="${OPERATOR_NS:-openshift-operators}"
OPERATOR_CHANNEL="${OPERATOR_CHANNEL:-stable}"
OPERATOR_SOURCE="${OPERATOR_SOURCE:-redhat-operators}"
VOLUME_SIZE="${VOLUME_SIZE:-100Gi}"
KAFKA_WAIT="${KAFKA_WAIT:-600}"
TOPIC_WAIT="${TOPIC_WAIT:-180}"
OPERATOR_WAIT="${OPERATOR_WAIT:-600}"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing $1"
}

ocx() {
  "$OC" --context "$CONTEXT" "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:?--context needs a kubeconfig context}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:?--out-dir needs a directory}"; shift 2 ;;
    --channel) OPERATOR_CHANNEL="${2:?--channel needs a name}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$CONTEXT" ]] || die "--context is required (the Kafka OpenShift cluster, not the ACM hub)"
need "$OC"
need openssl
need base64
need python3

ocx whoami >/dev/null || die "cannot authenticate to context ${CONTEXT}"
log "== target $(ocx whoami --show-server) user=$(ocx whoami) context=${CONTEXT} =="

if ocx get multiclusterobservability observability >/dev/null 2>&1; then
  die "context ${CONTEXT} has MultiClusterObservability/observability. That is the ACM hub. Re-run with the Kafka cluster context."
fi

log "== namespace ${KAFKA_NS} =="
ocx apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${KAFKA_NS}
EOF

log "== Streams for Apache Kafka operator (${OPERATOR_CHANNEL}) =="
ocx apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: amq-streams
  namespace: ${OPERATOR_NS}
spec:
  channel: ${OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: amq-streams
  source: ${OPERATOR_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

deadline=$((SECONDS + OPERATOR_WAIT))
phase=""
while (( SECONDS < deadline )); do
  phase="$(ocx get csv -n "$OPERATOR_NS" -o json 2>/dev/null | python3 -c '
import json,sys
doc=json.load(sys.stdin)
phases=[i.get("status",{}).get("phase","") for i in doc.get("items",[]) if str(i.get("metadata",{}).get("name","")).startswith("amqstreams")]
print(phases[0] if phases else "")
' || true)"
  if [[ "$phase" == "Succeeded" ]]; then
    break
  fi
  log "waiting for amqstreams CSV (phase=${phase:-absent})"
  sleep 10
done
[[ "$phase" == "Succeeded" ]] || die "amq-streams operator did not become Succeeded within ${OPERATOR_WAIT}s (last phase=${phase:-absent}). Check the channel in OperatorHub."
ocx wait --for=condition=Established crd/kafkas.kafka.strimzi.io --timeout=180s

log "== Kafka ${CLUSTER_NAME} (internal plain listener + external TLS route) =="
ocx apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: ${POOL_NAME}
  namespace: ${KAFKA_NS}
  labels:
    strimzi.io/cluster: ${CLUSTER_NAME}
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
        size: ${VOLUME_SIZE}
        kraftMetadata: shared
        deleteClaim: false
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${KAFKA_NS}
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: ${KAFKA_VERSION}
    metadataVersion: ${METADATA_VERSION}
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: external
        port: 9094
        type: route
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
EOF

if ! ocx wait -n "$KAFKA_NS" "kafka/${CLUSTER_NAME}" --for=condition=Ready --timeout="${KAFKA_WAIT}s"; then
  ocx get "kafka/${CLUSTER_NAME}" -n "$KAFKA_NS" -o jsonpath='{.status.conditions}' ; echo
  die "Kafka ${CLUSTER_NAME} did not become Ready. If the status names a different version, set KAFKA_VERSION and METADATA_VERSION and re-run."
fi

log "== topic ${TOPIC} =="
ocx apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: ${TOPIC}
  namespace: ${KAFKA_NS}
  labels:
    strimzi.io/cluster: ${CLUSTER_NAME}
spec:
  partitions: 3
  replicas: 1
  config:
    retention.ms: 604800000
EOF
ocx wait -n "$KAFKA_NS" "kafkatopic/${TOPIC}" --for=condition=Ready --timeout="${TOPIC_WAIT}s"

BROKER_POD="${CLUSTER_NAME}-${POOL_NAME}-0"
log "== probe topic from ${BROKER_POD} =="
printf 'hub-to-kafka-ok\n' | ocx exec -i -n "$KAFKA_NS" "$BROKER_POD" -c kafka -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic "$TOPIC"
ocx exec -n "$KAFKA_NS" "$BROKER_POD" -c kafka -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic "$TOPIC" \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 20000

BOOTSTRAP="$(ocx get kafka "$CLUSTER_NAME" -n "$KAFKA_NS" -o json | python3 -c '
import json,sys
doc=json.load(sys.stdin)
for listener in doc.get("status",{}).get("listeners") or []:
    if listener.get("name")=="external" and listener.get("bootstrapServers"):
        print(listener["bootstrapServers"])
        raise SystemExit
sys.exit("external listener has no bootstrapServers")
')"

mkdir -p "$OUT_DIR"
umask 077
ocx get secret "${CLUSTER_NAME}-cluster-ca-cert" -n "$KAFKA_NS" -o jsonpath='{.data.ca\.crt}' | base64 -d > "${OUT_DIR}/kafka-cluster-ca.crt"
openssl x509 -in "${OUT_DIR}/kafka-cluster-ca.crt" -noout -subject -issuer >/dev/null \
  || die "${CLUSTER_NAME}-cluster-ca-cert did not decode to a certificate"

cat > "${OUT_DIR}/kafka-export.env" <<EOF
KAFKA_BOOTSTRAP='${BOOTSTRAP}'
KAFKA_TOPIC='${TOPIC}'
EOF
chmod 600 "${OUT_DIR}/kafka-export.env" "${OUT_DIR}/kafka-cluster-ca.crt"

log "== handoff =="
log "bootstrap: ${BOOTSTRAP}"
log "topic:     ${TOPIC}"
log "files:     ${OUT_DIR}/kafka-export.env"
log "           ${OUT_DIR}/kafka-cluster-ca.crt"
log "next:      ./acm-kafka-export.sh --context hub --handoff ${OUT_DIR}"
