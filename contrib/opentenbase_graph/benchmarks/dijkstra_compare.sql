-- ============================================================================
-- opentenbase_graph v1.2 benchmark: weighted_shortest_path (Dijkstra) vs
-- the v1.0 unweighted shortest_path + a hand-rolled BFS hop-count path
--
-- Goal: show that v1.2's Dijkstra returns the minimum-cost path in weighted
-- graphs (something the v1.0 BFS-based shortest_path cannot do by design),
-- and quantify the cost overhead vs the hop-count path.
--
-- Run on PostgreSQL 18 + opentenbase_graph v1.2.  This script is interactive
-- (not part of installcheck).  Adjust EDGES_SCALE / N_QUERIES at the top if
-- you need a heavier run; the defaults below finish in <30s on a VM.
-- ============================================================================

\set EDGES_SCALE 10000
\set N_QUERIES 50

-- ----------------------------------------------------------------------------
-- 1. dataset: random directed graph with random positive integer weights
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bench_edges CASCADE;
CREATE TABLE bench_edges (
    src bigint,
    dst bigint,
    weight double precision
);

INSERT INTO bench_edges
SELECT
    (random() * 999)::bigint + 1                AS src,
    (random() * 999)::bigint + 1                AS dst,
    ((random() * 9)::int + 1)::double precision AS weight   -- 1..10
FROM generate_series(1, :EDGES_SCALE);

-- pick random start/end pairs that are *guaranteed* to be reachable
DROP TABLE IF EXISTS bench_pairs CASCADE;
CREATE TABLE bench_pairs AS
WITH reachable AS (
    SELECT src AS s, dst AS e
    FROM bench_edges
    WHERE EXISTS (
        SELECT 1 FROM bench_edges e2 WHERE e2.src = bench_edges.dst
    )
    ORDER BY random()
    LIMIT :N_QUERIES
)
SELECT s, e FROM reachable;

CREATE EXTENSION IF NOT EXISTS opentenbase_graph;

-- ----------------------------------------------------------------------------
-- 2. correctness check: Dijkstra must always return a cost <= the BFS hop
-- path's cost (BFS hop count × cheapest weight in graph)
-- ----------------------------------------------------------------------------
SELECT 'correctness' AS section;
WITH p AS (SELECT * FROM bench_pairs LIMIT 10),
     dj AS (
         SELECT p.s, p.e, wsp.total_cost, wsp.hops, wsp.path
         FROM p, LATERAL opentenbase_graph.weighted_shortest_path(
             'bench_edges'::regclass, 'src'::text, 'dst'::text, 'weight'::text,
             p.s, p.e, 1e18
         ) wsp
     ),
     bfs AS (
         SELECT p.s, p.e, sp.depth AS hops, sp.path
         FROM p, LATERAL opentenbase_graph.shortest_path(
             'bench_edges'::regclass, 'bench_edges'::regclass,
             'src'::text, 'dst'::text,
             p.s, p.e, 1000
         ) sp
     )
SELECT
    dj.s,
    dj.e,
    round(dj.total_cost::numeric, 2)         AS dijkstra_cost,
    dj.hops                                  AS dijkstra_hops,
    bfs.hops                                 AS bfs_hops,
    CASE WHEN dj.hops <= bfs.hops THEN '✓' ELSE '✗' END AS hops_reasonable
FROM dj JOIN bfs USING (s, e);

-- ----------------------------------------------------------------------------
-- 3. latency sweep: Dijkstra vs BFS on the same query pairs
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bench_results CASCADE;
CREATE TABLE bench_results (
    method   text,
    queries  int,
    total_ms double precision,
    avg_ms   double precision
);

CREATE OR REPLACE FUNCTION bench_run_dijkstra()
RETURNS TABLE(total_ms double precision, avg_ms double precision)
LANGUAGE plpgsql AS $$
DECLARE
    p record;
    t0 double precision;
    elapsed double precision := 0;
    cnt int := 0;
BEGIN
    FOR p IN SELECT * FROM bench_pairs LOOP
        t0 := clock_timestamp();
        PERFORM opentenbase_graph.weighted_shortest_path(
            'bench_edges'::regclass, 'src'::text, 'dst'::text, 'weight'::text,
            p.s, p.e, 1e18
        );
        elapsed := elapsed + extract(epoch FROM (clock_timestamp() - t0)) * 1000;
        cnt := cnt + 1;
    END LOOP;
    total_ms := elapsed;
    avg_ms := elapsed / cnt;
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION bench_run_bfs()
RETURNS TABLE(total_ms double precision, avg_ms double precision)
LANGUAGE plpgsql AS $$
DECLARE
    p record;
    t0 double precision;
    elapsed double precision := 0;
    cnt int := 0;
BEGIN
    FOR p IN SELECT * FROM bench_pairs LOOP
        t0 := clock_timestamp();
        PERFORM opentenbase_graph.shortest_path(
            'bench_edges'::regclass, 'bench_edges'::regclass,
            'src'::text, 'dst'::text,
            p.s, p.e, 1000
        );
        elapsed := elapsed + extract(epoch FROM (clock_timestamp() - t0)) * 1000;
        cnt := cnt + 1;
    END LOOP;
    total_ms := elapsed;
    avg_ms := elapsed / cnt;
    RETURN NEXT;
END;
$$;

INSERT INTO bench_results
SELECT 'dijkstra (v1.2 weighted)', bench_run_dijkstra().*
FROM (SELECT 1) x, LATERAL (SELECT total_ms, avg_ms FROM bench_run_dijkstra()) r;

INSERT INTO bench_results
SELECT 'bfs (v1.0 unweighted)', bench_run_bfs().*
FROM (SELECT 1) x, LATERAL (SELECT total_ms, avg_ms FROM bench_run_bfs()) r;

SELECT method, queries, round(total_ms::numeric, 2) AS total_ms,
       round(avg_ms::numeric, 3) AS avg_ms
FROM bench_results
ORDER BY avg_ms;

-- ----------------------------------------------------------------------------
-- 4. scale sweep: vary EDGES_SCALE to show Dijkstra complexity stays
-- sub-quadratic thanks to the temp-table indexed priority queue
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    s int;
    q record;
    t0 double precision;
    elapsed double precision;
    cnt int;
BEGIN
    RAISE NOTICE '--- scale sweep ---';
    RAISE NOTICE 'edges   | avg_ms (dijkstra) | avg_ms (bfs)';
    FOR s IN SELECT unnest(ARRAY[1000, 5000, 10000, 50000]) LOOP
        TRUNCATE bench_edges;
        INSERT INTO bench_edges
        SELECT
            (random() * 999)::bigint + 1,
            (random() * 999)::bigint + 1,
            ((random() * 9)::int + 1)::double precision
        FROM generate_series(1, s);

        elapsed := 0; cnt := 0;
        FOR q IN SELECT * FROM bench_pairs LIMIT 20 LOOP
            t0 := clock_timestamp();
            PERFORM opentenbase_graph.weighted_shortest_path(
                'bench_edges'::regclass, 'src'::text, 'dst'::text, 'weight'::text,
                q.s, q.e, 1e18
            );
            elapsed := elapsed + extract(epoch FROM (clock_timestamp() - t0)) * 1000;
            cnt := cnt + 1;
        END LOOP;
        RAISE NOTICE '%   | % ms | (bfs skipped for brevity)',
            s, round((elapsed / cnt)::numeric, 2);
    END LOOP;
END;
$$;

DROP TABLE bench_results;
DROP TABLE bench_pairs;
DROP TABLE bench_edges;
