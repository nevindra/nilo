#!/usr/bin/env python3
"""A release against the one before it, on every module, on the axes a shared machine can measure exactly.

ADR 242. Each ref named is exported with `git archive` into a tree of its
own and built with the same flags and its own cache (docs/history.md, "Give
every tree its own build cache"). Two things are built in each tree:

- the benchmark server, `nilo-hello` from `bench/main.zig`, which every tag
  since v0.2.0 carries and which is measured from outside;
- `bench/release/`, one program a module, copied in from *this* checkout
  and built against the tree's modules by path. An old tag never heard of
  it, which is the point: the harness of today measures a tag of last
  month. A program the tree's API cannot compile, or a module the tree does
  not export, is "n/a" for that ref and says why.

Every ref is measured beside the others in one run, interleaved, never
against a number quoted from an older run.

    python3 bench/release.py v0.6.0 main
    python3 bench/release.py main            # against the tag before it
    python3 bench/release.py --json out.json --markdown out.md v0.4.0 v0.5.0 v0.6.0

What is measured, each the way a shared runner can read it exactly:

- **Instructions an operation**, for throughput. A shared vCPU spreads req/s
  by more than the 10% ADR 017 allows, so each program runs under
  cachegrind on one CPU at two counts and the difference over the difference
  is one operation, with start, setup and stop taken out. For `http` the
  operation is one `GET /users/7` on a keep-alive connection to the server.
  It counts work, not time: a cache miss or a lock is invisible to it, which
  is why req/s is still measured on a box and written into `bench/result/`.
- **Allocations and bytes an operation**, counted by the harness over an
  arena reset after every operation. For `http` this axis is exact on every
  push already, in `test "the request path stays inside its allocation
  budget"`, and is not repeated here.
- **Bytes an idle connection**, for `http`: the marginal figure at 2,000
  the way `bench/result/http.md` takes 4,669, `(RSS at 2,000 - RSS at 1,000)
  / 1,000`, each connection served one `GET /health` first.
- **Stripped binary bytes**, `ReleaseFast` with `-Dstrip=true`: the server,
  and each module's program.

A change is called one only when the two refs' ranges do not overlap. The
CPU is pinned to `x86_64_v3` so the instruction count does not follow the
runner's model; the server still links glibc, whose string functions are
picked by CPU, so a figure is comparable with the figures of its own run and
the change is the record.
"""

import argparse
import contextlib
import json
import os
import platform
import re
import resource
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mem  # noqa: E402  open_one and rss_kb, so the idle figure is mem.py's method

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARNESS = os.path.join(ROOT, "bench", "release")
HOST, PORT = "127.0.0.1", 8787  # `listen(.{})`'s default, which every tag's bench/main.zig uses

# Every flag that decides the bytes. `-Dtarget` is also what lets the native
# link work on a host whose glibc was built by GCC 16 (CLAUDE.md).
FLAGS = ["-Doptimize=ReleaseFast", "-Dstrip=true", "-Dtarget=x86_64-linux-gnu", "-Dcpu=x86_64_v3"]

REQUEST = b"GET /users/7 HTTP/1.1\r\nHost: bench\r\nConnection: keep-alive\r\n\r\n"

# The module, what one operation is, and the two counts cachegrind runs it
# at: far enough apart that the difference is mostly operations, near enough
# that a run takes seconds. `bench/release/<module>.zig` says why each
# operation is the one.
MODULES = [
    ("http", "a `GET /users/7` answered with 1 KB of JSON", 1000, 5000),
    ("core", "a path param and a query value percent-decoded, a number read from a `Str`", 1000, 5000),
    ("id", "a v7 key made, printed and parsed back", 1000, 5000),
    ("config", "a five-field settings struct read from pairs", 1000, 5000),
    ("pw", "a password checked against its Argon2id hash at the default Cost", 2, 6),
    ("cache", "one `put` and one `get` of a flat value", 1000, 5000),
    ("jwt", "an RS256 token verified, its claims read", 20, 100),
    ("proto", "a 20-record logs request decoded into structs and written back", 200, 1000),
    ("fetch", "a GET on a pooled keep-alive connection to an upstream in the process", 1000, 5000),
    ("fetch_ws", "a 100-byte text message sent on an open WebSocket to an upstream in the process, and its echo received", 1000, 5000),
    ("job", "a job pushed onto `job.Memory`, claimed, run and marked done", 2000, 10000),
    ("job_zoned", "the next tick of `0 2 * * *` in Europe/Berlin, asked the afternoon before the clocks go forward", 20000, 100000),
    ("sql", "a row found by key on SQLite, `.in_fiber`", 1000, 21000),
    ("s3", "a GetObject signed with SigV4 from a stub in the process", 1000, 5000),
]

