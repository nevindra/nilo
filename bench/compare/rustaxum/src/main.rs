// Rust + axum — the ceiling reference.
use std::sync::LazyLock;

use axum::{
    extract::Path,
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use serde::Serialize;

static BIO: LazyLock<String> =
    LazyLock::new(|| "A systems nerd who writes Zig before breakfast. ".repeat(19));

const MAX_ID: u32 = 1_000_000;

#[derive(Serialize)]
struct User<'a> {
    id: u32,
    name: &'a str,
    email: &'a str,
    bio: &'a str,
}

async fn get_user(Path(raw): Path<String>) -> Response {
    let cors = (header::ACCESS_CONTROL_ALLOW_ORIGIN, "*");

    let id: u32 = match raw.parse() {
        Ok(v) if v > 0 && v <= MAX_ID => v,
        _ => {
            return (
                StatusCode::NOT_FOUND,
                [cors, (header::CONTENT_TYPE, "text/plain")],
                format!("no user {raw}"),
            )
                .into_response()
        }
    };

    // Serialised per request, like nilo.
    let body = serde_json::to_string(&User {
        id,
        name: "Routed Tester",
        email: "tester@example.dev",
        bio: &BIO,
    })
    .unwrap();

    (
        [cors, (header::CONTENT_TYPE, "application/json")],
        body,
    )
        .into_response()
}

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route("/users/{id}", get(get_user))
        .route("/health", get(|| async { "alive\n" }));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:8805").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
