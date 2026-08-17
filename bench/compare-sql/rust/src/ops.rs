//! diesel-async and SQLx against the tokio-postgres underneath them.
//!
//! The same shape as `zigsql/src/ops.zig` and `go/ops.go`: every arm lives in
//! one process and the blocks interleave, so drift lands on both halves of a
//! pair and cancels in the subtraction. That file's header has the reasoning.
//!
//! Three arms rather than two, and they are not equally clean:
//!
//! - **tokio-postgres** is the control.
//! - **diesel-async** is a query builder *over* tokio-postgres, so subtracting
//!   the control leaves the mapper and nothing else. This is the number that
//!   answers "what does the ORM cost".
//! - **SQLx** brings its own driver. Its distance from the control is a driver
//!   difference plus a mapper one, and reading it as an ORM tax would be
//!   wrong. It is here because it is the library closest to what `nilo_sql`
//!   is — types as the contract, no change tracking — not because the
//!   subtraction is clean.
//!
//! A current-thread runtime on purpose: one connection, no pool, and no work
//! stealing to add scheduling noise to a 20 µs measurement.

use std::time::Instant;

use chrono::{DateTime, Utc};
use diesel::prelude::*;
use diesel_async::{AsyncConnection as _, AsyncPgConnection, RunQueryDsl};
use sqlx::Connection as _;

const TABLE: &str = "nilo_compare_people";

const KEY_SQL: &str = r#"SELECT "id", "email", "age", "created_at" FROM "nilo_compare_people" WHERE "id" = $1 LIMIT 1"#;
const PAGE_SQL: &str = r#"SELECT "id", "email", "age", "created_at" FROM "nilo_compare_people" WHERE "age" > $1 AND "email" LIKE $2 ORDER BY "created_at" DESC, "id" ASC LIMIT 20"#;
const SCAN_SQL: &str = r#"SELECT "id", "email", "age", "created_at" FROM "nilo_compare_people""#;
const EMPTY_SQL: &str = "SELECT 1";

const WIDE_COLS: &str = r#""id", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "n1", "n2", "n3", "n4", "n5", "n6", "d1", "d2", "d3", "d4", "b1", "b2""#;

const FOUR_COLS: &str = r#""id", "email", "age", "created_at""#;

const INSERT_SQL: &str = r#"INSERT INTO "nilo_compare_writes" ("id", "email", "age", "created_at") VALUES ($1, $2, $3, $4) RETURNING "id", "email", "age", "created_at""#;
/// One array per column, `unnest` on the server — the shape `insertMany`
/// compiles to. The control sends the same statement rather than a hand-rolled
/// multi-VALUES, which would be a different benchmark.
const BATCH_SQL: &str = r#"INSERT INTO "nilo_compare_writes" ("id", "email", "age", "created_at") SELECT * FROM unnest($1::bigint[], $2::text[], $3::int[], $4::timestamptz[]) RETURNING "id", "email", "age", "created_at""#;
const UPDATE_SQL: &str = r#"UPDATE "nilo_compare_updates" SET "age" = $1 WHERE "id" = $2 RETURNING "id", "email", "age", "created_at""#;
const DELETE_SQL: &str = r#"DELETE FROM "nilo_compare_deletes" WHERE "id" = $1 RETURNING "id", "email", "age", "created_at""#;
const TX_FIND_SQL: &str = r#"SELECT "id", "email", "age", "created_at" FROM "nilo_compare_people" WHERE "id" = $1 LIMIT 1"#;

/// 2026-01-01T00:00:00Z. Every candidate derives `created_at` from this, so a
/// written row's checksum does not depend on when the benchmark ran.
const EPOCH_BASE_S: i64 = 1_767_225_600;
const BATCH_ROWS: usize = 100;

const BLOCKS: usize = 300;
const WARMUP_BLOCKS: usize = 20;

#[derive(Clone, Copy)]
struct Shape {
    name: &'static str,
    rows: usize,
    columns: usize,
    rounds: usize,
    writes: bool,
}

