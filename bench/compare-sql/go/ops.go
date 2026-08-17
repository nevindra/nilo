// GORM against the pgx it is built on.
//
// Deliberately the same shape as `zigsql/src/ops.zig`, down to the block
// count and the checksum: the two arms interleave inside one process so that
// drift lands on both halves of a pair and cancels in the subtraction. The
// header of that file has the reasoning and it is not repeated here.
//
// The control is pgx rather than database/sql, because gorm.io/driver/postgres
// *is* pgx underneath. A control on a different driver would fold the driver's
// difference into the mapper's.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"gorm.io/gorm/logger"
)

const table = "nilo_compare_people"
const wideTable = "nilo_compare_wide"
const writeTable = "nilo_compare_writes"
const updateTable = "nilo_compare_updates"
const deleteTable = "nilo_compare_deletes"

// 2026-01-01T00:00:00Z. Every candidate derives `created_at` from this, so the
// checksum of a written row does not depend on when the benchmark ran.
const epochBaseS int64 = 1_767_225_600

const fourCols = `"id", "email", "age", "created_at"`

const (
	insertSQL = `INSERT INTO "` + writeTable + `" (` + fourCols +
		`) VALUES ($1, $2, $3, $4) RETURNING ` + fourCols
	// One array per column, `unnest` on the server — the shape `insertMany`
	// compiles to. The control sends the same statement rather than a
	// hand-rolled multi-VALUES, which would be a different benchmark.
	batchSQL = `INSERT INTO "` + writeTable + `" (` + fourCols +
		`) SELECT * FROM unnest($1::bigint[], $2::text[], $3::int[], $4::timestamptz[])` +
		` RETURNING ` + fourCols
	updateSQL = `UPDATE "` + updateTable + `" SET "age" = $1 WHERE "id" = $2 RETURNING ` + fourCols
	deleteSQL = `DELETE FROM "` + deleteTable + `" WHERE "id" = $1 RETURNING ` + fourCols
	txFindSQL = `SELECT ` + fourCols + ` FROM "` + table + `" WHERE "id" = $1 LIMIT 1`
)

const (
	keySQL   = `SELECT "id", "email", "age", "created_at" FROM "` + table + `" WHERE "id" = $1 LIMIT 1`
	pageSQL  = `SELECT "id", "email", "age", "created_at" FROM "` + table + `" WHERE "age" > $1 AND "email" LIKE $2 ORDER BY "created_at" DESC, "id" ASC LIMIT 20`
	scanSQL  = `SELECT "id", "email", "age", "created_at" FROM "` + table + `"`
	emptySQL = `SELECT 1`

	wideCols    = `"id", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "n1", "n2", "n3", "n4", "n5", "n6", "d1", "d2", "d3", "d4", "b1", "b2"`
	wideKeySQL  = `SELECT ` + wideCols + ` FROM "` + wideTable + `" WHERE "id" = $1 LIMIT 1`
	wideScanSQL = `SELECT ` + wideCols + ` FROM "` + wideTable + `"`
)

// The Row. GORM needs the tags; the four fields are the same four every other
// candidate declares.
type Person struct {
	ID        int64     `gorm:"column:id;primaryKey"`
	Email     string    `gorm:"column:email"`
	Age       int32     `gorm:"column:age"`
	CreatedAt time.Time `gorm:"column:created_at"`
}

func (Person) TableName() string { return table }

// Twenty columns: seven text, six integer, four timestamp, two boolean, and
// the key. No floating point in the fixture — a checksum four runtimes have to
// agree about bit for bit is not the place to find out how each of them
// rounds.
type Wide struct {
	ID int64     `gorm:"column:id;primaryKey"`
	T1 string    `gorm:"column:t1"`
	T2 string    `gorm:"column:t2"`
	T3 string    `gorm:"column:t3"`
	T4 string    `gorm:"column:t4"`
	T5 string    `gorm:"column:t5"`
	T6 string    `gorm:"column:t6"`
	T7 string    `gorm:"column:t7"`
	N1 int32     `gorm:"column:n1"`
	N2 int32     `gorm:"column:n2"`
	N3 int32     `gorm:"column:n3"`
	N4 int32     `gorm:"column:n4"`
	N5 int32     `gorm:"column:n5"`
	N6 int64     `gorm:"column:n6"`
	D1 time.Time `gorm:"column:d1"`
	D2 time.Time `gorm:"column:d2"`
	D3 time.Time `gorm:"column:d3"`
	D4 time.Time `gorm:"column:d4"`
	B1 bool      `gorm:"column:b1"`
	B2 bool      `gorm:"column:b2"`
}

