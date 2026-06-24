# Securing and Scaling User Workload Monitoring: From Setup to Kyverno Guardrails
 
As Kubernetes fleets expand, balancing stable infrastructure monitoring with developers' needs to monitor custom applications becomes a common challenge. OpenShift and Red Hat Advanced Cluster Management (RHACM) address this via User Workload Monitoring (UWM). However, ensuring that these monitoring configurations remain consistent and free from unauthorized manual edits requires an additional layer of governance.
 
This blog explores how to enable UWM, delegate access to developers, use a policy engine like Kyverno to enforce configuration standards, and integrate metrics collection through the multicluster observability add-on (MCOA).
 
## Step 1: Enabling User Workload Monitoring
 
By default, OpenShift's monitoring stack is strictly dedicated to core platform components. To monitor custom applications without risking the stability of the platform's core Prometheus, administrators can enable UWM.
 
This is accomplished by editing the `cluster-monitoring-config` ConfigMap in the `openshift-monitoring` namespace and adding the `enableUserWorkload: true` flag. Once this configuration is saved, the Prometheus Operator automatically deploys dedicated `prometheus-user-workload` and `thanos-ruler-user-workload` pods to begin scraping application endpoints.
 
## Step 2: Installing and Configuring Kyverno
 
Kyverno provides multiple installation methods: Helm and YAML manifest. When installing in a production environment, Helm is the recommended and most flexible method as it offers convenient configuration options to satisfy a wide range of customizations.
 
### Prerequisites
 
Before installing Kyverno, ensure that:
- You have cluster administrator privileges
- Helm 3.x is installed
- Your Kubernetes cluster meets Kyverno's minimum version requirements (typically Kubernetes 1.23+)
- Kyverno must always be installed in a dedicated Namespace; it must not be co-located with other applications in existing Namespaces including system Namespaces such as kube-system.
### Installation via Helm (Recommended)
 
For production environments, use Helm for a highly-available installation:
 
```bash
# Add the Kyverno Helm repository
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
 
# Create namespace and install Kyverno with high availability
helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=2 \
  --set cleanupController.replicas=2 \
  --set reportsController.replicas=2
```
 
#### Special Considerations for OpenShift
 
The Kyverno Helm chart defines its own values for the Pod's securityContext object which, although it conforms to the upstream Pod Security Standards' restricted profile, may potentially be incompatible with your defined Security Context Constraints. Deploying the Kyverno Helm chart as-is on an OpenShift environment may result in an error similar to "unable to validate against any security context constraint".
 
To resolve this on OpenShift:
 
```bash
helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --set securityContext=null
```
 
OpenShift will automatically apply the appropriate Security Context Constraints upon deployment.
 
### Installation via YAML Manifest (Alternative)
 
If you prefer a simpler, non-production installation, you can use the YAML manifest:
 
```bash
kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.11.1/install.yaml
```
 
### Verify Installation
 
After installation, verify that Kyverno is running correctly:
 
```bash
# Check Kyverno pods
kubectl get pods -n kyverno
 
# Expected output should show:
# - kyverno-admission-controller-xxxxx (required)
# - kyverno-background-controller-xxxxx
# - kyverno-cleanup-controller-xxxxx
# - kyverno-reports-controller-xxxxx
```
 
## Step 3: Enabling Kyverno Metrics
 
When you install Kyverno via Helm, additional services are created inside the kyverno Namespace which expose metrics on port 8000. These metrics provide visibility into policy enforcement, admission review latencies, and rule execution results.
 
### Metrics Service Configuration
 
By default, the metrics service is created as a ClusterIP, meaning metrics can only be scraped by a Prometheus server within the cluster. For in-cluster monitoring (typical scenario):
 
```yaml
admissionController:
  metricsService:
    create: true
    type: ClusterIP
    port: 8000
```
 
For scenarios where Prometheus runs outside the cluster, expose the metrics service as NodePort or LoadBalancer:
 
```bash
helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --set admissionController.metricsService.type=NodePort \
  --set admissionController.metricsService.port=8000 \
  --set admissionController.metricsService.nodePort=30539
```
 
### Configuring Metrics Granularity
 
You can specify the scope of your monitoring targets to either the rule, policy, or cluster level, which enables you to extract more granular insights from collected metrics.
 
To optimize metrics collection, you can configure namespace inclusion and exclusion in your Helm values:
 
```yaml
config:
  metricsConfig:
    namespaces:
      include: [] # Empty means all namespaces
      exclude:
        - kyverno
        - kube-system
        - test
```
 
This configuration reduces memory footprint by excluding metrics from test or experimental namespaces.
 
## Step 4: Defining Metrics in Scrape Config Using MCOA
 
The multicluster observability add-on (MCOA) in Red Hat Advanced Cluster Management for Kubernetes enables seamless metrics collection and federation across multiple clusters. MCOA manages the full metrics pipeline end to end, including recording rules deployed automatically, metrics federated seamlessly, and dashboards populated immediately.
 
### Creating a ServiceMonitor for Kyverno
 
To integrate Kyverno metrics with Prometheus/MCOA, create a ServiceMonitor resource:
 
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kyverno-metrics
  namespace: kyverno
  labels:
    app.kubernetes.io/name: kyverno
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/instance: kyverno
  namespaceSelector:
    matchNames:
      - kyverno
  endpoints:
    - port: metrics
      interval: 60s
      path: /metrics
      scheme: http
      tlsConfig:
        insecureSkipVerify: true
