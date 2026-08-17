//! Rust's answer to the seven routes in `bench/s3_server.zig`, on axum with
//! the official `aws-sdk-s3`.
//!
//! Same rule as the Go and Bun candidates: the SDK as a service would use it,
//! one client shared across every request, static credentials, path style for
//! MinIO. Nothing is hand-rolled — the point of the comparison is what each
//! ecosystem's ordinary answer costs, not what its fastest possible answer
//! costs.
//!
//! The two `/warm` routes carry no S3 at all. They are what makes the table
//! mean something: axum and nilo are not the same speed at answering a
//! megabyte, and without a floor to subtract, a comparison of four S3 clients
//! is mostly a comparison of four HTTP servers.

use std::sync::Arc;
use std::time::Duration;

use aws_credential_types::Credentials;
use aws_sdk_s3::presigning::PresigningConfig;
use aws_sdk_s3::{config::Region, Client, Config};
use axum::body::Bytes;
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::{routing::get, Router};

const BUCKET: &str = "nilo-test";
const ONE_K: &str = "bench/1k.bin";
const SIXTY_FOUR_K: &str = "bench/64k.bin";
const ONE_M: &str = "bench/1m.bin";
const OCTETS: &str = "application/octet-stream";
const FILLER: u8 = b'x';

struct State {
    client: Client,
}

/// A control payload, allocated and filled **per request**, because that is
/// what the route it is subtracted from does.
///
/// The first version of this held two `Bytes` on the shared state and cloned
/// them, which on `Bytes` is a refcount bump and no allocation at all — the
/// most flattering of the four candidates' mistakes and the same mistake in
/// kind. `/o/1m` sizes a buffer from `content-length` and fills it every time,
/// so a control that hands out a pointer to the same megabyte is not the same
/// work minus the object store. Measured against nilo, which never had the
/// bug, the gap at a megabyte was larger than anything the benchmark exists to
/// find.
fn warm(n: usize) -> Response {
    send(OCTETS, Bytes::from(vec![FILLER; n]))
}

fn env(name: &str, fallback: &str) -> String {
    std::env::var(name)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| fallback.to_string())
}

/// Bytes out with an explicit content type. axum sets Content-Length from a
/// `Bytes` body, so the framing matches everybody else's without being asked.
fn send(content_type: &'static str, body: Bytes) -> Response {
    ([(header::CONTENT_TYPE, content_type)], body).into_response()
}

async fn object(state: Arc<State>, key: &'static str) -> Response {
    match state
        .client
        .get_object()
        .bucket(BUCKET)
        .key(key)
        .send()
        .await
    {
        // `collect` is the SDK's own way of holding a body whole, and it
        // sizes from Content-Length the way nilo does — one allocation, not a
        // growing buffer.
        Ok(out) => match out.body.collect().await {
            Ok(data) => send(OCTETS, data.into_bytes()),
            Err(e) => (StatusCode::BAD_GATEWAY, e.to_string()).into_response(),
        },
        Err(e) => (StatusCode::BAD_GATEWAY, e.to_string()).into_response(),
    }
}

#[tokio::main]
async fn main() {
    let endpoint = env("S3_ENDPOINT", "http://127.0.0.1:9100");

    let config = Config::builder()
        .region(Region::new(env("S3_REGION", "us-east-1")))
        .endpoint_url(&endpoint)
        .force_path_style(true)
        .credentials_provider(Credentials::new(
            env("S3_ACCESS_KEY", "niloadmin"),
            env("S3_SECRET_KEY", "nilosecret123"),
            None,
            None,
            "bench",
        ))
        .behavior_version(aws_sdk_s3::config::BehaviorVersion::latest())
        .build();

    let client = Client::from_conf(config);

    // One warm call before the port opens, so the first request the load
    // generator sends is not the one that dials the store.
    if let Err(e) = client
        .get_object()
        .bucket(BUCKET)
        .key(ONE_K)
        .send()
        .await
    {
        eprintln!("could not reach {endpoint}: {e}");
        std::process::exit(1);
    }

    let state = Arc::new(State { client });

    let app = Router::new()
        .route("/health", get(|| async { "alive\n" }))
        .route("/warm/1k", get(|| async { warm(1 << 10) }))
        .route("/warm/1m", get(|| async { warm(1 << 20) }))
        .route("/o/1k", {
            let s = state.clone();
            get(move || object(s.clone(), ONE_K))
        })
        .route("/o/64k", {
            let s = state.clone();
            get(move || object(s.clone(), SIXTY_FOUR_K))
        })
        .route("/o/1m", {
            let s = state.clone();
            get(move || object(s.clone(), ONE_M))
        })
        .route("/presign", {
            let s = state.clone();
            get(move || {
                let s = s.clone();
                async move {
                    let cfg = PresigningConfig::expires_in(Duration::from_secs(900)).unwrap();
                    match s
                        .client
                        .get_object()
                        .bucket(BUCKET)
                        .key(ONE_K)
                        .presigned(cfg)
                        .await
                    {
                        Ok(signed) => send(
                            "text/plain",
                            Bytes::from(signed.uri().to_string()),
                        ),
                        Err(e) => {
                            (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response()
                        }
                    }
                }
            })
        });

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8812").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