func (Wide) TableName() string { return wideTable }

func tallyWide(w *Wide) int64 {
	return w.ID + int64(w.N1) + int64(w.N2) + int64(w.N3) + int64(w.N4) + int64(w.N5) + w.N6 +
		int64(len(w.T1)+len(w.T2)+len(w.T3)+len(w.T4)+len(w.T5)+len(w.T6)+len(w.T7)) +
		w.D1.Unix() + w.D2.Unix() + w.D3.Unix() + w.D4.Unix() +
		b2i(w.B1) + b2i(w.B2)
}

func b2i(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

// Three tables with identical columns, because the write shapes must not
// disturb each other: `insert` truncates its table, `delete` empties its own,
// and `update` overwrites in place and so never needs reseeding.
type Written struct {
	ID        int64     `gorm:"column:id;primaryKey"`
	Email     string    `gorm:"column:email"`
	Age       int32     `gorm:"column:age"`
	CreatedAt time.Time `gorm:"column:created_at"`
}

func (Written) TableName() string { return writeTable }

type Updated struct {
	ID        int64     `gorm:"column:id;primaryKey"`
	Email     string    `gorm:"column:email"`
	Age       int32     `gorm:"column:age"`
	CreatedAt time.Time `gorm:"column:created_at"`
}

func (Updated) TableName() string { return updateTable }

type Deleted struct {
	ID        int64     `gorm:"column:id;primaryKey"`
	Email     string    `gorm:"column:email"`
	Age       int32     `gorm:"column:age"`
	CreatedAt time.Time `gorm:"column:created_at"`
}

func (Deleted) TableName() string { return deleteTable }

// The values a write shape stores, derived from the row's own id so that two
// arms writing "the same" row write the same bytes and the checksum does not
// move between runs.
func writtenEmail(id int64) string  { return fmt.Sprintf("w%d@example.dev", id) }
func writtenAge(id int64) int32     { return int32(20 + id%50) }
func writtenTime(id int64) time.Time {
	return time.Unix(epochBaseS+id-1, 0).UTC()
}

const (
	blocks       = 300
	warmupBlocks = 20
	batchRows    = 100
)

type shape struct {
	name    string
	rows    int
	columns int
	rounds  int
	writes  bool
}

var shapes = []shape{
	{"empty", 0, 0, 200, false},
	{"key", 1, 4, 200, false},
	{"page", 20, 4, 100, false},
	{"scan", 1000, 4, 20, false},
	// The narrow shapes vary the row count and hold the width at four; these
	// two hold the row count and vary the width, which is the axis a wide
	// entity table actually moves along.
	{"wide", 1, 20, 200, false},
	{"wide_scan", 1000, 20, 10, false},
	// Everything above this line reads. These five are the other half.
	{"insert", 1, 4, 50, true},
	{"batch", batchRows, 4, 10, true},
	{"update", 1, 4, 50, true},
	{"delete", 1, 4, 50, true},
	// A read and a write inside BEGIN/COMMIT: four statements where the other
	// shapes send one.
	{"tx", 2, 4, 50, true},
}

// The same sum every candidate has to produce. See `tally` in ops.zig — a
// candidate that decodes lazily cannot arrive at this number.
func tally(id int64, email string, age int32, t time.Time) int64 {
	return id + int64(age) + int64(len(email)) + t.Unix()
}

type armOut struct {
	Checksum int64   `json:"checksum"`
	Blocks   []int64 `json:"blocks"`
}

type shapeOut struct {
	Rows    int               `json:"rows"`
	Columns int               `json:"columns"`
	Rounds  int               `json:"rounds"`
	Arms    map[string]armOut `json:"arms"`
}

type out struct {
	Language  string              `json:"language"`
	Shapes    map[string]shapeOut `json:"shapes"`
	PeakRSSKB int64               `json:"peak_rss_kb"`
}

func main() {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		fmt.Fprintln(os.Stderr, "go-ops needs DATABASE_URL")
		os.Exit(1)
	}
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, url)
	must(err)
	defer conn.Close(ctx)

	// PrepareStmt so the arms are compared in the same configuration nilo_sql
	// is measured in. Without it this would be GORM-unprepared against
	// pgx-prepared, and `bench/result/sql.md` §1 puts that difference at 29%
	// on this transport — larger than anything a mapper costs.
	gdb, err := gorm.Open(postgres.Open(url), &gorm.Config{
		PrepareStmt: true,
		Logger:      logger.Discard,
	})
	must(err)
	sqlDB, err := gdb.DB()
	must(err)
	// One connection, like every other arm. A pool here would measure
	// queueing, which is drive.py's question.
	sqlDB.SetMaxOpenConns(1)
	sqlDB.SetMaxIdleConns(1)
	defer sqlDB.Close()

	// Knobs for the syscall census rather than for the benchmark. Counting
	// packets per query under strace needs a run small enough to trace and a
	// warm-up of zero. Left at their defaults these change nothing.
	nBlocks := envInt("OPS_BLOCKS", blocks)
	nWarmup := envInt("OPS_WARMUP", warmupBlocks)
	only := os.Getenv("OPS_SHAPES")

	fmt.Fprintf(os.Stderr, "go — GORM against raw pgx, %d interleaved blocks\n", nBlocks)
	fmt.Fprintf(os.Stderr, "  warming %d blocks a shape…\n", nWarmup)
	for _, s := range shapes {
		if !wanted(only, s.name) {
			continue
		}
		for i := 0; i < nWarmup; i++ {
			must(prepareWrites(ctx, conn, s))
			_, _, err := pgxBlock(ctx, conn, s)
			must(err)
			if s.name != "empty" {
				must(prepareWrites(ctx, conn, s))
				_, _, err := gormBlock(ctx, gdb, s)
				must(err)
			}
		}
	}

	result := out{Language: "go", Shapes: map[string]shapeOut{}}
	for _, s := range shapes {
		if !wanted(only, s.name) {
			continue
		}
		rawNs := make([]int64, 0, nBlocks)
		gormNs := make([]int64, 0, nBlocks)
		var rawSum, gormSum int64

		for b := 0; b < nBlocks; b++ {
			// Flip the order on odd blocks, for the reason ops.zig gives.
			order := []string{"pgx", "gorm"}
			if b%2 == 1 {
				order = []string{"gorm", "pgx"}
			}
			for _, which := range order {
				// Before **each arm's** block rather than before each pair:
				// two arms inserting the same primary keys into a table only
				// one of them emptied is a unique-violation, not a benchmark.
				must(prepareWrites(ctx, conn, s))
				if which == "pgx" {
					ns, sum, err := pgxBlock(ctx, conn, s)
					must(err)
					rawNs = append(rawNs, ns)
					rawSum = sum
				} else if s.name != "empty" {
					ns, sum, err := gormBlock(ctx, gdb, s)
					must(err)
					gormNs = append(gormNs, ns)
					gormSum = sum
				}
			}
		}

		arms := map[string]armOut{"pgx": {Checksum: rawSum, Blocks: rawNs}}
		if s.name != "empty" {
			arms["gorm"] = armOut{Checksum: gormSum, Blocks: gormNs}
			fmt.Fprintf(os.Stderr, "  %-9s pgx %9d ns   gorm %9d ns\n",
				s.name, median(rawNs), median(gormNs))
		} else {
			fmt.Fprintf(os.Stderr, "  %-9s pgx %9d ns\n", s.name, median(rawNs))
		}
		result.Shapes[s.name] = shapeOut{
			Rows: s.rows, Columns: s.columns, Rounds: s.rounds, Arms: arms,
		}
	}
	result.PeakRSSKB = peakRSSKB()

	blob, err := json.Marshal(result)
	must(err)
	fmt.Printf("RESULT %s\n", blob)
}

