// Drizzle and Prisma against the node-postgres underneath one of them.
//
// The same shape as `zigsql/src/ops.zig`, `go/ops.go` and `rust/src/ops.rs`:
// every arm lives in one process and the blocks interleave, so drift lands on
// both halves of a pair and cancels in the subtraction. That file's header has
// the reasoning.
//
// Three arms, and as in Rust they are not equally clean:
//
//   pg       node-postgres, the control.
//   drizzle  a query builder *over* node-postgres, so subtracting the control
//            leaves the mapper and nothing else. `docs/roadmap.md` names
//            Drizzle as nilo_sql's fair yardstick, which is why it is here.
//   prisma   its own engine and its own connection. Its distance from the
//            control is an engine difference as well as a mapper one, and
//            reading it as an ORM tax would be wrong.

import fs from 'node:fs';
import pg from 'pg';
import { drizzle } from 'drizzle-orm/node-postgres';
import { pgTable, bigint, text, integer, timestamp, boolean } from 'drizzle-orm/pg-core';
import { eq, and, gt, like, desc, asc } from 'drizzle-orm';
import { PrismaClient } from '@prisma/client';

const TABLE = 'nilo_compare_people';
const WIDE_TABLE = 'nilo_compare_wide';

const KEY_SQL = `SELECT "id", "email", "age", "created_at" FROM "${TABLE}" WHERE "id" = $1 LIMIT 1`;
const PAGE_SQL = `SELECT "id", "email", "age", "created_at" FROM "${TABLE}" WHERE "age" > $1 AND "email" LIKE $2 ORDER BY "created_at" DESC, "id" ASC LIMIT 20`;
const SCAN_SQL = `SELECT "id", "email", "age", "created_at" FROM "${TABLE}"`;
const EMPTY_SQL = 'SELECT 1';

const WIDE_COLS = '"id", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "n1", "n2", "n3", "n4", "n5", "n6", "d1", "d2", "d3", "d4", "b1", "b2"';
const WIDE_KEY_SQL = `SELECT ${WIDE_COLS} FROM "${WIDE_TABLE}" WHERE "id" = $1 LIMIT 1`;
const WIDE_SCAN_SQL = `SELECT ${WIDE_COLS} FROM "${WIDE_TABLE}"`;

const WRITE_TABLE = 'nilo_compare_writes';
const UPDATE_TABLE = 'nilo_compare_updates';
const DELETE_TABLE = 'nilo_compare_deletes';

const FOUR_COLS = '"id", "email", "age", "created_at"';

const INSERT_SQL = `INSERT INTO "${WRITE_TABLE}" (${FOUR_COLS}) VALUES ($1, $2, $3, $4) RETURNING ${FOUR_COLS}`;
// One array per column, `unnest` on the server — the shape `insertMany`
// compiles to. The control sends the same statement rather than a hand-rolled
// multi-VALUES, which would be a different benchmark.
const BATCH_SQL = `INSERT INTO "${WRITE_TABLE}" (${FOUR_COLS}) SELECT * FROM unnest($1::bigint[], $2::text[], $3::int[], $4::timestamptz[]) RETURNING ${FOUR_COLS}`;
const UPDATE_SQL = `UPDATE "${UPDATE_TABLE}" SET "age" = $1 WHERE "id" = $2 RETURNING ${FOUR_COLS}`;
const DELETE_SQL = `DELETE FROM "${DELETE_TABLE}" WHERE "id" = $1 RETURNING ${FOUR_COLS}`;
const TX_FIND_SQL = `SELECT ${FOUR_COLS} FROM "${TABLE}" WHERE "id" = $1 LIMIT 1`;

// 2026-01-01T00:00:00Z. Every candidate derives `created_at` from this, so a
// written row's checksum does not depend on when the benchmark ran.
const EPOCH_BASE_S = 1767225600;
const BATCH_ROWS = 100;

const BLOCKS = 300;
const WARMUP_BLOCKS = 20;

