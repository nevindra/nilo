"""Create the bucket the live tests and the benchmark both want, and fill it.

Signs its own requests, so there is no `boto3`, no `mc` and nothing to install:
the whole of SigV4 is forty lines and it is worth having a second
implementation of it in this repository anyway. `s3/sign.zig`'s tests check
against AWS's published vectors; this checks against a real server, and the
two of them disagreeing is a finding.

    python3 bench/s3_setup.py                    # the defaults below
    S3_ENDPOINT=http://127.0.0.1:9100 python3 bench/s3_setup.py
"""
import datetime
import hashlib
import hmac
import os
import sys
import urllib.request
import urllib.error

ENDPOINT = os.environ.get("S3_ENDPOINT", "http://127.0.0.1:9100").rstrip("/")
ACCESS_KEY = os.environ.get("S3_ACCESS_KEY", "niloadmin")
SECRET_KEY = os.environ.get("S3_SECRET_KEY", "nilosecret123")
REGION = os.environ.get("S3_REGION", "us-east-1")
BUCKET = os.environ.get("S3_BUCKET", "nilo-test")

# What the benchmark reads. One object per size, because the interesting
# question is where the cost stops being per-call and starts being per-byte.
SIZES = {"1k": 1024, "64k": 64 * 1024, "1m": 1024 * 1024}


def sign_key(secret, date, region, service):
    k = hmac.new(("AWS4" + secret).encode(), date.encode(), hashlib.sha256).digest()
    k = hmac.new(k, region.encode(), hashlib.sha256).digest()
    k = hmac.new(k, service.encode(), hashlib.sha256).digest()
    return hmac.new(k, b"aws4_request", hashlib.sha256).digest()


def request(method, path, body=b"", content_type=None):
    """One signed request. `path` is already encoded and starts with `/`."""
    host = ENDPOINT.split("://", 1)[1]
    now = datetime.datetime.now(datetime.UTC)
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    date = stamp[:8]
    payload = hashlib.sha256(body).hexdigest()

    headers = {"host": host, "x-amz-content-sha256": payload, "x-amz-date": stamp}
    if content_type:
        headers["content-type"] = content_type

    names = sorted(headers)
    signed = ";".join(names)
    canonical = "\n".join([
        method, path, "",
        *(f"{n}:{headers[n].strip()}" for n in names), "",
        signed, payload,
    ])

    scope = f"{date}/{REGION}/s3/aws4_request"
    sts = "\n".join([
        "AWS4-HMAC-SHA256", stamp, scope,
        hashlib.sha256(canonical.encode()).hexdigest(),
    ])
    signature = hmac.new(
        sign_key(SECRET_KEY, date, REGION, "s3"), sts.encode(), hashlib.sha256
    ).hexdigest()

    headers["authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={ACCESS_KEY}/{scope},"
        f"SignedHeaders={signed},Signature={signature}"
    )

    req = urllib.request.Request(
        ENDPOINT + path, data=body or None, method=method, headers=headers
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return res.status, res.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def main():
    status, body = request("PUT", f"/{BUCKET}")
    if status not in (200, 409):
        print(f"could not create {BUCKET}: {status} {body[:200]!r}", file=sys.stderr)
        return 1
    print(f"bucket {BUCKET}: {'created' if status == 200 else 'already there'}")

    for name, size in SIZES.items():
        key = f"bench/{name}.bin"
        status, body = request(
            "PUT", f"/{BUCKET}/{key}", b"x" * size, "application/octet-stream"
        )
        if status != 200:
            print(f"could not put {key}: {status} {body[:200]!r}", file=sys.stderr)
            return 1
        print(f"  {key}: {size:,} bytes")

    # And read one back, so that a setup which "worked" but signs GETs wrong
    # fails here rather than inside a benchmark.
    status, body = request("GET", f"/{BUCKET}/bench/1k.bin")
    if status != 200 or len(body) != 1024:
        print(f"read-back failed: {status} {len(body)} bytes", file=sys.stderr)
        return 1
    print("read-back: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
