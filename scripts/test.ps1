
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Resolve the repository root relative to this script's location.
$repoRoot = Split-Path -Parent $PSScriptRoot
$testProject = Join-Path $repoRoot "test.project.json"
$testRunner = Join-Path $repoRoot "run-tests.lua"
$testPlace = Join-Path $repoRoot "test-place.rbxl"
$logFile = Join-Path $repoRoot "jest-output.log"

function Stop-TestRun([string]$Message) {
    Write-Error $Message
    exit 1
}

if (-not (Test-Path -LiteralPath $testProject -PathType Leaf)) {
    Stop-TestRun "test.project.json was not found in the repository root: $repoRoot"
}

if (-not (Test-Path -LiteralPath $testRunner -PathType Leaf)) {
    Stop-TestRun "run-tests.lua was not found in the repository root: $repoRoot"
}

if (-not (Get-Command rojo -ErrorAction SilentlyContinue)) {
    Stop-TestRun "The 'rojo' command was not found. Install the project tools using Rokit."
}

# Locate the most recently installed version of Roblox Studio.
$studioRoot = Join-Path $env:LOCALAPPDATA "Roblox\Versions"
$studio = Get-ChildItem -Path $studioRoot -Filter "RobloxStudioBeta.exe" -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $studio) {
    Stop-TestRun "RobloxStudioBeta.exe could not be found in '$studioRoot'."
}

Write-Host "==> Building the test place with Rojo..."
Push-Location $repoRoot
try {
    & rojo build $testProject -o $testPlace
    if ($LASTEXITCODE -ne 0) {
        Stop-TestRun "Rojo build failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

if (-not (Test-Path $testPlace)) {
    Stop-TestRun "Rojo did not create the test place."
}

# Remove the previous log to avoid mistaking an old successful run for the current one.
if (Test-Path -LiteralPath $logFile) {
    Remove-Item -LiteralPath $logFile -Force
}

Write-Host "==> Running Jest in Roblox Studio..."
Write-Host "Studio: $studio"
Write-Host "Place: $testPlace"
Write-Host "Log: $logFile"

$studioArguments = @(
    "--task",
    "RunScript",
    "--localPlaceFile",
    "`"$testPlace`"",
    "--runScriptFile",
    "`"$testRunner`"",
    "--outputFile",
    "`"$logFile`"",
    "--quitAfterExecution"
)

try {
    # Wait for Roblox Studio to finish.
    $studioProcess = Start-Process `
        -FilePath $studio `
        -ArgumentList $studioArguments `
        -PassThru `
        -Wait

    $studioExitCode = $studioProcess.ExitCode
}
catch {
    Stop-TestRun "Failed to start Roblox Studio: $($_.Exception.Message)"
}

# Wait for the log file to appear.
$deadline = [DateTime]::UtcNow.AddMinutes(3)

while (-not (Test-Path -LiteralPath $logFile -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge $deadline) {
        Stop-TestRun "Roblox Studio did not create the test log within 3 minutes. Exit code: $studioExitCode"
    }

    Start-Sleep -Seconds 2
}

# Wait until the log file stops changing.
$previousLength = -1
$stableReads = 0

while ($stableReads -lt 3) {
    $currentLength = (Get-Item -LiteralPath $logFile).Length

    if ($currentLength -gt 0 -and $currentLength -eq $previousLength) {
        $stableReads++
    }
    else {
        $stableReads = 0
    }

    $previousLength = $currentLength

    if ([DateTime]::UtcNow -ge $deadline) {
        Stop-TestRun "The test log was not fully written within the allowed time."
    }

    if ($stableReads -lt 3) {
        Start-Sleep -Seconds 2
    }
}

$logText = Get-Content -LiteralPath $logFile -Raw

Write-Host ""
Write-Host "========== Jest output =========="
Get-Content -LiteralPath $logFile
Write-Host "================================="

if ([string]::IsNullOrWhiteSpace($logText)) {
    Stop-TestRun "The test log is empty. Jest results cannot be verified."
}

# Check the Jest summary.
$suitesMatch = [regex]::Match(
    $logText,
    'Test Suites:\s*(?<value>[^\r\n]*)'
)

$testsMatch = [regex]::Match(
    $logText,
    'Tests:\s*(?<value>[^\r\n]*)'
)

if (-not $suitesMatch.Success -or -not $testsMatch.Success) {
    Stop-TestRun "The Jest summary is missing from the log. Successful execution cannot be verified."
}

$suitesLine = $suitesMatch.Groups["value"].Value
$testsLine = $testsMatch.Groups["value"].Value

if ($suitesLine -match '\b\d+\s+failed\b' -or $testsLine -match '\b\d+\s+failed\b') {
    Stop-TestRun "Jest reported failed tests."
}

$totalTestsMatch = [regex]::Match(
    $testsLine,
    '\b(?<total>\d+)\s+total\b'
)

if (-not $totalTestsMatch.Success -or [int]$totalTestsMatch.Groups["total"].Value -lt 1) {
    Stop-TestRun "Jest did not confirm that at least one test was executed: '$testsLine'."
}

if ($studioExitCode -ne 0) {
    Stop-TestRun "Roblox Studio exited with code $studioExitCode. Check the log."
}

Write-Host ""
Write-Host "SUCCESS: Jest executed $($totalTestsMatch.Groups['total'].Value) test(s). No failures were reported." -ForegroundColor Green
exit 0
