//! moka and quick_cache under the same load nilo_cache is put under.
//!
//! These are the two caches a Rust program reaches for, and they answer the
//! question from the other side of it: both keep their entries on the heap and
//! bound a *count* (or a weight the caller invents), where nilo_cache bounds
//! bytes and copies. moka's replacement policy is the one this comparison is
//! really about — it is the Rust descendant of Caffeine, admission by LFU and
//! eviction by LRU, which is the strongest policy in this whole comparison.
//!
//!     cargo run --release -- bench <threads> <seconds>
//!     cargo run --release -- mem   <entries>
//!     cargo run --release -- hitrate
//!
//! The keys are built before the clock starts, the same as on every other
//! side: formatting a key inside a timed loop measures the formatter.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use rand::rngs::SmallRng;
use rand::{Rng, SeedableRng};

/// The same 24 bytes every other side stores.
type Cart = [u8; 24];

const KEYS_N: usize = 50_000;

fn cart() -> Cart {
    let mut b = [0u8; 24];
    b[0] = 1;
    b[8] = 2;
    b[12] = 3;
    b
}

fn build_keys(n: usize) -> Vec<String> {
    (0..n).map(|i| format!("cart:{}", i)).collect()
}

fn rss_kib() -> i64 {
    let s = match std::fs::read_to_string("/proc/self/status") {
        Ok(s) => s,
        Err(_) => return 0,
    };
    for line in s.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            for tok in rest.split_whitespace() {
                if let Ok(v) = tok.parse::<i64>() {
                    return v;
                }
            }
        }
    }
    0
}

/// One cache behind whichever of the two is being measured, so the driving
/// loop below is literally the same code for both.
trait Bench: Send + Sync {
    fn set(&self, key: &str, value: Cart);
    fn get(&self, key: &str) -> bool;
    fn name(&self) -> &'static str;
}

struct Moka(moka::sync::Cache<String, Cart>);

impl Bench for Moka {
    fn name(&self) -> &'static str {
        "moka"
    }
    fn set(&self, key: &str, value: Cart) {
        self.0.insert(key.to_owned(), value);
    }
    fn get(&self, key: &str) -> bool {
        self.0.get(key).is_some()
    }
}

struct Quick(quick_cache::sync::Cache<String, Cart>);

impl Bench for Quick {
    fn name(&self) -> &'static str {
        "quick_cache"
    }
    fn set(&self, key: &str, value: Cart) {
        self.0.insert(key.to_owned(), value);
    }
    fn get(&self, key: &str) -> bool {
        self.0.get(key).is_some()
    }
}

/// Both are given a capacity in entries, because that is what both bound. A
/// byte budget is not a thing either of them takes, which is the difference
/// the memory table below is there to price.
fn make(which: usize, entries: usize) -> Arc<dyn Bench> {
    match which {
        0 => Arc::new(Moka(
            moka::sync::Cache::builder().max_capacity(entries as u64).build(),
        )),
        _ => Arc::new(Quick(quick_cache::sync::Cache::new(entries))),
    }
}

fn bench(threads: usize, seconds: u64) {
    let keys = Arc::new(build_keys(KEYS_N));
    let value = cart();

    for which in 0..2 {
        for (label, write_every) in [("get_flat", 0usize), ("mixed_flat", 10usize)] {
            // Sized to hold the whole working set, the way the other sides are
            // given a budget that holds theirs.
            let cache = make(which, KEYS_N * 2);
            for k in keys.iter() {
                cache.set(k, value);
            }
            // moka's writes land through a queue that a later read drains, so
            // a benchmark that starts the clock immediately measures the
            // draining rather than the cache. One pass of reads settles it.
            for k in keys.iter() {
                cache.get(k);
            }

            let stop = Arc::new(AtomicBool::new(false));
            let ops = Arc::new(AtomicU64::new(0));
            let began = Instant::now();

            std::thread::scope(|s| {
                for t in 0..threads {
                    let cache = Arc::clone(&cache);
                    let keys = Arc::clone(&keys);
                    let stop = Arc::clone(&stop);
                    let ops = Arc::clone(&ops);
                    s.spawn(move || {
                        let mut rng = SmallRng::seed_from_u64(7 + t as u64);
                        let mut local: u64 = 0;
                        while !stop.load(Ordering::Relaxed) {
                            for n in 0..512usize {
                                let k = &keys[rng.gen_range(0..KEYS_N)];
                                if write_every != 0 && n % write_every == 0 {
                                    cache.set(k, value);
                                } else {
                                    std::hint::black_box(cache.get(k));
                                }
                                local += 1;
                            }
                        }
                        ops.fetch_add(local, Ordering::Relaxed);
                    });
                }
                std::thread::sleep(std::time::Duration::from_secs(seconds));
                stop.store(true, Ordering::Relaxed);
            });

            let took = began.elapsed();
            let n = ops.load(Ordering::Relaxed);
            println!(
                "  {:<12} {:<20} {:2} threads  {:12.0} ops/s  {:7.1} ns/op",
                cache.name(),
                label,
                threads,
                n as f64 / took.as_secs_f64(),
                took.as_nanos() as f64 * threads as f64 / n as f64,
            );
        }
    }
}

