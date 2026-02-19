# Reserve Rehash ARM Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor `reserve_rehash` policy to reduce unnecessary resize/page-fault pressure while preserving correctness, then validate on x86/ARM including mandatory TPC-H Q18.

**Architecture:** Keep existing conservative policy as baseline, add an adaptive high-load in-place rehash branch driven by tombstone/headroom signals, and enforce one remote test entry for all validation.

**Tech Stack:** Rust (`hashbrown` internals/tests), PowerShell (remote orchestrator), SSH, Linux `perf`, Python/Daft TPC-H Q18 runner.

---

### Task 1: Add Remote Test Entry Script

**Files:**
- Create: `scripts/remote-test.ps1`

**Step 1: Write the script skeleton with modes and target selection**

Implement CLI params:
- `-Mode unit|perf|q18|all`
- `-Target x86|arm|both`
- optional dataset/perf knobs

**Step 2: Implement repo sync to remote hosts**

Tar + SCP local workspace (excluding `.git` and `target`) into `/root/hashbrown-under-test` per host.

**Step 3: Implement `unit` mode command**

Run targeted Rust tests for reserve_rehash behavior on remote.

**Step 4: Implement `perf` mode command**

Run perf-stat over reserve/rehash stress workload and capture page-fault counters.

**Step 5: Implement `q18` mode command**

On each host, rebuild `/root/daft-perf` with temporary cargo patch to `/root/hashbrown-under-test`, then run `benchmarking/tpch/run_q18_native.py`.

**Step 6: Run script help check**

Run: `./scripts/remote-test.ps1 -Mode unit -Target x86 -NoSync`
Expected: script parses args and reaches remote command stage.

### Task 2: Write Failing Tests First (TDD Red)

**Files:**
- Modify: `src/raw.rs`

**Step 1: Add tests for adaptive in-place behavior and fallback behavior**

Add tests under `#[cfg(test)] mod test_map`:
- high-load + tombstones + sufficient headroom => no resize
- high-load + tombstones + insufficient headroom => resize

**Step 2: Run RED test remotely**

Run: `./scripts/remote-test.ps1 -Mode unit -Target both -TestFilter reserve_rehash_adaptive`
Expected: at least the new in-place test fails under old policy.

### Task 3: Implement Adaptive Policy (Green)

**Files:**
- Modify: `src/raw.rs`

**Step 1: Update `reserve_rehash_inner` decision logic**

Add tombstone/headroom-driven adaptive branch while preserving current conservative fallback.

**Step 2: Keep safety comments and invariants explicit**

Document derived counts and why branch selection is safe.

**Step 3: Run GREEN tests remotely**

Run: `./scripts/remote-test.ps1 -Mode unit -Target both -TestFilter reserve_rehash_adaptive`
Expected: targeted tests pass on both hosts.

### Task 4: Add/Run Perf Stress Verification

**Files:**
- Create: `examples/reserve_rehash_stress.rs`
- Modify: `scripts/remote-test.ps1`

**Step 1: Add stress workload example**

Create deterministic colliding-table workload that exercises reserve+delete+rehash path.

**Step 2: Run perf verification remotely**

Run: `./scripts/remote-test.ps1 -Mode perf -Target both`
Expected: report wall-clock and page-fault counters for each host.

### Task 5: Mandatory Q18 Final Gate

**Files:**
- Modify: `scripts/remote-test.ps1`

**Step 1: Ensure q18 mode generates/uses parquet cache path**

Default to small reproducible scale and regenerate if missing.

**Step 2: Run q18 verification remotely**

Run: `./scripts/remote-test.ps1 -Mode q18 -Target both`
Expected: successful Q18 execution and timing output on both hosts.

### Task 6: Evidence Logging and Delivery

**Files:**
- Modify: `findings.md`
- Modify: `progress.md`
- Modify: `task_plan.md`

**Step 1: Record key results**

Log unit/perf/q18 outcomes, page-fault metrics, and pass/fail status.

**Step 2: Update phase statuses**

Mark phases complete with any residual risks listed.

**Step 3: Final verification sweep before completion claim**

Run: `./scripts/remote-test.ps1 -Mode all -Target both`
Expected: all gates pass.