// Put the write tables back the way a timed block expects to find them.
// Outside the timer, and on the pgx connection for both arms — a TRUNCATE
// autocommits, so which connection issued it is not something the other one
// can tell.
func prepareWrites(ctx context.Context, conn *pgx.Conn, s shape) error {
	switch s.name {
	case "insert", "batch":
		_, err := conn.Exec(ctx, `TRUNCATE "`+writeTable+`"`)
		return err
	case "delete":
		if _, err := conn.Exec(ctx, `TRUNCATE "`+deleteTable+`"`); err != nil {
			return err
		}
		// Exactly the rows the block will remove, and no more: seeding a
		// thousand to delete fifty would put an index of a different size
		// under every measurement.
		_, err := conn.Exec(ctx,
			`INSERT INTO "`+deleteTable+`" (`+fourCols+`)`+
				` SELECT g, 'w' || g || '@example.dev', 20 + (g % 50),`+
				` to_timestamp($2::bigint + g - 1)`+
				` FROM generate_series(1, $1::int) g`,
			int32(s.rounds), epochBaseS)
		return err
	}
	return nil
}

// The control's write path: four statements rather than four query shapes, and
// the same rows read back through RETURNING that the ORM arm reads. A control
// that discarded the stored row would be doing less work.
func pgxWriteBlock(ctx context.Context, conn *pgx.Conn, s shape) (int64, int64, error) {
	var sum int64

	ids := make([]int64, batchRows)
	emails := make([]string, batchRows)
	ages := make([]int32, batchRows)
	stamps := make([]time.Time, batchRows)

	started := time.Now()
	for i := 0; i < s.rounds; i++ {
		id := int64(i + 1)
		key := int64(i%1000) + 1
		var rows pgx.Rows
		var err error

		switch s.name {
		case "insert":
			rows, err = conn.Query(ctx, insertSQL,
				id, writtenEmail(id), writtenAge(id), writtenTime(id))
		case "batch":
			for j := 0; j < batchRows; j++ {
				rid := int64(i*batchRows + j + 1)
				ids[j], emails[j] = rid, writtenEmail(rid)
				ages[j], stamps[j] = writtenAge(rid), writtenTime(rid)
			}
			rows, err = conn.Query(ctx, batchSQL, ids, emails, ages, stamps)
		case "update":
			rows, err = conn.Query(ctx, updateSQL, writtenAge(key), key)
		case "delete":
			rows, err = conn.Query(ctx, deleteSQL, id)
		case "tx":
			n, e := pgxTxRound(ctx, conn, key)
			if e != nil {
				return 0, 0, e
			}
			sum += n
			continue
		}
		if err != nil {
			return 0, 0, err
		}
		n, err := drainFour(rows)
		if err != nil {
			return 0, 0, err
		}
		sum += n
	}
	return time.Since(started).Nanoseconds() / int64(s.rounds), sum, nil
}

