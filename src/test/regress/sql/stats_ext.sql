-- Generic extended statistics support

-- We will be checking execution plans without/with statistics, so
-- let's make sure we get simple non-parallel plans. Also set the
-- work_mem low so that we can use small amounts of data.

-- check the number of estimated/actual rows in the top node
create function check_estimated_rows(text) returns table (estimated int, actual int)
language plpgsql as
$$
declare
    ln text;
    tmp text[];
    first_row bool := true;
begin
    for ln in
        execute format('explain analyze %s', $1)
    loop
        if first_row then
            first_row := false;
            tmp := regexp_match(ln, 'rows=(\d*) .* rows=(\d*)');
            return query select tmp[1]::int, tmp[2]::int;
        end if;
    end loop;
end;
$$;

-- Verify failures
CREATE STATISTICS tst;
CREATE STATISTICS tst ON a, b;
CREATE STATISTICS tst FROM sometab;
CREATE STATISTICS tst ON a, b FROM nonexistent;
CREATE STATISTICS tst ON a, b FROM pg_class;
CREATE STATISTICS tst ON relname, relname, relnatts FROM pg_class;
CREATE STATISTICS tst ON relnatts + relpages FROM pg_class;
CREATE STATISTICS tst ON (relpages, reltuples) FROM pg_class;
CREATE STATISTICS tst (unrecognized) ON relname, relnatts FROM pg_class;

-- Ensure stats are dropped sanely, and test IF NOT EXISTS while at it
CREATE TABLE ab1 (a INTEGER, b INTEGER, c INTEGER);
CREATE STATISTICS IF NOT EXISTS ab1_a_b_stats ON a, b FROM ab1;
CREATE STATISTICS IF NOT EXISTS ab1_a_b_stats ON a, b FROM ab1;
DROP STATISTICS ab1_a_b_stats;

CREATE SCHEMA regress_schema_2;
CREATE STATISTICS regress_schema_2.ab1_a_b_stats ON a, b FROM ab1;

-- Let's also verify the pg_get_statisticsobjdef output looks sane.
SELECT pg_get_statisticsobjdef(oid) FROM pg_statistic_ext WHERE stxname = 'ab1_a_b_stats';

DROP STATISTICS regress_schema_2.ab1_a_b_stats;

-- Ensure statistics are dropped when columns are
CREATE STATISTICS ab1_b_c_stats ON b, c FROM ab1;
CREATE STATISTICS ab1_a_b_c_stats ON a, b, c FROM ab1;
CREATE STATISTICS ab1_b_a_stats ON b, a FROM ab1;
ALTER TABLE ab1 DROP COLUMN a;
\d ab1
-- Ensure statistics are dropped when table is
SELECT stxname FROM pg_statistic_ext WHERE stxname LIKE 'ab1%';
DROP TABLE ab1;
SELECT stxname FROM pg_statistic_ext WHERE stxname LIKE 'ab1%';

-- Ensure things work sanely with SET STATISTICS 0
CREATE TABLE ab1 (a INTEGER, b INTEGER);
ALTER TABLE ab1 ALTER a SET STATISTICS 0;
INSERT INTO ab1 SELECT a, a%23 FROM generate_series(1, 1000) a;
CREATE STATISTICS ab1_a_b_stats ON a, b FROM ab1;
ANALYZE ab1;
ALTER TABLE ab1 ALTER a SET STATISTICS -1;
-- partial analyze doesn't build stats either
ANALYZE ab1 (a);
ANALYZE ab1;
DROP TABLE ab1;

-- Verify supported object types for extended statistics
CREATE schema tststats;

CREATE TABLE tststats.t (a int, b int, c text);
CREATE INDEX ti ON tststats.t (a, b);
CREATE SEQUENCE tststats.s;
CREATE VIEW tststats.v AS SELECT * FROM tststats.t;
CREATE MATERIALIZED VIEW tststats.mv AS SELECT * FROM tststats.t;
CREATE TYPE tststats.ty AS (a int, b int, c text);
CREATE FOREIGN DATA WRAPPER extstats_dummy_fdw;
CREATE SERVER extstats_dummy_srv FOREIGN DATA WRAPPER extstats_dummy_fdw;
CREATE FOREIGN TABLE tststats.f (a int, b int, c text) SERVER extstats_dummy_srv;
CREATE TABLE tststats.pt (a int, b int, c text) PARTITION BY RANGE (a, b);
CREATE TABLE tststats.pt1 PARTITION OF tststats.pt FOR VALUES FROM (-10, -10) TO (10, 10);

