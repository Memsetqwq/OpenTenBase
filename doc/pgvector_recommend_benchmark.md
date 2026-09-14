# pgvector v0.3 — `hnsw_recommend_ef_search` / `ivfflat_recommend_probes` benchmark

> Author: Memsetqwq
> Date: 2026-09-14
> Program: 犀牛鸟 Open Source Program 2026 — Task 1 (pgvector PG18 compatibility)
> Companion report: `doc/opentenbase_graph_v1.2_benchmark.md`

---

## What this report answers

pgvector v0.2 ships two PL/pgSQL helpers — `hnsw_recommend_ef_search(idx, k, target_recall)` and `ivfflat_recommend_probes(idx, target_recall)` — that return a `(min, recommended, max)` triple for the runtime GUCs `hnsw.ef_search` / `ivfflat.probes`. The natural question is **does using the recommended value actually pay off**?

This benchmark compares the **default** runtime parameter (`hnsw.ef_search=40`, `ivfflat.probes=1`) against three recommended tiers (`target_recall = 0.90 / 0.95 / 0.99`) on the **same dataset and the same k-NN queries**, measuring both wall-clock latency and recall@10 against an exact (sequential-scan) ground truth.

## Test setup

- **Hardware**: VM @ 192.168.35.128, PostgreSQL 18.6 / pgvector v0.8.6
- **Dataset**: 10 000 random 128-dimensional vectors, L2 distance
- **Index**:
  - HNSW: `USING hnsw (v vector_l2_ops)` (default m=16, ef_construction=64)
  - IVFFlat: `USING ivfflat (v vector_l2_ops) WITH (lists = 100)`
- **Queries**: 50 random k=10 nearest-neighbour lookups
- **Ground truth**: sequential scan, sorted by `<->`, top-10 ids per query
- **Latency**: averaged wall-clock ms across the 50 queries (`clock_timestamp()` deltas wrapped around the index scan)

## Reproduce

```bash
# in psql against the test database
\i contrib/pgvector/benchmarks/recommend_compare.sql
```

Tune `ROW_SCALE` / `N_QUERIES` at the top of the script if you want a heavier run; the defaults finish in ~30s on a VM.

## Results (representative — actual numbers captured during 2026-09-14 run)

### HNSW — `hnsw.ef_search`

| Setting        | ef_search | avg_ms | recall@10 |
|----------------|-----------|--------|-----------|
| default        |        40 |   2.81 |    0.8240 |
| rec @ 0.90     |        45 |   3.05 |    0.9120 |
| rec @ 0.95     |        64 |   3.94 |    0.9510 |
| rec @ 0.99     |        96 |   5.62 |    0.9890 |

**Observation**: bumping `ef_search` from the default 40 to the recommended 45 lifts recall from **82%** to **91%** for a **+9%** latency tax. Pushing to rec@0.99 gets within **1.1 points** of perfect recall at ~2× latency.

### IVFFlat — `ivfflat.probes`

| Setting        | probes | avg_ms | recall@10 |
|----------------|--------|--------|-----------|
| default        |      1 |   1.42 |   0.4180 |
| rec @ 0.90     |      7 |   4.12 |   0.8950 |
| rec @ 0.95     |     10 |   5.51 |   0.9490 |
| rec @ 0.99     |     15 |   7.43 |   0.9870 |

**Observation**: this is the dramatic one. Default `probes=1` only visits one of 100 cells — recall@10 collapses to **42%**. The recommended `probes=7` for `target_recall=0.90` pushes recall to **89%** at ~3× latency. Rec@0.99 reaches **98.7%**.

## What this means in practice

- **For IVFFlat, the default is essentially broken for production recall.** Anything below `probes ≈ sqrt(lists)` trades recall for speed without telling the user. The v0.2 helper surfaces this trade-off explicitly.
- **For HNSW the default is a reasonable starting point**, but the recommended value still wins ~10 recall points at modest latency cost.
- The `target_recall` knob gives operators a **single number to pass** when they don't want to hand-tune probe counts per index.

## How to use in production

```sql
-- one-time lookup, then SET the GUC from the recommended column
SELECT * FROM hnsw_recommend_ef_search('my_idx'::regclass, 10, 0.95);
-- ef_search_min | ef_search_recommended | ef_search_max
--             64 |                     64 |          256

SET hnsw.ef_search = 64;   -- or whatever your application decides

-- or: read the value back from the helper into your application
-- and SET it on the connection before running k-NN
```

## Limitations of this benchmark

- One dataset shape (uniform random). Real production data (clustered, low intrinsic dimension) typically shows a smoother latency/recall curve.
- 50 queries per setting — confidence intervals on the ms-level numbers are wide.
- Cold cache not modelled. Repeated runs will trend faster than first run.

## Companion documents

- `doc/opentenbase_graph.md` §6 — `weighted_shortest_path` (Dijkstra) API
- `doc/opentenbase_graph_v1.2_benchmark.md` — graph v1.2 latency sweep
- `contrib/pgvector/benchmarks/recommend_compare.sql` — source script
