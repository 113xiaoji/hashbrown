param(
    [ValidateSet("unit", "perf", "q18", "all")]
    [string]$Mode = "all",

    [ValidateSet("x86", "arm", "both")]
    [string]$Target = "both",

    [string]$TestFilter = "reserve_rehash_adaptive",
    [string]$RemoteRepoPath = "/root/hashbrown-under-test",
    [switch]$NoSync,
    [ValidateSet("working-tree", "head")]
    [string]$SyncSource = "working-tree",

    [int]$PerfRuns = 5,
    [int]$PerfInsertCount = 500000,
    [int]$PerfRemoveCount = 150000,
    [int]$PerfAdditional = 30000,
    [int]$PerfWorkloadIters = 1,

    [double]$TpchScaleFactor = 0.2,
    [int]$TpchNumParts = 1,
    [string]$TpchParquetFolder = "",
    [int]$TpchIters = 5,
    [int]$TpchWarmup = 1,
    [int]$TpchThreads = 1,
    [switch]$SkipQ18Build
)

$ErrorActionPreference = "Stop"

$Hosts = @{
    x86 = "root@106.14.164.133"
    arm = "root@124.70.162.35"
}

function Assert-LastExitCode {
    param(
        [string]$Action
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$Action failed with exit code $LASTEXITCODE"
    }
}

function Resolve-TargetHosts {
    param(
        [string]$TargetName
    )

    switch ($TargetName) {
        "x86" { return @("x86") }
        "arm" { return @("arm") }
        "both" { return @("x86", "arm") }
        default { throw "Unsupported target: $TargetName" }
    }
}

function Invoke-RemoteScript {
    param(
        [string]$RemoteHost,
        [string]$Script,
        [string]$Label
    )

    $tmpLocal = Join-Path $env:TEMP ("codex-remote-" + [Guid]::NewGuid().ToString("N") + ".sh")
    $tmpRemote = "/tmp/" + [IO.Path]::GetFileName($tmpLocal)
    try {
        $normalizedScript = $Script -replace "`r", ""
        if (-not $normalizedScript.EndsWith("`n")) {
            $normalizedScript += "`n"
        }
        [IO.File]::WriteAllText($tmpLocal, $normalizedScript, [Text.Encoding]::ASCII)

        & scp $tmpLocal "${RemoteHost}:$tmpRemote"
        Assert-LastExitCode "${RemoteHost}: upload remote script"

        & ssh $RemoteHost "bash '$tmpRemote'"
        Assert-LastExitCode "${RemoteHost}: $Label"
    }
    finally {
        if (Test-Path $tmpLocal) {
            Remove-Item -Force $tmpLocal
        }
        & ssh $RemoteHost "rm -f '$tmpRemote'" | Out-Null
    }
}

function Sync-WorkspaceToHost {
    param(
        [string]$RemoteHost,
        [string]$RepoRoot,
        [string]$RemotePath,
        [string]$Source
    )

    $tmpTar = Join-Path $env:TEMP ("hashbrown-sync-" + [Guid]::NewGuid().ToString("N") + ".tar")
    try {
        if ($Source -eq "head") {
            & git -C $RepoRoot archive --format=tar HEAD -o $tmpTar
            Assert-LastExitCode "Create HEAD archive"
        }
        else {
            & tar -cf $tmpTar --exclude=.git --exclude=target -C $RepoRoot .
            Assert-LastExitCode "Create workspace tar"
        }

        & scp $tmpTar "${RemoteHost}:/tmp/hashbrown-under-test.tar"
        Assert-LastExitCode "Upload workspace tar"

        $extractScript = @"
set -euo pipefail
rm -rf '$RemotePath'
mkdir -p '$RemotePath'
tar -xf /tmp/hashbrown-under-test.tar -C '$RemotePath'
rm -f /tmp/hashbrown-under-test.tar
"@
        Invoke-RemoteScript -RemoteHost $RemoteHost -Script $extractScript -Label "Extract workspace"

        if ($Source -eq "head") {
            $localPerfExample = Join-Path $RepoRoot "examples/reserve_rehash_stress.rs"
            if (Test-Path $localPerfExample) {
                & ssh $RemoteHost "mkdir -p '$RemotePath/examples'"
                Assert-LastExitCode "${RemoteHost}: create examples directory"
                & scp $localPerfExample "${RemoteHost}:$RemotePath/examples/reserve_rehash_stress.rs"
                Assert-LastExitCode "${RemoteHost}: upload perf example"
            }
        }
    }
    finally {
        if (Test-Path $tmpTar) {
            Remove-Item -Force $tmpTar
        }
    }
}

function Run-UnitMode {
    param(
        [string]$RemoteHost,
        [string]$RemotePath,
        [string]$Filter
    )

    $unitScript = @"
set -euo pipefail
cd '$RemotePath'
if [ -n '$Filter' ]; then
    cargo test --lib '$Filter' -- --nocapture
else
    cargo test --lib -- --nocapture
fi
"@
    Invoke-RemoteScript -RemoteHost $RemoteHost -Script $unitScript -Label "Unit tests"
}