# The modules whose operation prints the wall clock. SigV4's `x-amz-date` pads
# every field under ten with a `0`, and a padded field is ~190 instructions a
# request more than an unpadded one, so `s3` measured in seconds :00 to :09
# reads 0.35% higher than the same binary a few seconds later. These are
# measured for every ref back to back inside one minute, from second 10, so
# each ref signs with the same digits.
CLOCKED = {"s3"}


def git(*args):
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout.strip()


def resolve(ref):
    """The commit `ref` names, trying `origin/` for a branch a CI checkout has only as a remote."""
    for name in (ref, f"origin/{ref}"):
        try:
            return git("rev-parse", "--verify", "--quiet", f"{name}^{{commit}}")
        except subprocess.CalledProcessError:
            continue
    raise SystemExit(f"{ref} names no commit here")


def previous_tag(ref):
    """The newest tag reachable from `ref` that is not `ref`'s own commit."""
    try:
        return git("describe", "--tags", "--abbrev=0", f"{resolve(ref)}^")
    except subprocess.CalledProcessError:
        raise SystemExit(f"no tag comes before {ref}; name the ref to measure it against")


def zig_build(cwd, steps, tree):
    """`zig build steps…` in `cwd`, into the tree's `out`; the first error line on failure."""
    out = subprocess.run(
        ["zig", "build", *steps, *FLAGS,
         "--cache-dir", os.path.join(tree, ".zig-cache"), "-p", os.path.join(tree, "out")],
        cwd=cwd, capture_output=True, text=True,
    )
    if out.returncode == 0:
        return None
    for line in out.stderr.splitlines():
        if "error:" in line:
            return line.strip()
    return f"zig build {' '.join(steps)} exited with {out.returncode}"


def build(ref, commit, work):
    """The tree for `commit`, and every binary it could build: {module: path or error}."""
    tree = os.path.join(work, commit[:12])
    if not os.path.isdir(tree):
        os.makedirs(tree)
        archive = subprocess.Popen(["git", "archive", commit], cwd=ROOT, stdout=subprocess.PIPE)
        subprocess.run(["tar", "-x", "-C", tree], stdin=archive.stdout, check=True)
        if archive.wait() != 0:
            raise SystemExit(f"git archive {ref} failed")
    # Copied afresh every time, so a kept `--work` measures today's harness.
    harness = os.path.join(tree, "bench", "release-harness")
    shutil.rmtree(harness, ignore_errors=True)
    shutil.copytree(HARNESS, harness, ignore=shutil.ignore_patterns(".zig-cache", "zig-out"))
    built = {}
    bin_dir = os.path.join(tree, "out", "bin")
    # v0.1.0 has no `bench/main.zig`, and a tree that cannot build its server
    # is that tree's "n/a" for `http` rather than the end of the run.
    server = os.path.join(bin_dir, "nilo-hello")
    with contextlib.suppress(FileNotFoundError):
        os.remove(server)
    error = zig_build(tree, ["install"], tree)
    if error is None and not os.path.exists(server):
        error = "this ref installs no nilo-hello (it has no bench/main.zig)"
    built["http"] = {"error": error} if error else server
    # Every program in one `zig build`, so they compile side by side and the
    # nilo build is configured once rather than once a module; a program that
    # did not land is built again on its own, which is cached up to its
    # failure, for the error to report.
    names = [name for name, *_ in MODULES[1:]]
    for name in names:
        with contextlib.suppress(FileNotFoundError):
            os.remove(os.path.join(bin_dir, f"nilo-release-{name}"))
    print(f"  {ref}: {' '.join(names)}", file=sys.stderr)
    zig_build(harness, names, tree)
    for name in names:
        path = os.path.join(bin_dir, f"nilo-release-{name}")
        built[name] = path if os.path.exists(path) else {"error": zig_build(harness, [name], tree)}
    return built


def contents(path):
    with open(path, "rb") as f:
        return f.read()


def port_is_free():
    try:
        socket.create_connection((HOST, PORT), timeout=0.2).close()
    except OSError:
        return True
    return False


