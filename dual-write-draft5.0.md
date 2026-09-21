# Dual-write: one spoke agent, two destinations

**Audience:** Platform engineers and SREs who run multi-hub ACM Observability and also keep a central enterprise metrics store.  
**Applies to:** MultiCluster Observability Addon (MCOA) metrics collection with Prometheus Agent (ACM 2.15+; confirm the API group for your release).  
**Status:** Draft 5.0

You do not need a second collector on every managed cluster to feed both regional ACM Observability and a central store such as Grafana Enterprise Metrics (GEM) or Thanos.

MCOA’s Prometheus Agent already speaks ordinary Prometheus remote-write. One scrape path can send **two** `remoteWrite` streams: a lean set to the ACM hub, and a fuller set to the enterprise store. That is the dual-write pattern.

This is a reference architecture, not a separate MCOA feature. The default path still writes only to the ACM hub. The second destination is something you add and operate. Enable MCOA first: [MCOA core and configuration](mcoa-core-and-configuration-draft5.0.md).

## The two problems this pattern is for

Teams that want both regional ACM dashboards and a long-term enterprise store often run **two agents** on the spoke. That doubles CPU, memory, and egress on the edge.

Hub moves make the cost worse. If the enterprise store keys history on the regional hub’s tenant, moving a cluster to another hub splits the time series. Dashboards look like a new cluster was born.

Dual-write attacks both problems: one agent, and an enterprise stream whose identity does not depend on which hub currently owns the spoke.

## What dual-write looks like

```text
Spoke cluster
  Prometheus Agent
       |
       +-- filtered remote-write --> Regional ACM hub (Day-2 dashboards)
       |
       +-- fuller remote-write  --> Enterprise store (GEM / Thanos)
       |
       +-- local WAL            --> buffers while a destination is unreachable
```

| Stream | Destination | What it is for |
| :--- | :--- | :--- |
| Regional health | ACM hub Observability | Filtered platform set for out-of-the-box dashboards and Day-2 ops |
| Enterprise store | GEM or central Thanos | Fuller granularity, long retention, global dashboards |

You still send **two network streams**. What you remove is the **second collector** on the spoke. Relabeling can also make the two payloads complementary instead of identical, so you are not storing the same samples twice by accident.

The Agent is configured with standard APIs: `PrometheusAgent`, `ScrapeConfig`, and `PrometheusRule`. The old custom metrics-collector path is gone. Do not mix that collector replacement with every other spoke operator concern; this post is only about where samples are written.

## What you get

### 1. Filter at the edge, per destination

Each `remoteWrite` entry can have its own `writeRelabelConfigs`. Drop high-churn series on the hub path to save WAN and hub storage, and leave them on the enterprise path.

That is different from scrape-time `metricRelabelings` on a `ScrapeConfig`, which drop series **before** they enter the write-ahead log (WAL). Use scrape drops when nobody needs the series. Use write relabeling when the hub should be lean but the enterprise store should still see the detail. See [edge relabeling](edgerelabeling.md) for the two-level model.

**Watch out:** a bad drop rule can hide series that ACM’s default dashboards still need.

### 2. Continuous enterprise history across hub moves

If the enterprise URL does not change when the spoke changes hubs, and the Agent keeps **stable identity labels** (for example an immutable `cluster_id`, plus GEM tenant labels if you use them), the enterprise store does not rewrite history.

**Watch out:**

- Continuity is for the **hub-independent** stream. The ACM hub path can still gap during detach, reattach, or reconfiguration.
- GEM tenant IDs and ACM cluster labels are related. They are not automatically the same. Design the label contract before you migrate.
- If hub migration tears down the Agent and you lose the extra `remoteWrite` entry, enterprise continuity stops until that config is restored.

### 3. Short outages, not unlimited disaster recovery

The Agent buffers scraped samples in a local WAL and retries remote-write when a destination comes back. Typical Prometheus remote-write buffering is on the order of **about two hours**, and it depends on configuration. That is not a product SLO of “one hour” or “forever.”

Short network blips to the hub or to GEM often drain cleanly after reconnect.

**Watch out:**

- A WAL on ephemeral storage (`emptyDir`) is **lost on pod restart**.
- A planned hub failover that terminates the Agent can still gap any path that depends on that Agent. Dual-write to GEM protects **enterprise** history. It does not, by itself, give you zero-gap ACM disaster recovery.