CREATE STATISTICS tststats.s1 ON a, b FROM tststats.t;
CREATE STATISTICS tststats.s2 ON a, b FROM tststats.ti;
CREATE STATISTICS tststats.s3 ON a, b FROM tststats.s;
CREATE STATISTICS tststats.s4 ON a, b FROM tststats.v;
CREATE STATISTICS tststats.s5 ON a, b FROM tststats.mv;
CREATE STATISTICS tststats.s6 ON a, b FROM tststats.ty;
CREATE STATISTICS tststats.s7 ON a, b FROM tststats.f;
CREATE STATISTICS tststats.s8 ON a, b FROM tststats.pt;
CREATE STATISTICS tststats.s9 ON a, b FROM tststats.pt1;
DO $$
DECLARE
	relname text := reltoastrelid::regclass FROM pg_class WHERE oid = 'tststats.t'::regclass;
BEGIN
	EXECUTE 'CREATE STATISTICS tststats.s10 ON a, b FROM ' || relname;
EXCEPTION WHEN wrong_object_type THEN
	RAISE NOTICE 'stats on toast table not created';
END;
$$;

DROP SCHEMA tststats CASCADE;
DROP FOREIGN DATA WRAPPER extstats_dummy_fdw CASCADE;

-- n-distinct tests
CREATE TABLE ndistinct (
    filler1 TEXT,
    filler2 NUMERIC,
    a INT,
    b INT,
    filler3 DATE,
    c INT,
    d INT
);

-- over-estimates when using only per-column statistics
INSERT INTO ndistinct (a, b, c, filler1)
     SELECT i/100, i/100, i/100, cash_words((i/100)::money)
       FROM generate_series(1,1000) s(i);

ANALYZE ndistinct;

-- Group Aggregate, due to over-estimate of the number of groups
SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY b, c');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b, c');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b, c, d');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY b, c, d');

-- correct command
CREATE STATISTICS s10 ON a, b, c FROM ndistinct;

ANALYZE ndistinct;

SELECT s.stxkind, d.stxdndistinct
  FROM pg_statistic_ext s, pg_statistic_ext_data d
 WHERE s.stxrelid = 'ndistinct'::regclass
   AND d.stxoid = s.oid;

-- Hash Aggregate, thanks to estimates improved by the statistic
SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY b, c');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b, c');

-- last two plans keep using Group Aggregate, because 'd' is not covered
-- by the statistic and while it's NULL-only we assume 200 values for it
SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b, c, d');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY b, c, d');

TRUNCATE TABLE ndistinct;

-- under-estimates when using only per-column statistics
INSERT INTO ndistinct (a, b, c, filler1)
     SELECT mod(i,50), mod(i,51), mod(i,32),
            cash_words(mod(i,33)::int::money)
       FROM generate_series(1,5000) s(i);

ANALYZE ndistinct;

SELECT s.stxkind, d.stxdndistinct
  FROM pg_statistic_ext s, pg_statistic_ext_data d
 WHERE s.stxrelid = 'ndistinct'::regclass
   AND d.stxoid = s.oid;

-- correct esimates
SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b, c');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b, c, d');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY b, c, d');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, d');

DROP STATISTICS s10;

SELECT s.stxkind, d.stxdndistinct
  FROM pg_statistic_ext s, pg_statistic_ext_data d
 WHERE s.stxrelid = 'ndistinct'::regclass
   AND d.stxoid = s.oid;

-- dropping the statistics results in under-estimates
SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b, c');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, b, c, d');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY b, c, d');

SELECT * FROM check_estimated_rows('SELECT COUNT(*) FROM ndistinct GROUP BY a, d');