@contextlib.contextmanager
def serving(cmd, log):
    """The server started, with a connection to it once it listens; stopped by SIGTERM after.

    A measurement that fails part-way leaves no server behind holding the port:
    whatever happens inside, the process is killed on the way out.
    """
    if not port_is_free():
        raise SystemExit(f"something is already listening on {PORT}")
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=log)
    try:
        # Under valgrind a start takes seconds; the bound is what keeps a
        # server that never listens from hanging the run.
        deadline = time.monotonic() + 120
        while True:
            if proc.poll() is not None:
                raise SystemExit(f"{cmd[-1]} exited with {proc.returncode} before listening")
            try:
                s = socket.create_connection((HOST, PORT), timeout=1)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise SystemExit(f"{cmd[-1]} did not listen on {PORT} within 120 s")
                time.sleep(0.05)
        yield proc, s
        stop(proc)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


def stop(proc):
    proc.send_signal(signal.SIGTERM)
    try:
        if proc.wait(timeout=60) != 0:
            raise SystemExit(f"the server exited with {proc.returncode} on SIGTERM")
    except subprocess.TimeoutExpired:
        raise SystemExit("the server did not stop within 60 s of SIGTERM (ADR 077)")
    deadline = time.monotonic() + 10
    while not port_is_free():
        if time.monotonic() > deadline:
            raise SystemExit(f"port {PORT} still answers 10 s after the server exited")
        time.sleep(0.05)


def served(s):
    """Read one whole response, which has a `Content-Length`."""
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            raise SystemExit("the server closed the connection")
        buf += chunk
        end = buf.find(b"\r\n\r\n")
        if end < 0:
            continue
        length = re.search(rb"(?im)^content-length: *(\d+)", buf[:end])
        if length is None:
            raise SystemExit("a response without a Content-Length")
        if len(buf) >= end + 4 + int(length.group(1)):
            return


def cachegrind(work):
    out = os.path.join(work, "cachegrind.out")
    return out, ["taskset", "-c", "0", "valgrind", "--tool=cachegrind", "--cache-sim=no",
                 f"--cachegrind-out-file={out}"]


def summary(out):
    with open(out) as f:
        for line in f:
            if line.startswith("summary:"):
                return int(line.split()[1])
    raise SystemExit(f"no summary in {out}")


def server_instructions(binary, n, work):
    """Every instruction the server ran from start to stop, serving `n` requests."""
    out, cmd = cachegrind(work)
    with open(os.path.join(work, "valgrind.log"), "w") as log, serving(cmd + [binary], log) as (_, s):
        with s:
            for _ in range(n):
                s.sendall(REQUEST)
                served(s)
    return summary(out)


def program_instructions(binary, n, work):
    out, cmd = cachegrind(work)
    run = subprocess.run(cmd + [binary, str(n)], capture_output=True, text=True, timeout=600)
    if run.returncode != 0:
        raise SystemExit(f"{binary} {n} exited with {run.returncode} under valgrind:\n{run.stderr[-2000:]}")
    return summary(out)


def allocations(binary, few, many):
    """Allocations and bytes an operation, from the harness's own line.

    The difference over the difference, as for instructions: an arena with no
    capacity kept yet makes the first operation allocate more than the rest.
    """
    totals = []
    for n in (few, many):
        run = subprocess.run([binary, str(n)], capture_output=True, text=True, timeout=600)
        if run.returncode != 0:
            raise SystemExit(f"{binary} {n} exited with {run.returncode}:\n{run.stderr[-2000:]}")
        # The harness's line, not merely the last: `deinit` runs after it is
        # printed, and a module may say something on the way down.
        line = next((l for l in reversed(run.stderr.splitlines()) if l.startswith('{"n":')), None)
        if line is None:
            raise SystemExit(f"{binary} {n} printed no harness line:\n{run.stderr[-2000:]}")
        totals.append(json.loads(line))
    n = many - few
    return (totals[1]["allocs"] - totals[0]["allocs"]) / n, (totals[1]["bytes"] - totals[0]["bytes"]) / n


def idle_bytes(binary, settle, work):
    rss, held = [], []
    with open(os.path.join(work, "server.log"), "w") as f, serving(["taskset", "-c", "0", binary], f) as (proc, probe):
        probe.close()
        try:
            for want in (1000, 2000):
                while len(held) < want:
                    held.append(mem.open_one(HOST, PORT, "/health", 10.0))
                time.sleep(settle)
                rss.append(mem.rss_kb(proc.pid))
        finally:
            for s in held:
                s.close()
    return (rss[1] - rss[0]) * 1024 / 1000


