param(
    [int]$Seed = 1,
    [int]$RandomTransactions = 40,
    [switch]$NativeCovergroups,
    [switch]$DumpVcd
)

$ErrorActionPreference = "Stop"
$UvmDir = $PSScriptRoot
$Root = Resolve-Path (Join-Path $UvmDir "..\..")
$Work = "canfd_secoc_uvm_work"
$LogPath = Join-Path $UvmDir "canfd_secoc_uvm_seed_${Seed}_random_${RandomTransactions}.log"
$RefBase = Join-Path $UvmDir "secoc_cmac_ref"

if ($RandomTransactions -lt 4) {
    throw "RandomTransactions must be at least 4"
}

function Resolve-QuestaTool([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = Join-Path "C:\intelFPGA_lite\questa_fse\win64" "$Name.exe"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    throw "Could not find Questa $Name"
}

$vlib = Resolve-QuestaTool "vlib"
$vmap = Resolve-QuestaTool "vmap"
$vlog = Resolve-QuestaTool "vlog"
$vsim = Resolve-QuestaTool "vsim"
$questaRoot = Resolve-Path (Join-Path (Split-Path $vlog -Parent) "..")
$dpiInclude = Join-Path $questaRoot "include"
$zig = Join-Path $env:APPDATA "Python\Python312\Scripts\python-zig.exe"
if (-not (Test-Path -LiteralPath $zig)) {
    throw "python-zig was not found at $zig; it is required to build the DPI reference"
}

Push-Location $Root
try {
    $zigArgs = @("cc", "-shared", "-O2", "-I$dpiInclude", "-o",
                 "$RefBase.dll", (Join-Path $UvmDir "secoc_cmac_ref.c"))
    & $zig @zigArgs
    if ($LASTEXITCODE -ne 0) { throw "Failed to build SecOC CMAC DPI reference" }

    if (Test-Path -LiteralPath $Work) {
        Remove-Item -LiteralPath $Work -Recurse -Force
    }
    & $vlib $Work
    & $vmap work $Work

    $vlogArgs = @("-sv", "+incdir+$UvmDir")
    if ($NativeCovergroups) { $vlogArgs += "+define+NATIVE_COVERGROUPS" }
    $vlogArgs += @(
        (Join-Path $UvmDir "canfd_secoc_uvm_if.sv"),
        (Join-Path $Root "rtl\aes128_reusable\00_aes128_top.sv"),
        (Join-Path $Root "rtl\aes128_reusable\01_aes_sbox_rom.sv"),
        (Join-Path $Root "rtl\aes128_reusable\02_aes_sbox_seq.sv"),
        (Join-Path $Root "rtl\aes128_reusable\03_aes_mix_columns_seq.sv"),
        (Join-Path $Root "rtl\aes128_reusable\04_aes_key_expand_seq.sv"),
        (Join-Path $Root "aes128_lowpower.sv"),
        (Join-Path $Root "canfd_secoc_mmio.sv"),
        (Join-Path $UvmDir "canfd_secoc_uvm_pkg.sv"),
        (Join-Path $UvmDir "canfd_secoc_uvm_tb_top.sv")
    )
    & $vlog @vlogArgs
    if ($LASTEXITCODE -ne 0) { throw "CAN-FD/SecOC UVM vlog compile failed" }

    $do = "run -all; quit"
    if ($DumpVcd) {
        $vcd = (Join-Path $UvmDir "canfd_secoc_uvm_seed_${Seed}.vcd").Replace("\", "/")
        $do = "vcd file {$vcd}; vcd add -r /canfd_secoc_uvm_tb_top/*; run -all; vcd flush; quit"
    }
    $vsimArgs = @("-c", "-sv_seed", "$Seed", "-sv_lib", $RefBase,
                  "-l", $LogPath)
    if ($DumpVcd) { $vsimArgs += "-voptargs=+acc" }
    $vsimArgs += @("work.canfd_secoc_uvm_tb_top", "-do", $do,
                   "+UVM_TESTNAME=canfd_secoc_uvm_test",
                   "+UVM_VERBOSITY=UVM_NONE",
                   "+RANDOM_TXNS=$RandomTransactions",
                   "+CANFD_SEED=$Seed")
    & $vsim @vsimArgs
    if ($LASTEXITCODE -ne 0) { throw "CAN-FD/SecOC UVM simulation failed" }

    $log = Get-Content -Raw -LiteralPath $LogPath
    if ($log -match "UVM_(ERROR|FATAL)\s*:\s*[1-9]") {
        throw "CAN-FD/SecOC UVM reported errors; see $LogPath"
    }
    if ($log -notmatch "randomized=$RandomTransactions") {
        throw "Requested randomized transaction count was not reported"
    }
    if ($log -notmatch "Portable CAN-FD/SecOC functional coverage: 100\.00% \(16/16 bins\)") {
        throw "Portable CAN-FD/SecOC coverage did not close"
    }
    if ($log -notmatch "Concurrent assertions=5 failures=0") {
        throw "CAN-FD/SecOC assertion summary was not clean"
    }
}
finally {
    Pop-Location
}
