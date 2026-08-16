// Go net/http — the stdlib baseline. Go 1.22+ ServeMux does method+wildcard
// routing, so this is a real routed GET rather than a hand-rolled match.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
)

type User struct {
	ID    uint32 `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
	Bio   string `json:"bio"`
}

var bio = strings.Repeat("A systems nerd who writes Zig before breakfast. ", 19)

const maxID = 1000000

func main() {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /users/{id}", func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Access-Control-Allow-Origin", "*")

		id, err := strconv.ParseUint(r.PathValue("id"), 10, 32)
		if err != nil || id == 0 || id > maxID {
			http.Error(w, "no user "+r.PathValue("id"), http.StatusNotFound)
			return
		}

		// Serialised per request, like nilo — not a pre-rendered buffer.
		b, _ := json.Marshal(User{uint32(id), "Routed Tester", "tester@example.dev", bio})
		h.Set("Content-Type", "application/json")
		w.Write(b)
	})

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("alive\n"))
	})

	log.Fatal(http.ListenAndServe("127.0.0.1:8801", mux))
}
