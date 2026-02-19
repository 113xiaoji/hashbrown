use core::hash::{BuildHasher, Hasher};
use hashbrown::HashMap;
use std::time::Instant;

#[derive(Clone, Default)]
struct ZeroBuildHasher;

#[derive(Default)]
struct ZeroHasher;

impl Hasher for ZeroHasher {
    fn finish(&self) -> u64 {
        0
    }

    fn write(&mut self, _bytes: &[u8]) {}

    fn write_u64(&mut self, _i: u64) {}

    fn write_usize(&mut self, _i: usize) {}
}

impl BuildHasher for ZeroBuildHasher {
    type Hasher = ZeroHasher;

    fn build_hasher(&self) -> Self::Hasher {
        ZeroHasher::default()
    }
}

#[derive(Clone, Copy)]
struct Config {
    insert_count: usize,
    remove_count: usize,
    additional: usize,
    iters: usize,
}

fn parse_usize_arg(args: &[String], key: &str, default: usize) -> usize {
    args.windows(2)
        .find_map(|pair| {
            (pair[0] == key)
                .then(|| pair[1].parse::<usize>().ok())
                .flatten()
        })
        .unwrap_or(default)
}

fn run_once(cfg: Config) -> (f64, usize, usize) {
    let mut map: HashMap<u64, u64, ZeroBuildHasher> =
        HashMap::with_capacity_and_hasher(cfg.insert_count, ZeroBuildHasher);

    for i in 0..cfg.insert_count as u64 {
        map.insert(i, i);
    }

    let remove_start = cfg.insert_count / 4;
    let remove_count = cfg
        .remove_count
        .min(cfg.insert_count.saturating_sub(remove_start));
    for i in 0..remove_count as u64 {
        map.remove(&((remove_start as u64) + i));
    }

    let before_capacity = map.capacity();

    let t0 = Instant::now();
    map.reserve(cfg.additional);
    let reserve_s = t0.elapsed().as_secs_f64();

    let new_start = cfg.insert_count as u64;
    for i in 0..cfg.additional as u64 {
        map.insert(new_start + i, new_start + i);
    }

    let after_capacity = map.capacity();

    (reserve_s, before_capacity, after_capacity)
}

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(core::cmp::Ordering::Equal));
    let n = values.len();
    if n % 2 == 0 {
        (values[n / 2 - 1] + values[n / 2]) / 2.0
    } else {
        values[n / 2]
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cfg = Config {
        insert_count: parse_usize_arg(&args, "--insert-count", 500_000),
        remove_count: parse_usize_arg(&args, "--remove-count", 150_000),
        additional: parse_usize_arg(&args, "--additional", 30_000),
        iters: parse_usize_arg(&args, "--iters", 5),
    };

    let mut reserve_times = Vec::with_capacity(cfg.iters);
    let mut before_capacity = 0;
    let mut after_capacity = 0;

    for _ in 0..cfg.iters {
        let (reserve_s, before, after) = run_once(cfg);
        reserve_times.push(reserve_s);
        before_capacity = before;
        after_capacity = after;
    }

    println!(
        "{{\"insert_count\":{},\"remove_count\":{},\"additional\":{},\"iters\":{},\"before_capacity\":{},\"after_capacity\":{},\"reserve_median_s\":{},\"reserve_all_s\":{:?}}}",
        cfg.insert_count,
        cfg.remove_count,
        cfg.additional,
        cfg.iters,
        before_capacity,
        after_capacity,
        median(reserve_times.clone()),
        reserve_times
    );
}
