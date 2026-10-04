param(
    [string]$QuestaBin = "C:\intelFPGA_lite\questa_fse\win64",
    [string[]]$Modes = @("All", "SecurityExtension", "CanFdSecoc", "FullSocScenario"),
    [switch]$DumpCanFdWaveform
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Build = Join-Path $Root "Build\Questa\Processor"
$Project = Join-Path $Root "FPGA\Quartus"
$Spi = Join-Path $Root "IP\sensor_spi_ip\sensor_spi_ip.v"
if (-not (Test-Path -LiteralPath $Spi)) { throw "Regenerate the SPI IP as documented in Docs/REPRODUCTION.md" }
$sourceFiles = foreach ($line in Get-Content -LiteralPath (Join-Path $Project "riscv_aes_advancements.qsf")) {
    if ($line -match '^set_global_assignment -name SYSTEMVERILOG_FILE (.+)$') {
        (Resolve-Path (Join-Path $Project $Matches[1].Trim('"'))).Path
    }
}
$sourceFiles += @($Spi, (Join-Path $Root "Testbench\riscv_core_tb.sv"))
$plusArgs = @{
    All = ""; SecurityExtension = "+SECURITY_EXTENSION_ONLY"
    CanFdSecoc = "+CANFD_SECOC_ONLY"; FullSocScenario = "+FULL_SOC_SCENARIO_ONLY"
}
foreach ($mode in $Modes) {
    if (-not $plusArgs.ContainsKey($mode)) { throw "Unsupported mode: $mode" }
}
New-Item -ItemType Directory -Force -Path $Build | Out-Null
Push-Location $Build
try {
    if (-not (Test-Path -LiteralPath 'work')) {
        & "$QuestaBin\vlib.exe" work
        if ($LASTEXITCODE -ne 0) { throw "vlib failed" }
    }
    & "$QuestaBin\vmap.exe" work (Join-Path $Build "work")
    if ($LASTEXITCODE -ne 0) { throw "vmap failed" }
    & "$QuestaBin\vlog.exe" -sv +define+SIMULATION -l compile.log @sourceFiles
    if ($LASTEXITCODE -ne 0) { throw "Processor RTL compilation failed" }
    $rows = foreach ($mode in $Modes) {
        $log = Join-Path $Build "processor_${mode}.log"
        $do = "run -all; quit -f"
        $args = @('-c', '-t', '1ps', '-voptargs=+acc', '-l', $log, 'work.riscv_core_tb')
        if ($plusArgs[$mode]) { $args += $plusArgs[$mode] }
        $args += @('-do', $do)
        & "$QuestaBin\vsim.exe" @args | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Processor simulation failed: $mode" }
        if ($DumpCanFdWaveform -and $mode -eq "CanFdSecoc") {
            Copy-Item -LiteralPath (Join-Path $Build "riscv_core_tb.vcd") -Destination (Join-Path $Build "canfd_dma_debug.vcd") -Force
        }
        $text = Get-Content -Raw -LiteralPath $log
        $result = [regex]::Match($text, 'RV32I-style directed verification summary: PASS=(\d+) FAIL=(\d+)')
        if (-not $result.Success -or [int]$result.Groups[1].Value -eq 0 -or [int]$result.Groups[2].Value -ne 0 -or $text -match '\*\* (Error|Fatal):') {
            throw "Processor checks failed or summary missing: $mode"
        }
        [pscustomobject]@{ Mode = $mode; Pass = [int]$result.Groups[1].Value; Fail = 0; Log = (Split-Path -Leaf $log) }
    }
    $summaryName = if ($Modes.Count -eq 1) { "processor_$($Modes[0]).csv" } else { "processor_regression.csv" }
    $rows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $Build $summaryName)
    $rows | Format-Table -AutoSize
} finally { Pop-Location }
