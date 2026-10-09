#!/usr/bin/env python3
"""Refresh the time zone data `nilo_job` embeds (ADR 161).

    python3 -I job/tzdata/refresh.py                       # the latest IANA release, into job/tzdata
    python3 -I job/tzdata/refresh.py --release 2026e       # a named one
    python3 -I job/tzdata/refresh.py --out /path/to/dir    # for `-Dtzdata=/path/to/dir`

What it does, in order:

1. Downloads `tzdata<release>.tar.gz` and its detached signature from
   data.iana.org into a new temporary directory.
2. Verifies the signature with `gpg`, in a throwaway keyring that holds only
   the key pinned below (fetched from keys.openpgp.org by its fingerprint), and
   checks the signer's fingerprint is that key. Without gpg it refuses, unless
   `--sha256 <hex>` names the tarball's digest.
3. Compiles the data with the host's `zic` as `zic -b slim -r @<cutoff>`: the
   "slim" form, which stores only the rules that cannot be derived from the
   footer, and a cut-off, because a schedule only ever asks about moments after
   today, so everything before it is history that would cost bytes.
4. Keeps one TZif file per **Zone** and no file per **Link**, and writes
   `tzdata.zig`: the release, the cut-off, every name, and `lookup`, which
   `@embedFile`s one file chosen while compiling. A zone nobody names costs the
   program nothing.

`--out` has to be a directory this script owns: it is emptied first. The result
is what `-Dtzdata=<dir>` takes, so a short-notice rule change (Kazakhstan 2024
gave 29 days, Manitoba 2026 about 33) does not wait for a nilo release.

Python's standard library and `zic` and `gpg` on the PATH; nothing else.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

BASE = "https://data.iana.org/time-zones/releases/"

# Paul Eggert's key, which signs every release (the tz mailing list publishes
# the same fingerprint). The signature is only worth what this pin is worth, so
# a different signer is a failure.
SIGNER = "7E3792A9D8ACF7D633BC1588ED97E90E62AA7E34"

# 2026-01-01T00:00:00Z. Moved by hand when a refresh is done in a later year:
# the cut-off should be shortly before the release date, never after it.
DEFAULT_CUTOFF = 1767225600

SOURCES = ["africa", "antarctica", "asia", "australasia", "europe", "northamerica", "southamerica", "etcetera", "backward"]


def get(url, dest):
    with urllib.request.urlopen(url, timeout=60) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f)


def latest_release():
    with urllib.request.urlopen(BASE, timeout=60) as r:
        page = r.read().decode()
    found = set(re.findall(r'tzdata(\d{4}[a-z])\.tar\.gz', page))
    return max(found, key=lambda v: (v[:4], v[4:]))


def verify(work, release, sha256):
    tar = os.path.join(work, f"tzdata{release}.tar.gz")
    digest = hashlib.sha256(open(tar, "rb").read()).hexdigest()
    if sha256:
        if digest != sha256.lower():
            sys.exit(f"tzdata{release}.tar.gz has sha256 {digest}, not the {sha256} asked for")
        return digest, "sha256 given on the command line"
    if not shutil.which("gpg"):
        sys.exit("gpg is not installed; install it, or pass --sha256 with a digest you trust")
    home = os.path.join(work, "gnupg")
    os.mkdir(home, 0o700)
    env = dict(os.environ, GNUPGHOME=home)
    subprocess.run(["gpg", "--batch", "--keyserver", "hkps://keys.openpgp.org", "--recv-keys", SIGNER],
                   check=True, env=env, capture_output=True)
    done = subprocess.run(["gpg", "--batch", "--status-fd", "1", "--verify", tar + ".asc", tar],
                          env=env, capture_output=True, text=True)
    valid = [l.split() for l in done.stdout.splitlines() if l.startswith("[GNUPG:] VALIDSIG")]
    if done.returncode != 0 or not valid or valid[0][-1] != SIGNER:
        sys.exit(f"the signature on tzdata{release}.tar.gz is not a good one from {SIGNER}:\n{done.stderr}")
    return digest, f"gpg signature by {SIGNER}"


def zones_and_links(src):
    zones, links = set(), {}
    for name in SOURCES:
        for line in open(os.path.join(src, name), encoding="utf-8"):
            line = line.split("#", 1)[0].split()
            if len(line) >= 2 and line[0] == "Zone":
                zones.add(line[1])
            elif len(line) >= 3 and line[0] == "Link":
                links[line[2]] = line[1]
    return zones, links


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--release", help="a release such as 2026e (default: the latest)")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--cutoff", type=int, default=DEFAULT_CUTOFF, help="Unix seconds; rules before it are dropped")
    ap.add_argument("--sha256", help="the tarball's digest, in place of a gpg check")
    ap.add_argument("--zic", default="zic")
    args = ap.parse_args()

    release = args.release or latest_release()
    work = tempfile.mkdtemp(prefix="nilo-tzdata-")
    try:
        tar = os.path.join(work, f"tzdata{release}.tar.gz")
        get(f"{BASE}tzdata{release}.tar.gz", tar)
        if not args.sha256:
            get(f"{BASE}tzdata{release}.tar.gz.asc", tar + ".asc")
        digest, how = verify(work, release, args.sha256)

        src = os.path.join(work, "src")
        os.mkdir(src)
        with tarfile.open(tar) as t:
            t.extractall(src, filter="data")
        if open(os.path.join(src, "version")).read().strip() != release:
            sys.exit("the tarball's version file does not name the release asked for")

        built = os.path.join(work, "zic")
        subprocess.run([args.zic, "-b", "slim", "-r", f"@{args.cutoff}", "-d", built, *SOURCES],
                       cwd=src, check=True)

        zones, links = zones_and_links(src)
        # A link to a link resolves to a zone; a link to nothing is a mistake
        # in the data and stops the refresh.
        def canonical(name):
            seen = set()
            while name not in zones:
                if name in seen or name not in links:
                    sys.exit(f"{name} is a link to nothing")
                seen.add(name)
                name = links[name]
            return name

        # `zic` writes a file for every name, link or not; only a zone's own is kept.
        out = os.path.abspath(args.out)
        tzif = os.path.join(out, "tzif")
        shutil.rmtree(tzif, ignore_errors=True)
        total = 0
        for z in sorted(zones):
            dest = os.path.join(tzif, z)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copyfile(os.path.join(built, z), dest)
            total += os.path.getsize(dest)

        table = {z: z for z in zones}
        table.update({l: canonical(l) for l in links})
        # Etc/UTC and friends are in `etcetera`; "factory" and "localtime" are not shipped.
        names = sorted(table)

        lines = [
            "//! Time zone data for `nilo_job` (ADR 161), generated by `refresh.py` in this directory.",
            "//! Do not edit: run it again.",
            "//!",
            f"//! Release {release}, compiled `zic -b slim -r @{args.cutoff}`: one TZif file per Zone",
            "//! under `tzif/`, none per Link. Which file a program embeds is chosen while it compiles",
            "//! (`lookup`), so a zone it never names is not in the binary.",
            "",
            "const std = @import(\"std\");",
            "",
            "/// The IANA release these files were compiled from. `job.tzdata_version`.",
            f"pub const version = \"{release}\";",
            "",
            "/// Unix seconds. Rules before it were left out, because a schedule only asks about moments after now.",
            f"pub const cutoff: i64 = {args.cutoff};",
            "",
            f"/// How the tarball was checked: {how}.",
            f"pub const tarball_sha256 = \"{digest}\";",
            "",
            "/// Every name a schedule may be given, zones and links, in byte order.",
            "pub const names = [_][]const u8{",
            *[f"    \"{n}\"," for n in names],
            "};",
            "",
            "/// The TZif bytes of the zone `name` is or links to, or null for a name that is neither.",
            "/// `name` is comptime so that only the one `@embedFile` taken is analysed.",
            "pub fn lookup(comptime name: []const u8) ?[]const u8 {",
            f"    @setEvalBranchQuota({len(names) * 200 + 10_000});",
            *[f"    if (comptime std.mem.eql(u8, name, \"{n}\")) return @embedFile(\"tzif/{table[n]}\");" for n in names],
            "    return null;",
            "}",
            "",
            "pub const Entry = struct { name: []const u8, bytes: []const u8 };",
            "",
            "/// Every zone with its bytes, for a test that reads them all. Nothing in a program refers to",
            "/// it, so it is never analysed there and none of its `@embedFile`s is taken.",
            "pub const all = [_]Entry{",
            *[f"    .{{ .name = \"{z}\", .bytes = @embedFile(\"tzif/{z}\") }}," for z in sorted(zones)],
            "};",
            "",
        ]
        with open(os.path.join(out, "tzdata.zig"), "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        print(f"tzdata {release}: {len(zones)} zones, {len(links)} links, {total} bytes in {tzif}; {how}")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
