# Dual-write from MCOA: one PrometheusAgent, two destinations

**Audience:** Platform architects and SREs running multi-hub RHACM with an enterprise metrics store (for example Grafana Enterprise Metrics or a central Thanos).  
**Applies to:** MultiCluster Observability Addon (MCOA) metrics collection using PrometheusAgent (RHACM 2.15+; confirm API group and defaults for your release).

---

Managing observability across multiple ACM hubs often creates two problems: **duplicate collectors on the spoke**, and **broken historical continuity** when a managed cluster moves from one regional hub to another.

Teams that need both regional ACM Observability *and* a central enterprise Source of Truth (SoT) traditionally ran two agents. That doubles edge CPU, memory, and egress. Hub migration made it worse: if long-term identity was tied to the regional hub’s tenancy, dashboards in the enterprise store fractured when the spoke changed hubs.

MCOA’s move to a standard **PrometheusAgent** makes a better pattern practical: **one scrape path, multiple `remoteWrite` destinations**—commonly called a **dual-write** architecture. This post describes that pattern, what it solves, and what it does *not* guarantee.

> **Important:** Dual-write is a **reference architecture** enabled by PrometheusAgent’s native multi-`remoteWrite` support. It is not a separate branded MCOA product feature. The default MCOA path still remote-writes to the ACM hub; enterprise destinations are an intentional extension you design and operate.

---

## What changes with MCOA collection

MCOA reworks spoke metrics collection by replacing the legacy **custom metrics-collector** with the upstream **PrometheusAgent**, configured through standard APIs (`PrometheusAgent`, `ScrapeConfig`, `PrometheusRule`) in the `open-cluster-management-observability` namespace.

(The legacy **endpoint-operator** path that deployed the old collector is deprecated in favor of this model; do not conflate “collector replacement” with every spoke operator concern.)

Because the Agent speaks normal Prometheus remote-write, you can define **more than one** `remoteWrite` target and attach **per-destination** `writeRelabelConfigs`.

```text
                    ┌─ writeRelabel (lean) ──► Regional ACM Hub (Day-2 / OOTB)
 Spoke metrics ──►  │
   PrometheusAgent ─┴─ writeRelabel (fuller) ► Enterprise SoT (GEM / central Thanos)
         │
         └─ local WAL (buffers while a destination is unreachable)
```

Typical split:

| Stream | Destination | Intent |
| --- | --- | --- |
| **1 – Regional health** | ACM hub Observability | Filtered platform set for OOTB dashboards and Day-2 ops |
| **2 – Enterprise SoT** | GEM or central Thanos | Fuller granularity, long retention, global dashboards |

You still send **two network streams**. What you eliminate is a **second collector stack** on the edge—not necessarily duplicate samples—unless relabeling makes the payloads complementary rather than identical.

---

## Three outcomes (and their limits)

### 1. One agent, destination-specific edge filtering

Use `writeRelabelConfigs` on each `remoteWrite` entry to keep or drop series **per destination**. Example: drop high-churn container memory series on the hub path to save WAN and hub storage, while leaving them on the enterprise path.

This pairs with scrape-level `metricRelabelings` on `ScrapeConfig` (drop before WAL). See your edge-relabeling guide for the two-level model.

**Benefit:** Lower spoke footprint than dual agents; control cost per path.  
**Limit:** Misconfigured drops can hide series operators still need on the hub.

### 2. Continuity across spoke hub migration (enterprise path)

If the enterprise remote-write target is **independent of which ACM hub owns the spoke**, and the Agent keeps **stable identity labels** (for example a durable `cluster_id` / GEM tenant labels), then moving the spoke between regional hubs does **not** rewrite history in the enterprise SoT.

**Benefit:** Enterprise dashboards stay a continuous record across hub moves.  
**Limits:**

- Continuity applies to the **hub-independent** stream. The **ACM hub** path can still show gaps during detach/reattach or reconfiguration.
- Labels must be designed deliberately; “tenant ID” in GEM and ACM cluster labels are related but not always identical.
- If hub migration tears down or recreates the Agent in a way that removes the enterprise remote-write config, continuity is broken until that config is restored.

### 3. Better tolerance of network blips (not unlimited DR)

The PrometheusAgent buffers scraped samples in a local Write-Ahead Log (WAL) and retries remote-write when a destination recovers. Under typical Prometheus remote-write behavior, buffering is on the order of **about two hours** and is **configuration-dependent**—not a hard product SLO of “one hour” or “forever.”

**Benefit:** Short network partitions to hub or GEM often drain cleanly after reconnect.  
**Limits:**

