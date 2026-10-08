#!/usr/bin/env bash
# On an ACM hub that already runs MCOA:
#   1. Run Red Hat build of OpenTelemetry in namespace acm-otel.
#   2. Receive Prometheus remote-write 2.0 and export OTLP metrics to Kafka.
#   3. Add a remote-write 2.0 target on the MCOA platform PrometheusAgent.
#
# The collector runs on the hub. It is not the MCOA OpenTelemetryCollector
# stanza, so MCOA does not copy it to spokes.
#
# Remote-write 2.0 is what the OpenTelemetry Prometheus Remote Write receiver
# accepts. That receiver is Technology Preview in Red Hat build of
# OpenTelemetry 3.11. The 2.0 spec is experimental. The existing
# acm-observability remote-write entry is left on remote-write 1.0.
#
# This script does not install MCOA and does not change spec.capabilities.
#
# Handoff from openshift-kafka.sh:
#   <handoff>/kafka-export.env          KAFKA_BOOTSTRAP, KAFKA_TOPIC
#   <handoff>/kafka-cluster-ca.crt
#
# Usage:
#   ./acm-kafka-export.sh --context hub --handoff ./kafka-handoff
#   ./acm-kafka-export.sh --context hub --handoff ./kafka-handoff --with-baremetal

set -euo pipefail

OC="${OC:-oc}"
CONTEXT=""
HANDOFF=""
MCO_NAME="${MCO_NAME:-observability}"
MCO_NS="${MCO_NS:-open-cluster-management-observability}"
CMA_NAME="${CMA_NAME:-multicluster-observability-addon}"
OTEL_NS="${OTEL_NS:-acm-otel}"
OTEL_NAME="${OTEL_NAME:-kafka-bridge}"
OPERATOR_NS="${OPERATOR_NS:-openshift-operators}"
OPERATOR_CHANNEL="${OPERATOR_CHANNEL:-stable}"
OPERATOR_SOURCE="${OPERATOR_SOURCE:-redhat-operators}"
OPERATOR_WAIT="${OPERATOR_WAIT:-600}"
WITH_BAREMETAL=0

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \?//'
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
    --handoff) HANDOFF="${2:?--handoff needs the directory from openshift-kafka.sh}"; shift 2 ;;
    --channel) OPERATOR_CHANNEL="${2:?--channel needs a name}"; shift 2 ;;
    --with-baremetal) WITH_BAREMETAL=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$CONTEXT" ]] || die "--context is required (the ACM hub)"
[[ -n "$HANDOFF" ]] || die "--handoff is required"
[[ -f "${HANDOFF}/kafka-export.env" ]] || die "missing ${HANDOFF}/kafka-export.env"
[[ -f "${HANDOFF}/kafka-cluster-ca.crt" ]] || die "missing ${HANDOFF}/kafka-cluster-ca.crt"
need "$OC"
need python3
openssl x509 -in "${HANDOFF}/kafka-cluster-ca.crt" -noout -subject >/dev/null \
  || die "${HANDOFF}/kafka-cluster-ca.crt is not a certificate"

# shellcheck disable=SC1090
source "${HANDOFF}/kafka-export.env"
[[ -n "${KAFKA_BOOTSTRAP:-}" ]] || die "KAFKA_BOOTSTRAP missing from kafka-export.env"
[[ -n "${KAFKA_TOPIC:-}" ]] || die "KAFKA_TOPIC missing from kafka-export.env"

ocx whoami >/dev/null || die "cannot authenticate to context ${CONTEXT}"
log "== target $(ocx whoami --show-server) user=$(ocx whoami) context=${CONTEXT} =="

ocx get "multiclusterobservability/${MCO_NAME}" >/dev/null \
  || die "MultiClusterObservability/${MCO_NAME} not found. This script does not install MCOA."
ocx get "clustermanagementaddon/${CMA_NAME}" >/dev/null \
  || die "ClusterManagementAddOn/${CMA_NAME} not found. MCOA is not deployed on this hub."

metrics_on="$(ocx get "multiclusterobservability/${MCO_NAME}" -o jsonpath='{.spec.capabilities.platform.metrics.default.enabled}')"
[[ "$metrics_on" == "true" ]] || die "platform metrics are not enabled. This script will not change spec.capabilities."

log "== MCOA already present; platform metrics enabled =="