-- functional dependencies tests
CREATE TABLE functional_dependencies (
    filler1 TEXT,
    filler2 NUMERIC,
    a INT,
    b TEXT,
    filler3 DATE,
    c INT,
    d TEXT
);

CREATE INDEX fdeps_ab_idx ON functional_dependencies (a, b);
CREATE INDEX fdeps_abc_idx ON functional_dependencies (a, b, c);

-- random data (no functional dependencies)
INSERT INTO functional_dependencies (a, b, c, filler1)
     SELECT mod(i, 23), mod(i, 29), mod(i, 31), i FROM generate_series(1,5000) s(i);

ANALYZE functional_dependencies;

SELECT * FROM check_estimated_rows('SELECT * FROM functional_dependencies WHERE a = 1 AND b = ''1''');

SELECT * FROM check_estimated_rows('SELECT * FROM functional_dependencies WHERE a = 1 AND b = ''1'' AND c = 1');

-- create statistics
CREATE STATISTICS func_deps_stat (dependencies) ON a, b, c FROM functional_dependencies;

ANALYZE functional_dependencies;

SELECT * FROM check_estimated_rows('SELECT * FROM functional_dependencies WHERE a = 1 AND b = ''1''');

SELECT * FROM check_estimated_rows('SELECT * FROM functional_dependencies WHERE a = 1 AND b = ''1'' AND c = 1');

-- a => b, a => c, b => c
TRUNCATE functional_dependencies;
DROP STATISTICS func_deps_stat;

INSERT INTO functional_dependencies (a, b, c, filler1)
     SELECT mod(i,100), mod(i,50), mod(i,25), i FROM generate_series(1,5000) s(i);

ANALYZE functional_dependencies;

SELECT * FROM check_estimated_rows('SELECT * FROM functional_dependencies WHERE a = 1 AND b = ''1''');

SELECT * FROM check_estimated_rows('SELECT * FROM functional_dependencies WHERE a = 1 AND b = ''1'' AND c = 1');

-- create statistics
CREATE STATISTICS func_deps_stat (dependencies) ON a, b, c FROM functional_dependencies;

ANALYZE functional_dependencies;

SELECT * FROM check_estimated_rows('SELECT * FROM functional_dependencies WHERE a = 1 AND b = ''1''');

SELECT * FROM check_estimated_rows('SELECT * FROM functional_dependencies WHERE a = 1 AND b = ''1'' AND c = 1');

-- check change of column type doesn't break it
ALTER TABLE functional_dependencies ALTER COLUMN c TYPE numeric;

SELECT * FROM check_estimated_rows('SELECT * FROM functional_dependencies WHERE a = 1 AND b = ''1'' AND c = 1');

ANALYZE functional_dependencies;

SELECT * FROM check_estimated_rows('SELECT * FROM functional_dependencies WHERE a = 1 AND b = ''1'' AND c = 1');

-- MCV lists
CREATE TABLE mcv_lists (
    filler1 TEXT,
    filler2 NUMERIC,
    a INT,
    b VARCHAR,
    filler3 DATE,
    c INT,
    d TEXT
);

-- random data (no MCV list)
INSERT INTO mcv_lists (a, b, c, filler1)
     SELECT mod(i,37), mod(i,41), mod(i,43), mod(i,47) FROM generate_series(1,5000) s(i);

ANALYZE mcv_lists;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a = 1 AND b = ''1''');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a = 1 AND b = ''1'' AND c = 1');

-- create statistics
CREATE STATISTICS mcv_lists_stats (mcv) ON a, b, c FROM mcv_lists;

ANALYZE mcv_lists;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a = 1 AND b = ''1''');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a = 1 AND b = ''1'' AND c = 1');

-- 100 distinct combinations, all in the MCV list
TRUNCATE mcv_lists;
DROP STATISTICS mcv_lists_stats;

INSERT INTO mcv_lists (a, b, c, filler1)
     SELECT mod(i,100), mod(i,50), mod(i,25), i FROM generate_series(1,5000) s(i);