function Run-PerfMode {
    param(
        [string]$RemoteHost,
        [string]$RemotePath,
        [int]$Runs,
        [int]$InsertCount,
        [int]$RemoveCount,
        [int]$Additional,
        [int]$Iters
    )

    $perfScript = @"
set -euo pipefail
cd '$RemotePath'
cargo build --release --example reserve_rehash_stress
perf stat -r $Runs -e page-faults,minor-faults,major-faults \
    target/release/examples/reserve_rehash_stress \
        --insert-count $InsertCount \
        --remove-count $RemoveCount \
        --additional $Additional \
        --iters $Iters
"@
    Invoke-RemoteScript -RemoteHost $RemoteHost -Script $perfScript -Label "Perf validation"
}

function Run-Q18Mode {
    param(
        [string]$RemoteHost,
        [string]$RemotePath,
        [double]$ScaleFactor,
        [int]$NumParts,
        [string]$ParquetFolder,
        [int]$Iters,
        [int]$Warmup,
        [int]$Threads,
        [bool]$SkipBuild
    )

    $scaleStr = "{0:N1}" -f $ScaleFactor
    $scaleStr = $scaleStr.Replace(",", "").Replace(".", "_")

    $q18Script = @"
set -euo pipefail
cd /root/daft-perf
source .venv/bin/activate

orig_cfg='.cargo/config.toml'
bak_cfg='.cargo/config.toml.hashbrown.bak'
cp "`$orig_cfg" "`$bak_cfg"
cleanup() {
    mv "`$bak_cfg" "`$orig_cfg"
}
trap cleanup EXIT

cat > "`$orig_cfg" <<EOF
[env]
PYO3_PYTHON = "./.venv/bin/python"

[patch.crates-io]
hashbrown = { path = "$RemotePath" }
EOF

export AWS_LC_SYS_CMAKE_BUILDER=1
export CARGO_BUILD_JOBS=1
if [ "$([int](-not $SkipBuild))" -eq 1 ]; then
    cargo update -p hashbrown@0.16.0 --precise 0.16.1 || cargo update -p hashbrown@0.16.1 --precise 0.16.1 || true
    maturin develop
fi

if [ -n "$ParquetFolder" ]; then
    parquet_dir="$ParquetFolder"
else
    parquet_dir="data/tpch-dbgen/$scaleStr/$NumParts/parquet"
    if [ ! -d "`$parquet_dir/lineitem" ]; then
        DAFT_RUNNER=native python benchmarking/tpch/data_generation.py --tpch_gen_folder /root/data/tpch-dbgen --scale_factor $ScaleFactor --num_parts $NumParts --generate_parquet
    fi
fi

DAFT_RUNNER=native python benchmarking/tpch/run_q18_native.py \
    --parquet-folder "`$parquet_dir" \
    --threads $Threads \
    --iters $Iters \
    --warmup $Warmup
"@

    Invoke-RemoteScript -RemoteHost $RemoteHost -Script $q18Script -Label "TPC-H Q18 validation"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$targetKeys = Resolve-TargetHosts -TargetName $Target

foreach ($targetKey in $targetKeys) {
    $remoteHost = $Hosts[$targetKey]
    Write-Host "==== Target: $targetKey ($remoteHost) ===="

    if (-not $NoSync) {
        Write-Host "-- Sync workspace"
        Sync-WorkspaceToHost -RemoteHost $remoteHost -RepoRoot $repoRoot -RemotePath $RemoteRepoPath -Source $SyncSource
    }

    if ($Mode -eq "unit" -or $Mode -eq "all") {
        Write-Host "-- Run unit mode"
        Run-UnitMode -RemoteHost $remoteHost -RemotePath $RemoteRepoPath -Filter $TestFilter
    }

    if ($Mode -eq "perf" -or $Mode -eq "all") {
        Write-Host "-- Run perf mode"
        Run-PerfMode -RemoteHost $remoteHost -RemotePath $RemoteRepoPath -Runs $PerfRuns -InsertCount $PerfInsertCount -RemoveCount $PerfRemoveCount -Additional $PerfAdditional -Iters $PerfWorkloadIters
    }

    if ($Mode -eq "q18" -or $Mode -eq "all") {
        Write-Host "-- Run q18 mode"
        Run-Q18Mode -RemoteHost $remoteHost -RemotePath $RemoteRepoPath -ScaleFactor $TpchScaleFactor -NumParts $TpchNumParts -ParquetFolder $TpchParquetFolder -Iters $TpchIters -Warmup $TpchWarmup -Threads $TpchThreads -SkipBuild $SkipQ18Build
    }
}

Write-Host "All requested remote checks completed."
