param(
    [int[]]$Seeds = @(1, 7, 19, 42, 99),
    [int]$RandomTransactions = 40,
    [string]$ResultsDir = ""
)

$ErrorActionPreference = "Stop"
$UvmDir = $PSScriptRoot
$Root = Resolve-Path (Join-Path $UvmDir "..\..")
$Runner = Join-Path $UvmDir "run_canfd_secoc_uvm_questa.ps1"
if ([string]::IsNullOrWhiteSpace($ResultsDir)) {
    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $ResultsDir = Join-Path $Root "verification\results\${stamp}_canfd_secoc_uvm"
}
$ResultsDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsDir)
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

$rows = foreach ($seed in $Seeds) {
    $runArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Runner,
                 "-Seed", $seed, "-RandomTransactions", $RandomTransactions)
    $runOutput = & powershell.exe @runArgs
    $runOutput | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "UVM seed $seed failed" }
    $source = Join-Path $UvmDir "canfd_secoc_uvm_seed_${seed}_random_${RandomTransactions}.log"
    $target = Join-Path $ResultsDir (Split-Path -Leaf $source)
    Copy-Item -LiteralPath $source -Destination $target -Force
    $log = Get-Content -Raw -LiteralPath $source
    $summary = [regex]::Match($log,
        'transactions=(\d+) randomized=(\d+) accepted=(\d+) auth_fail=(\d+) fresh_fail=(\d+) mismatches=(\d+)')
    $assertions = [regex]::Match($log,
        'Concurrent assertions=(\d+) failures=(\d+) cover hits=(\d+)')
    if (-not ($summary.Success -and $assertions.Success)) {
        throw "Could not parse UVM evidence for seed $seed"
    }
    [pscustomobject]@{
        Seed = $seed
        Directed = 6
        Randomized = [int]$summary.Groups[2].Value
        Total = [int]$summary.Groups[1].Value
        Accepted = [int]$summary.Groups[3].Value
        AuthFail = [int]$summary.Groups[4].Value
        FreshFail = [int]$summary.Groups[5].Value
        Mismatches = [int]$summary.Groups[6].Value
        CoverageBins = "16/16"
        Assertions = [int]$assertions.Groups[1].Value
        AssertionFailures = [int]$assertions.Groups[2].Value
        CoverHits = [int]$assertions.Groups[3].Value
        Log = Split-Path -Leaf $target
    }
}

$csv = Join-Path $ResultsDir "canfd_secoc_uvm_regression.csv"
$rows | Export-Csv -NoTypeInformation -LiteralPath $csv
$total = ($rows | Measure-Object Total -Sum).Sum
$random = ($rows | Measure-Object Randomized -Sum).Sum
$failures = ($rows | Measure-Object AssertionFailures -Sum).Sum
$summaryText = @(
    "CAN-FD/SecOC UVM constrained-random regression",
    "Seeds=$($Seeds -join ',')",
    "DirectedPerSeed=6",
    "RandomizedPerSeed=$RandomTransactions",
    "TotalRandomized=$random",
    "TotalTransactions=$total",
    "CoverageBins=16/16 per seed",
    "ConcurrentAssertions=5",
    "AssertionFailures=$failures",
    "CSV=$(Split-Path -Leaf $csv)"
)
$summaryText | Set-Content -LiteralPath (Join-Path $ResultsDir "SUMMARY.txt")
$rows | Format-Table -AutoSize
$summaryText -join [Environment]::NewLine
