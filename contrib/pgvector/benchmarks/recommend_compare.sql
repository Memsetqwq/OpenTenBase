-- ============================================================================
-- pgvector v0.3 benchmark: hnsw_recommend_ef_search / ivfflat_recommend_probes
--
-- Goal: quantify the latency / recall tradeoff between:
--   (a) the *default* runtime parameter (hnsw.ef_search=40, ivfflat.probes=1)
--   (b) values produced by the v0.2 *_recommend_* helpers at target_recall
--       = 0.90 / 0.95 / 0.99.
--
-- Run on PostgreSQL 18 + pgvector v0.8.6.  All timings are wall-clock seconds
-- captured by EXPLAIN (ANALYZE, BUFFERS) and averaged over N_QUERIES.
--
-- This script is interactive (not part of installcheck).  Adjust ROW_SCALE
-- below if you want a heavier run; ROW_SCALE=10000 takes ~30s on a VM.
-- ============================================================================

\set ROW_SCALE 10000
\set N_QUERIES 50
\set K 10

-- ----------------------------------------------------------------------------
-- 1. dataset + indexes (idempotent)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bench_vec CASCADE;
CREATE TABLE bench_vec (id bigserial PRIMARY KEY, v vector(128));

-- generate ROW_SCALE random 128-dim unit-ish vectors
INSERT INTO bench_vec(v)
SELECT ('[' || array_to_string(
    ARRAY(
        SELECT (random() * 2 - 1)::float8
        FROM generate_series(1, 128)
    ),
    ','
) || ']')::vector
FROM generate_series(1, :ROW_SCALE);

-- ground-truth nearest neighbors (sequential scan) into a side table for recall
DROP TABLE IF EXISTS bench_truth CASCADE;
CREATE TABLE bench_truth AS
SELECT
    q.id AS qid,
    array_agg(t.id ORDER BY q.v <-> t.v) AS truth_ids
FROM (SELECT id, v FROM bench_vec ORDER BY random() LIMIT :N_QUERIES) q
JOIN bench_vec t ON t.id <> q.id
GROUP BY q.id;

CREATE INDEX bench_vec_hnsw_idx ON bench_vec USING hnsw (v vector_l2_ops);
CREATE INDEX bench_vec_ivf_idx  ON bench_vec USING ivfflat (v vector_l2_ops) WITH (lists = 100);

-- refresh planner stats
ANALYZE bench_vec;

-- ----------------------------------------------------------------------------
-- 2. recommended parameter values for each target_recall
-- ----------------------------------------------------------------------------
SELECT 'hnsw recommended' AS series, *
FROM hnsw_recommend_ef_search('bench_vec_hnsw_idx'::regclass, :K, 0.90)
UNION ALL
SELECT 'hnsw recommended', *
FROM hnsw_recommend_ef_search('bench_vec_hnsw_idx'::regclass, :K, 0.95)
UNION ALL
SELECT 'hnsw recommended', *
FROM hnsw_recommend_ef_search('bench_vec_hnsw_idx'::regclass, :K, 0.99);

SELECT 'ivfflat recommended' AS series, *
FROM ivfflat_recommend_probes('bench_vec_ivf_idx'::regclass, 0.90)
UNION ALL
SELECT 'ivfflat recommended', *
FROM ivfflat_recommend_probes('bench_vec_ivf_idx'::regclass, 0.95)
UNION ALL
SELECT 'ivfflat recommended', *
FROM ivfflat_recommend_probes('bench_vec_ivf_idx'::regclass, 0.99);

-- ----------------------------------------------------------------------------
-- 3. latency / recall sweep
--    For each setting we run :N_QUERIES random k-NN queries and measure
--    average ms + recall@K against bench_truth.
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bench_results CASCADE;
CREATE TABLE bench_results (
    series      text,
    setting     text,
    param_value int,
    avg_ms      double precision,
    recall_at_k double precision
);

-- helper plpgsql function: runs N_QUERIES and aggregates latency + recall
CREATE OR REPLACE FUNCTION bench_run_hnsw(p_ef int)
RETURNS TABLE(avg_ms double precision, recall_at_k double precision)
LANGUAGE plpgsql AS $$
DECLARE
    q record;
    t0 double precision;
    elapsed double precision := 0;
    hits int := 0;
    total int := 0;
    pred_ids bigint[];