const SHAPES = [
  { name: 'empty', rows: 0, columns: 0, rounds: 200 },
  { name: 'key', rows: 1, columns: 4, rounds: 200 },
  { name: 'page', rows: 20, columns: 4, rounds: 100 },
  { name: 'scan', rows: 1000, columns: 4, rounds: 20 },
  // The narrow shapes vary the row count and hold the width at four; these two
  // hold the row count and vary the width, which is the axis a wide entity
  // table actually moves along.
  { name: 'wide', rows: 1, columns: 20, rounds: 200 },
  { name: 'wide_scan', rows: 1000, columns: 20, rounds: 10 },
  // Everything above this line reads. These five are the other half.
  { name: 'insert', rows: 1, columns: 4, rounds: 50, writes: true },
  { name: 'batch', rows: BATCH_ROWS, columns: 4, rounds: 10, writes: true },
  { name: 'update', rows: 1, columns: 4, rounds: 50, writes: true },
  { name: 'delete', rows: 1, columns: 4, rounds: 50, writes: true },
  // A read and a write inside BEGIN/COMMIT: four statements where the other
  // shapes send one.
  { name: 'tx', rows: 2, columns: 4, rounds: 50, writes: true },
];

// node-postgres hands back `bigint` as a string, because an int8 does not fit
// a JS number in general. Every id here is under a thousand and every checksum
// is under 2^53, so parsing to a number is exact — and leaving it as a string
// would have made this arm skip the only conversion the other arms do.
pg.types.setTypeParser(20, (v) => Number(v));

const people = pgTable(TABLE, {
  id: bigint('id', { mode: 'number' }),
  email: text('email'),
  age: integer('age'),
  createdAt: timestamp('created_at', { withTimezone: true }),
});

const wide = pgTable(WIDE_TABLE, {
  id: bigint('id', { mode: 'number' }),
  t1: text('t1'), t2: text('t2'), t3: text('t3'), t4: text('t4'),
  t5: text('t5'), t6: text('t6'), t7: text('t7'),
  n1: integer('n1'), n2: integer('n2'), n3: integer('n3'),
  n4: integer('n4'), n5: integer('n5'),
  n6: bigint('n6', { mode: 'number' }),
  d1: timestamp('d1', { withTimezone: true }),
  d2: timestamp('d2', { withTimezone: true }),
  d3: timestamp('d3', { withTimezone: true }),
  d4: timestamp('d4', { withTimezone: true }),
  b1: boolean('b1'), b2: boolean('b2'),
});

// Three tables with identical columns, because the write shapes must not
// disturb each other: `insert` truncates its table, `delete` empties its own,
// and `update` overwrites in place and so never needs reseeding.
const fourCols = () => ({
  id: bigint('id', { mode: 'number' }),
  email: text('email'),
  age: integer('age'),
  createdAt: timestamp('created_at', { withTimezone: true }),
});

const writes = pgTable(WRITE_TABLE, fourCols());
const updates = pgTable(UPDATE_TABLE, fourCols());
const deletes = pgTable(DELETE_TABLE, fourCols());

/// The values a write shape stores, derived from the row's own id so that two
/// arms writing "the same" row write the same bytes and the checksum does not
/// move between runs.
const writtenEmail = (id) => `w${id}@example.dev`;
const writtenAge = (id) => 20 + (id % 50);
const writtenTime = (id) => new Date((EPOCH_BASE_S + id - 1) * 1000);

/// The same sum every candidate has to produce.
function tally(id, email, age, date) {
  return Number(id) + Number(age) + email.length + Math.floor(date.getTime() / 1000);
}

const secs = (d) => Math.floor(d.getTime() / 1000);

/// Twenty columns, spelled out. This is what the mappers are compared against,
/// and a version that looped over Object.values would be a mapper of its own.
function tallyWide(w) {
  return Number(w.id)
    + Number(w.n1) + Number(w.n2) + Number(w.n3) + Number(w.n4) + Number(w.n5) + Number(w.n6)
    + w.t1.length + w.t2.length + w.t3.length + w.t4.length
    + w.t5.length + w.t6.length + w.t7.length
    + secs(w.d1) + secs(w.d2) + secs(w.d3) + secs(w.d4)
    + (w.b1 ? 1 : 0) + (w.b2 ? 1 : 0);
}

