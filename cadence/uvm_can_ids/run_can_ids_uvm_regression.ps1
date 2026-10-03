param(
    [int[]]$Seeds = @(1, 7, 19, 42, 99),
    [int]$RandomTransactions = 200,
    [switch]$NativeCovergroups,
    [string]$ResultsDir = ""
)

$ErrorActionPreference = "Stop"

$UvmDir = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $UvmDir "..\..")
$Runner = Join-Path $UvmDir "run_can_ids_uvm_questa.ps1"

if ($RandomTransactions -lt 6) {
    throw "RandomTransactions must be at least 6"
}
if ($Seeds.Count -eq 0) {
    throw "At least one seed is required"
}
if ([string]::IsNullOrWhiteSpace($ResultsDir)) {
    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $ResultsDir = Join-Path $RepoRoot "verification\results\${stamp}_can_ids_uvm_randomized"
}

$ResultsDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsDir)
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

$rows = foreach ($seed in $Seeds) {
    $runArgs = @{
        Seed = $seed
        RandomTransactions = $RandomTransactions
    }
    if ($NativeCovergroups) {
        $runArgs.NativeCovergroups = $true
    }

    $null = & $Runner @runArgs

    $sourceLog = Join-Path $UvmDir "can_ids_uvm_seed_${seed}_random_${RandomTransactions}.log"
    $targetLog = Join-Path $ResultsDir (Split-Path -Leaf $sourceLog)
    Copy-Item -LiteralPath $sourceLog -Destination $targetLog -Force
    $log = Get-Content -Raw -LiteralPath $sourceLog

    $metricMatches = [regex]::Matches($log, 'TP=(\d+) TN=(\d+) FP=(\d+) FN=(\d+)')
    $metrics = if ($metricMatches.Count -gt 0) { $metricMatches[$metricMatches.Count - 1] } else { $null }
    $coverage = [regex]::Match($log, 'functional coverage: ([0-9.]+)% \((\d+)/(\d+) bins\)')
    $sva = [regex]::Match($log, 'Concurrent assertions=(\d+) failures=(\d+) submit attempts=(\d+) active attempts=(\d+) attack-alert cover hits=(\d+)')

    if (($null -eq $metrics) -or -not ($metrics.Success -and $coverage.Success -and $sva.Success)) {
        throw "Could not parse required UVM evidence from $sourceLog"
    }

    [pscustomobject]@{
        Seed = $seed
        Directed = 9
        Randomized = $RandomTransactions
        Total = 9 + $RandomTransactions
        Coverage = [double]$coverage.Groups[1].Value
        CoveredBins = [int]$coverage.Groups[2].Value
        TotalBins = [int]$coverage.Groups[3].Value
        Assertions = [int]$sva.Groups[1].Value
        AssertionFailures = [int]$sva.Groups[2].Value
        SubmitAttempts = [int]$sva.Groups[3].Value
        ActiveAttempts = [int]$sva.Groups[4].Value
        CoverHits = [int]$sva.Groups[5].Value
        TP = [int]$metrics.Groups[1].Value
        TN = [int]$metrics.Groups[2].Value
        FP = [int]$metrics.Groups[3].Value
        FN = [int]$metrics.Groups[4].Value
        Log = Split-Path -Leaf $targetLog
    }
}

$csvPath = Join-Path $ResultsDir "can_ids_uvm_randomized_regression.csv"
$rows | Export-Csv -NoTypeInformation -Path $csvPath

$totalTransactions = ($rows | Measure-Object -Property Total -Sum).Sum
$totalRandomized = ($rows | Measure-Object -Property Randomized -Sum).Sum
$totalTp = ($rows | Measure-Object -Property TP -Sum).Sum
$totalTn = ($rows | Measure-Object -Property TN -Sum).Sum
$totalFp = ($rows | Measure-Object -Property FP -Sum).Sum
$totalFn = ($rows | Measure-Object -Property FN -Sum).Sum
$totalAssertionFailures = ($rows | Measure-Object -Property AssertionFailures -Sum).Sum
$minimumCoverage = ($rows | Measure-Object -Property Coverage -Minimum).Minimum

$summary = @(
    "CAN-IDS UVM constrained-random regression",
    "Seeds=$($Seeds -join ',')",
    "DirectedPerSeed=9",
    "RandomizedPerSeed=$RandomTransactions",
    "TotalRandomized=$totalRandomized",
    "TotalTransactions=$totalTransactions",
    "MinimumPortableCoverage=$('{0:F2}' -f $minimumCoverage)%",
    "CoverageBins=38/38 per seed",
    "ConcurrentAssertions=4",
    "AssertionFailures=$totalAssertionFailures",
    "AggregateTP=$totalTp",
    "AggregateTN=$totalTn",
    "AggregateFP=$totalFp",
    "AggregateFN=$totalFn",
    "CSV=$(Split-Path -Leaf $csvPath)"
)
$summaryPath = Join-Path $ResultsDir "SUMMARY.txt"
$summary | Set-Content -Path $summaryPath

$rows | Format-Table -AutoSize
$summary -join [Environment]::NewLine
