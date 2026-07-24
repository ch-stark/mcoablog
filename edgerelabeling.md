# MCOA Edge Relabeling & Custom Metrics Collection Guide
 
This guide consolidates everything related to metric pruning ("edge relabeling") under the **MultiCluster Observability Addon (MCOA)** framework: the two relabeling levels, the fleet-wide automation policy that deploys them, and the User Workload Monitoring (UWM) templates for custom application metrics.
 
---
 
## 1. Background
 
Under MCOA, the shift from a legacy custom endpoint collector to a standard upstream **Prometheus Agent** brings native support for Prometheus relabeling APIs. This unlocks a two-tier metric pruning capability at the edge of managed (spoke) clusters — commonly called **Edge Relabeling**.
 
There are two levels at which you can drop or reshape metrics before they reach the Hub:
 
| Level | Mechanism | Where it lives |
|---|---|---|
| **Level 1 — Global Agent Level** | `writeRelabelConfigs` | Inside `PrometheusAgent.spec.remoteWrite` |
| **Level 2 — Local Scrape Level** | `metricRelabelings` | Inside `ScrapeConfig.spec` |
 
---
 
## 2. Level 1: Global Agent Level (`writeRelabelConfigs`)
 
### How it works under the hood
1. **Ingestion**: The Prometheus Agent scrapes/federates metrics from the in-cluster Prometheus instance.
2. **Local WAL buffering**: Scraped samples are written to the agent's local, disk-backed Write-Ahead Log (WAL) — they land on disk regardless of what happens next.
3. **Late-stage dropping**: Just before the agent pushes data to the Hub (or another remote-write endpoint), the relabeling engine evaluates `writeRelabelConfigs`. Matching metrics are discarded at this egress boundary.
### Key advantages
- **Destination-specific routing**: Because `writeRelabelConfigs` is defined per `remoteWrite` target, you can send a full metric set to a local/regional Hub for troubleshooting while sending a heavily filtered stream to the Global Hub to save WAN bandwidth.
- **Local edge availability**: Since metrics are already written to the local WAL, they remain queryable on the spoke for local alerting/dashboards even though they're dropped before transmission.
### Configuration template
```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: PrometheusAgent
metadata:
  name: mcoa-default-platform-metrics-collector-global
  namespace: open-cluster-management-observability
spec:
  remoteWrite:
    - name: acm-observability
      url: 'https://observatorium-api.open-cluster-management-observability.svc:8080/...'
      # Evaluated post-scrape, pre-transmission
      writeRelabelConfigs:
        - action: drop
          regex: ^(container_memory_cache|container_memory_rss)$
          sourceLabels:
            - __name__
```
 
---
 
## 3. Level 2: Local Scrape Level (`metricRelabelings`)
 
### How it works under the hood
1. **Ingestion**: The Prometheus Agent issues an HTTP GET to the local in-cluster Prometheus `/federate` endpoint.
2. **Boundary filtering**: Before scraped metrics are serialized, indexed, or written to the agent's TSDB/WAL, `metricRelabelings` rules execute.
3. **Total exclusion**: Matching metrics are dropped immediately at the scrape boundary — they never touch local disk.
### Key advantages
- **Zero local resource overhead**: Filtered metrics never enter the agent's database, saving disk I/O, CPU, and persistent storage on managed clusters.
- **Prevents WAL bloat**: Ideal for edge devices or Single Node OpenShift (SNO) clusters with constrained storage.
### Configuration template
```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: platform-metrics-alerts
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/component: platform-metrics-collector
spec:
  jobName: alerts
  metricsPath: /federate
  scheme: HTTPS
  scrapeClass: ocp-monitoring
  staticConfigs:
    - targets:
        - prometheus-k8s.openshift-monitoring.svc:9091
  # Evaluated immediately during the pull/federation phase
  metricRelabelings:
    - action: drop
      regex: ^Watchdog$
      sourceLabels:
        - alertname
```
 
---
 
## 4. SRE Decision Matrix
 
| Architectural Dimension | Global Agent Level (`writeRelabelConfigs`) | Local Scrape Level (`metricRelabelings`) |
|---|---|---|
| **Execution Point** | Post-scrape, pre-remote-write transmission | During the HTTP scrape/federation boundary |
| **Local WAL Impact** | Present — metrics are written to WAL before being filtered | Absent — metrics are dropped instantly, never written to WAL |
| **Granularity** | Per-Destination — different rules per remote-write target | Per-Scrape Job — applies globally for that job, all destinations |
| **Primary Use Case** | Multi-target routing (full metrics to Local Hub, filtered to Global Hub) | Eliminating high-volume platform/app noise to protect spoke CPU and disk I/O |
| **Resource Savings** | Egress bandwidth and central Hub storage costs | Spoke storage, spoke memory, and egress bandwidth |
 
