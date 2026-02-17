# Building a Distributed Key-Value Store

## 1. Executive Summary

This document describes the architecture, protocols, and implementation strategy for **Meridian**, a distributed key-value store designed for **low-latency reads** and **tunable consistency**. The system targets workloads where *eventual consistency* is acceptable for most operations but *linearizable reads* are available on demand.

Key goals:

- **P99 read latency** under 5ms within a single datacenter
- **Horizontal scalability** to 500+ nodes per cluster
- **Automatic rebalancing** with zero-downtime partition splits
- Support for ~~strong consistency everywhere~~ tunable consistency per request
- ==Multi-region replication== with conflict resolution

---

## 2. Architecture Overview

### 2.1 Node Roles

Every node in the cluster takes on one or more roles:

1. **Coordinator** — receives client requests and routes them to the correct partition
2. **Storage Node** — owns a set of partitions and persists data to disk
3. **Gossip Agent** — participates in failure detection and membership protocol
4. **Rebalancer** — runs on a subset of nodes to orchestrate partition moves

> All nodes run the gossip agent. The coordinator role is stateless and can be colocated with any storage node.

### 2.2 Data Model

Each record is a key-value pair with metadata:

| Field | Type | Description |
|-------|------|-------------|
| `key` | `bytes` | Partition key, max 512 bytes |
| `value` | `bytes` | Opaque payload, max 1 MB |
| `version` | `uint64` | Lamport timestamp |
| `tombstone` | `bool` | Soft-delete marker |
| `ttl` | `duration` | Optional time-to-live |

### 2.3 Partitioning

We use **consistent hashing** with virtual nodes. Each physical node owns `V` virtual nodes on the ring, where `V` is proportional to the node's capacity weight.

```python
import hashlib
from bisect import bisect_right

class ConsistentHashRing:
    def __init__(self, nodes: list[str], vnodes_per_node: int = 128):
        self.ring: list[tuple[int, str]] = []
        for node in nodes:
            for i in range(vnodes_per_node):
                h = int(hashlib.sha256(f"{node}:vn{i}".encode()).hexdigest(), 16)
                self.ring.append((h, node))
        self.ring.sort()

    def get_node(self, key: str) -> str:
        h = int(hashlib.sha256(key.encode()).hexdigest(), 16)
        idx = bisect_right([e[0] for e in self.ring], h) % len(self.ring)
        return self.ring[idx][1]

    def get_preference_list(self, key: str, n: int = 3) -> list[str]:
        """Return N distinct physical nodes for replication."""
        h = int(hashlib.sha256(key.encode()).hexdigest(), 16)
        idx = bisect_right([e[0] for e in self.ring], h) % len(self.ring)
        result, seen = [], set()
        while len(result) < n:
            node = self.ring[idx % len(self.ring)][1]
            if node not in seen:
                result.append(node)
                seen.add(node)
            idx += 1
        return result
```

---

## 3. Replication Protocol

### 3.1 Write Path

Writes follow a **quorum-based** protocol parameterized by `(N, W, R)`:

- `N` = total replicas (default 3)
- `W` = write quorum (default 2)
- `R` = read quorum (default 2)

> **Important:** The constraint `W + R > N` must hold for linearizable reads.
>
>> Note: For eventually consistent reads, `R = 1` is sufficient and significantly reduces tail latency.

The coordinator performs these steps:

1. Receive the `PUT` request from the client
2. Compute the *preference list* for the key
3. Send the write to all `N` replicas in parallel
4. Wait for `W` acknowledgments
5. Return success to the client

### 3.2 Conflict Resolution

When replicas diverge, we use **vector clocks** for causality tracking. If two versions are *concurrent* (neither dominates), the system invokes a pluggable merge function.