function envInt(name, def) {
  const v = process.env[name];
  const n = v === undefined ? NaN : Number(v);
  return Number.isFinite(n) ? n : def;
}

/// `OPS_SHAPES=empty,key` restricts the run. Empty means every shape, which is
/// what the benchmark itself always wants.
function wanted(only, name) {
  return !only || only.split(',').some((w) => w.trim() === name);
}

function median(xs) {
  if (!xs.length) return 0;
  const c = [...xs].sort((a, b) => a - b);
  return c[Math.floor(c.length / 2)];
}

/// The high-water mark rather than the current size — a runtime that has
/// already handed pages back should not look thriftier than it was.
function peakRssKb() {
  try {
    for (const line of fs.readFileSync('/proc/self/status', 'utf8').split('\n')) {
      if (line.startsWith('VmHWM:')) return Number(line.split(/\s+/)[1]);
    }
  } catch { /* not Linux; the driver reports 0 */ }
  return 0;
}

const nowNs = () => process.hrtime.bigint();

// ------------------------------------------------------------------- arms

/// Put the write tables back the way a timed block expects to find them.
/// Outside the timer, and on the control's connection for all three arms — a
/// TRUNCATE autocommits, so which connection issued it is not something the
/// others can tell.
async function prepareWrites(client, s) {
  if (s.name === 'insert' || s.name === 'batch') {
    await client.query(`TRUNCATE "${WRITE_TABLE}"`);
  } else if (s.name === 'delete') {
    await client.query(`TRUNCATE "${DELETE_TABLE}"`);
    // Exactly the rows the block will remove, and no more: seeding a thousand
    // to delete fifty would put an index of a different size under every
    // measurement.
    await client.query(
      `INSERT INTO "${DELETE_TABLE}" (${FOUR_COLS})
       SELECT g, 'w' || g || '@example.dev', 20 + (g % 50),
              to_timestamp($2::bigint + g - 1)
       FROM generate_series(1, $1::int) g`,
      [s.rounds, EPOCH_BASE_S],
    );
  }
}

/// The control's write path: five statements rather than five query shapes, and
/// the same rows read back through RETURNING that the mapper arms read. A
/// control that discarded the stored row would be doing less work.
async function pgWriteBlock(client, s) {
  let sum = 0;
  const drain = (res) => {
    for (const r of res.rows) sum += tally(r.id, r.email, r.age, r.created_at);
  };
  const started = nowNs();
  for (let i = 0; i < s.rounds; i++) {
    const id = i + 1;
    const key = (i % 1000) + 1;
    switch (s.name) {
      case 'insert':
        drain(await client.query({
          name: 'cmp_insert', text: INSERT_SQL,
          values: [id, writtenEmail(id), writtenAge(id), writtenTime(id)],
        }));
        break;
      case 'batch': {
        const ids = [], emails = [], ages = [], stamps = [];
        for (let j = 0; j < BATCH_ROWS; j++) {
          const rid = i * BATCH_ROWS + j + 1;
          ids.push(rid); emails.push(writtenEmail(rid));
          ages.push(writtenAge(rid)); stamps.push(writtenTime(rid));
        }
        drain(await client.query({
          name: 'cmp_batch', text: BATCH_SQL, values: [ids, emails, ages, stamps],
        }));
        break;
      }
      case 'update':
        drain(await client.query({
          name: 'cmp_update', text: UPDATE_SQL, values: [writtenAge(key), key],
        }));
        break;
      case 'delete':
        drain(await client.query({ name: 'cmp_delete', text: DELETE_SQL, values: [id] }));
        break;
      default:
        // BEGIN, a read, a write, COMMIT — spelled out rather than through a
        // helper, so the statement count matches every other arm's exactly.
        await client.query('BEGIN');
        drain(await client.query({ name: 'cmp_tx_find', text: TX_FIND_SQL, values: [key] }));
        drain(await client.query({
          name: 'cmp_update', text: UPDATE_SQL, values: [writtenAge(key), key],
        }));
        await client.query('COMMIT');
    }
  }
  return [Number(nowNs() - started) / s.rounds, sum];
}

