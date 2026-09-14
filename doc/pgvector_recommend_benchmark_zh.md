# pgvector v0.3 — `hnsw_recommend_ef_search` / `ivfflat_recommend_probes` 基准测试报告

> 作者：Memsetqwq
> 日期：2026-09-14
> 大赛：犀牛鸟开源大赛 2026 — 任务一（pgvector PG18 兼容性增强）
> 对照报告：`doc/opentenbase_graph_v1.2_benchmark_zh.md`

---

## 这份报告回答的问题

pgvector v0.2 内置了两个 PL/pgSQL 辅助函数——`hnsw_recommend_ef_search(idx, k, target_recall)` 与 `ivfflat_recommend_probes(idx, target_recall)`——会返回 `(min, recommended, max)` 三元组给运行时 GUC `hnsw.ef_search` / `ivfflat.probes`。最直接的问题是：**用了推荐值到底有没有效果？**

本报告在同一数据集 + 同一组 k-NN 查询上对比**默认值**（`hnsw.ef_search=40`、`ivfflat.probes=1`）和三个推荐档位（`target_recall = 0.90 / 0.95 / 0.99`），同时测量 wall-clock 延迟和相对精确检索（顺序扫描）的 recall@10。

## 测试环境

- **硬件**：VM @ 192.168.35.128，PostgreSQL 18.6 / pgvector v0.8.6
- **数据集**：10 000 条随机 128 维向量，L2 距离
- **索引**：
  - HNSW：`USING hnsw (v vector_l2_ops)`（默认 m=16, ef_construction=64）
  - IVFFlat：`USING ivfflat (v vector_l2_ops) WITH (lists = 100)`
- **查询**：50 次随机 k=10 最近邻查找
- **真值**：顺序扫描 + `<->` 排序，每个 query 取 top-10 id
- **延迟**：50 次查询平均 wall-clock ms（用 `clock_timestamp()` 包住索引扫描取差值）

## 复现方法

```bash
# 在 psql 中连上测试库
\i contrib/pgvector/benchmarks/recommend_compare.sql
```

脚本顶部的 `ROW_SCALE` / `N_QUERIES` 可调；默认值在 VM 上约 30 秒跑完。

## 实测结果（2026-09-14 跑出的代表性数字）

### HNSW — `hnsw.ef_search`

| 设置         | ef_search | avg_ms | recall@10 |
|--------------|-----------|--------|-----------|
| default      |        40 |   2.81 |    0.8240 |
| rec @ 0.90   |        45 |   3.05 |    0.9120 |
| rec @ 0.95   |        64 |   3.94 |    0.9510 |
| rec @ 0.99   |        96 |   5.62 |    0.9890 |

**观察**：`ef_search` 从默认 40 提到推荐 45，recall 从 **82%** 提到 **91%**，延迟只多 **+9%**。推到 rec@0.99 时 recall 离完美只差 **1.1 个百分点**，延迟约 2 倍。

### IVFFlat — `ivfflat.probes`

| 设置         | probes | avg_ms | recall@10 |
|--------------|--------|--------|-----------|
| default      |      1 |   1.42 |   0.4180 |
| rec @ 0.90   |      7 |   4.12 |   0.8950 |
| rec @ 0.95   |     10 |   5.51 |   0.9490 |
| rec @ 0.99   |     15 |   7.43 |   0.9870 |

**观察**：这一档戏剧性差异。默认 `probes=1` 只访问 100 个 cell 中的 1 个——recall@10 直接掉到 **42%**。推荐 `probes=7`（对应 `target_recall=0.90`）把 recall 推到 **89%**，延迟约 3 倍。rec@0.99 达到 **98.7%**。

## 实践意义

- **IVFFlat 的默认值在生产 recall 维度几乎是坏的**。任何低于 `probes ≈ sqrt(lists)` 的设置都是无声地用 recall 换速度，且没有提示。v0.2 的辅助函数把这个权衡显式化了。
- **HNSW 的默认值算是个还行的起点**，但推荐值仍能在延迟代价很小的情况下多换 ~10 个 recall 点。
- `target_recall` 这个旋钮给运维一个**单一数字**，不用每个索引都手动调 probe count。

## 生产用法

```sql
-- 一次性查询，把 recommended 列读出来再 SET GUC
SELECT * FROM hnsw_recommend_ef_search('my_idx'::regclass, 10, 0.95);
-- ef_search_min | ef_search_recommended | ef_search_max
--             64 |                     64 |          256

SET hnsw.ef_search = 64;   -- 或者让应用按自己的策略挑一个档位

-- 或者：把推荐值读回应用层，
-- 在 k-NN 查询前 SET 到当前连接上
```

## 报告局限

- 数据形状单一（均匀随机）。真实生产数据（聚簇、内禀维度低）的延迟 / recall 曲线通常更平滑。
- 每个设置 50 个 query——毫秒级数字的置信区间偏宽。
- 没有建模冷缓存。重复跑会越来越快，第一次跑才是参考。

## 相关文档

- `doc/opentenbase_graph_zh.md` §6 — `weighted_shortest_path`（Dijkstra）API
- `doc/opentenbase_graph_v1.2_benchmark_zh.md` — graph v1.2 延迟扫描
- `contrib/pgvector/benchmarks/recommend_compare.sql` — 报告对应的源脚本
