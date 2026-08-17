// gws — the Go WebSocket library nilo's per-socket memory was questioned
// against, driven by the same harness (`bench/ws_idle.py`) so the two sets of
// numbers are taken the same way on the same machine.
//
// Written to match what `bench/ws_server.zig` does and nothing more:
//
//   - Echo, and the idiomatic gws echo — `defer message.Close()` is what hands
//     the payload buffer back to gws's pool, and it is the whole mechanism
//     being compared against.
//   - No PermessageDeflate. nilo has no compression, and context takeover
//     would add a sliding window per connection, which is memory in the
//     direction nobody is arguing about.
//   - No ParallelEnabled. It adds a read queue per connection; nilo reads
//     serially on one fiber per connection, so leaving it off is the shape
//     that matches and the one that is kinder to gws's number.
//   - No SetDeadline. The harness runs nilo with IDLE_MS=0 for the same
//     reason: a keepalive closing sockets mid-measurement measures the
//     keepalive.
//
// `/gc` is here because Go's RSS includes a heap the collector has not
// returned yet, and reading it raw would charge gws for garbage rather than
// for connections. The harness reads RSS twice — once as it stands, once after
// this — so both readings are on the record.
package main

import (
	"log"
	"net/http"
	"runtime"
	"runtime/debug"

	"github.com/lxzan/gws"
)

type Handler struct {
	gws.BuiltinEventHandler
}

func (h *Handler) OnMessage(socket *gws.Conn, message *gws.Message) {
	defer message.Close()
	_ = socket.WriteMessage(message.Opcode, message.Bytes())
}

func main() {
	upgrader := gws.NewUpgrader(&Handler{}, &gws.ServerOption{})

	http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		socket, err := upgrader.Upgrade(w, r)
		if err != nil {
			return
		}
		go socket.ReadLoop()
	})

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("alive\n"))
	})

	// Collect and hand back what the heap is not using, so the harness can
	// report memory held as well as memory not yet returned.
	http.HandleFunc("/gc", func(w http.ResponseWriter, r *http.Request) {
		runtime.GC()
		debug.FreeOSMemory()
		_, _ = w.Write([]byte("ok\n"))
	})

	log.Fatal(http.ListenAndServe("127.0.0.1:8790", nil))
}
