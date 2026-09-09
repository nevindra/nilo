// go-cache under the same load nilo_cache is put under, so the two numbers
// are about the same work rather than about two benchmarks.
//
//	go run . bench <threads> <seconds>
//	go run . mem   <entries>
//
// The keys are built before the clock starts, the same as on the other side:
// formatting a key inside a timed loop measures fmt.
package main

import (
	"fmt"
	"math/rand"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	cache "github.com/patrickmn/go-cache"
)

// The same 24 bytes the other side stores as a flat value. Go boxes it into
// an interface{} on the way in, which is part of what is being compared
// rather than something to work around.
type Cart struct {
	Owner uint64
	Items uint32
	Total uint64
}

const keysN = 50000

func buildKeys(n int) []string {
	keys := make([]string, n)
	for i := range keys {
		keys[i] = "cart:" + strconv.Itoa(i)
	}
	return keys
}

func rssKiB() int64 {
	data, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0
	}
	for _, line := range splitLines(string(data)) {
		if len(line) > 6 && line[:6] == "VmRSS:" {
			var v int64
			fmt.Sscanf(line[6:], "%d", &v)
			return v
		}
	}
	return 0
}

func splitLines(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return out
}

func bench(threads, seconds int) {
	keys := buildKeys(keysN)
	// The keys a lookup uses are a **separate copy** of the same text.
	//
	// Without this the comparison is not one. Go compares two strings by
	// checking their data pointers first, and a benchmark that looks up with
	// the very string object it stored hits that shortcut on every probe — so
	// the key comparison costs nothing and the map looks faster than it is
	// against anything that has to compare bytes. A real lookup key is built
	// from a request, not fished out of the array that filled the cache.
	// The other side stores its key in a ring and compares bytes every time,
	// with no shortcut available to it.
	lookup := make([]string, len(keys))
	for i, k := range keys {
		lookup[i] = string([]byte(k))
	}
	page := make([]byte, 512)
	for i := range page {
		page[i] = 'p'
	}
	pageStr := string(page)

	type row struct {
		name string
		work func(c *cache.Cache, k string, n int) bool
		warm func(c *cache.Cache, k string)
	}
	rows := []row{
		{"get_flat in cache", nil, nil}, // filled below with a small span
		{"get_flat", nil, nil},
		{"put_flat", nil, nil},
		{"mixed_flat", nil, nil},
		{"get_page", nil, nil},
		{"mixed_page", nil, nil},
	}
	_ = rows

	run := func(label string, span int, kind string) {
		c := cache.New(cache.NoExpiration, cache.NoExpiration)
		// Warm only what this row reads, for the reason the other side does.
		for _, k := range keys[:span] {
			switch kind {
			case "flat", "mixed_flat", "put_flat":
				c.Set(k, Cart{1, 2, 3}, cache.NoExpiration)
			default:
				c.Set(k, pageStr, cache.NoExpiration)
			}
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
				for !stop.Load() {
					for n := 0; n < 512; n++ {
						k := lookup[rng.Intn(span)]
						switch kind {
						case "flat", "page":
							if _, ok := c.Get(k); ok {
								hits[t]++
							}
						case "put_flat":
							c.Set(k, Cart{1, 2, 3}, cache.NoExpiration)
						case "mixed_flat":
							if n%10 == 0 {
								c.Set(k, Cart{1, 2, 3}, cache.NoExpiration)
							} else if _, ok := c.Get(k); ok {
								hits[t]++
							}
						case "mixed_page":
							if n%10 == 0 {
								c.Set(k, pageStr, cache.NoExpiration)
							} else if _, ok := c.Get(k); ok {
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
		perS := float64(totalOps) / took.Seconds()
		ns := float64(took.Nanoseconds()) * float64(threads) / float64(totalOps)
		hitPct := 0.0
		if totalOps > 0 {
			hitPct = float64(totalHits) * 100 / float64(totalOps)
		}
		fmt.Printf("  %-20s %2d threads  %12.0f ops/s  %7.1f ns/op  hits %5.1f%%\n",
			label, threads, perS, ns, hitPct)
	}

	fmt.Println("what one operation costs (each row warmed first)")
	run("get_flat in cache", 2000, "flat")
	run("get_flat", keysN, "flat")
	run("put_flat", keysN, "put_flat")
	run("mixed_flat", keysN, "mixed_flat")
	run("get_page", keysN, "page")
	run("mixed_page", keysN, "mixed_page")
}

// What N entries cost to hold, read from outside the heap's own accounting:
// RSS is what the machine gives up, whoever asked for it.
func mem(entries int) {
	debug.SetGCPercent(100)
	runtime.GC()
	debug.FreeOSMemory()
	before := rssKiB()

	keys := buildKeys(entries)
	c := cache.New(cache.NoExpiration, cache.NoExpiration)
	for _, k := range keys {
		c.Set(k, Cart{1, 2, 3}, cache.NoExpiration)
	}

	runtime.GC()
	debug.FreeOSMemory()
	after := rssKiB()

	// Held so the collector cannot take it before it is weighed.
	if c.ItemCount() != entries {
		fmt.Printf("  (only %d of %d entries survived)\n", c.ItemCount(), entries)
	}
	fmt.Printf("  go-cache      %d entries   RSS %d KiB - %d KiB = %d KiB   %.1f bytes/entry\n",
		entries, after, before, after-before,
		float64(after-before)*1024/float64(entries))
	runtime.KeepAlive(c)
	runtime.KeepAlive(keys)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: bench <threads> <seconds> | mem <entries>")
		return
	}
	arg := func(i, def int) int {
		if len(os.Args) > i {
			v, err := strconv.Atoi(os.Args[i])
			if err == nil {
				return v
			}
		}
		return def
	}
	switch os.Args[1] {
	case "bench":
		bench(arg(2, 1), arg(3, 3))
	case "mem":
		mem(arg(2, 200000))
	case "others":
		benchOthers(arg(2, 1), arg(3, 3))
	case "othersmem":
		memOthers(arg(2, 200000))
	case "hitrate":
		hitrate()
	default:
		fmt.Println("unknown mode", os.Args[1])
	}
}
