// Go's answer to the seven routes in bench/s3_server.zig, on net/http with
// aws-sdk-go-v2.
//
// The comparison is only worth anything if both sides are allowed to be
// themselves, so this is the SDK as a Go service would use it: one client, one
// presign client, credentials that do not expire, path style for MinIO.
//
// The one thing tuned away from its default is the connection pool.
// http.Transport ships with MaxIdleConnsPerHost = 2, which would cap this at
// two calls to the store in flight and report the queue as Go's speed. nilo's
// gate is 4096; this is 1024, which is past what the load generator can fill
// either way. Anything else left alone is a default on purpose.
package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

const (
	bucket  = "nilo-test"
	oneK    = "bench/1k.bin"
	sixtyK  = "bench/64k.bin"
	oneM    = "bench/1m.bin"
	octets  = "application/octet-stream"
	filler  = 'x'
	presign = 900 * time.Second
)

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// Whatever bytes a route answers with, framed with an explicit length.
//
// Without the Content-Length, net/http picks chunked for the megabyte and the
// wire bytes stop matching everybody else's — which is exactly how Node was
// caught in the sibling benchmark, twelve bytes of framing nobody else sent.
func send(w http.ResponseWriter, contentType string, body []byte) {
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	w.Write(body)
}

func main() {
	endpoint := env("S3_ENDPOINT", "http://127.0.0.1:9100")

	// The pool, and the reason it is here rather than left alone: see the
	// file comment. Everything else on this transport is the default.
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConns = 4096
	transport.MaxIdleConnsPerHost = 1024
	transport.MaxConnsPerHost = 0

	cfg := aws.Config{
		Region: env("S3_REGION", "us-east-1"),
		Credentials: credentials.NewStaticCredentialsProvider(
			env("S3_ACCESS_KEY", "niloadmin"),
			env("S3_SECRET_KEY", "nilosecret123"),
			"",
		),
		HTTPClient: &http.Client{Transport: transport},
	}
	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.BaseEndpoint = aws.String(endpoint)
		o.UsePathStyle = true
	})
	presigner := s3.NewPresignClient(client)

	// The control payloads, allocated and filled **per request**, because that
	// is what the routes they are subtracted from do.
	//
	// The first version of this built them once and reused them, and it was
	// wrong in a way that flattered whichever candidate did it: `/o/1m` sizes a
	// buffer from `content-length` and fills it every time, so a control that
	// hands out the same slice repeatedly is not the same work minus the object
	// store — it is less work. Measured, that gap was 2.2x at a megabyte, which
	// is larger than any difference the benchmark exists to find.
	warm := func(n int) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			body := make([]byte, n)
			for i := range body {
				body[i] = filler
			}
			send(w, octets, body)
		}
	}

	object := func(key string) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			out, err := client.GetObject(r.Context(), &s3.GetObjectInput{
				Bucket: aws.String(bucket),
				Key:    aws.String(key),
			})
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadGateway)
				return
			}
			defer out.Body.Close()

			// Sized from Content-Length and filled once, which is what nilo
			// does: it reads the length, refuses anything over the bucket's
			// ceiling, and then makes exactly one allocation.
			body := make([]byte, aws.ToInt64(out.ContentLength))
			if _, err := io.ReadFull(out.Body, body); err != nil {
				http.Error(w, err.Error(), http.StatusBadGateway)
				return
			}
			send(w, octets, body)
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		send(w, "text/plain", []byte("alive\n"))
	})
	mux.HandleFunc("GET /warm/1k", warm(1<<10))
	mux.HandleFunc("GET /warm/1m", warm(1<<20))
	mux.HandleFunc("GET /o/1k", object(oneK))
	mux.HandleFunc("GET /o/64k", object(sixtyK))
	mux.HandleFunc("GET /o/1m", object(oneM))
	mux.HandleFunc("GET /presign", func(w http.ResponseWriter, r *http.Request) {
		signed, err := presigner.PresignGetObject(r.Context(), &s3.GetObjectInput{
			Bucket: aws.String(bucket),
			Key:    aws.String(oneK),
		}, s3.WithPresignExpires(presign))
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		send(w, "text/plain", []byte(signed.URL))
	})

	// One warm call before the port opens, so the first request the load
	// generator sends is not the one that dials the store and resolves the
	// region. nilo does the same thing in `nilo_start`.
	if _, err := client.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(oneK),
	}); err != nil {
		fmt.Fprintf(os.Stderr, "could not reach %s: %v\n", endpoint, err)
		os.Exit(1)
	}

	server := &http.Server{Addr: ":8811", Handler: mux}
	ln, err := net.Listen("tcp", server.Addr)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	server.Serve(ln)
}