const SHAPES: [Shape; 11] = [
    Shape { name: "empty", rows: 0, columns: 0, rounds: 200, writes: false },
    Shape { name: "key", rows: 1, columns: 4, rounds: 200, writes: false },
    Shape { name: "page", rows: 20, columns: 4, rounds: 100, writes: false },
    Shape { name: "scan", rows: 1000, columns: 4, rounds: 20, writes: false },
    // The narrow shapes vary the row count and hold the width at four; these
    // two hold the row count and vary the width, which is the axis a wide
    // entity table actually moves along.
    Shape { name: "wide", rows: 1, columns: 20, rounds: 200, writes: false },
    Shape { name: "wide_scan", rows: 1000, columns: 20, rounds: 10, writes: false },
    // Everything above this line reads. These five are the other half.
    Shape { name: "insert", rows: 1, columns: 4, rounds: 50, writes: true },
    Shape { name: "batch", rows: BATCH_ROWS, columns: 4, rounds: 10, writes: true },
    Shape { name: "update", rows: 1, columns: 4, rounds: 50, writes: true },
    Shape { name: "delete", rows: 1, columns: 4, rounds: 50, writes: true },
    // A read and a write inside BEGIN/COMMIT: four statements where the other
    // shapes send one.
    Shape { name: "tx", rows: 2, columns: 4, rounds: 50, writes: true },
];

/// The same sum every candidate has to produce.
fn tally(id: i64, email: &str, age: i32, t: DateTime<Utc>) -> i64 {
    id + age as i64 + email.len() as i64 + t.timestamp()
}

/// The values a write shape stores, derived from the row's own id so that two
/// arms writing "the same" row write the same bytes and the checksum does not
/// move between runs.
fn written_email(id: i64) -> String {
    format!("w{id}@example.dev")
}

fn written_age(id: i64) -> i32 {
    (20 + id % 50) as i32
}

fn written_time(id: i64) -> DateTime<Utc> {
    DateTime::from_timestamp(EPOCH_BASE_S + id - 1, 0).unwrap()
}

// ---------------------------------------------------------------- diesel

diesel::table! {
    nilo_compare_people (id) {
        id -> BigInt,
        email -> Text,
        age -> Integer,
        created_at -> Timestamptz,
    }
}

#[derive(Queryable, Selectable)]
#[diesel(table_name = nilo_compare_people)]
struct DieselPerson {
    id: i64,
    email: String,
    age: i32,
    created_at: DateTime<Utc>,
}

diesel::table! {
    nilo_compare_wide (id) {
        id -> BigInt,
        t1 -> Text, t2 -> Text, t3 -> Text, t4 -> Text,
        t5 -> Text, t6 -> Text, t7 -> Text,
        n1 -> Integer, n2 -> Integer, n3 -> Integer,
        n4 -> Integer, n5 -> Integer, n6 -> BigInt,
        d1 -> Timestamptz, d2 -> Timestamptz,
        d3 -> Timestamptz, d4 -> Timestamptz,
        b1 -> Bool, b2 -> Bool,
    }
}

/// Twenty columns: seven text, six integer, four timestamp, two boolean, and
/// the key. No floating point in the fixture — a checksum four runtimes have
/// to agree about bit for bit is not the place to find out how each of them
/// rounds.
///
/// Written out twice rather than generated from one list, because the two
/// derives want the fields in the struct body and a macro cannot stand there.
#[derive(Queryable, Selectable)]
#[diesel(table_name = nilo_compare_wide)]
struct DieselWide {
    id: i64,
    t1: String, t2: String, t3: String, t4: String,
    t5: String, t6: String, t7: String,
    n1: i32, n2: i32, n3: i32, n4: i32, n5: i32, n6: i64,
    d1: DateTime<Utc>, d2: DateTime<Utc>,
    d3: DateTime<Utc>, d4: DateTime<Utc>,
    b1: bool, b2: bool,
}

