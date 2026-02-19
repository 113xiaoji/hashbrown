# Reserve Rehash ARM Stability Design

## Problem Statement

`RawTableInner::reserve_rehash_inner()` currently only allows in-place rehash when `new_items <= full_capacity / 2`.
For high-load tables with tombstones, this forces a full resize even when reclaiming tombstones would satisfy the reserve.
On large tables this introduces extra allocation + control-byte initialization + first-touch pressure, which is correlated with the reported page-fault spikes and ARM instability.

## Goals

- Reduce unnecessary resize operations on high-load, tombstone-heavy tables.
- Preserve correctness and conservative fallback behavior for churn-heavy workloads.
- Keep the policy architecture-independent (no ARM-only branches).

## Non-Goals

- No allocator-specific tuning.
- No public API changes.
- No architecture-specific constants.

## Selected Approach

Use an adaptive in-place rehash policy in `reserve_rehash_inner`:

1. Keep existing fast path unchanged:
   - If `new_items <= full_capacity / 2`, do in-place rehash.
2. Add a high-load adaptive path:
   - Compute reclaimable tombstones and post-rehash spare headroom.
   - Allow in-place rehash only when:
     - reserve demand beyond current empties can be covered by reclaimable tombstones, and
     - post-rehash spare headroom remains above a minimum threshold.
3. Otherwise preserve existing conservative resize-to-next-size fallback.

## Decision Signals

All signals come from existing table state:

- `items`
- `growth_left`
- `full_capacity = bucket_mask_to_capacity(bucket_mask)`

Derived:

- `reclaimed_tombstones = full_capacity - items - growth_left`
- `needed_from_tombstones = additional.saturating_sub(growth_left)`
- `post_rehash_growth_left = full_capacity - new_items` (only valid if `new_items <= full_capacity`)
- `min_post_rehash_growth_left = max(1, full_capacity / 16)`

Adaptive rehash condition:

- `new_items <= full_capacity`
- `needed_from_tombstones > 0`
- `needed_from_tombstones <= reclaimed_tombstones`
- `post_rehash_growth_left >= min_post_rehash_growth_left`

## Why This Is More General

- Existing conservative path is retained as fallback.
- Trigger is based on table state, not workload labels or architecture checks.
- Headroom guard prevents immediate rehash churn in delete-heavy, continuously-growing paths.

## Correctness Notes

- In-place rehash does not change allocation layout and already has panic-safe cleanup.
- We only pick in-place rehash when reserve can be satisfied after tombstone reclamation.
- If reserve cannot be satisfied (or leaves too little headroom), we keep resize behavior.

## Test Strategy

### Unit tests (TDD)

Add tests in `src/raw.rs` (`test_map`) that:

1. Build a high-load colliding table with tombstones and assert `reserve()` stays in-place (bucket count unchanged) under adaptive conditions.
2. Assert fallback resize still happens when post-rehash headroom is too small.
3. Assert existing no-tombstone growth behavior still resizes.

### Remote verification

Use a single entry command:

`./scripts/remote-test.ps1`

Modes:

- `unit`: run targeted Rust tests on x86/ARM.
- `perf`: run perf-stat workload for reserve/rehash path on x86/ARM.
- `q18`: rebuild daft-perf with patched local `hashbrown` and run TPC-H Q18 on x86/ARM.
- `all`: run `unit + perf + q18`.

## Mandatory Final Gate

TPC-H Q18 must pass on both x86 and ARM via the same remote entry (`q18` mode) before completion.