if [[ "$WITH_BAREMETAL" -eq 1 ]]; then
  log "== ScrapeConfig platform-metrics-baremetal =="
  ocx apply -f - <<EOF
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: platform-metrics-baremetal
  namespace: ${MCO_NS}
  labels:
    app.kubernetes.io/component: platform-metrics-collector
spec:
  jobName: baremetal
  metricsPath: /federate
  scheme: HTTPS
  scrapeClass: not-configurable
  params:
    match[]:
      - '{job="metal3-state"}'
  staticConfigs:
    - targets:
        - not-configurable
EOF
  already="$(ocx get "clustermanagementaddon/${CMA_NAME}" -o json | python3 -c '
import json,sys
doc=json.load(sys.stdin)
for p in doc.get("spec",{}).get("installStrategy",{}).get("placements") or []:
    for c in p.get("configs") or []:
        if c.get("name")=="platform-metrics-baremetal" and c.get("resource")=="scrapeconfigs":
            print("yes")
            raise SystemExit
print("no")
')"
  if [[ "$already" == "yes" ]]; then
    log "placement already references platform-metrics-baremetal"
  else
    ocx patch "clustermanagementaddon/${CMA_NAME}" --type=json -p='[
      {
        "op": "add",
        "path": "/spec/installStrategy/placements/0/configs/-",
        "value": {
          "group": "monitoring.rhobs",
          "resource": "scrapeconfigs",
          "name": "platform-metrics-baremetal",
          "namespace": "'"${MCO_NS}"'"
        }
      }
    ]'
    log "attached platform-metrics-baremetal to placements/0"
  fi
fi

log "== Red Hat build of OpenTelemetry operator (${OPERATOR_CHANNEL}) =="
ocx apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opentelemetry-product
  namespace: ${OPERATOR_NS}