/// What N entries cost to hold, as RSS, the same question asked of every other
/// side. Neither of these takes a byte budget, so each is given a capacity of
/// exactly N and then weighed.
/// **One cache a process.** Measuring both in one run read the second as 0.0
/// bytes an entry: the allocator does not hand the first one's memory back, so
/// the second one's `before` was already at the first one's peak. `run.sh`
/// invokes this once per name.
fn mem(entries: usize, only: usize) {
    let keys = build_keys(entries);
    let value = cart();

    for which in only..only + 1 {
        let before = rss_kib();
        let cache = make(which, entries);
        for k in keys.iter() {
            cache.set(k, value);
        }
        // moka inserts through a queue; without draining it the count and the
        // memory are both understated.
        let mut live = 0usize;
        for k in keys.iter() {
            if cache.get(k) {
                live += 1;
            }
        }
        let after = rss_kib();
        println!(
            "  {:<12}    {} entries   RSS {} KiB - {} KiB = {} KiB   {:.1} bytes/entry   ({} retrievable = {:.1}%)",
            cache.name(),
            entries,
            after,
            before,
            after - before,
            (after - before) as f64 * 1024.0 / entries as f64,
            live,
            live as f64 * 100.0 / entries as f64,
        );
        std::hint::black_box(&cache);
    }
}

/// The number that decides whether a cache is worth its memory. Same trace
/// shape as the Zig and Go sides: Zipf 0.99, read-through, and the capacity
/// swept in entries rather than bytes because that is what these two take.
fn hitrate() {
    const KEYS: usize = 100_000;
    const TRACE: usize = 3_000_000;

    let keys = build_keys(KEYS);
    let value = cart();

    let mut cdf = vec![0f64; KEYS];
    let mut sum = 0f64;
    for i in 0..KEYS {
        sum += 1.0 / ((i + 1) as f64).powf(0.99);
        cdf[i] = sum;
    }
    for c in cdf.iter_mut() {
        *c /= sum;
    }
    let pick = |u: f64| -> usize {
        let (mut lo, mut hi) = (0usize, KEYS - 1);
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if cdf[mid] < u {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    };

    let mut rng = SmallRng::seed_from_u64(2);
    let trace: Vec<u32> = (0..TRACE).map(|_| pick(rng.gen::<f64>()) as u32).collect();

    // The entry counts nilo held at each budget, so the two are compared at
    // the same number of entries rather than at the same number of bytes —
    // which is the only way to ask a count-bounded cache this question.
    println!("hit rate, zipf 0.99, read-through, {} lookups", TRACE);
    for which in 0..2 {
        for (budget_kib, entries) in [
            (128usize, 2086usize),
            (256, 4159),
            (512, 8223),
            (1024, 16283),
            (2048, 32438),
            (4096, 64081),
        ] {
            let cache = make(which, entries);
            let mut hits = 0u64;
            for &i in trace.iter() {
                let k = &keys[i as usize];
                if cache.get(k) {
                    hits += 1;
                } else {
                    cache.set(k, value);
                }
            }
            println!(
                "  {:<12} {:6} KiB equivalent ({} entries)  {:7.1}%",
                cache.name(),
                budget_kib,
                entries,
                hits as f64 * 100.0 / TRACE as f64,
            );
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let arg = |i: usize, d: usize| -> usize {
        args.get(i).and_then(|s| s.parse().ok()).unwrap_or(d)
    };
    match args.get(1).map(|s| s.as_str()) {
        Some("bench") => bench(arg(2, 1), arg(3, 3) as u64),
        Some("mem") => mem(arg(2, 200_000), arg(3, 0)),
        Some("hitrate") => hitrate(),
        _ => println!("usage: bench <threads> <seconds> | mem <entries> | hitrate"),
    }
}