/// The query builder's write path.
async function drizzleWriteBlock(db, s) {
  let sum = 0;
  const drain = (rows) => {
    for (const r of rows) sum += tally(r.id, r.email, r.age, r.createdAt);
  };
  const started = nowNs();
  for (let i = 0; i < s.rounds; i++) {
    const id = i + 1;
    const key = (i % 1000) + 1;
    switch (s.name) {
      case 'insert':
        drain(await db.insert(writes).values({
          id, email: writtenEmail(id), age: writtenAge(id), createdAt: writtenTime(id),
        }).returning());
        break;
      case 'batch': {
        // Drizzle emits a multi-row VALUES here where the control emits
        // `unnest`. That is not a mismatch to fix — it is what Drizzle does,
        // and the difference in what the two put on the wire is part of what
        // the batch shape is measuring.
        const rows = [];
        for (let j = 0; j < BATCH_ROWS; j++) {
          const rid = i * BATCH_ROWS + j + 1;
          rows.push({
            id: rid, email: writtenEmail(rid),
            age: writtenAge(rid), createdAt: writtenTime(rid),
          });
        }
        drain(await db.insert(writes).values(rows).returning());
        break;
      }
      case 'update':
        drain(await db.update(updates).set({ age: writtenAge(key) })
          .where(eq(updates.id, key)).returning());
        break;
      case 'delete':
        drain(await db.delete(deletes).where(eq(deletes.id, id)).returning());
        break;
      default:
        await db.transaction(async (tx) => {
          const found = await tx.select().from(people).where(eq(people.id, key)).limit(1);
          drain(found);
          drain(await tx.update(updates).set({ age: writtenAge(key) })
            .where(eq(updates.id, key)).returning());
        });
    }
  }
  return [Number(nowNs() - started) / s.rounds, sum];
}

/// Prisma's write path, through its own engine and its own connection.
async function prismaWriteBlock(prisma, s) {
  let sum = 0;
  const drain = (rows) => {
    for (const r of rows) sum += tally(r.id, r.email, r.age, r.created_at);
  };
  const started = nowNs();
  for (let i = 0; i < s.rounds; i++) {
    const id = i + 1;
    const key = (i % 1000) + 1;
    switch (s.name) {
      case 'insert':
        drain([await prisma.nilo_compare_writes.create({
          data: {
            id: BigInt(id), email: writtenEmail(id),
            age: writtenAge(id), created_at: writtenTime(id),
          },
        })]);
        break;
      case 'batch': {
        const data = [];
        for (let j = 0; j < BATCH_ROWS; j++) {
          const rid = i * BATCH_ROWS + j + 1;
          data.push({
            id: BigInt(rid), email: writtenEmail(rid),
            age: writtenAge(rid), created_at: writtenTime(rid),
          });
        }
        // `createManyAndReturn` rather than `createMany`: the other two arms
        // read the stored rows back, and an arm that discarded them would be
        // doing less work.
        drain(await prisma.nilo_compare_writes.createManyAndReturn({ data }));
        break;
      }
      case 'update':
        drain([await prisma.nilo_compare_updates.update({
          where: { id: BigInt(key) }, data: { age: writtenAge(key) },
        })]);
        break;
      case 'delete':
        drain([await prisma.nilo_compare_deletes.delete({ where: { id: BigInt(id) } })]);
        break;
      default:
        // The interactive form, not the array form: the array form is a batch
        // of independent statements, and what every other arm does here is
        // read *then* write inside one transaction.
        await prisma.$transaction(async (tx) => {
          const found = await tx.nilo_compare_people.findUnique({ where: { id: BigInt(key) } });
          if (found) drain([found]);
          drain([await tx.nilo_compare_updates.update({
            where: { id: BigInt(key) }, data: { age: writtenAge(key) },
          })]);
        });
    }
  }
  return [Number(nowNs() - started) / s.rounds, sum];
}