// BEGIN, a read, a write, COMMIT — spelled out rather than through pgx's
// `BeginFunc`, so the statement count matches every other arm's exactly.
func pgxTxRound(ctx context.Context, conn *pgx.Conn, key int64) (int64, error) {
	var sum int64
	if _, err := conn.Exec(ctx, "BEGIN"); err != nil {
		return 0, err
	}
	rows, err := conn.Query(ctx, txFindSQL, key)
	if err != nil {
		return 0, err
	}
	n, err := drainFour(rows)
	if err != nil {
		return 0, err
	}
	sum += n
	rows, err = conn.Query(ctx, updateSQL, writtenAge(key), key)
	if err != nil {
		return 0, err
	}
	n, err = drainFour(rows)
	if err != nil {
		return 0, err
	}
	sum += n
	if _, err := conn.Exec(ctx, "COMMIT"); err != nil {
		return 0, err
	}
	return sum, nil
}

// Read every row of a four-column result the way the ORM arm reads it.
func drainFour(rows pgx.Rows) (int64, error) {
	var sum int64
	for rows.Next() {
		var id int64
		var email string
		var age int32
		var created time.Time
		if err := rows.Scan(&id, &email, &age, &created); err != nil {
			rows.Close()
			return 0, err
		}
		sum += tally(id, email, age, created)
	}
	rows.Close()
	return sum, rows.Err()
}