```json
{
  "key": "user:4821",
  "versions": [
    {
      "value": "{\"name\": \"Alice\", \"email\": \"alice@example.com\"}",
      "vector_clock": {"node-a": 3, "node-b": 2},
      "timestamp": "2026-01-15T08:30:00Z"
    },
    {
      "value": "{\"name\": \"Alice Chen\", \"email\": \"alice@example.com\"}",
      "vector_clock": {"node-a": 2, "node-b": 3},
      "timestamp": "2026-01-15T08:30:05Z"
    }
  ],
  "resolved_by": "last-writer-wins"
}
```

---

## 4. Storage Engine

#### 4.1 LSM-Tree Design

The on-disk format uses a **Log-Structured Merge Tree** with the following levels:

- **L0 (memtable flush):** unsorted SSTable files, max 64 MB each
- **L1:** sorted runs, 10x size ratio, max 640 MB total
- **L2:** sorted runs, 10x size ratio, max 6.4 GB total
- **L3+:** continues the 10x amplification pattern

> Compaction uses a *leveled* strategy by default but supports *tiered* compaction for write-heavy workloads.

##### 4.1.1 Bloom Filters

Each SSTable includes a **Bloom filter** to avoid unnecessary disk reads:

| Level | False Positive Rate | Bits per Key |
|-------|-------------------|--------------|
| L0 | 1% | 10 |
| L1 | 0.1% | 14 |
| L2+ | 0.01% | 20 |

###### Tuning Notes

The bits-per-key setting directly trades memory for read amplification. For workloads with high *point-read* ratios, increasing L0 to 14 bits eliminates most false positives at the cost of ~40% more filter memory.

#### 4.2 Write-Ahead Log

Every mutation is first written to a **WAL** before being applied to the memtable:

```bash
#!/usr/bin/env bash
# WAL segment rotation — runs as a cron job every 5 minutes

WAL_DIR="/var/lib/meridian/wal"
ARCHIVE_DIR="/var/lib/meridian/wal_archive"
MAX_SIZE=$((64 * 1024 * 1024))  # 64 MB

current=$(ls -t "$WAL_DIR"/segment_*.wal 2>/dev/null | head -1)
[[ -z "$current" ]] && exit 0

size=$(stat -f%z "$current" 2>/dev/null || stat -c%s "$current")
if (( size >= MAX_SIZE )); then
    archive="segment_$(date +%Y%m%d_%H%M%S).wal.gz"
    gzip -c "$current" > "${ARCHIVE_DIR}/${archive}"
    truncate -s 0 "$current"
    find "$ARCHIVE_DIR" -name "*.wal.gz" -mtime +7 -delete
fi
```

---

## 5. Consistency Models

### 5.1 Available Consistency Levels

Meridian supports multiple consistency levels per request:

- **`ONE`** — return after *any* single replica responds
- **`QUORUM`** — return after a majority of replicas respond
- **`ALL`** — return after ==every replica== responds
- **`LOCAL_QUORUM`** — quorum within the local datacenter only
- **`LINEARIZABLE`** — uses a ~~Paxos~~ Raft-based protocol for strong consistency

### 5.2 Read Repair

When a `QUORUM` read detects stale replicas, the coordinator triggers **read repair** asynchronously. See the [Dynamo paper](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) for background on this technique.

---

## 6. Failure Detection

### 6.1 Phi Accrual Failure Detector

Instead of a binary *alive/dead* classification, we use the **Phi Accrual Failure Detector** which outputs a *suspicion level* on a continuous scale:

```
phi = -log10(1 - F(timeSinceLastHeartbeat))
```

Where `F` is the CDF of the normal distribution fitted to historical inter-arrival times.

- `phi < 1` — node is *probably alive*
- `1 <= phi < 8` — node is *suspected*
- `phi >= 8` — node is *considered dead* (default threshold)

### 6.2 Gossip Protocol

Membership state is disseminated using a **SWIM-style** protocol. The persistent membership table schema:

```sql
CREATE TABLE cluster_membership (
    node_id         UUID PRIMARY KEY,
    address         INET NOT NULL,
    port            INTEGER NOT NULL DEFAULT 7400,
    status          VARCHAR(20) NOT NULL DEFAULT 'alive',
    generation      BIGINT NOT NULL DEFAULT 0,
    datacenter      VARCHAR(64),
    rack            VARCHAR(64),
    capacity_weight REAL NOT NULL DEFAULT 1.0,
    last_heartbeat  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    metadata        JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX idx_membership_status ON cluster_membership(status);

CREATE VIEW active_nodes AS
SELECT node_id, address, port, datacenter, rack, capacity_weight
FROM cluster_membership
WHERE status IN ('alive', 'suspected')
  AND last_heartbeat > NOW() - INTERVAL '30 seconds';
```

---

## 7. Operational Runbook

### 7.1 Deployment Checklist

- [x] Provision nodes with at least 16 GB RAM and NVMe storage
- [x] Configure network security groups for ports `7400` (gossip) and `7401` (client)
- [x] Deploy seed node configuration to all instances
- [x] Verify cluster membership convergence via `/status` endpoint
- [ ] Run `meridian-bench` load test against staging cluster
- [ ] Configure alerting thresholds for `phi` detector
- [ ] Set up automated WAL archival to object storage
- [ ] Enable cross-datacenter replication for DR

### 7.2 Monitoring Metrics

The following metrics are exported via *Prometheus*:

- `meridian_requests_total{method, consistency, status}` — request counter
- `meridian_request_duration_seconds{method}` — latency histogram
- `meridian_replicas_stale_total` — read repair trigger count
- `meridian_compaction_duration_seconds{level}` — compaction timing
- `meridian_wal_size_bytes` — current WAL segment size
- `meridian_bloom_false_positive_rate{level}` — observed FP rate

### 7.3 Common Issues

> **Symptom:** Read latency spikes during compaction.
>
>> **Root cause:** L0 to L1 compaction competing for disk I/O.
>>
>> **Mitigation:** Enable rate limiting via `compaction_throughput_mb = 50` in the config.

> **Symptom:** Cluster split-brain after network partition heals.
>
>> **Resolution:** The gossip protocol will automatically reconcile within `3 * gossip_interval`. If not, trigger a manual state push with `meridian-ctl force-sync`.

---

## 8. Performance Benchmarks

Results from a 16-core, 64 GB node with NVMe storage:

| Workload | Ops/sec | P50 Latency | P99 Latency |
|----------|---------|-------------|-------------|
| 100% reads | 850,000 | 0.3 ms | 1.2 ms |
| 50/50 read/write | 420,000 | 0.8 ms | 3.5 ms |
| 100% writes | 310,000 | 1.1 ms | 4.8 ms |
| Scan (100 keys) | 45,000 | 2.4 ms | 8.1 ms |

Cluster throughput with `N=3, W=2, R=2` and `QUORUM` consistency across 15 nodes:

- **Read throughput:** ~4.2 million ops/sec (linear scaling to ~80%)
- **Write throughput:** ~1.8 million ops/sec
- **Rebalance time:** ~12 minutes to integrate a new node with 500 GB of data

---

## 9. Future Work

The following items are planned for upcoming releases:

1. **Transactions** — lightweight transactions using Raft consensus for single-partition atomicity
2. **Secondary indexes** — global and local secondary index support with async building
3. **Change data capture** — streaming changelog for downstream consumers
4. **Tiered storage** — automatic migration of cold data to object storage
5. **Compression** — per-SSTable compression with `zstd` at configurable levels

Design constraints guiding future development:

- *Never* sacrifice availability for features
- Keep the **hot path** allocation-free where possible
- Maintain backward compatibility for the wire protocol across minor versions
- All new features must be ~~enabled by default~~ opt-in with feature flags

---

*Last updated: 2026-02-18 | Authors: Infrastructure Team | Status: ==Living Document==*