// Three tables with identical columns, because the write shapes must not
// disturb each other: `insert` truncates its table, `delete` empties its own,
// and `update` overwrites in place and so never needs reseeding.
diesel::table! {
    nilo_compare_writes (id) {
        id -> BigInt,
        email -> Text,
        age -> Integer,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    nilo_compare_updates (id) {
        id -> BigInt,
        email -> Text,
        age -> Integer,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    nilo_compare_deletes (id) {
        id -> BigInt,
        email -> Text,
        age -> Integer,
        created_at -> Timestamptz,
    }
}

#[derive(Insertable, Queryable, Selectable)]
#[diesel(table_name = nilo_compare_writes)]
struct DieselWritten {
    id: i64,
    email: String,
    age: i32,
    created_at: DateTime<Utc>,
}

#[derive(Queryable, Selectable)]
#[diesel(table_name = nilo_compare_updates)]
struct DieselUpdated {
    id: i64,
    email: String,
    age: i32,
    created_at: DateTime<Utc>,
}

#[derive(Queryable, Selectable)]
#[diesel(table_name = nilo_compare_deletes)]
struct DieselDeleted {
    id: i64,
    email: String,
    age: i32,
    created_at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
struct SqlxWide {
    id: i64,
    t1: String, t2: String, t3: String, t4: String,
    t5: String, t6: String, t7: String,
    n1: i32, n2: i32, n3: i32, n4: i32, n5: i32, n6: i64,
    d1: DateTime<Utc>, d2: DateTime<Utc>,
    d3: DateTime<Utc>, d4: DateTime<Utc>,
    b1: bool, b2: bool,
}

macro_rules! tally_wide {
    ($w:expr) => {
        $w.id
            + $w.n1 as i64 + $w.n2 as i64 + $w.n3 as i64
            + $w.n4 as i64 + $w.n5 as i64 + $w.n6
            + ($w.t1.len() + $w.t2.len() + $w.t3.len() + $w.t4.len()
                + $w.t5.len() + $w.t6.len() + $w.t7.len()) as i64
            + $w.d1.timestamp() + $w.d2.timestamp()
            + $w.d3.timestamp() + $w.d4.timestamp()
            + $w.b1 as i64 + $w.b2 as i64
    };
}

// ------------------------------------------------------------------ sqlx

#[derive(sqlx::FromRow)]
struct SqlxPerson {
    id: i64,
    email: String,
    age: i32,
    created_at: DateTime<Utc>,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let url = std::env::var("DATABASE_URL")?;
    let _ = TABLE;

    // --- the control -----------------------------------------------------
    let (raw, raw_conn) = tokio_postgres::connect(&url, tokio_postgres::NoTls).await?;
    tokio::spawn(async move {
        let _ = raw_conn.await;
    });
    // Prepared once, held for the run: the configuration every other arm is
    // measured in. `bench/result/sql.md` §1 puts the difference at 29% on this
    // transport, which is larger than anything a mapper costs.
    let st_empty = raw.prepare(EMPTY_SQL).await?;
    let st_key = raw.prepare(KEY_SQL).await?;
    let st_page = raw.prepare(PAGE_SQL).await?;
    let st_scan = raw.prepare(SCAN_SQL).await?;
    let st_wide_key = raw
        .prepare(&format!(
            r#"SELECT {WIDE_COLS} FROM "nilo_compare_wide" WHERE "id" = $1 LIMIT 1"#
        ))
        .await?;
    let st_wide_scan = raw
        .prepare(&format!(
            r#"SELECT {WIDE_COLS} FROM "nilo_compare_wide""#
        ))
        .await?;
    let sts = Statements {
        empty: st_empty,
        key: st_key,
        page: st_page,
        scan: st_scan,
        wide_key: st_wide_key,
        wide_scan: st_wide_scan,
        insert: raw.prepare(INSERT_SQL).await?,
        batch: raw.prepare(BATCH_SQL).await?,
        update: raw.prepare(UPDATE_SQL).await?,
        delete: raw.prepare(DELETE_SQL).await?,
        tx_find: raw.prepare(TX_FIND_SQL).await?,
    };

    // --- the ORM ---------------------------------------------------------
    let mut diesel_conn = AsyncPgConnection::establish(&url).await?;

    // --- the typed-query library ----------------------------------------
    let mut sqlx_conn = sqlx::postgres::PgConnection::connect(&url).await?;

    // Knobs for the syscall census rather than for the benchmark. Counting
    // packets per query under strace needs a run small enough to trace and a
    // warm-up of zero. Left at their defaults these change nothing.
    let n_blocks = env_usize("OPS_BLOCKS", BLOCKS);
    let n_warmup = env_usize("OPS_WARMUP", WARMUP_BLOCKS);
    let only = std::env::var("OPS_SHAPES").unwrap_or_default();

    eprintln!("rust — diesel-async and SQLx against raw tokio-postgres, {n_blocks} interleaved blocks");
    eprintln!("  warming {n_warmup} blocks a shape…");
    for s in SHAPES {
        if !wanted(&only, s.name) { continue; }
        for _ in 0..n_warmup {
            prepare_writes(&raw, s).await?;
            raw_block(&raw, &sts, s).await?;
            if s.name != "empty" {
                prepare_writes(&raw, s).await?;
                diesel_block(&mut diesel_conn, s).await?;
                prepare_writes(&raw, s).await?;
                sqlx_block(&mut sqlx_conn, s).await?;
            }
        }
    }

    let mut shapes = serde_json::Map::new();
    for s in SHAPES {
        if !wanted(&only, s.name) { continue; }
        let mut raw_ns = Vec::with_capacity(n_blocks);
        let mut di_ns = Vec::with_capacity(n_blocks);
        let mut sx_ns = Vec::with_capacity(n_blocks);
        let (mut raw_sum, mut di_sum, mut sx_sum) = (0i64, 0i64, 0i64);

        for b in 0..n_blocks {
            // Rotate which arm goes first. Whichever runs first in a group
            // pays for what the others left in the caches, and always giving
            // that position to the same arm is a bias that averages to a
            // constant rather than to zero.
            let order: [usize; 3] = match b % 3 {
                0 => [0, 1, 2],
                1 => [1, 2, 0],
                _ => [2, 0, 1],
            };
            for which in order {
                // Before **each arm's** block rather than before each triple:
                // two arms inserting the same primary keys into a table only
                // one of them emptied is a unique-violation, not a benchmark.
                prepare_writes(&raw, s).await?;
                match which {
                    0 => {
                        let (ns, sum) =
                            raw_block(&raw, &sts, s).await?;
                        raw_ns.push(ns);
                        raw_sum = sum;
                    }
                    1 if s.name != "empty" => {
                        let (ns, sum) = diesel_block(&mut diesel_conn, s).await?;
                        di_ns.push(ns);
                        di_sum = sum;
                    }
                    2 if s.name != "empty" => {
                        let (ns, sum) = sqlx_block(&mut sqlx_conn, s).await?;
                        sx_ns.push(ns);
                        sx_sum = sum;
                    }
                    _ => {}
                }
            }
        }

        let mut arms = serde_json::Map::new();
        arms.insert("tokiopg".into(), arm_json(raw_sum, &raw_ns));
        if s.name != "empty" {
            arms.insert("diesel".into(), arm_json(di_sum, &di_ns));
            arms.insert("sqlx".into(), arm_json(sx_sum, &sx_ns));
            eprintln!(
                "  {:<9} tokiopg {:>9} ns   diesel {:>9} ns   sqlx {:>9} ns",
                s.name,
                median(&raw_ns),
                median(&di_ns),
                median(&sx_ns)
            );
        } else {
            eprintln!("  {:<9} tokiopg {:>9} ns", s.name, median(&raw_ns));
        }

        shapes.insert(
            s.name.into(),
            serde_json::json!({ "rows": s.rows, "columns": s.columns, "rounds": s.rounds, "arms": arms }),
        );
    }

    let out = serde_json::json!({
        "language": "rust",
        "shapes": shapes,
        "peak_rss_kb": peak_rss_kb(),
    });
    println!("RESULT {out}");
    Ok(())
}

fn arm_json(checksum: i64, ns: &[i64]) -> serde_json::Value {
    serde_json::json!({ "checksum": checksum, "blocks": ns })
}

/// The prepared statements the control holds for the run, in one struct so the
/// block function does not take six positional arguments.
struct Statements {
    empty: tokio_postgres::Statement,
    key: tokio_postgres::Statement,
    page: tokio_postgres::Statement,
    scan: tokio_postgres::Statement,
    wide_key: tokio_postgres::Statement,
    wide_scan: tokio_postgres::Statement,
    insert: tokio_postgres::Statement,
    batch: tokio_postgres::Statement,
    update: tokio_postgres::Statement,
    delete: tokio_postgres::Statement,
    tx_find: tokio_postgres::Statement,
}

/// Put the write tables back the way a timed block expects to find them.
/// Outside the timer, and on the control's connection for all three arms — a
/// TRUNCATE autocommits, so which connection issued it is not something the
/// others can tell.
async fn prepare_writes(
    c: &tokio_postgres::Client,
    s: Shape,
) -> Result<(), Box<dyn std::error::Error>> {
    match s.name {
        "insert" | "batch" => {
            c.batch_execute(r#"TRUNCATE "nilo_compare_writes""#).await?;
        }
        "delete" => {
            c.batch_execute(r#"TRUNCATE "nilo_compare_deletes""#).await?;
            // Exactly the rows the block will remove, and no more: seeding a
            // thousand to delete fifty would put an index of a different size
            // under every measurement.
            c.execute(
                &format!(
                    r#"INSERT INTO "nilo_compare_deletes" ({FOUR_COLS})
                       SELECT g, 'w' || g || '@example.dev', 20 + (g % 50),
                              to_timestamp($2::bigint + g - 1)
                       FROM generate_series(1, $1::int) g"#
                ),
                &[&(s.rounds as i32), &EPOCH_BASE_S],
            )
            .await?;
        }
        _ => {}
    }
    Ok(())
}

/// Read every row of a four-column result the way the mapper arms read it.
fn drain_four(rows: &[tokio_postgres::Row]) -> i64 {
    let mut sum = 0i64;
    for r in rows {
        let id: i64 = r.get(0);
        let email: &str = r.get(1);
        let age: i32 = r.get(2);
        let created: DateTime<Utc> = r.get(3);
        sum += tally(id, email, age, created);
    }
    sum
}

/// The control's write path: five statements rather than five query shapes, and
/// the same rows read back through RETURNING that the mapper arms read. A
/// control that discarded the stored row would be doing less work.
async fn raw_write_block(
    c: &tokio_postgres::Client,
    sts: &Statements,
    s: Shape,
) -> Result<(i64, i64), Box<dyn std::error::Error>> {
    let mut sum = 0i64;
    let started = Instant::now();
    for i in 0..s.rounds {
        let id = i as i64 + 1;
        let key = (i as i64 % 1000) + 1;
        let rows = match s.name {
            "insert" => {
                c.query(
                    &sts.insert,
                    &[&id, &written_email(id), &written_age(id), &written_time(id)],
                )
                .await?
            }
            "batch" => {
                let mut ids = Vec::with_capacity(BATCH_ROWS);
                let mut emails = Vec::with_capacity(BATCH_ROWS);
                let mut ages = Vec::with_capacity(BATCH_ROWS);
                let mut stamps = Vec::with_capacity(BATCH_ROWS);
                for j in 0..BATCH_ROWS {
                    let rid = (i * BATCH_ROWS + j + 1) as i64;
                    ids.push(rid);
                    emails.push(written_email(rid));
                    ages.push(written_age(rid));
                    stamps.push(written_time(rid));
                }
                c.query(&sts.batch, &[&ids, &emails, &ages, &stamps]).await?
            }
            "update" => c.query(&sts.update, &[&written_age(key), &key]).await?,
            "delete" => c.query(&sts.delete, &[&id]).await?,
            _ => {
                // BEGIN, a read, a write, COMMIT — spelled out rather than
                // through a transaction helper, so the statement count matches
                // every other arm's exactly.
                c.batch_execute("BEGIN").await?;
                sum += drain_four(&c.query(&sts.tx_find, &[&key]).await?);
                sum += drain_four(&c.query(&sts.update, &[&written_age(key), &key]).await?);
                c.batch_execute("COMMIT").await?;
                continue;
            }
        };
        sum += drain_four(&rows);
    }
    Ok((started.elapsed().as_nanos() as i64 / s.rounds as i64, sum))
}

/// The query builder's write path.
async fn diesel_write_block(
    c: &mut AsyncPgConnection,
    s: Shape,
) -> Result<(i64, i64), Box<dyn std::error::Error>> {
    use diesel_async::scoped_futures::ScopedFutureExt;

    let mut sum = 0i64;
    let started = Instant::now();
    for i in 0..s.rounds {
        let id = i as i64 + 1;
        let key = (i as i64 % 1000) + 1;
        match s.name {
            "insert" => {
                let row = DieselWritten {
                    id,
                    email: written_email(id),
                    age: written_age(id),
                    created_at: written_time(id),
                };
                let stored: Vec<DieselWritten> = diesel::insert_into(nilo_compare_writes::table)
                    .values(&row)
                    .returning(DieselWritten::as_returning())
                    .get_results(c)
                    .await?;
                for w in &stored {
                    sum += tally(w.id, &w.email, w.age, w.created_at);
                }
            }
            "batch" => {
                // Diesel emits a multi-row VALUES here where the control emits
                // `unnest`. That is not a mismatch to fix — it is what Diesel
                // does, and the difference in what the two put on the wire is
                // part of what the batch shape is measuring.
                let mut rows = Vec::with_capacity(BATCH_ROWS);
                for j in 0..BATCH_ROWS {
                    let rid = (i * BATCH_ROWS + j + 1) as i64;
                    rows.push(DieselWritten {
                        id: rid,
                        email: written_email(rid),
                        age: written_age(rid),
                        created_at: written_time(rid),
                    });
                }
                let stored: Vec<DieselWritten> = diesel::insert_into(nilo_compare_writes::table)
                    .values(&rows)
                    .returning(DieselWritten::as_returning())
                    .get_results(c)
                    .await?;
                for w in &stored {
                    sum += tally(w.id, &w.email, w.age, w.created_at);
                }
            }
            "update" => {
                use nilo_compare_updates::dsl as u;
                let stored: Vec<DieselUpdated> =
                    diesel::update(u::nilo_compare_updates.filter(u::id.eq(key)))
                        .set(u::age.eq(written_age(key)))
                        .returning(DieselUpdated::as_returning())
                        .get_results(c)
                        .await?;
                for r in &stored {
                    sum += tally(r.id, &r.email, r.age, r.created_at);
                }
            }
            "delete" => {
                use nilo_compare_deletes::dsl as x;
                let stored: Vec<DieselDeleted> =
                    diesel::delete(x::nilo_compare_deletes.filter(x::id.eq(id)))
                        .returning(DieselDeleted::as_returning())
                        .get_results(c)
                        .await?;
                for r in &stored {
                    sum += tally(r.id, &r.email, r.age, r.created_at);
                }
            }
            _ => {
                // Diesel's own transaction rather than a hand-written
                // BEGIN/COMMIT: what it wraps the two statements in is part of
                // what a caller pays for using it.
                let got = c
                    .transaction::<i64, diesel::result::Error, _>(|conn| {
                        async move {
                            use nilo_compare_people::dsl as d;
                            use nilo_compare_updates::dsl as u;
                            let mut inner = 0i64;
                            let found: Vec<DieselPerson> = d::nilo_compare_people
                                .filter(d::id.eq(key))
                                .limit(1)
                                .select(DieselPerson::as_select())
                                .load(conn)
                                .await?;
                            for p in &found {
                                inner += tally(p.id, &p.email, p.age, p.created_at);
                            }
                            let stored: Vec<DieselUpdated> =
                                diesel::update(u::nilo_compare_updates.filter(u::id.eq(key)))
                                    .set(u::age.eq(written_age(key)))
                                    .returning(DieselUpdated::as_returning())
                                    .get_results(conn)
                                    .await?;
                            for r in &stored {
                                inner += tally(r.id, &r.email, r.age, r.created_at);
                            }
                            Ok(inner)
                        }
                        .scope_boxed()
                    })
                    .await?;
                sum += got;
            }
        }
    }
    Ok((started.elapsed().as_nanos() as i64 / s.rounds as i64, sum))
}

/// SQLx's write path, through the same statements the control sends.
async fn sqlx_write_block(
    c: &mut sqlx::postgres::PgConnection,
    s: Shape,
) -> Result<(i64, i64), Box<dyn std::error::Error>> {
    let mut sum = 0i64;
    let started = Instant::now();
    for i in 0..s.rounds {
        let id = i as i64 + 1;
        let key = (i as i64 % 1000) + 1;
        let rows: Vec<SqlxPerson> = match s.name {
            "insert" => {
                sqlx::query_as::<_, SqlxPerson>(INSERT_SQL)
                    .bind(id)
                    .bind(written_email(id))
                    .bind(written_age(id))
                    .bind(written_time(id))
                    .fetch_all(&mut *c)
                    .await?
            }
            "batch" => {
                let mut ids = Vec::with_capacity(BATCH_ROWS);
                let mut emails = Vec::with_capacity(BATCH_ROWS);
                let mut ages = Vec::with_capacity(BATCH_ROWS);
                let mut stamps = Vec::with_capacity(BATCH_ROWS);
                for j in 0..BATCH_ROWS {
                    let rid = (i * BATCH_ROWS + j + 1) as i64;
                    ids.push(rid);
                    emails.push(written_email(rid));
                    ages.push(written_age(rid));
                    stamps.push(written_time(rid));
                }
                sqlx::query_as::<_, SqlxPerson>(BATCH_SQL)
                    .bind(ids)
                    .bind(emails)
                    .bind(ages)
                    .bind(stamps)
                    .fetch_all(&mut *c)
                    .await?
            }
            "update" => {
                sqlx::query_as::<_, SqlxPerson>(UPDATE_SQL)
                    .bind(written_age(key))
                    .bind(key)
                    .fetch_all(&mut *c)
                    .await?
            }
            "delete" => {
                sqlx::query_as::<_, SqlxPerson>(DELETE_SQL)
                    .bind(id)
                    .fetch_all(&mut *c)
                    .await?
            }
            _ => {
                // Disambiguated: `Connection::begin` and `Acquire::begin` are
                // both in scope on a `&mut PgConnection`.
                let mut tx = sqlx::Connection::begin(&mut *c).await?;
                for p in sqlx::query_as::<_, SqlxPerson>(TX_FIND_SQL)
                    .bind(key)
                    .fetch_all(&mut *tx)
                    .await?
                {
                    sum += tally(p.id, &p.email, p.age, p.created_at);
                }
                for p in sqlx::query_as::<_, SqlxPerson>(UPDATE_SQL)
                    .bind(written_age(key))
                    .bind(key)
                    .fetch_all(&mut *tx)
                    .await?
                {
                    sum += tally(p.id, &p.email, p.age, p.created_at);
                }
                tx.commit().await?;
                continue;
            }
        };
        for p in &rows {
            sum += tally(p.id, &p.email, p.age, p.created_at);
        }
    }
    Ok((started.elapsed().as_nanos() as i64 / s.rounds as i64, sum))
}

async fn raw_block(
    c: &tokio_postgres::Client,
    sts: &Statements,
    s: Shape,
) -> Result<(i64, i64), Box<dyn std::error::Error>> {
    if s.writes {
        return raw_write_block(c, sts, s).await;
    }
    let mut sum = 0i64;
    let started = Instant::now();
    for i in 0..s.rounds {
        let rows = match s.name {
            "empty" => c.query(&sts.empty, &[]).await?,
            "key" => c.query(&sts.key, &[&((i as i64 % 1000) + 1)]).await?,
            "page" => c.query(&sts.page, &[&20i32, &"p%"]).await?,
            "wide" => c.query(&sts.wide_key, &[&((i as i64 % 1000) + 1)]).await?,
            "wide_scan" => c.query(&sts.wide_scan, &[]).await?,
            _ => c.query(&sts.scan, &[]).await?,
        };
        if s.columns == 20 {
            // Twenty reads, written out. Spelling all of it is the point: this
            // is the control the mappers are compared against, and a control
            // that looped over column indices would be a mapper of its own.
            for r in &rows {
                let t1: &str = r.get(1);
                let t2: &str = r.get(2);
                let t3: &str = r.get(3);
                let t4: &str = r.get(4);
                let t5: &str = r.get(5);
                let t6: &str = r.get(6);
                let t7: &str = r.get(7);
                let d1: DateTime<Utc> = r.get(14);
                let d2: DateTime<Utc> = r.get(15);
                let d3: DateTime<Utc> = r.get(16);
                let d4: DateTime<Utc> = r.get(17);
                sum += r.get::<_, i64>(0)
                    + r.get::<_, i32>(8) as i64
                    + r.get::<_, i32>(9) as i64
                    + r.get::<_, i32>(10) as i64
                    + r.get::<_, i32>(11) as i64
                    + r.get::<_, i32>(12) as i64
                    + r.get::<_, i64>(13)
                    + (t1.len() + t2.len() + t3.len() + t4.len()
                        + t5.len() + t6.len() + t7.len()) as i64
                    + d1.timestamp() + d2.timestamp() + d3.timestamp() + d4.timestamp()
                    + r.get::<_, bool>(18) as i64
                    + r.get::<_, bool>(19) as i64;
            }
        } else if s.name != "empty" {
            for r in &rows {
                let id: i64 = r.get(0);
                let email: &str = r.get(1);
                let age: i32 = r.get(2);
                let created: DateTime<Utc> = r.get(3);
                sum += tally(id, email, age, created);
            }
        }
    }
    Ok((started.elapsed().as_nanos() as i64 / s.rounds as i64, sum))
}

async fn diesel_block(
    c: &mut AsyncPgConnection,
    s: Shape,
) -> Result<(i64, i64), Box<dyn std::error::Error>> {
    if s.writes {
        return diesel_write_block(c, s).await;
    }
    use nilo_compare_people::dsl as d;
    use nilo_compare_wide::dsl as w;
    let mut sum = 0i64;

    if s.columns == 20 {
        let started = Instant::now();
        for i in 0..s.rounds {
            let rows: Vec<DieselWide> = if s.name == "wide" {
                w::nilo_compare_wide
                    .filter(w::id.eq((i as i64 % 1000) + 1))
                    .limit(1)
                    .select(DieselWide::as_select())
                    .load(c)
                    .await?
            } else {
                w::nilo_compare_wide
                    .select(DieselWide::as_select())
                    .load(c)
                    .await?
            };
            for r in &rows {
                sum += tally_wide!(r);
            }
        }
        return Ok((started.elapsed().as_nanos() as i64 / s.rounds as i64, sum));
    }

    let started = Instant::now();
    for i in 0..s.rounds {
        let rows: Vec<DieselPerson> = match s.name {
            "key" => {
                d::nilo_compare_people
                    .filter(d::id.eq((i as i64 % 1000) + 1))
                    .limit(1)
                    .select(DieselPerson::as_select())
                    .load(c)
                    .await?
            }
            "page" => {
                d::nilo_compare_people
                    .filter(d::age.gt(20i32).and(d::email.like("p%")))
                    .order((d::created_at.desc(), d::id.asc()))
                    .limit(20)
                    .select(DieselPerson::as_select())
                    .load(c)
                    .await?
            }
            _ => {
                d::nilo_compare_people
                    .select(DieselPerson::as_select())
                    .load(c)
                    .await?
            }
        };
        for p in &rows {
            sum += tally(p.id, &p.email, p.age, p.created_at);
        }
    }
    Ok((started.elapsed().as_nanos() as i64 / s.rounds as i64, sum))
}

async fn sqlx_block(
    c: &mut sqlx::postgres::PgConnection,
    s: Shape,
) -> Result<(i64, i64), Box<dyn std::error::Error>> {
    if s.writes {
        return sqlx_write_block(c, s).await;
    }
    let mut sum = 0i64;

    if s.columns == 20 {
        let key_sql =
            format!(r#"SELECT {WIDE_COLS} FROM "nilo_compare_wide" WHERE "id" = $1 LIMIT 1"#);
        let scan_sql = format!(r#"SELECT {WIDE_COLS} FROM "nilo_compare_wide""#);
        let started = Instant::now();
        for i in 0..s.rounds {
            let rows: Vec<SqlxWide> = if s.name == "wide" {
                sqlx::query_as::<_, SqlxWide>(&key_sql)
                    .bind((i as i64 % 1000) + 1)
                    .fetch_all(&mut *c)
                    .await?
            } else {
                sqlx::query_as::<_, SqlxWide>(&scan_sql).fetch_all(&mut *c).await?
            };
            for r in &rows {
                sum += tally_wide!(r);
            }
        }
        return Ok((started.elapsed().as_nanos() as i64 / s.rounds as i64, sum));
    }

    let started = Instant::now();
    for i in 0..s.rounds {
        let rows: Vec<SqlxPerson> = match s.name {
            "key" => {
                sqlx::query_as::<_, SqlxPerson>(KEY_SQL)
                    .bind((i as i64 % 1000) + 1)
                    .fetch_all(&mut *c)
                    .await?
            }
            "page" => {
                sqlx::query_as::<_, SqlxPerson>(PAGE_SQL)
                    .bind(20i32)
                    .bind("p%")
                    .fetch_all(&mut *c)
                    .await?
            }
            _ => sqlx::query_as::<_, SqlxPerson>(SCAN_SQL).fetch_all(&mut *c).await?,
        };
        for p in &rows {
            sum += tally(p.id, &p.email, p.age, p.created_at);
        }
    }
    Ok((started.elapsed().as_nanos() as i64 / s.rounds as i64, sum))
}

fn env_usize(name: &str, default: usize) -> usize {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// `OPS_SHAPES=empty,key` restricts the run. Empty means every shape, which is
/// what the benchmark itself always wants.
fn wanted(only: &str, name: &str) -> bool {
    only.is_empty() || only.split(',').any(|w| w.trim() == name)
}

fn median(xs: &[i64]) -> i64 {
    if xs.is_empty() {
        return 0;
    }
    let mut c = xs.to_vec();
    c.sort_unstable();
    c[c.len() / 2]
}

/// The high-water mark rather than the current size.
fn peak_rss_kb() -> i64 {
    let Ok(text) = std::fs::read_to_string("/proc/self/status") else {
        return 0;
    };
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("VmHWM:") {
            if let Some(n) = rest.split_whitespace().next() {
                return n.parse().unwrap_or(0);
            }
        }
    }
    0
}