- WAL on **ephemeral storage** (`emptyDir`) can be **lost on pod restart**.
- **Planned hub failover / detach** that terminates the Agent can still create metrics gaps on paths that depend on that Agent lifecycle. Persistent WAL and softer detach behavior are operational concerns (and active product improvement areas)—dual-write to GEM reduces impact on *enterprise* history; it does not by itself deliver zero-gap ACM DR.

---

## Configuration sketch

MCOA manages the **hub** remote-write path and uses server-side apply to protect critical routing invariants. Treat the snippet below as an **architectural illustration**, not a paste-and-forget spoke edit.

In production:

1. Confirm how your release expects **additional** remote-write targets to be declared so they are not overwritten (hub-side templates / documented customization fields—not only a manual spoke CR tweak).
2. Pin the API group to what your cluster actually serves (`monitoring.rhobs` vs `monitoring.coreos.com` varies by operator stack and version).
3. Set **stable external labels** for enterprise tenancy before you migrate hubs.
4. Store TLS/auth material as secrets in `open-cluster-management-observability` (or the namespace your release documents).

```yaml
apiVersion: monitoring.rhobs/v1alpha1  # verify for your release
kind: PrometheusAgent
metadata:
  name: mcoa-platform-metrics-collector  # name may be release-specific
  namespace: open-cluster-management-observability
spec:
  # Stable identity for enterprise continuity across hub moves
  externalLabels:
    cluster_id: "<immutable-cluster-id>"
    # tenant: "<gem-tenant>"   # if required by your SoT

  secrets:
    - enterprise-sot-ca
    - enterprise-sot-cert

  remoteWrite:
    # Destination A: Enterprise SoT (hub-independent)
    - name: enterprise-sot-gem
      url: https://gem.example.com/api/v1/push   # your GEM/Thanos receive URL
      tlsConfig:
        caFile: /etc/prometheus/secrets/enterprise-sot-ca/ca.crt
        certFile: /etc/prometheus/secrets/enterprise-sot-cert/tls.crt
        keyFile: /etc/prometheus/secrets/enterprise-sot-cert/tls.key
      # Optional: keep fuller set; add drops only if SoT cost requires it
      # writeRelabelConfigs: []

    # Destination B: Regional ACM hub (often managed/enriched by MCOA)
    - name: acm-observability
      url: https://<hub-observability-receive>/api/v1/receive  # commonly injected by MCOA
      writeRelabelConfigs:
        # Illustrative only — tune to your allow/deny policy
        - action: drop
          sourceLabels: [__name__]
          regex: ^(container_memory_cache|container_memory_rss)$
```

**Operational checklist**

- [ ] Enterprise URL and auth work from every spoke network zone  
- [ ] `cluster_id` (and tenant labels) immutable across hub migration  
- [ ] Hub stream filtered enough for bandwidth; SoT stream matches retention/compliance needs  
- [ ] WAL / PVC strategy understood for Agent restarts and DR drills  
- [ ] Failure test: GEM down, hub down, Agent restart, spoke hub move  

---

## When to use this pattern

| Use dual-write when… | Prefer another approach when… |
| --- | --- |
| You need ACM Day-2 **and** a central SoT | A single central store is enough |
| Enterprise identity must survive hub moves | You only care about per-hub history |
| You can filter the hub path aggressively | You need identical full cardinality on both paths (costly) |
| Spokes can reach GEM/Thanos directly | Egress policy forces hub-only fan-in (then fan-out from hub/object storage instead) |

Related direction for **Global Hub** visibility over object storage (Query + Store Gateway, delayed historical read) is complementary: dual-write optimizes *ingest* identity and edge cost; Store Gateway patterns optimize *query* of durable blocks. They solve different layers.

---

## Bottom line

Do not force every regional ACM Thanos to be your global warehouse, and do not accept broken enterprise history as the price of hub mobility.

With MCOA’s PrometheusAgent, platform teams can draw a clean boundary:

- **ACM Observability** — regional fleet health and Day-2 operations (often a filtered stream)  
- **Enterprise metrics platform** — long-term SLAs and global query (hub-independent stream + stable labels)

The result is a **leaner edge** (one agent), **intentional** (not accidental) duplication of streams, and **continuity in the SoT** across hub moves—within the real limits of WAL persistence, Agent lifecycle, and how you manage configuration under MCOA.

---

## Next steps

- Validate the pattern in a non-prod placement with one spoke, then load-test cardinality and egress.  
- Align label contracts with your GEM/Thanos tenants before production migration.  
- Review edge relabeling (scrape vs `writeRelabelConfigs`) so hub and SoT policies stay complementary.  
- Include dual-write destinations and WAL/PVC assumptions in your ACM hub DR runbook.
