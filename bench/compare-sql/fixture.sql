-- The rows every candidate reads and writes.
--
-- Its own tables rather than `nilo_bench_people`, for two reasons.
-- `bench/sql.zig` drops and rebuilds that one every run, so sharing it would
-- mean a number here silently depending on which benchmark ran last. And
-- `created_at` has to be deterministic: `now()` at insert makes the expected
-- JSON body different on every fixture rebuild, and the checksum rule is the
-- whole reason a candidate cannot quietly skip work.
--
-- Four tables, because the shapes ask different questions:
--
--   nilo_compare_people   read fixture, 4 columns, 1000 rows. Never written.
--   nilo_compare_wide     read fixture, 20 columns, 1000 rows. The one that
--                         separates a mapper costing per column from one that
--                         resolved its columns while compiling.
--   nilo_compare_writes   insert target. Truncated by each candidate before
--                         every timed block, outside the timer.
--   nilo_compare_updates  update target, seeded with 1000 rows. Updates
--                         overwrite in place, so it never needs reseeding and
--                         the insert path never disturbs it.

DROP TABLE IF EXISTS nilo_compare_people;
DROP TABLE IF EXISTS nilo_compare_wide;
DROP TABLE IF EXISTS nilo_compare_writes;
DROP TABLE IF EXISTS nilo_compare_updates;
DROP TABLE IF EXISTS nilo_compare_deletes;

-- ---------------------------------------------------------------- narrow read

CREATE TABLE nilo_compare_people (
    id         bigint PRIMARY KEY,
    email      text NOT NULL,
    age        integer NOT NULL,
    created_at timestamptz NOT NULL
);

INSERT INTO nilo_compare_people (id, email, age, created_at)
SELECT g,
       'p' || g || '@example.dev',
       20 + (g % 50),
       timestamptz '2026-01-01 00:00:00Z' + ((g - 1) * interval '1 second')
FROM generate_series(1, 1000) g;

-- ------------------------------------------------------------------ wide read
--
-- Twenty columns: seven text, seven integer, four timestamptz, two boolean.
-- No floating point on purpose — the checksum has to be bit-identical across
-- four languages, and a double that four runtimes agree about is a different
-- benchmark from this one.
--
-- Twenty rather than the thirty-two some ORMs cap at: the point is to show the
-- slope, and a width that one candidate cannot express would end the
-- comparison instead of measuring it.

CREATE TABLE nilo_compare_wide (
    id   bigint PRIMARY KEY,
    t1 text NOT NULL, t2 text NOT NULL, t3 text NOT NULL, t4 text NOT NULL,
    t5 text NOT NULL, t6 text NOT NULL, t7 text NOT NULL,
    n1 integer NOT NULL, n2 integer NOT NULL, n3 integer NOT NULL,
    n4 integer NOT NULL, n5 integer NOT NULL, n6 bigint NOT NULL,
    d1 timestamptz NOT NULL, d2 timestamptz NOT NULL,
    d3 timestamptz NOT NULL, d4 timestamptz NOT NULL,
    b1 boolean NOT NULL, b2 boolean NOT NULL
);

INSERT INTO nilo_compare_wide
SELECT g,
       'alpha' || g, 'bravo' || g, 'charlie' || g, 'delta' || g,
       'echo' || g, 'foxtrot' || g, 'golf' || g,
       g % 97, g % 89, g % 83, g % 79, g % 73, g * 1000,
       timestamptz '2026-01-01 00:00:00Z' + ((g - 1) * interval '1 second'),
       timestamptz '2026-02-01 00:00:00Z' + ((g - 1) * interval '2 seconds'),
       timestamptz '2026-03-01 00:00:00Z' + ((g - 1) * interval '3 seconds'),
       timestamptz '2026-04-01 00:00:00Z' + ((g - 1) * interval '4 seconds'),
       (g % 2 = 0), (g % 3 = 0)
FROM generate_series(1, 1000) g;

-- --------------------------------------------------------------- write target

CREATE TABLE nilo_compare_writes (
    id         bigint PRIMARY KEY,
    email      text NOT NULL,
    age        integer NOT NULL,
    created_at timestamptz NOT NULL
);

-- -------------------------------------------------------------- update target

CREATE TABLE nilo_compare_updates (
    id         bigint PRIMARY KEY,
    email      text NOT NULL,
    age        integer NOT NULL,
    created_at timestamptz NOT NULL
);

INSERT INTO nilo_compare_updates (id, email, age, created_at)
SELECT g,
       'u' || g || '@example.dev',
       20 + (g % 50),
       timestamptz '2026-01-01 00:00:00Z' + ((g - 1) * interval '1 second')
FROM generate_series(1, 1000) g;

-- -------------------------------------------------------------- delete target
--
-- Deleting empties a table, so this one is reseeded by each candidate before
-- every timed block — outside the timer, and to exactly the row count the
-- block will remove. Sharing the insert target instead would have made the two
-- shapes measure each other.

CREATE TABLE nilo_compare_deletes (
    id         bigint PRIMARY KEY,
    email      text NOT NULL,
    age        integer NOT NULL,
    created_at timestamptz NOT NULL
);

-- ------------------------------------------------------- what the writes cost
--
-- With the default `synchronous_commit = on`, one autocommitted INSERT is
-- **660 µs** on this box and every candidate reads the same, because what is
-- being timed is an fsync of the write-ahead log and not a library. That is a
-- true number about the workload and a useless one about the comparison — it
-- says a single-connection writer is disk-bound, which is worth knowing once
-- and then getting out of the way of.
--
-- So it is turned off for this database, and only for this database, which is
-- a throwaway. What the write shapes then measure is the client and the
-- server's own work, which is the question. The fsync figure is reported
-- beside them rather than replaced by them.
--
-- Set on the database rather than per session: it then applies identically to
-- every candidate and every arm without four languages each having to spell
-- the same SET, and without depending on whether a driver forwards `options`
-- in its connection string.

ALTER DATABASE nilo SET synchronous_commit = off;

ANALYZE nilo_compare_people;
ANALYZE nilo_compare_wide;
ANALYZE nilo_compare_updates;