**Rule of thumb**: use Level 2 whenever you want a metric to never exist locally (cost/resource savings on the spoke); use Level 1 when you still want the metric available locally but want to control what leaves the cluster (per-destination routing).
 
---
 
## 5. Automating Deployment: OCM Configuration Policy
 
Configuring relabeling directly on each spoke doesn't scale across large fleets. The policy below uses Open Cluster Management (OCM) governance to automatically deploy a Level 2 `ScrapeConfig` — dropping high-cardinality container CPU/memory metrics at the federation boundary — to a targeted subset of clusters.
 
### What it deploys
- **Parent Policy** (`policy-mcoa-custom-scrape-drop`): runs in `enforce` mode, tagged under NIST SP 800-53 (CM-2 Baseline Configuration) governance metadata.
- **Custom ScrapeConfig** (`mcoa-custom-platform-drop`): placed in `open-cluster-management-agent-addon` (the MCOA agent install namespace on spokes), labeled `app.kubernetes.io/component: platform-metrics-collector` so the local OBO Prometheus Operator auto-discovers and merges it into the running agent. It drops `container_memory_cache`, `container_memory_rss`, `container_memory_swap`, `container_memory_working_set_bytes`, `container_cpu_cfs_periods_total`, and `container_cpu_cfs_throttled_periods_total` during the scrape.
- **Placement + Binding** (`placement-mcoa-custom-scrape-drop` / `binding-mcoa-custom-scrape-drop`): targets clusters in the `global` ClusterSet whose label matches `environment: dev`.
```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: policy-mcoa-custom-scrape-drop
  namespace: open-cluster-management-global-set
  annotations:
    policy.open-cluster-management.io/standards: NIST SP 800-53
    policy.open-cluster-management.io/categories: CM Configuration Management
    policy.open-cluster-management.io/controls: CM-2 Baseline Configuration
spec:
  disabled: false
  remediationAction: enforce # Change to 'inform' to inspect compliance before enforcing
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: mcoa-custom-scrape-drop-config
        spec:
          remediationAction: enforce
          severity: low
          namespaceSelector:
            include:
              - open-cluster-management-agent-addon # Target MCOA agent installation namespace on spokes
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: monitoring.rhobs/v1alpha1
                kind: ScrapeConfig
                metadata:
                  name: mcoa-custom-platform-drop
                  namespace: open-cluster-management-agent-addon
                  labels:
                    app.kubernetes.io/component: platform-metrics-collector
                spec:
                  jobName: platform-metrics-drop
                  metricsPath: /federate
                  scrapeClass: ocp-monitoring
                  scheme: HTTPS
                  staticConfigs:
                    - targets:
                        - prometheus-k8s.openshift-monitoring.svc:9091
                  # MetricRelabelings are evaluated at the scrape boundary before entering the local WAL on the spoke
                  metricRelabelings:
                    # Drop high-cardinality container memory metrics to optimize spoke resource footprint
                    - action: drop
                      regex: ^(container_memory_cache|container_memory_rss|container_memory_swap|container_memory_working_set_bytes)$
                      sourceLabels:
                        - __name__
                    # Drop high-cardinality container CPU limit/request metrics at the edge
                    - action: drop
                      regex: ^(container_cpu_cfs_periods_total|container_cpu_cfs_throttled_periods_total)$
                      sourceLabels:
                        - __name__
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: placement-mcoa-custom-scrape-drop
  namespace: open-cluster-management-global-set
spec:
  clusterSets:
    - global
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchLabels:
            # Customize this label selector to target a specific subset of clusters (e.g., SNO or dev environments)
            environment: dev
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: binding-mcoa-custom-scrape-drop
  namespace: open-cluster-management-global-set
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: placement-mcoa-custom-scrape-drop
subjects:
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: policy-mcoa-custom-scrape-drop
```
 
---
 
## 6. User Workload Monitoring (UWM) — Custom Application Metrics
 