BEGIN
    SET LOCAL hnsw.ef_search = p_ef;
    FOR q IN
        SELECT id, v FROM bench_vec ORDER BY random() LIMIT 50
    LOOP
        t0 := clock_timestamp();
        SELECT array_agg(t.id ORDER BY q.v <-> t.v)
          INTO pred_ids
          FROM bench_vec t
          WHERE t.id <> q.id
          ORDER BY q.v <-> t.v
          LIMIT 10;
        elapsed := elapsed + extract(epoch FROM (clock_timestamp() - t0)) * 1000;

        SELECT
            count(*)::int,
            (SELECT count(*)::int FROM unnest(pred_ids) p
              JOIN unnest((SELECT truth_ids FROM bench_truth WHERE qid = q.id)) tt
                ON p = tt)
          INTO total, hits
          FROM unnest(pred_ids);
    END LOOP;
    avg_ms := elapsed / 50.0;
    recall_at_k := hits::float8 / (total::float8);
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION bench_run_ivf(p_probes int)
RETURNS TABLE(avg_ms double precision, recall_at_k double precision)
LANGUAGE plpgsql AS $$
DECLARE
    q record;
    t0 double precision;
    elapsed double precision := 0;
    hits int := 0;
    total int := 0;
    pred_ids bigint[];
BEGIN
    SET LOCAL ivfflat.probes = p_probes;
    FOR q IN
        SELECT id, v FROM bench_vec ORDER BY random() LIMIT 50
    LOOP
        t0 := clock_timestamp();
        SELECT array_agg(t.id ORDER BY q.v <-> t.v)
          INTO pred_ids
          FROM bench_vec t
          WHERE t.id <> q.id
          ORDER BY q.v <-> t.v
          LIMIT 10;
        elapsed := elapsed + extract(epoch FROM (clock_timestamp() - t0)) * 1000;

        SELECT
            count(*)::int,
            (SELECT count(*)::int FROM unnest(pred_ids) p
              JOIN unnest((SELECT truth_ids FROM bench_truth WHERE qid = q.id)) tt
                ON p = tt)
          INTO total, hits
          FROM unnest(pred_ids);
    END LOOP;
    avg_ms := elapsed / 50.0;
    recall_at_k := hits::float8 / (total::float8);
    RETURN NEXT;
END;
$$;

-- HNSW sweep: default (40) vs three recommended tiers
INSERT INTO bench_results
SELECT 'hnsw', 'default',  40,  r.avg_ms, r.recall_at_k FROM bench_run_hnsw(40)  r
UNION ALL
SELECT 'hnsw', 'rec@0.90', rec, r.avg_ms, r.recall_at_k FROM hnsw_recommend_ef_search('bench_vec_hnsw_idx'::regclass, 10, 0.90), LATERAL (SELECT * FROM bench_run_hnsw(rec)) r
UNION ALL
SELECT 'hnsw', 'rec@0.95', rec, r.avg_ms, r.recall_at_k FROM hnsw_recommend_ef_search('bench_vec_hnsw_idx'::regclass, 10, 0.95), LATERAL (SELECT * FROM bench_run_hnsw(rec)) r
UNION ALL
SELECT 'hnsw', 'rec@0.99', rec, r.avg_ms, r.recall_at_k FROM hnsw_recommend_ef_search('bench_vec_hnsw_idx'::regclass, 10, 0.99), LATERAL (SELECT * FROM bench_run_hnsw(rec)) r;

-- IVFFlat sweep: default (1) vs three recommended tiers
INSERT INTO bench_results
SELECT 'ivfflat', 'default',  1,   r.avg_ms, r.recall_at_k FROM bench_run_ivf(1)  r
UNION ALL
SELECT 'ivfflat', 'rec@0.90', rec, r.avg_ms, r.recall_at_k FROM ivfflat_recommend_probes('bench_vec_ivf_idx'::regclass, 0.90), LATERAL (SELECT * FROM bench_run_ivf(rec)) r
UNION ALL
SELECT 'ivfflat', 'rec@0.95', rec, r.avg_ms, r.recall_at_k FROM ivfflat_recommend_probes('bench_vec_ivf_idx'::regclass, 0.95), LATERAL (SELECT * FROM bench_run_ivf(rec)) r
UNION ALL
SELECT 'ivfflat', 'rec@0.99', rec, r.avg_ms, r.recall_at_k FROM ivfflat_recommend_probes('bench_vec_ivf_idx'::regclass, 0.99), LATERAL (SELECT * FROM bench_run_ivf(rec)) r;

-- ----------------------------------------------------------------------------
-- 4. final summary
-- ----------------------------------------------------------------------------
SELECT series, setting, param_value, round(avg_ms::numeric, 2) AS avg_ms,
       round(recall_at_k::numeric, 4) AS recall_at_10
FROM bench_results
ORDER BY series, param_value;

DROP TABLE bench_results;
DROP TABLE bench_truth;
DROP TABLE bench_vec;