def inside_one_minute(measure, budget_s=40):
    """`measure()`, run where every ref reads the same clock digits.

    Started at second 10 of a minute at the earliest, and run again if it did
    not finish inside that minute: two refs on either side of a minute or of
    second :00 would be signing different text.
    """
    while True:
        now = time.gmtime()
        if not 10 <= now.tm_sec <= 60 - budget_s:
            time.sleep(0.2)
            continue
        result = measure()
        end = time.gmtime()
        if end.tm_min == now.tm_min and end.tm_hour == now.tm_hour:
            return result
        print("  the clock turned a minute mid-measurement; again", file=sys.stderr)


def machine():
    cpu = "unknown"
    with open("/proc/cpuinfo") as f:
        for line in f:
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break

    def tool(*cmd):
        return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()

    return {
        "cpu": cpu,
        "cpus": os.cpu_count(),
        "kernel": platform.release(),
        "zig": tool("zig", "version"),
        "valgrind": tool("valgrind", "--version"),
    }


def change(base, now):
    """The change from one list of runs to another, in words."""
    was, is_ = sum(base) / len(base), sum(now) / len(now)
    if was == is_:
        return "unchanged"
    if min(now) <= max(base) and min(base) <= max(now):
        return "inside the spread"
    if was == 0:
        return f"{is_ - was:+,.0f}"
    return f"{is_ - was:+,.0f}, {(is_ - was) / was * 100:+.2f}%"


def figure(runs):
    lo, hi = min(runs), max(runs)
    return f"{lo:,.0f}" if round(lo) == round(hi) else f"{lo:,.0f}–{hi:,.0f}"


def table(result, axis, title, which=None):
    refs = result["refs"]
    lines = [
        f"### {title}",
        "",
        "| module | " + " | ".join(f"{r['ref']} `{r['commit'][:7]}`" for r in refs) + " |",
        "|---|" + "---|" * len(refs),
    ]
    for name, *_ in MODULES:
        if which and name not in which:
            continue
        cells, before = [], None
        for r in refs:
            m = r["modules"][name]
            if "error" in m:
                cells.append("n/a")
                before = None
                continue
            runs = m[axis]
            cells.append(figure(runs) if before is None else f"{figure(runs)} ({change(before, runs)})")
            before = runs
        lines.append(f"| {name} | " + " | ".join(cells) + " |")
    return lines