```
 
Apply this configuration:
 
```bash
kubectl apply -f servicemonitor-kyverno.yaml
```
 
### MCOA ScrapeConfig Integration
 
Within the MCOA framework, you can configure ScrapeConfig resources to manage metrics collection:
 
```yaml
apiVersion: config.openshift.io/v1
kind: ScrapeConfig
metadata:
  name: kyverno-metrics
  namespace: open-cluster-management-agent-addon
spec:
  scrapeInterval: 60s
  scrapeTimeout: 10s
  staticConfigs:
    - targets:
        - "kyverno-svc-metrics.kyverno.svc.cluster.local:8000"
```
 
This ScrapeConfig instructs the PrometheusAgent to discover and scrape Kyverno metrics, which are then federated to the hub cluster's Thanos for centralized storage and querying.
 
### Verifying Metrics Collection
 
To verify that Kyverno metrics are being collected:
 
```bash
# Port-forward to Prometheus to view metrics
kubectl port-forward -n openshift-monitoring svc/prometheus-operated 9090:9090
 
# Access Prometheus at http://localhost:9090
# Navigate to Status → Targets and search for "kyverno" to confirm the scrape target
```
 
Alternatively, query metrics directly:
 
```bash
kubectl exec -n openshift-monitoring prometheus-operated-0 -- \
  promtool query instant 'kyverno_policy_changes_total'
```
 
## Step 5: Empowering Developers with RBAC
 
Once UWM is active, cluster administrators can grant developers specific role-based permissions to manage their own monitoring stack securely without needing cluster-admin rights:
 
- **monitoring-edit**: Allows developers to create, read, modify, and delete `ServiceMonitor` and `PodMonitor` resources to scrape metrics directly from their services and pods.
- **monitoring-rules-edit**: Permits the creation and modification of `PrometheusRule` custom resources for user-defined projects, enabling custom alerting.
- **user-workload-monitoring-config-edit**: Grants permission to configure the core UWM components (like Prometheus, Alertmanager, and Thanos Ruler) by editing the `user-workload-monitoring-config` ConfigMap.
## Step 6: Enforcing Configuration Consistency with Kyverno
 
While providing developers with self-service observability is powerful, it introduces the risk of configuration drift. Even when organizations use GitOps tools and Internal Developer Platforms to standardize deployments, instances of human intervention or human-initiated manual edits still occur.
 
This is where a policy engine like Kyverno becomes essential. Kyverno acts as a dynamic admission controller, allowing real-time policy enforcement through Custom Resource Definitions (CRDs).
 
### Example Kyverno Policy for ServiceMonitor Validation
 
Here's a Kyverno policy that enforces standards on ServiceMonitor resources:
 
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: validate-service-monitor
spec:
  validationFailureAction: audit
  rules:
    - name: check-required-labels
      match:
        resources:
          kinds:
            - monitoring.coreos.com/v1/ServiceMonitor
      validate:
        message: "ServiceMonitor must include required labels"
        pattern:
          metadata:
            labels:
              monitoring: "enabled"
    - name: check-scrape-interval
      match:
        resources:
          kinds:
            - monitoring.coreos.com/v1/ServiceMonitor
      validate:
        message: "Scrape interval must be between 30s and 5m"
        pattern:
          spec:
            endpoints:
              - interval: "?*"
```
 
Kyverno can detect when changes to monitoring resources are attempted through unexpected methods, such as direct manual edits bypassing the standard CI/CD pipeline. Depending on your organization's configuration, Kyverno can either:
- Simply notify administrators of the event (audit mode)
- Prevent unauthorized direct edits entirely (enforce mode)
### Monitoring Kyverno Policy Compliance
 
With MCOA enabled, you can create PrometheusRules to alert on policy violations:
 
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kyverno-policy-alerts
  namespace: kyverno
spec:
  groups:
    - name: kyverno.rules
      interval: 30s
      rules:
        - alert: KyvernoPolicyViolation
          expr: increase(kyverno_policy_results_total{result="fail"}[5m]) > 0
          annotations:
            summary: "Kyverno policy violation detected"
            description: "{{ $labels.policy }}/{{ $labels.rule }} violation"
```
 
## Conclusion
 
By combining OpenShift's User Workload Monitoring with strict Role-Based Access Control, Kyverno's policy enforcement, and Red Hat's multicluster observability add-on for centralized metrics federation, organizations can successfully democratize observability. Developers gain the autonomy to monitor their applications, while platform teams maintain peace of mind knowing that all monitoring configurations are protected from unintended manual drift.
 
This layered approach ensures:
- **Self-service observability** for development teams
- **Policy-driven configuration** enforcement across clusters
- **Centralized metrics collection** and visibility through MCOA
- **Compliance and audit trails** for all monitoring changes
- **Scalable governance** as your Kubernetes environment grows
## Next Steps
 
1. Install Kyverno in your OpenShift cluster using Helm
2. Enable metrics collection and configure ServiceMonitors
3. Integrate with MCOA for multicluster observability
4. Create Kyverno policies to enforce your organization's monitoring standards
5. Delegate developer access through appropriate RBAC roles
6. Monitor policy compliance and adjust policies based on audit findings
