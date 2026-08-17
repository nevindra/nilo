// A WebSocket load generator, pointed at nilo or at gws without changing a
// byte of itself.
//
// The repo had no way to measure WebSocket throughput at all — `bench.sh` is
// wrk against HTTP, and `bench/ws_idle.py` opens sockets and then deliberately
// does nothing on them. So every WebSocket change so far has been made against
// a memory number with the throughput half unmeasured, which is exactly the
// hole this closes.
//
// The client is gws's own, on purpose: the same client drives both servers, so
// whatever it costs cancels out. What is measured is a round trip — write a
// message, wait for the echo — one at a time per connection, which is the
// shape a chat or an RPC-over-WebSocket actually has. Throughput is the sum
// over connections; the latency figures are of the round trip.
//
//	go build -o wsload .
//	./wsload -url ws://127.0.0.1:8789/ws/small -conns 64 -d 30s
package main

import (
	"flag"
	"fmt"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/lxzan/gws"
)

// One bucket per microsecond up to 20ms, then everything else in the tail.
// Round trips over loopback are single-digit microseconds and the tail is what
// a p99 is made of, so the resolution goes where the question is.
const buckets = 20000

type conn struct {
	socket *gws.Conn
	echoed chan struct{}
	hist   [buckets + 1]uint32
	ops    uint64
	errs   uint64
}

func (c *conn) OnOpen(socket *gws.Conn)  {}
func (c *conn) OnPing(socket *gws.Conn, payload []byte) {
	_ = socket.WritePong(payload)
}
func (c *conn) OnPong(socket *gws.Conn, payload []byte) {}

func (c *conn) OnClose(socket *gws.Conn, err error) {
	// Unblock whoever is waiting, or the run hangs on a server that hung up.
	select {
	case c.echoed <- struct{}{}:
	default:
	}
}

func (c *conn) OnMessage(socket *gws.Conn, message *gws.Message) {
	message.Close()
	c.echoed <- struct{}{}
}

func main() {
	url := flag.String("url", "ws://127.0.0.1:8789/ws/small", "WebSocket URL")
	conns := flag.Int("conns", 64, "concurrent connections")
	dur := flag.Duration("d", 30*time.Second, "how long to run")
	warm := flag.Duration("warmup", 5*time.Second, "warmup before counting")
	size := flag.Int("payload", 6, "message payload bytes")
	flag.Parse()

	payload := make([]byte, *size)
	for i := range payload {
		payload[i] = 'x'
	}

	cs := make([]*conn, 0, *conns)
	for i := 0; i < *conns; i++ {
		c := &conn{echoed: make(chan struct{}, 1)}
		socket, _, err := gws.NewClient(c, &gws.ClientOption{Addr: *url})
		if err != nil {
			fmt.Fprintf(os.Stderr, "connect %d: %v\n", i, err)
			os.Exit(1)
		}
		c.socket = socket
		go socket.ReadLoop()
		cs = append(cs, c)
	}

	var stop atomic.Bool
	var counting atomic.Bool
	var wg sync.WaitGroup
	for _, c := range cs {
		wg.Add(1)
		go func(c *conn) {
			defer wg.Done()
			for !stop.Load() {
				start := time.Now()
				if err := c.socket.WriteMessage(gws.OpcodeText, payload); err != nil {
					c.errs++
					return
				}
				<-c.echoed
				if counting.Load() {
					us := time.Since(start).Microseconds()
					if us < 0 {
						us = 0
					}
					if us >= buckets {
						us = buckets
					}
					c.hist[us]++
					c.ops++
				}
			}
		}(c)
	}

	time.Sleep(*warm)
	counting.Store(true)
	began := time.Now()
	time.Sleep(*dur)
	elapsed := time.Since(began)
	stop.Store(true)
	counting.Store(false)

	for _, c := range cs {
		_ = c.socket.WriteClose(1000, nil)
	}
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
	}

	var total, errs uint64
	merged := make([]uint32, buckets+1)
	for _, c := range cs {
		total += c.ops
		errs += c.errs
		for i, n := range c.hist {
			merged[i] += n
		}
	}
	if total == 0 {
		fmt.Println("no messages completed")
		os.Exit(1)
	}

	pct := func(p float64) string {
		want := uint64(float64(total) * p)
		var seen uint64
		for i, n := range merged {
			seen += uint64(n)
			if seen >= want {
				if i >= buckets {
					return ">20ms"
				}
				return fmt.Sprintf("%dus", i)
			}
		}
		return "?"
	}

	fmt.Printf("url        %s\n", *url)
	fmt.Printf("conns      %d, payload %d bytes, %s\n", *conns, *size, elapsed.Round(time.Millisecond))
	fmt.Printf("messages   %d\n", total)
	fmt.Printf("throughput %.0f msg/s\n", float64(total)/elapsed.Seconds())
	fmt.Printf("latency    p50 %s  p90 %s  p99 %s  p999 %s\n",
		pct(0.50), pct(0.90), pct(0.99), pct(0.999))
	if errs > 0 {
		fmt.Printf("errors     %d\n", errs)
	}
	_ = sort.Ints
}