Collecting custom metrics from user-defined applications is handled by a dedicated spoke-side workload: the **`user-workload-metrics-collector`**. It uses a standard Prometheus Agent to federate metrics from OpenShift's in-cluster User Workload Monitoring (UWM) Prometheus service.
 
- **Default federation endpoint**: `prometheus-user-workload.openshift-user-workload-monitoring.svc:9092`
- **API compatibility**: Works natively with the OpenShift Cluster Monitoring Operator (CMO) and Cluster Observability Operator (COO).
### 6.1 Prerequisites
 
**On managed clusters** — enable UWM in the `cluster-monitoring-config` ConfigMap (namespace `openshift-monitoring`):
```yaml
data:
  config.yaml: |
    enableUserWorkload: true
```
 
**On the Hub** — enable user workload metrics in the `MultiClusterObservability` (MCO) CR:
```yaml
spec:
  capabilities:
    userWorkloads:
      metrics:
        default:
          enabled: true
```
 
### 6.2 Template A — Fleet-Wide Custom Application ScrapeConfig (Hub-Deployed)
 
Deployed on the Hub, in `open-cluster-management-observability`. Labeling it `app.kubernetes.io/component: user-workload-metrics-collector` tells MCOA to schedule it to matching target clusters. Collects specific custom metrics (e.g., `http_requests_total`, `app_db_connections_active`) from **all namespaces** on any matching cluster.
 
```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: fleet-custom-app-metrics
  namespace: open-cluster-management-observability
  labels:
    # CRITICAL: This label routes the configuration to the user workload metrics collector
    app.kubernetes.io/component: user-workload-metrics-collector
spec:
  jobName: user-workload-app-scrape
  metricsPath: /federate
  scheme: HTTPS
  # Standard ocp-monitoring scrapeClass provides the necessary service tokens
  scrapeClass: ocp-monitoring
  staticConfigs:
    - targets:
        # Default OpenShift UWM Prometheus federation endpoint
        - prometheus-user-workload.openshift-user-workload-monitoring.svc:9092
  params:
    match[]:
      # Federate only your specific high-value custom metrics
      - '{__name__="http_requests_total"}'
      - '{__name__="app_db_connections_active"}'
      - '{__name__="jvm_memory_used_bytes"}'
```
 
### 6.3 Template B — Namespace-Restricted ScrapeConfig (Edge Filtering)
 
Restricts collection to a single namespace (e.g., `payment-processing`) rather than federating across the whole cluster. Two ways to achieve this:
- **Snooping selector (Hub-wide)**: restrict namespaces via `scrapeConfigNamespaceSelector` in the placement-specific `PrometheusAgent` CR.
- **Explicit namespace enforcement (Spoke-wide)**: deployed directly on the spoke — if placed in the Agent's own namespace it covers all namespaces, but placed in a specific workload namespace it restricts federation to that namespace only.
```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: payment-restricted-metrics
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/component: user-workload-metrics-collector
spec:
  jobName: payment-app-scrape
  metricsPath: /federate
  scheme: HTTPS
  scrapeClass: ocp-monitoring
  staticConfigs:
    - targets:
        - prometheus-user-workload.openshift-user-workload-monitoring.svc:9092
  params:
    match[]:
      # Match only metrics originating from the 'payment-processing' namespace
      - '{__name__=~"payment_.*", namespace="payment-processing"}'
  metricRelabelings:
    # Optional relabeling: Ensure we attach a strict team owner label to everything scraped
    - targetLabel: team
      replacement: payments-sre
      action: replace
```
 
### 6.4 Template C — Advanced Relabeling (Cardinality Control)
 
User workload metrics are notorious for label explosion (session IDs, UUIDs, individual user agents). This template collects all `http_server_*` metrics but applies strict `metricRelabelings` to strip high-cardinality labels **before** they ever hit the WAL.
 
```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: cardinal-controlled-app-metrics
  namespace: open-cluster-management-observability
  labels:
    app.kubernetes.io/component: user-workload-metrics-collector
spec:
  jobName: high-cardinality-app-scrape
  metricsPath: /federate
  scheme: HTTPS
  scrapeClass: ocp-monitoring
  staticConfigs:
    - targets:
        - prometheus-user-workload.openshift-user-workload-monitoring.svc:9092
  params:
    match[]:
      - '{__name__=~"http_server_.*"}'
  # LEVEL 2 (Scrape Level) Relabeling - matches before entering the local WAL database
  metricRelabelings:
    # 1. Drop highly volatile UUID or transaction ID labels
    - action: labeldrop
      regex: ^(session_id|transaction_id|client_ip_address|user_agent)$
 
    # 2. Drop metrics matching a specific non-critical URI path (e.g., /healthz or /metrics)
    - action: drop
      regex: ^(/healthz|/metrics|/readyz)$
      sourceLabels:
        - uri
```
 