// The subject's write path: the same five shapes through GORM.
func gormWriteBlock(ctx context.Context, gdb *gorm.DB, s shape) (int64, int64, error) {
	var sum int64
	started := time.Now()
	for i := 0; i < s.rounds; i++ {
		id := int64(i + 1)
		key := int64(i%1000) + 1

		switch s.name {
		case "insert":
			// `clause.Returning` rather than trusting the struct GORM was
			// handed: the checksum has to come from what the server stored,
			// which is what every other arm reads back.
			w := Written{ID: id, Email: writtenEmail(id),
				Age: writtenAge(id), CreatedAt: writtenTime(id)}
			if err := gdb.Clauses(clause.Returning{}).Create(&w).Error; err != nil {
				return 0, 0, err
			}
			sum += tally(w.ID, w.Email, w.Age, w.CreatedAt)
		case "batch":
			ws := make([]Written, batchRows)
			for j := range ws {
				rid := int64(i*batchRows + j + 1)
				ws[j] = Written{ID: rid, Email: writtenEmail(rid),
					Age: writtenAge(rid), CreatedAt: writtenTime(rid)}
			}
			// GORM emits a multi-row VALUES here where the control emits
			// `unnest`. That is not a mismatch to fix — it is what GORM does,
			// and the difference in what the two put on the wire is part of
			// what the batch shape is measuring.
			if err := gdb.Clauses(clause.Returning{}).
				CreateInBatches(&ws, batchRows).Error; err != nil {
				return 0, 0, err
			}
			for k := range ws {
				sum += tally(ws[k].ID, ws[k].Email, ws[k].Age, ws[k].CreatedAt)
			}
		case "update":
			var us []Updated
			if err := gdb.Model(&us).Clauses(clause.Returning{}).
				Where("id = ?", key).Update("age", writtenAge(key)).Error; err != nil {
				return 0, 0, err
			}
			for k := range us {
				sum += tally(us[k].ID, us[k].Email, us[k].Age, us[k].CreatedAt)
			}
		case "delete":
			var ds []Deleted
			if err := gdb.Clauses(clause.Returning{}).
				Where("id = ?", id).Delete(&ds).Error; err != nil {
				return 0, 0, err
			}
			for k := range ds {
				sum += tally(ds[k].ID, ds[k].Email, ds[k].Age, ds[k].CreatedAt)
			}
		case "tx":
			err := gdb.Transaction(func(tx *gorm.DB) error {
				var p Person
				if err := tx.Where("id = ?", key).Take(&p).Error; err != nil {
					return err
				}
				sum += tally(p.ID, p.Email, p.Age, p.CreatedAt)
				var us []Updated
				if err := tx.Model(&us).Clauses(clause.Returning{}).
					Where("id = ?", key).Update("age", writtenAge(key)).Error; err != nil {
					return err
				}
				for k := range us {
					sum += tally(us[k].ID, us[k].Email, us[k].Age, us[k].CreatedAt)
				}
				return nil
			})
			if err != nil {
				return 0, 0, err
			}
		}
	}
	return time.Since(started).Nanoseconds() / int64(s.rounds), sum, nil
}

// The control: pgx with nothing above it, doing the same four reads and
// producing the same checksum.
func pgxBlock(ctx context.Context, conn *pgx.Conn, s shape) (int64, int64, error) {
	if s.writes {
		return pgxWriteBlock(ctx, conn, s)
	}
	var sum int64
	started := time.Now()
	for i := 0; i < s.rounds; i++ {
		var rows pgx.Rows
		var err error
		switch s.name {
		case "empty":
			rows, err = conn.Query(ctx, emptySQL)
		case "key":
			rows, err = conn.Query(ctx, keySQL, int64(i%1000)+1)
		case "page":
			rows, err = conn.Query(ctx, pageSQL, int32(20), "p%")
		case "wide":
			rows, err = conn.Query(ctx, wideKeySQL, int64(i%1000)+1)
		case "wide_scan":
			rows, err = conn.Query(ctx, wideScanSQL)
		default:
			rows, err = conn.Query(ctx, scanSQL)
		}
		if err != nil {
			return 0, 0, err
		}
		for rows.Next() {
			if s.name == "empty" {
				continue
			}
			if s.columns == 20 {
				// Twenty destinations, written out. Spelling all of it is the
				// point: this is the control the mapper is compared against,
				// and a control that ranged over a slice of `any` would be a
				// mapper of its own.
				var w Wide
				if err := rows.Scan(&w.ID, &w.T1, &w.T2, &w.T3, &w.T4, &w.T5, &w.T6, &w.T7,
					&w.N1, &w.N2, &w.N3, &w.N4, &w.N5, &w.N6,
					&w.D1, &w.D2, &w.D3, &w.D4, &w.B1, &w.B2); err != nil {
					rows.Close()
					return 0, 0, err
				}
				sum += tallyWide(&w)
				continue
			}
			var id int64
			var email string
			var age int32
			var created time.Time
			if err := rows.Scan(&id, &email, &age, &created); err != nil {
				rows.Close()
				return 0, 0, err
			}
			sum += tally(id, email, age, created)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return 0, 0, err
		}
	}
	return time.Since(started).Nanoseconds() / int64(s.rounds), sum, nil
}