spec:
  channel: ${OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: opentelemetry-product
  source: ${OPERATOR_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

deadline=$((SECONDS + OPERATOR_WAIT))
phase=""
while (( SECONDS < deadline )); do
  phase="$(ocx get csv -n "$OPERATOR_NS" -o json 2>/dev/null | python3 -c '
import json,sys
doc=json.load(sys.stdin)
phases=[]
for i in doc.get("items",[]):
    name=str(i.get("metadata",{}).get("name",""))
    if name.startswith("opentelemetry"):
        phases.append(i.get("status",{}).get("phase",""))
print(phases[0] if phases else "")
' || true)"
  if [[ "$phase" == "Succeeded" ]]; then
    break
  fi
  log "waiting for OpenTelemetry operator CSV (phase=${phase:-absent})"
  sleep 10
done
[[ "$phase" == "Succeeded" ]] || die "OpenTelemetry operator did not become Succeeded within ${OPERATOR_WAIT}s (last phase=${phase:-absent})."
ocx wait --for=condition=Established crd/opentelemetrycollectors.opentelemetry.io --timeout=180s

log "== collector ${OTEL_NAME} in ${OTEL_NS} =="
ocx apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${OTEL_NS}
EOF

ocx -n "$OTEL_NS" create secret generic kafka-cluster-ca \
  --from-file="ca.crt=${HANDOFF}/kafka-cluster-ca.crt" \
  --dry-run=client -o yaml | ocx apply -f -

# brokers list is a single bootstrap host:port from the Kafka route listener.
ocx apply -f - <<EOF
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: ${OTEL_NAME}
  namespace: ${OTEL_NS}
spec:
  mode: deployment
  replicas: 1
  managementState: managed
  volumeMounts:
    - name: kafka-ca
      mountPath: /etc/kafka-ca
      readOnly: true
  volumes:
    - name: kafka-ca
      secret:
        secretName: kafka-cluster-ca
  ports:
    - name: promrw
      port: 9090
      protocol: TCP
      targetPort: 9090
  config:
    receivers:
      prometheusremotewrite:
        endpoint: 0.0.0.0:9090
    processors:
      batch: {}
    exporters:
      debug:
        verbosity: basic
      kafka:
        brokers:
          - ${KAFKA_BOOTSTRAP}
        protocol_version: "2.0.0"
        metrics:
          topic: ${KAFKA_TOPIC}
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
EOF

if ! ocx -n "$OTEL_NS" rollout status "deploy/${OTEL_NAME}-collector" --timeout=300s; then
  ocx -n "$OTEL_NS" logs "deploy/${OTEL_NAME}-collector" --tail=40 || true
  die "collector deployment ${OTEL_NAME}-collector did not become ready"
fi

SVC="${OTEL_NAME}-collector"
ocx get svc "$SVC" -n "$OTEL_NS" >/dev/null \
  || die "service ${SVC} not found in ${OTEL_NS}"

ocx apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: prometheus-rw
  namespace: ${OTEL_NS}
spec:
  to:
    kind: Service
    name: ${SVC}
  port:
    targetPort: promrw
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

ROUTE_HOST="$(ocx get route prometheus-rw -n "$OTEL_NS" -o jsonpath='{.spec.host}')"
[[ -n "$ROUTE_HOST" ]] || die "route prometheus-rw has no host"
RECEIVE_URL="https://${ROUTE_HOST}/api/v1/write"
log "collector receive URL: ${RECEIVE_URL}"

log "== hub ingress CA for spoke agents =="
ca_file="$(mktemp)"
trap 'rm -f "$ca_file"' EXIT
ocx get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' | base64 -d > "$ca_file"
openssl x509 -in "$ca_file" -noout -subject >/dev/null \
  || die "hub router-ca did not decode to a certificate"
ocx -n "$MCO_NS" create secret generic hub-ingress-ca \
  --from-file=ca.crt="$ca_file" \
  --dry-run=client -o yaml | ocx apply -f -
rm -f "$ca_file"
trap - EXIT

log "== MCOA platform PrometheusAgent remote-write 2.0 =="
agent_json="$(mktemp)"
patch_file="$(mktemp)"
trap 'rm -f "$agent_json" "$patch_file"' EXIT
ocx get "clustermanagementaddon/${CMA_NAME}" -o json > "$agent_json"
AGENT_NAME="$(python3 - "$agent_json" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1]))
names=[]
for p in doc.get("spec",{}).get("installStrategy",{}).get("placements") or []:
    for c in p.get("configs") or []:
        if c.get("resource") in ("prometheusagents","prometheusagent"):
            names.append(c.get("name"))
platform=[n for n in names if n and "platform" in n]
if len(platform)==1:
    print(platform[0])
elif len(names)==1:
    print(names[0])
else:
    sys.stderr.write("platform PrometheusAgent not unique: %s\n" % names)
    sys.exit(1)
PY
)"
log "agent: ${AGENT_NAME}"

ocx get prometheusagent "$AGENT_NAME" -n "$MCO_NS" -o json > "$agent_json"
RECEIVE_URL="$RECEIVE_URL" python3 - "$agent_json" "$patch_file" <<'PY'
import json, os, sys
doc = json.load(open(sys.argv[1]))
spec = doc.get("spec") or {}
remote = list(spec.get("remoteWrite") or [])
if not any(e.get("name") == "acm-observability" for e in remote):
    sys.stderr.write("error: remoteWrite entry acm-observability is missing; refusing to replace the hub target\n")
    sys.exit(1)
remote = [e for e in remote if e.get("name") != "otel-kafka"]
remote.append({
    "name": "otel-kafka",
    "url": os.environ["RECEIVE_URL"],
    "protobufMessage": "io.prometheus.write.v2.Request",
    "tlsConfig": {
        "caFile": "/etc/prometheus/secrets/hub-ingress-ca/ca.crt",
    },
})
secrets = list(spec.get("secrets") or [])
if "hub-ingress-ca" not in secrets:
    secrets.append("hub-ingress-ca")
features = list(spec.get("enableFeatures") or [])
for flag in ("metadata-wal-records", "native-histograms"):
    if flag not in features:
        features.append(flag)
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump({
        "spec": {
            "remoteWrite": remote,
            "secrets": secrets,
            "enableFeatures": features,
        }
    }, fh)
PY

ocx patch prometheusagent "$AGENT_NAME" -n "$MCO_NS" --type=merge -p "$(cat "$patch_file")"
rm -f "$agent_json" "$patch_file"
trap - EXIT

log "== result =="
log "MCOA agent ${AGENT_NAME} sends remote-write 2.0 to ${RECEIVE_URL}"
log "acm-observability remote-write was kept"
log "collector ${OTEL_NS}/${OTEL_NAME} produces OTLP protobuf to ${KAFKA_BOOTSTRAP} topic ${KAFKA_TOPIC}"
log "enableFeatures on the agent: metadata-wal-records, native-histograms"
log "spoke pods in open-cluster-management-agent-addon will roll. Samples follow the federation interval (default 300s)."
