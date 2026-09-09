// freecache and bigcache under the same load, because go-cache is not the
// design nilo_cache is.
//
// go-cache is a `map[string]Item` under an `RWMutex` that hands back a pointer
// and grows without asking. It was the first comparison because it is what a
// Go program reaches for, but it answers a different question: nilo_cache is
// a fixed byte budget, a ring, and a copy on the way out — and so are these
// two. freecache in particular is the same design in another language, down to
// the segmented ring and the caller's buffer.
//
//	go run . others <threads> <seconds>
//	go run . othersmem <entries>
//	go run . hitrate
package main

import (
	"encoding/binary"
	"fmt"
	"math"
	"math/rand"
	"runtime"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	"github.com/allegro/bigcache/v3"
	"github.com/coocood/freecache"
)

// The same 24 bytes, encoded rather than boxed. Both of these store bytes, so
// this is the work their callers actually do — and it is the work nilo's
// caller does not, its flat value going in as its own bytes.
func encodeCart(owner uint64, items uint32, total uint64) []byte {
	var b [24]byte
	binary.LittleEndian.PutUint64(b[0:8], owner)
	binary.LittleEndian.PutUint32(b[8:12], items)
	binary.LittleEndian.PutUint64(b[12:20], total)
	return b[:]
}

// One cache, behind whichever of the three is being measured.
type byteCache interface {
	set(key []byte, value []byte)
	get(key []byte, into []byte) ([]byte, bool)
	name() string
}

type freeCache struct{ c *freecache.Cache }

func (f freeCache) name() string { return "freecache" }
func (f freeCache) set(k, v []byte) {
	_ = f.c.Set(k, v, 0)
}

func (f freeCache) get(k, into []byte) ([]byte, bool) {
	// `GetWithBuf` rather than `Get`, which is the fair call: it reads into a
	// buffer the caller already has, the way nilo's `get` does. `Get` would
	// allocate a fresh slice per hit and measure the allocator.
	v, err := f.c.GetWithBuf(k, into)
	if err != nil {
		return nil, false
	}
	return v, true
}

type bigCache struct{ c *bigcache.BigCache }

func (b bigCache) name() string { return "bigcache" }
func (b bigCache) set(k, v []byte) {
	_ = b.c.Set(string(k), v)
}

func (b bigCache) get(k, into []byte) ([]byte, bool) {
	v, err := b.c.Get(string(k))
	if err != nil {
		return nil, false
	}
	return v, true
}

func newFree(bytes int) byteCache  { return freeCache{freecache.NewCache(bytes)} }
func newBig(bytes int) byteCache {
	// No expiry, and no cleaner: what is being measured is what the cache
	// forgets when it runs out of room, not what a clock takes off it.
	cfg := bigcache.DefaultConfig(10 * time.Minute)
	cfg.CleanWindow = 0
	cfg.Shards = 64
	// **A megabyte is the smallest thing it can be told**, so the rows below
	// that are all the same cache. freecache has the same floor at 512 KiB.
	// Neither can be asked the question at the sizes where a policy shows.
	cfg.HardMaxCacheSize = bytes >> 20
	if cfg.HardMaxCacheSize < 1 {
		cfg.HardMaxCacheSize = 1
	}
	cfg.Verbose = false
	c, err := bigcache.New(nil, cfg)
	if err != nil {
		panic(err)
	}
	return bigCache{c}
}

