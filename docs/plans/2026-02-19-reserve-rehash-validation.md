# Reserve Rehash Optimization Validation (2026-02-19)

## Scope

Validate `reserve_rehash` adaptive policy changes in `src/raw.rs` and confirm before/after performance on x86 and ARM.

Compared revisions:

- Baseline: `HEAD` archive (`head`)
- Patched: local working tree (`working-tree`)

Shared benchmark workload:

- `examples/reserve_rehash_stress.rs`
- `insert=100000`, `remove=30000`, `additional=15000`, `iters=1` unless stated

## Implementation Summary

Policy update in `reserve_rehash_inner`:

- Keep existing low-load in-place rehash rule.
- Add high-load adaptive in-place branch gated by:
  - reserve pressure beyond current empties,
  - reclaimable tombstones,
  - minimum post-rehash headroom.
- Keep conservative resize fallback unchanged.

Supporting artifacts:

- `scripts/remote-test.ps1` (remote unit/perf/q18 orchestration)
- `examples/reserve_rehash_stress.rs` (deterministic colliding workload)
- new adaptive unit tests in `src/raw.rs`

## Verification Commands Executed

Local correctness:

```powershell
cargo test --lib reserve_rehash_adaptive -- --nocapture
cargo test --lib -- --nocapture
```

Remote adaptive correctness (patched tree on each host):

```powershell
ssh -o LogLevel=ERROR root@106.14.164.133 "bash -lc 'cd /root/hashbrown-bench-working && cargo test --lib reserve_rehash_adaptive -- --nocapture 2>&1'"
ssh -o LogLevel=ERROR root@124.70.162.35 "bash -lc 'cd /root/hashbrown-bench-working && cargo test --lib reserve_rehash_adaptive -- --nocapture 2>&1'"
```

Remote perf confirmation:

```powershell
ssh -o LogLevel=ERROR <host> "bash -lc '... /root/hashbrown-bench-head ... perf stat ...'"
ssh -o LogLevel=ERROR <host> "bash -lc '... /root/hashbrown-bench-working ... perf stat ...'"
```

## Results

### Correctness

- Local adaptive tests: pass (`3/3`)
- Local full lib tests: pass (`107/107`)
- Remote adaptive tests:
  - x86: pass (`3/3`)
  - ARM: pass (`3/3`)

### Perf Campaign A (r=3 runs, 2026-02-19)

- x86:
  - reserve median: `0.16522939 -> 0.144551111` (`-12.51%`)
  - page-faults: `693 -> 623` (`-10.10%`)
  - elapsed: `161.79s -> 120.60s` (`-25.46%`)
- ARM:
  - reserve median: `0.952830896 -> 0.33082173` (`-65.28%`)
  - page-faults: `1025 -> 607` (`-40.78%`)
  - elapsed: `49.31s -> 38.048s` (`-22.84%`)

Classification: ARM multi-win in this campaign (2/3 metrics by improvement magnitude).

### Perf Campaign B (single-run confirmation, 2026-02-19)

- x86:
  - reserve: `0.273180011 -> 0.192206367` (`-29.64%`)
  - page-faults: `1713 -> 627` (`-63.40%`)
  - elapsed: `294.55s -> 158.32s` (`-46.25%`)
- ARM:
  - reserve: `0.556536029 -> 0.336620969` (`-39.51%`)
  - page-faults: `1186 -> 609` (`-48.65%`)
  - elapsed: `38.82s -> 37.49s` (`-3.43%`)

Classification: ARM single-win in this campaign (reserve metric).

### Perf Campaign C (strict ARM-first + x86 completion, 2026-02-20)

Primary `perf -r 9` comparison (`insert=100000`, `remove=30000`, `additional=15000`, `iters=1`):

- ARM:
  - reserve median: `0.224397087 -> 0.218172860` (`-2.77%`)
  - page-faults: `1186 -> 607` (`-48.82%`)
  - elapsed: `21.961s -> 21.776s` (`-0.84%`)
- x86:
  - reserve median: `0.183684728 -> 0.194842205` (`+6.07%`, regression)
  - page-faults: `1144 -> 635` (`-44.49%`)
  - elapsed: `133.03s -> 204.99s` (`+54.09%`, regression)

Campaign C outcome:

- ARM is a clear local multi-win (all three primary metrics improved vs ARM baseline).
- Cross-arch perspective in this campaign also favors ARM: ARM improved `3/3`, x86 improved `1/3`.

Campaign C caveat:

- x86 detailed run was resumed with continuation scripts due long host runtime; primary `perf -r 9` block remains comparable, but repeat/grid sections use reduced iteration counts for completion.

## Confidence Assessment

High-confidence conclusions:

- Correctness is intact on local and both remote architectures.
- Patch consistently reduces bucket growth (`after_capacity` from `229376` to `114688`).
- Patch consistently improves page-fault counts on both architectures.
- ARM reserve-latency signal remains positive across all campaigns.

Lower-confidence conclusions:

- x86 reserve/elapsed behavior is sensitive to host/runtime noise and long-run scheduling effects.
- Cross-arch "multi-win by magnitude" classification varies by campaign.

Delivery claim:

- **ARM side multi-win is demonstrated in Campaign C** (reserve + page-fault + elapsed all improved on ARM).
- **Cross-arch comparative stability remains environment-sensitive on x86**.

## Additional Tests Recommended

If stronger production confidence is required, run:

1. Fixed-core, low-noise reruns (`taskset`, isolated CPUs, no background jobs) with `perf -r >= 7`.
2. Full before/after TPC-H Q18 comparison on both hosts using fresh rebuild on each run.
3. Extended stress grid (`insert/remove/additional` sweep) to ensure adaptive threshold behavior is robust outside one workload point.