def markdown(result):
    m = result["machine"]
    lines = table(result, "instructions", "Instructions an operation")
    lines += [""] + table(result, "allocs", "Allocations an operation", [n for n, *_ in MODULES[1:]])
    lines += [""] + table(result, "alloc_bytes", "Bytes allocated an operation", [n for n, *_ in MODULES[1:]])
    lines += [""] + table(result, "binary_bytes", "Stripped binary bytes")
    lines += [""] + table(result, "idle_bytes", "Bytes an idle connection", ["http"])
    lines += ["", "### What each operation is", "", "| module | one operation | counts |", "|---|---|---|"]
    lines += [f"| {name} | {what} | {few:,} and {many:,} |" for name, what, few, many in MODULES]
    # One line a ref and reason, because a harness that cannot be configured
    # against a ref fails every program with the same words.
    missing = []
    for r in result["refs"]:
        reasons = {}
        for name, *_ in MODULES:
            if "error" in r["modules"][name]:
                reasons.setdefault(r["modules"][name]["error"], []).append(f"`{name}`")
        missing += [f"- {', '.join(names)} at {r['ref']}: {why}" for why, names in reasons.items()]
    if missing:
        lines += ["", "### Not measured", ""] + missing
    same = [
        f"- {r['ref']}: " + ", ".join(f"`{name}` (as {other})" for name, other in r["same_binary_as"].items())
        for r in result["refs"] if r.get("same_binary_as")
    ]
    if same:
        lines += ["", "### Built byte-identical to an earlier ref", ""] + same
    lines += [
        "",
        f"Measured on {m['cpu']} ({m['cpus']} CPUs), Linux {m['kernel']}, Zig {m['zig']}, "
        f"{m['valgrind']}, {result['rounds']} interleaved rounds, a range where they differed. "
        "A change in brackets is against the column to its left, and reads \"inside the spread\" "
        "when the two ranges overlap. How to read it: ADR 242.",
    ]
    return "\n".join(lines) + "\n"


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("refs", nargs="+", help="oldest first; one ref alone is measured against the tag before it")
    p.add_argument("--rounds", type=int, default=2)
    p.add_argument("--settle", type=float, default=2.0, help="seconds before each RSS read, as mem.py")
    p.add_argument("--only", help="a comma-separated list of modules to measure, for trying one out")
    p.add_argument("--work", help="where the trees are built; a temporary directory, removed after, by default")
    p.add_argument("--json")
    p.add_argument("--markdown")
    args = p.parse_args()

    if platform.machine() != "x86_64":
        raise SystemExit("the build pins x86_64_v3, so this runs on x86_64 only")
    for tool in ("zig", "valgrind", "taskset"):
        if shutil.which(tool) is None:
            raise SystemExit(f"{tool} is not installed")
    # Every module this checkout ships has a program, or the report would be
    # silent about one; `dev` is a tool and not a module (ADR 190).
    with open(os.path.join(ROOT, "build.zig")) as f:
        shipped = re.search(r"const shipped_roots = \[_\]\[\]const u8\{([^}]*)\}", f.read())
    unmeasured = set(re.findall(r'"(\w+)"', shipped.group(1))) - {"dev"} - {m[0] for m in MODULES}
    if unmeasured:
        raise SystemExit(f"no program in bench/release/ for {', '.join(sorted(unmeasured))}; add one and a row in MODULES")
    if args.only:
        wanted = set(args.only.split(","))
        MODULES[:] = [m for m in MODULES if m[0] in wanted or m[0] == "http"]

    refs = args.refs if len(args.refs) > 1 else [previous_tag(args.refs[0]), args.refs[0]]
    commits = [resolve(r) for r in refs]

    # The server's descriptors are inherited from here: 2,000 sockets each
    # side is past a default soft limit of 1,024.
    _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = 1 << 16 if hard == resource.RLIM_INFINITY else hard
    if want < 4100:
        raise SystemExit(f"the descriptor limit is {hard}, and an idle-connection reading needs 4,100")
    resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))

    work = args.work or tempfile.mkdtemp(prefix="nilo-release-")
    os.makedirs(work, exist_ok=True)
    rows, binaries = [], []
    try:
        for ref, commit in zip(refs, commits):
            print(f"building {ref} ({commit[:7]})", file=sys.stderr)
            built = build(ref, commit, work)
            row = {"ref": ref, "commit": commit, "modules": {}}
            for name, *_ in MODULES:
                if isinstance(built[name], dict):
                    row["modules"][name] = built[name]
                    continue
                content = contents(built[name])
                row["modules"][name] = {"binary_bytes": [len(content)], "instructions": []}
                if name == "http":
                    row["modules"][name]["idle_bytes"] = []
                for earlier, earlier_built in zip(rows, binaries):
                    path = earlier_built.get(name)
                    if isinstance(path, str) and contents(path) == content:
                        row.setdefault("same_binary_as", {})[name] = earlier["ref"]
            rows.append(row)
            binaries.append(built)

        for row, built in zip(rows, binaries):
            for name, *_ in MODULES[1:]:
                m = row["modules"][name]
                if "error" not in m:
                    _, _, few, many = next(x for x in MODULES if x[0] == name)
                    allocs, nbytes = allocations(built[name], few, many)
                    m["allocs"], m["alloc_bytes"] = [allocs], [nbytes]

        def per_operation(name, binary, few, many):
            count = server_instructions if name == "http" else program_instructions
            return (count(binary, many, work) - count(binary, few, work)) / (many - few)

        for round_ in range(args.rounds):
            for row, built in zip(rows, binaries):
                for name, _, few, many in MODULES:
                    m = row["modules"][name]
                    if "error" in m or name in CLOCKED:
                        continue
                    print(f"round {round_ + 1}: {row['ref']} {name}", file=sys.stderr)
                    m["instructions"].append(per_operation(name, built[name], few, many))
                    if name == "http":
                        m["idle_bytes"].append(idle_bytes(built[name], args.settle, work))
            for name, _, few, many in MODULES:
                if name not in CLOCKED:
                    continue
                print(f"round {round_ + 1}: {name}, every ref inside one minute", file=sys.stderr)
                todo = [(row, built) for row, built in zip(rows, binaries) if "error" not in row["modules"][name]]
                counts = inside_one_minute(lambda: [per_operation(name, b[name], few, many) for _, b in todo])
                for (row, _), count in zip(todo, counts):
                    row["modules"][name]["instructions"].append(count)
    finally:
        if not args.work:
            shutil.rmtree(work, ignore_errors=True)

    result = {"machine": machine(), "rounds": args.rounds, "refs": rows}
    text = markdown(result)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(result, f, indent=2)
            f.write("\n")
    if args.markdown:
        with open(args.markdown, "w") as f:
            f.write(text)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