// The subject: the same rows through GORM's mapper.
func gormBlock(ctx context.Context, gdb *gorm.DB, s shape) (int64, int64, error) {
	if s.writes {
		return gormWriteBlock(ctx, gdb, s)
	}
	var sum int64
	started := time.Now()
	for i := 0; i < s.rounds; i++ {
		switch s.name {
		case "key":
			var p Person
			// `Take` rather than `First`: First appends an ORDER BY on the
			// primary key, which is a different statement from the one every
			// other arm sends.
			if err := gdb.Where("id = ?", int64(i%1000)+1).Take(&p).Error; err != nil {
				return 0, 0, err
			}
			sum += tally(p.ID, p.Email, p.Age, p.CreatedAt)
		case "page":
			var ps []Person
			if err := gdb.Where(`"age" > ? AND "email" LIKE ?`, int32(20), "p%").
				Order(`"created_at" DESC, "id" ASC`).Limit(20).Find(&ps).Error; err != nil {
				return 0, 0, err
			}
			for _, p := range ps {
				sum += tally(p.ID, p.Email, p.Age, p.CreatedAt)
			}
		case "wide":
			var w Wide
			if err := gdb.Where("id = ?", int64(i%1000)+1).Take(&w).Error; err != nil {
				return 0, 0, err
			}
			sum += tallyWide(&w)
		case "wide_scan":
			var ws []Wide
			if err := gdb.Find(&ws).Error; err != nil {
				return 0, 0, err
			}
			for k := range ws {
				sum += tallyWide(&ws[k])
			}
		default:
			var ps []Person
			if err := gdb.Find(&ps).Error; err != nil {
				return 0, 0, err
			}
			for _, p := range ps {
				sum += tally(p.ID, p.Email, p.Age, p.CreatedAt)
			}
		}
	}
	return time.Since(started).Nanoseconds() / int64(s.rounds), sum, nil
}

func envInt(name string, def int) int {
	text := os.Getenv(name)
	if text == "" {
		return def
	}
	n, err := strconv.Atoi(text)
	if err != nil {
		return def
	}
	return n
}

// `OPS_SHAPES=empty,key` restricts the run. Empty means every shape, which is
// what the benchmark itself always wants.
func wanted(only, name string) bool {
	if only == "" {
		return true
	}
	for _, want := range strings.Split(only, ",") {
		if strings.TrimSpace(want) == name {
			return true
		}
	}
	return false
}

func median(xs []int64) int64 {
	if len(xs) == 0 {
		return 0
	}
	c := append([]int64(nil), xs...)
	sort.Slice(c, func(i, j int) bool { return c[i] < c[j] })
	return c[len(c)/2]
}

// The high-water mark, so a runtime that has already handed pages back does
// not look thriftier than it was while the benchmark ran.
func peakRSSKB() int64 {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(b), "\n") {
		if !strings.HasPrefix(line, "VmHWM:") {
			continue
		}
		f := strings.Fields(line)
		if len(f) < 2 {
			return 0
		}
		n, _ := strconv.ParseInt(f[1], 10, 64)
		return n
	}
	return 0
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "FAILED:", err)
		os.Exit(1)
	}
}