async function pgBlock(client, s) {
  if (s.writes) return pgWriteBlock(client, s);
  let sum = 0;
  const started = nowNs();
  for (let i = 0; i < s.rounds; i++) {
    let res;
    switch (s.name) {
      // Named statements, so this arm is prepared like every other one.
      case 'empty':
        res = await client.query({ name: 'cmp_empty', text: EMPTY_SQL });
        break;
      case 'key':
        res = await client.query({ name: 'cmp_key', text: KEY_SQL, values: [(i % 1000) + 1] });
        break;
      case 'page':
        res = await client.query({ name: 'cmp_page', text: PAGE_SQL, values: [20, 'p%'] });
        break;
      case 'wide':
        res = await client.query({ name: 'cmp_wide', text: WIDE_KEY_SQL, values: [(i % 1000) + 1] });
        break;
      case 'wide_scan':
        res = await client.query({ name: 'cmp_wide_scan', text: WIDE_SCAN_SQL });
        break;
      default:
        res = await client.query({ name: 'cmp_scan', text: SCAN_SQL });
    }
    if (s.columns === 20) {
      for (const r of res.rows) sum += tallyWide(r);
    } else if (s.name !== 'empty') {
      for (const r of res.rows) sum += tally(r.id, r.email, r.age, r.created_at);
    }
  }
  return [Number(nowNs() - started) / s.rounds, sum];
}

async function drizzleBlock(db, s) {
  if (s.writes) return drizzleWriteBlock(db, s);
  let sum = 0;
  if (s.columns === 20) {
    const started = nowNs();
    for (let i = 0; i < s.rounds; i++) {
      const rows = s.name === 'wide'
        ? await db.select().from(wide).where(eq(wide.id, (i % 1000) + 1)).limit(1)
        : await db.select().from(wide);
      for (const r of rows) sum += tallyWide(r);
    }
    return [Number(nowNs() - started) / s.rounds, sum];
  }
  const started = nowNs();
  for (let i = 0; i < s.rounds; i++) {
    let rows;
    switch (s.name) {
      case 'key':
        rows = await db.select().from(people).where(eq(people.id, (i % 1000) + 1)).limit(1);
        break;
      case 'page':
        rows = await db.select().from(people)
          .where(and(gt(people.age, 20), like(people.email, 'p%')))
          .orderBy(desc(people.createdAt), asc(people.id)).limit(20);
        break;
      default:
        rows = await db.select().from(people);
    }
    for (const r of rows) sum += tally(r.id, r.email, r.age, r.createdAt);
  }
  return [Number(nowNs() - started) / s.rounds, sum];
}

async function prismaBlock(prisma, s) {
  if (s.writes) return prismaWriteBlock(prisma, s);
  let sum = 0;
  if (s.columns === 20) {
    const started = nowNs();
    for (let i = 0; i < s.rounds; i++) {
      const rows = s.name === 'wide'
        ? [await prisma.nilo_compare_wide.findUnique({ where: { id: BigInt((i % 1000) + 1) } })]
        : await prisma.nilo_compare_wide.findMany();
      for (const r of rows) if (r) sum += tallyWide(r);
    }
    return [Number(nowNs() - started) / s.rounds, sum];
  }
  const started = nowNs();
  for (let i = 0; i < s.rounds; i++) {
    let rows;
    switch (s.name) {
      case 'key': {
        const r = await prisma.nilo_compare_people.findUnique({
          where: { id: BigInt((i % 1000) + 1) },
        });
        rows = r ? [r] : [];
        break;
      }
      case 'page':
        rows = await prisma.nilo_compare_people.findMany({
          where: { age: { gt: 20 }, email: { startsWith: 'p' } },
          orderBy: [{ created_at: 'desc' }, { id: 'asc' }],
          take: 20,
        });
        break;
      default:
        rows = await prisma.nilo_compare_people.findMany();
    }
    for (const r of rows) sum += tally(r.id, r.email, r.age, r.created_at);
  }
  return [Number(nowNs() - started) / s.rounds, sum];
}