### 6.5 Registering Custom ScrapeConfigs on the Hub
 
Creating a `ScrapeConfig` resource alone does **not** deploy it. You must register it inside the `ClusterManagementAddOn` (CMA) placement definitions so MCOA compiles it into a `ManifestWork` and ships it to the spokes.
 
1. Edit the CMA:
```bash
   oc edit clustermanagementaddon multicluster-observability-addon
```
2. Add your `ScrapeConfig` to the `configs` list under the desired placement:
```yaml
   spec:
     installStrategy:
       type: Placements
       placements:
         - name: global
           namespace: open-cluster-management-global-set
           configs:
             # Default platform agents are already here...
             - group: monitoring.rhobs
               resource: scrapeconfigs
               name: fleet-custom-app-metrics # Matches Template A name
               namespace: open-cluster-management-observability
```
3. Verify deployment — confirm MCOA synthesized a `ManifestWork` containing the custom `ScrapeConfig` for the target spokes:
```bash
   oc get manifestworks -n <spoke-cluster-namespace> | grep observability
```
 
---
 
## 7. Worked Examples
 
### Example 1 — Save WAN bandwidth without losing local visibility (Level 1)
**Scenario**: Your regional Hub needs full container metrics for troubleshooting, but the Global Hub only needs a summary.
**Approach**: Use `writeRelabelConfigs` on the `remoteWrite` entry that points at the Global Hub, dropping verbose `container_*` series, while leaving the entry pointing at the regional Hub untouched. Metrics still exist in the spoke's local WAL for local dashboards/alerts.
 
```yaml
remoteWrite:
  - name: regional-hub
    url: 'https://regional-hub.example.com/api/write'
    # No writeRelabelConfigs — full fidelity for local troubleshooting
  - name: global-hub
    url: 'https://observatorium-api.open-cluster-management-observability.svc:8080/...'
    writeRelabelConfigs:
      - action: drop
        regex: ^container_.*$
        sourceLabels:
          - __name__
```
 
### Example 2 — Protect disk on a resource-constrained SNO cluster (Level 2)
**Scenario**: A Single Node OpenShift edge device has limited disk and you never want noisy `kubelet_volume_stats_*` metrics to exist locally at all.
**Approach**: Drop them in `metricRelabelings` on the `ScrapeConfig` so they never touch the WAL, saving disk I/O and storage.
 
```yaml
metricRelabelings:
  - action: drop
    regex: ^kubelet_volume_stats_.*$
    sourceLabels:
      - __name__
```
 
### Example 3 — Roll out the drop rule fleet-wide, but only to `dev` clusters
**Scenario**: You want to test the container CPU/memory drop policy from Section 5 before enforcing it everywhere.
**Approach**: Set `remediationAction: inform` on the policy first to see compliance status without making changes, review results with:
```bash
oc get policy policy-mcoa-custom-scrape-drop -n open-cluster-management-global-set -o yaml
```
Once satisfied, flip both `spec.remediationAction` and the `ConfigurationPolicy`'s `spec.remediationAction` to `enforce` (as shown in Section 5) to have OCM actively deploy and maintain the `ScrapeConfig` on all clusters labeled `environment: dev`.
 
### Example 4 — Scrape only one application's metrics from one namespace (Template B)
**Scenario**: The `payment-processing` team wants their own metrics collected with a mandatory `team: payments-sre` label, without pulling in noise from other namespaces.
**Approach**: Use Template B as-is — the `match[]` filter restricts to `payment_*` metrics in the `payment-processing` namespace, and the `metricRelabelings` `replace` action stamps every series with the owning team label for chargeback/alerting routing.
 
### Example 5 — Strip high-cardinality labels from HTTP server metrics (Template C)
**Scenario**: Your app emits `http_server_request_duration_seconds` with a `session_id` label per user session, which would blow up cardinality on ingestion.
**Approach**: Use Template C's `labeldrop` action to remove the `session_id` label (and similar volatile labels) at scrape time, keeping the metric but discarding the problematic label before it ever reaches the TSDB/WAL.