func benchOthers(threads, seconds int) {
	keys := buildKeys(keysN)
	lookup := make([][]byte, len(keys))
	for i, k := range keys {
		lookup[i] = []byte(k)
	}
	page := make([]byte, 512)
	for i := range page {
		page[i] = 'p'
	}
	flat := encodeCart(1, 2, 3)

	run := func(mkc func(int) byteCache, label, kind string, span int) {
		c := mkc(64 << 20)
		value := flat
		if kind == "page" || kind == "mixed_page" {
			value = page
		}
		for _, k := range lookup[:span] {
			c.set(k, value)
		}

		var stop atomic.Bool
		var wg sync.WaitGroup
		ops := make([]int64, threads)
		hits := make([]int64, threads)
		began := time.Now()
		for t := 0; t < threads; t++ {
			wg.Add(1)
			go func(t int) {
				defer wg.Done()
				rng := rand.New(rand.NewSource(int64(7 + t)))
				into := make([]byte, 1024)
				for !stop.Load() {
					for n := 0; n < 512; n++ {
						k := lookup[rng.Intn(span)]
						switch kind {
						case "flat", "page":
							if _, ok := c.get(k, into); ok {
								hits[t]++
							}
						case "put_flat":
							c.set(k, value)
						case "mixed_flat", "mixed_page":
							if n%10 == 0 {
								c.set(k, value)
							} else if _, ok := c.get(k, into); ok {
								hits[t]++
							}
						}
						ops[t]++
					}
				}
			}(t)
		}
		time.Sleep(time.Duration(seconds) * time.Second)
		stop.Store(true)
		wg.Wait()
		took := time.Since(began)

		var totalOps, totalHits int64
		for i := range ops {
			totalOps += ops[i]
			totalHits += hits[i]
		}
		hitPct := 0.0
		if totalOps > 0 {
			hitPct = float64(totalHits) * 100 / float64(totalOps)
		}
		fmt.Printf("  %-10s %-20s %2d threads  %12.0f ops/s  %7.1f ns/op  hits %5.1f%%\n",
			c.name(), label, threads,
			float64(totalOps)/took.Seconds(),
			float64(took.Nanoseconds())*float64(threads)/float64(totalOps),
			hitPct)
	}

	for _, mk := range []func(int) byteCache{newFree, newBig} {
		run(mk, "get_flat in cache", "flat", 2000)
		run(mk, "get_flat", "flat", keysN)
		run(mk, "put_flat", "put_flat", keysN)
		run(mk, "mixed_flat", "mixed_flat", keysN)
		run(mk, "get_page", "page", keysN)
		run(mk, "mixed_page", "mixed_page", keysN)
	}
}

// What N entries cost to hold. Both of these take a fixed budget the way nilo
// does, so the question is the same one asked of nilo: the smallest budget
// that still holds them, weighed as RSS.
func memOthers(entries int) {
	keys := buildKeys(entries)
	lookup := make([][]byte, len(keys))
	for i, k := range keys {
		lookup[i] = []byte(k)
	}
	flat := encodeCart(1, 2, 3)

	for _, mk := range []func(int) byteCache{newFree, newBig} {
		for _, mib := range []int{4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128} {
			runtime.GC()
			debug.FreeOSMemory()
			before := rssKiB()

			c := mk(mib << 20)
			for _, k := range lookup {
				c.set(k, flat)
			}
			into := make([]byte, 64)
			live := 0
			for _, k := range lookup {
				if _, ok := c.get(k, into); ok {
					live++
				}
			}
			if live*100 < entries*98 {
				runtime.KeepAlive(c)
				continue
			}

			runtime.GC()
			debug.FreeOSMemory()
			after := rssKiB()
			fmt.Printf("  %-10s    %d entries   RSS %d KiB - %d KiB = %d KiB   %.1f bytes/entry"+
				"   (budget %d MiB, %d retrievable = %.1f%%)\n",
				c.name(), entries, after, before, after-before,
				float64(after-before)*1024/float64(entries),
				mib, live, float64(live)*100/float64(entries))
			runtime.KeepAlive(c)
			break
		}
	}
}

// The number that decides whether a cache is worth its memory: what fraction
// of lookups it answers on traffic shaped like traffic. Same trace, same
// budgets, same read-through loop as the Zig side.
func hitrate() {
	const keysNH = 100000
	const traceN = 3000000

	keys := buildKeys(keysNH)
	lookup := make([][]byte, len(keys))
	for i, k := range keys {
		lookup[i] = []byte(k)
	}

	cdf := make([]float64, keysNH)
	sum := 0.0
	for i := range cdf {
		sum += 1.0 / math.Pow(float64(i+1), 0.99)
		cdf[i] = sum
	}
	for i := range cdf {
		cdf[i] /= sum
	}
	pick := func(u float64) int {
		lo, hi := 0, keysNH-1
		for lo < hi {
			mid := lo + (hi-lo)/2
			if cdf[mid] < u {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		return lo
	}

	trace := make([]int32, traceN)
	rng := rand.New(rand.NewSource(2))
	for i := range trace {
		trace[i] = int32(pick(rng.Float64()))
	}

	flat := encodeCart(1, 2, 3)
	budgets := []int{128 << 10, 256 << 10, 512 << 10, 1 << 20, 2 << 20, 4 << 20, 8 << 20, 16 << 20}

	fmt.Println("hit rate, zipf 0.99, read-through, 3000000 lookups")
	for _, mk := range []func(int) byteCache{newFree, newBig} {
		for _, budget := range budgets {
			c := mk(budget)
			into := make([]byte, 64)
			hits := 0
			for _, i := range trace {
				k := lookup[i]
				if _, ok := c.get(k, into); ok {
					hits++
				} else {
					c.set(k, flat)
				}
			}
			fmt.Printf("  %-10s %6d KiB  %7.1f%%\n",
				c.name(), budget>>10, float64(hits)*100/float64(traceN))
		}
	}
}
