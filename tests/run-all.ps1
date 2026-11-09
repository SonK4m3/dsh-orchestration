# Runs the kit's suites, records their check counts, then verifies that the counts
# written in README.md and AGENTS.md still match.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-all.ps1
#   ... -IncludePosix     also drive tests/test_install.sh through WSL
#   ... -SkipDocCheck     run the suites only
#
# Exit code is the number of failing steps (0 = everything green). Logs land in
# tests/.logs/ (gitignored); the counts land in tests/.last-run.json.

[CmdletBinding()]
param(
  [switch]$IncludePosix,
  [switch]$SkipDocCheck
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location -LiteralPath $root

$logDir = Join-Path $root 'tests\.logs'
if (-not (Test-Path -LiteralPath $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Invoke-Suite([string]$name, [string]$exe, [string[]]$argList) {
  $log = Join-Path $logDir ($name + '.log')
  if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
  & $exe @argList 2>&1 | Out-File -LiteralPath $log -Encoding utf8
  $code = $LASTEXITCODE
  $text = Get-Content -LiteralPath $log -Raw

  Write-Host ''
  Write-Host ('=== ' + $name + '  (exit ' + $code + ')') -ForegroundColor Cyan
  $tail = @($text -split "`n" | Where-Object { $_ -match 'checks passed|PASS|FAIL|SKIP' } | Select-Object -Last 6)
  foreach ($line in $tail) { Write-Host ('  ' + $line.TrimEnd()) }

  return @{ Code = $code; Text = $text }
}

# "PASS - 284/284 checks passed" and "PASS 108   FAIL 0   SKIP 0" are the two shapes
# the suites print. The em dash before 284 in the node suite is deliberately not
# matched: this file stays pure ASCII.
function Read-Counts([string]$text) {
  $pairs = [regex]::Match($text, '(\d+)/(\d+) checks passed')
  if ($pairs.Success) {
    return @{ Passed = [int]$pairs.Groups[1].Value; Total = [int]$pairs.Groups[2].Value; Fail = [int]$pairs.Groups[2].Value - [int]$pairs.Groups[1].Value }
  }
  $triple = [regex]::Match($text, 'PASS (\d+)\s+FAIL (\d+)\s+SKIP (\d+)')
  if ($triple.Success) {
    return @{ Passed = [int]$triple.Groups[1].Value; Total = [int]$triple.Groups[1].Value + [int]$triple.Groups[2].Value; Fail = [int]$triple.Groups[2].Value }
  }
  return $null
}

function Convert-ToWslPath([string]$windowsPath) {
  $resolved = (Resolve-Path -LiteralPath $windowsPath).Path
  $drive = $resolved.Substring(0, 1).ToLowerInvariant()
  $rest = $resolved.Substring(2).Replace('\', '/')
  return ('/mnt/' + $drive + $rest)
}

Write-Host 'DSH orchestration kit - running every suite' -ForegroundColor White
Write-Host ('  repo: ' + $root)

$results = [ordered]@{}
$failed = 0

$profiles = Invoke-Suite 'profiles' 'node' @('tests/test_profiles.js')
$results['profiles'] = @{ Passed = 0; Total = 0; Exit = $profiles.Code }
$counts = Read-Counts $profiles.Text
if ($counts) { $results['profiles'] = @{ Passed = $counts.Passed; Total = $counts.Total; Exit = $profiles.Code } }
if ($profiles.Code -ne 0) { $failed += 1 }

$installPs = Invoke-Suite 'install-ps1' 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tests/test_install.ps1')
$results['installPs'] = @{ Passed = 0; Total = 0; Exit = $installPs.Code }
$counts = Read-Counts $installPs.Text
if ($counts) { $results['installPs'] = @{ Passed = $counts.Passed; Total = $counts.Total; Exit = $installPs.Code } }
if ($installPs.Code -ne 0) { $failed += 1 }

$installSh = $null
if ($IncludePosix) {
  if (Get-Command wsl -ErrorAction SilentlyContinue) {
    $driver = Convert-ToWslPath (Join-Path $root 'tests/wsl-run.sh')
    $installSh = Invoke-Suite 'install-sh' 'wsl' @('-d', 'Ubuntu', '-e', 'bash', $driver)
    $counts = Read-Counts $installSh.Text
    $results['installSh'] = $null
    if ($counts) { $results['installSh'] = @{ Passed = $counts.Passed; Total = $counts.Total; Exit = $installSh.Code } }
    if ($installSh.Code -ne 0) { $failed += 1 }
  } else {
    Write-Host ''
    Write-Host '=== install-sh  (SKIPPED: no wsl on PATH)' -ForegroundColor Yellow
    $results['installSh'] = $null
  }
} else {
  Write-Host ''
  Write-Host '=== install-sh  (SKIPPED: pass -IncludePosix to run it through WSL)' -ForegroundColor Yellow
  $results['installSh'] = $null
}

$state = @{
  generatedAt = (Get-Date).ToString('o')
  posixRequested = [bool]$IncludePosix
  profiles = $results['profiles']
  installPs = $results['installPs']
  installSh = $results['installSh']
}
$statePath = Join-Path $root 'tests\.last-run.json'
$json = $state | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ('counts recorded in tests\.last-run.json')

if (-not $SkipDocCheck) {
  $doc = Invoke-Suite 'doc-counts' 'node' @('tests/check-doc-counts.js')
  if ($doc.Code -ne 0) { $failed += 1 }
}

Write-Host ''
if ($failed -eq 0) {
  Write-Host 'ALL GREEN' -ForegroundColor Green
} else {
  Write-Host ($failed.ToString() + ' step(s) failed') -ForegroundColor Red
}
exit $failed
