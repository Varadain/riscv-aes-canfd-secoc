param(
    [int]$Seed = 1,
    [int]$RandomTransactions = 200,
    [switch]$DumpVcd,
    [switch]$NativeCovergroups,
    [string]$VcdPath = ""
)

$ErrorActionPreference = "Stop"

$UvmDir = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $UvmDir "..\..")).Path
$BuildRoot = Join-Path $RepoRoot "Build\Questa\CAN_IDS"
$Work = Join-Path $BuildRoot "work"
$LogPath = Join-Path $BuildRoot "can_ids_uvm_seed_${Seed}_random_${RandomTransactions}.log"

if ($RandomTransactions -lt 6) {
    throw "RandomTransactions must be at least 6"
}

function Resolve-QuestaTool {
    param([string]$ToolName)

    $cmd = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $candidate = Join-Path "C:\intelFPGA_lite\questa_fse\win64" "$ToolName.exe"
    if (Test-Path $candidate) {
        return $candidate
    }

    throw "Could not find $ToolName. Add Questa to PATH or install Intel Questa FSE at C:\intelFPGA_lite\questa_fse\win64."
}

$vlib = Resolve-QuestaTool "vlib"
$vmap = Resolve-QuestaTool "vmap"
$vlog = Resolve-QuestaTool "vlog"
$vsim = Resolve-QuestaTool "vsim"

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
Push-Location $BuildRoot
try {
    if (Test-Path -LiteralPath $Work) {
        $resolvedWork = [IO.Path]::GetFullPath($Work)
        $buildPrefix = [IO.Path]::GetFullPath($BuildRoot) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedWork.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Work library is outside the build directory"
        }
        Remove-Item -LiteralPath $resolvedWork -Recurse -Force
    }

    & $vlib $Work
    & $vmap work $Work

    $vlogArgs = @(
        "-sv",
        "+incdir+$UvmDir"
    )
    if ($NativeCovergroups) {
        $vlogArgs += "+define+NATIVE_COVERGROUPS"
    }
    $vlogArgs += @(
        (Join-Path $UvmDir "can_ids_uvm_if.sv"),
        (Join-Path $RepoRoot "RTL\CAN\can_ids_mmio.sv"),
        (Join-Path $UvmDir "can_ids_uvm_pkg.sv"),
        (Join-Path $UvmDir "can_ids_uvm_tb_top.sv")
    )
    & $vlog @vlogArgs
    if ($LASTEXITCODE -ne 0) {
        throw "vlog failed while compiling the CAN-IDS UVM environment"
    }

    $doCmd = "run -all; quit"
    if ($DumpVcd) {
        if ([string]::IsNullOrWhiteSpace($VcdPath)) {
            $VcdPath = Join-Path $BuildRoot "can_ids_uvm_seed_${Seed}_random_${RandomTransactions}.vcd"
        }
        $resolvedVcd = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($VcdPath)
        $vcdForQuesta = $resolvedVcd.Replace("\", "/")
        $doCmd = "vcd file {$vcdForQuesta}; " +
                 "vcd add /can_ids_uvm_tb_top/clk; " +
                 "vcd add -r /can_ids_uvm_tb_top/ids_if/*; " +
                 "vcd add -r /can_ids_uvm_tb_top/u_can_ids_mmio/*; " +
                 "run -all; vcd flush; quit"
    }

    $vsimArgs = @("-c", "-sv_seed", "$Seed")
    if ($DumpVcd) {
        $vsimArgs += "-voptargs=+acc"
    }
    $vsimArgs += @(
        "-l", $LogPath,
        "work.can_ids_uvm_tb_top",
        "-do", $doCmd,
        "+UVM_TESTNAME=can_ids_uvm_test",
        "+UVM_VERBOSITY=UVM_NONE",
        "+RANDOM_TXNS=$RandomTransactions"
    )
    & $vsim @vsimArgs
    if ($LASTEXITCODE -ne 0) {
        throw "vsim failed while running the CAN-IDS UVM environment"
    }
    $logText = Get-Content -Raw -Path $LogPath
    if ($logText -match "UVM_(ERROR|FATAL)\s*:\s*[1-9]") {
        throw "CAN-IDS UVM run completed with UVM errors or fatals. See $LogPath"
    }
    if ($logText -notmatch "Constrained-random CAN-IDS transactions=$RandomTransactions") {
        throw "CAN-IDS UVM run did not report the requested randomized transaction count. See $LogPath"
    }
    if ($logText -notmatch "Portable CAN-IDS functional coverage: 100\.00% \(38/38 bins\)") {
        throw "CAN-IDS UVM run did not close portable functional coverage. See $LogPath"
    }
    if ($logText -notmatch "Concurrent assertions=4 failures=0") {
        throw "CAN-IDS UVM run did not report a clean assertion summary. See $LogPath"
    }
}
finally {
    Pop-Location
}