## How to add the second destination

MCOA owns the **hub** remote-write path and uses server-side apply to protect it. Treat the YAML below as an architecture sketch, not a paste-and-forget edit on the spoke.

In production:

1. Confirm how your release expects **additional** remote-write targets so MCOA does not overwrite them. Prefer hub-side templates or the documented customization fields, not only a manual spoke CR tweak.
2. Pin the API group to what the cluster actually serves (`monitoring.rhobs` vs `monitoring.coreos.com` depends on operator stack and version).
3. Set **stable external labels** for enterprise tenancy **before** you migrate hubs.
4. Store TLS and auth material as secrets in `open-cluster-management-observability` (or the namespace your release documents).

```yaml
apiVersion: monitoring.rhobs/v1alpha1  # verify for your release
kind: PrometheusAgent
metadata:
  name: mcoa-platform-metrics-collector  # name may be release-specific
  namespace: open-cluster-management-observability
spec:
  # Stable identity so enterprise history survives hub moves
  externalLabels:
    cluster_id: "<immutable-cluster-id>"
    # tenant: "<gem-tenant>"   # if your store requires it

  secrets:
    - enterprise-sot-ca
    - enterprise-sot-cert

  remoteWrite:
    # Destination A: enterprise store (independent of which ACM hub owns the spoke)
    - name: enterprise-sot-gem
      url: https://gem.example.com/api/v1/push   # your GEM or Thanos receive URL
      tlsConfig:
        caFile: /etc/prometheus/secrets/enterprise-sot-ca/ca.crt
        certFile: /etc/prometheus/secrets/enterprise-sot-cert/tls.crt
        keyFile: /etc/prometheus/secrets/enterprise-sot-cert/tls.key
      # Keep the fuller set. Add drops only if store cost requires it.
      # writeRelabelConfigs: []

    # Destination B: regional ACM hub (often injected and protected by MCOA)
    - name: acm-observability
      url: https://<hub-observability-receive>/api/v1/receive
      writeRelabelConfigs:
        # Illustrative only. Tune to your allow or deny policy.
        - action: drop
          sourceLabels: [__name__]
          regex: ^(container_memory_cache|container_memory_rss)$
```

**Before you rely on this in production**

- [ ] The enterprise URL and auth work from every spoke network zone
- [ ] `cluster_id` (and tenant labels) stay the same across hub migration
- [ ] The hub stream is filtered enough for bandwidth; the enterprise stream matches retention and compliance
- [ ] You know whether the WAL sits on ephemeral disk or a PVC, and you have drilled Agent restart
- [ ] You have failed GEM, failed the hub, restarted the Agent, and moved a spoke between hubs

## When to use this pattern

| Use dual-write when | Prefer another approach when |
| :--- | :--- |
| You need ACM Day-2 **and** a central store | One central store is enough |
| Enterprise identity must survive hub moves | You only care about per-hub history |
| You can filter the hub path aggressively | You need identical full cardinality on both paths (that is costly) |
| Spokes can reach GEM or Thanos directly | Egress policy forces hub-only fan-in (then fan out from the hub or object storage) |

Global Hub query over object storage (Query plus Store Gateway, delayed historical read) is a **different layer**. Dual-write is about ingest identity and edge cost. Store Gateway is about querying durable blocks. You can use both. Do not treat one as a substitute for the other.

## Bottom line

Do not make every regional ACM Thanos your global warehouse. Do not accept broken enterprise history as the price of moving a spoke between hubs.

With MCOA’s Prometheus Agent you can keep a clean split:

- **ACM Observability:** regional fleet health and Day-2 operations, often a filtered stream
- **Enterprise metrics platform:** long-term SLAs and global query, a hub-independent stream with stable labels

The result is a leaner edge (one agent), two streams you chose on purpose, and continuity in the enterprise store across hub moves. That holds only if the WAL persists, the Agent stays configured through migration, and you add the second destination the way your MCOA release expects.

## Next steps

- Prove the pattern on one non-prod spoke, then load-test cardinality and egress.
- Agree the label contract with your GEM or Thanos tenants before any production hub move.
- Review scrape-time vs `writeRelabelConfigs` so hub and enterprise policies stay complementary. See [edge relabeling](edgerelabeling.md) and [cardinality](cardinality-draft5.0.md).
- Put dual-write destinations and WAL/PVC assumptions in the ACM hub disaster-recovery runbook.