ANALYZE mcv_lists;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a = 1 AND b = ''1''');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a < 1 AND b < ''1''');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a <= 0 AND b <= ''0''');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a = 1 AND b = ''1'' AND c = 1');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a < 5 AND b < ''1'' AND c < 5');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a <= 4 AND b <= ''0'' AND c <= 4');

-- create statistics
CREATE STATISTICS mcv_lists_stats (mcv) ON a, b, c FROM mcv_lists;

ANALYZE mcv_lists;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a = 1 AND b = ''1''');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a < 1 AND b < ''1''');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a <= 0 AND b <= ''0''');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a = 1 AND b = ''1'' AND c = 1');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a < 5 AND b < ''1'' AND c < 5');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a <= 4 AND b <= ''0'' AND c <= 4');

-- check change of unrelated column type does not reset the MCV statistics
ALTER TABLE mcv_lists ALTER COLUMN d TYPE VARCHAR(64);

SELECT d.stxdmcv IS NOT NULL
  FROM pg_statistic_ext s, pg_statistic_ext_data d
 WHERE s.stxname = 'mcv_lists_stats'
   AND d.stxoid = s.oid;

-- check change of column type resets the MCV statistics
ALTER TABLE mcv_lists ALTER COLUMN c TYPE numeric;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a = 1 AND b = ''1''');

ANALYZE mcv_lists;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a = 1 AND b = ''1''');

-- 100 distinct combinations with NULL values, all in the MCV list
TRUNCATE mcv_lists;
DROP STATISTICS mcv_lists_stats;

INSERT INTO mcv_lists (a, b, c, filler1)
     SELECT
         (CASE WHEN mod(i,100) = 1 THEN NULL ELSE mod(i,100) END),
         (CASE WHEN mod(i,50) = 1  THEN NULL ELSE mod(i,50) END),
         (CASE WHEN mod(i,25) = 1  THEN NULL ELSE mod(i,25) END),
         i
     FROM generate_series(1,5000) s(i);

ANALYZE mcv_lists;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a IS NULL AND b IS NULL');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a IS NULL AND b IS NULL AND c IS NULL');

-- create statistics
CREATE STATISTICS mcv_lists_stats (mcv) ON a, b, c FROM mcv_lists;

ANALYZE mcv_lists;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a IS NULL AND b IS NULL');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE a IS NULL AND b IS NULL AND c IS NULL');

-- test pg_mcv_list_items with a very simple (single item) MCV list
TRUNCATE mcv_lists;
INSERT INTO mcv_lists (a, b, c) SELECT 1, 2, 3 FROM generate_series(1,1000) s(i);
ANALYZE mcv_lists;

SELECT m.*
  FROM pg_statistic_ext s, pg_statistic_ext_data d,
       pg_mcv_list_items(d.stxdmcv) m
 WHERE s.stxname = 'mcv_lists_stats'
   AND d.stxoid = s.oid;

-- 2 distinct combinations with NULL values, all in the MCV list
TRUNCATE mcv_lists;
DROP STATISTICS mcv_lists_stats;

INSERT INTO mcv_lists (a, b, c, d)
     SELECT
         (CASE WHEN mod(i,2) = 0 THEN NULL ELSE 0 END),
         (CASE WHEN mod(i,2) = 0 THEN NULL ELSE 'x' END),
         (CASE WHEN mod(i,2) = 0 THEN NULL ELSE 0 END),
         (CASE WHEN mod(i,2) = 0 THEN NULL ELSE 'x' END)
     FROM generate_series(1,5000) s(i);

ANALYZE mcv_lists;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE b = ''x'' OR d = ''x''');

-- create statistics
CREATE STATISTICS mcv_lists_stats (mcv) ON b, d FROM mcv_lists;

ANALYZE mcv_lists;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists WHERE b = ''x'' OR d = ''x''');

-- mcv with arrays
CREATE TABLE mcv_lists_arrays (
    a TEXT[],
    b NUMERIC[],
    c INT[]
);

INSERT INTO mcv_lists_arrays (a, b, c)
     SELECT
         ARRAY[md5((i/100)::text), md5((i/100-1)::text), md5((i/100+1)::text)],
         ARRAY[(i/100-1)::numeric/1000, (i/100)::numeric/1000, (i/100+1)::numeric/1000],
         ARRAY[(i/100-1), i/100, (i/100+1)]
     FROM generate_series(1,5000) s(i);