// ------------------------------------------------------------------- main

async function main() {
  const url = process.env.DATABASE_URL;
  if (!url) {
    console.error('node ops needs DATABASE_URL');
    process.exit(1);
  }

  const client = new pg.Client(url);
  await client.connect();
  const db = drizzle(client);

  // One connection, like every other arm. Prisma pools by default and a pool
  // here would measure queueing, which is drive.py's question.
  const sep = url.includes('?') ? '&' : '?';
  const prisma = new PrismaClient({
    datasources: { db: { url: `${url}${sep}connection_limit=1` } },
  });
  await prisma.$connect();

  // Knobs for the syscall census rather than for the benchmark. Counting
  // packets per query under strace needs a run small enough to trace and a
  // warm-up of zero. Left at their defaults these change nothing.
  const nBlocks = envInt('OPS_BLOCKS', BLOCKS);
  const nWarmup = envInt('OPS_WARMUP', WARMUP_BLOCKS);
  const only = process.env.OPS_SHAPES || '';

  console.error(`node — Drizzle and Prisma against raw node-postgres, ${nBlocks} interleaved blocks`);
  console.error(`  warming ${nWarmup} blocks a shape…`);
  for (const s of SHAPES) {
    if (!wanted(only, s.name)) continue;
    for (let i = 0; i < nWarmup; i++) {
      await prepareWrites(client, s);
      await pgBlock(client, s);
      if (s.name !== 'empty') {
        await prepareWrites(client, s);
        await drizzleBlock(db, s);
        await prepareWrites(client, s);
        await prismaBlock(prisma, s);
      }
    }
  }

  const shapes = {};
  for (const s of SHAPES) {
    if (!wanted(only, s.name)) continue;
    const ns = { pg: [], drizzle: [], prisma: [] };
    const sums = { pg: 0, drizzle: 0, prisma: 0 };

    for (let b = 0; b < nBlocks; b++) {
      // Rotate which arm goes first, for the reason ops.zig gives.
      const orders = [['pg', 'drizzle', 'prisma'], ['drizzle', 'prisma', 'pg'], ['prisma', 'pg', 'drizzle']];
      for (const which of orders[b % 3]) {
        if (which !== 'pg' && s.name === 'empty') continue;
        // Before **each arm's** block rather than before each triple: two arms
        // inserting the same primary keys into a table only one of them
        // emptied is a unique-violation, not a benchmark.
        await prepareWrites(client, s);
        const [t, sum] = which === 'pg' ? await pgBlock(client, s)
          : which === 'drizzle' ? await drizzleBlock(db, s)
            : await prismaBlock(prisma, s);
        ns[which].push(Math.round(t));
        sums[which] = sum;
      }
    }

    const arms = { pg: { checksum: sums.pg, blocks: ns.pg } };
    if (s.name !== 'empty') {
      arms.drizzle = { checksum: sums.drizzle, blocks: ns.drizzle };
      arms.prisma = { checksum: sums.prisma, blocks: ns.prisma };
      console.error(`  ${s.name.padEnd(9)} pg ${String(median(ns.pg)).padStart(9)} ns   `
        + `drizzle ${String(median(ns.drizzle)).padStart(9)} ns   `
        + `prisma ${String(median(ns.prisma)).padStart(9)} ns`);
    } else {
      console.error(`  ${s.name.padEnd(9)} pg ${String(median(ns.pg)).padStart(9)} ns`);
    }
    shapes[s.name] = { rows: s.rows, columns: s.columns, rounds: s.rounds, arms };
  }

  console.log('RESULT ' + JSON.stringify({
    language: 'node', shapes, peak_rss_kb: peakRssKb(),
  }));

  await prisma.$disconnect();
  await client.end();
}

main().catch((e) => {
  console.error('FAILED:', e);
  process.exit(1);
});