CREATE STATISTICS mcv_lists_arrays_stats (mcv) ON a, b, c
  FROM mcv_lists_arrays;

ANALYZE mcv_lists_arrays;

-- mcv with bool
CREATE TABLE mcv_lists_bool (
    a BOOL,
    b BOOL,
    c BOOL
);

INSERT INTO mcv_lists_bool (a, b, c)
     SELECT
         (mod(i,2) = 0), (mod(i,4) = 0), (mod(i,8) = 0)
     FROM generate_series(1,10000) s(i);

ANALYZE mcv_lists_bool;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists_bool WHERE a AND b AND c');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists_bool WHERE NOT a AND b AND c');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists_bool WHERE NOT a AND NOT b AND c');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists_bool WHERE NOT a AND b AND NOT c');

CREATE STATISTICS mcv_lists_bool_stats (mcv) ON a, b, c
  FROM mcv_lists_bool;

ANALYZE mcv_lists_bool;

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists_bool WHERE a AND b AND c');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists_bool WHERE NOT a AND b AND c');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists_bool WHERE NOT a AND NOT b AND c');

SELECT * FROM check_estimated_rows('SELECT * FROM mcv_lists_bool WHERE NOT a AND b AND NOT c');

-- Permission tests. Users should not be able to see specific data values in
-- the extended statistics, if they lack permission to see those values in
-- the underlying table.
--
-- Currently this is only relevant for MCV stats.
CREATE TABLE priv_test_tbl (
    a int,
    b int
);

INSERT INTO priv_test_tbl
     SELECT mod(i,5), mod(i,10) FROM generate_series(1,100) s(i);

CREATE STATISTICS priv_test_stats (mcv) ON a, b
  FROM priv_test_tbl;

ANALYZE priv_test_tbl;

-- User with no access
CREATE USER regress_stats_user1;
SET SESSION AUTHORIZATION regress_stats_user1;
SELECT * FROM priv_test_tbl; -- Permission denied

-- Attempt to gain access using a leaky operator
CREATE FUNCTION op_leak(int, int) RETURNS bool
    AS 'BEGIN RAISE NOTICE ''op_leak => %, %'', $1, $2; RETURN $1 < $2; END'
    LANGUAGE plpgsql;
CREATE OPERATOR <<< (procedure = op_leak, leftarg = int, rightarg = int,
                     restrict = scalarltsel);
SELECT * FROM priv_test_tbl WHERE a <<< 0 AND b <<< 0; -- Permission denied
DELETE FROM priv_test_tbl WHERE a <<< 0 AND b <<< 0; -- Permission denied

-- Grant access via a security barrier view, but hide all data
RESET SESSION AUTHORIZATION;
CREATE VIEW priv_test_view WITH (security_barrier=true)
    AS SELECT * FROM priv_test_tbl WHERE false;
GRANT SELECT, DELETE ON priv_test_view TO regress_stats_user1;

-- Should now have access via the view, but see nothing and leak nothing
SET SESSION AUTHORIZATION regress_stats_user1;
SELECT * FROM priv_test_view WHERE a <<< 0 AND b <<< 0; -- Should not leak
DELETE FROM priv_test_view WHERE a <<< 0 AND b <<< 0; -- Should not leak

-- Grant table access, but hide all data with RLS
RESET SESSION AUTHORIZATION;
ALTER TABLE priv_test_tbl ENABLE ROW LEVEL SECURITY;
GRANT SELECT, DELETE ON priv_test_tbl TO regress_stats_user1;

-- Should now have direct table access, but see nothing and leak nothing
SET SESSION AUTHORIZATION regress_stats_user1;
SELECT * FROM priv_test_tbl WHERE a <<< 0 AND b <<< 0; -- Should not leak
DELETE FROM priv_test_tbl WHERE a <<< 0 AND b <<< 0; -- Should not leak

-- Tidy up
DROP OPERATOR <<< (int, int);
DROP FUNCTION op_leak(int, int);
RESET SESSION AUTHORIZATION;
DROP VIEW priv_test_view;
DROP TABLE priv_test_tbl;
DROP USER regress_stats_user1;
