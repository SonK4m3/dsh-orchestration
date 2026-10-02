<#
  test_install.ps1 - drive setup.ps1 through every path that can silently do the
  wrong thing, against throwaway targets inside this repository.

  Run:  pwsh -File tests/test_install.ps1
  Keep the sandbox for inspection:  pwsh -File tests/test_install.ps1 -KeepArtifacts

  Every scenario spawns a real child PowerShell process running setup.ps1, so what
  is asserted is the installer's observable behaviour (exit code + output + files
  on disk), not the behaviour of its functions called in-process.

  The test root lives inside the kit on purpose: the DSH file sandbox grants write
  access only inside the workspace, so %TEMP% is not a safe scratch space here.
#>
[CmdletBinding()]
param([switch]$KeepArtifacts)

$ErrorActionPreference = 'Stop'

$KitRoot = Split-Path -Parent $PSScriptRoot
$Setup = Join-Path $KitRoot 'setup.ps1'
$Root = Join-Path $KitRoot '.test-install'

$HostExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $HostExe)) { $HostExe = Join-Path $PSHOME 'powershell.exe' }

$BeginMarker = '<!-- dsh-orchestration:begin -->'
$ProfileNames = @('pro', 'plus', 'pro-2-subagents', 'plus-2-subagents', 'pro-max', 'pro-exec-max')

$script:Pass = 0
$script:Fail = 0

function Write-Section([string]$title) {
  Write-Host ''
  Write-Host $title -ForegroundColor Cyan
}

function Format-Value($Value) {
  $text = if ($null -eq $Value) { '<null>' } else { [string]$Value }
  $text = $text -replace "`r`n", '\n' -replace "`n", '\n'
  if ($text.Length -gt 160) { $text = $text.Substring(0, 160) + '...' }
  return $text
}

function Assert-True([bool]$Condition, [string]$Label, [string]$Detail = '') {
  if ($Condition) {
    $script:Pass++
    Write-Host "  ok    $Label"
  } else {
    $script:Fail++
    $suffix = if ($Detail) { " -- $Detail" } else { '' }
    Write-Host "  FAIL  $Label$suffix" -ForegroundColor Red
  }
}

function Assert-Equal($Actual, $Expected, [string]$Label) {
  Assert-True ($Actual -eq $Expected) $Label ("expected '" + (Format-Value $Expected) + "', got '" + (Format-Value $Actual) + "'")
}

function Assert-Contains([string]$Haystack, [string]$Needle, [string]$Label) {
  Assert-True $Haystack.Contains($Needle) $Label "did not contain: $Needle"
}

function Assert-Absent([string]$Path, [string]$Label) {
  Assert-True (-not (Test-Path -LiteralPath $Path)) $Label "unexpected path: $Path"
}

function New-TestDir([string]$name) {
  $dir = Join-Path $Root $name
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  return $dir
}

function Get-Text([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  return (Get-Content -LiteralPath $path -Raw)
}

function Get-Hash([string]$path) {
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Invoke-Setup([string[]]$Arguments) {
  # The child's stderr is merged into the success stream on purpose: under
  # $ErrorActionPreference = 'Stop' a native process that writes to stderr raises a
  # terminating NativeCommandError, and this script asserts on messages that
  # setup.ps1 deliberately prints to stderr. (Start-Process would be cleaner, but
  # the DSH file sandbox denies it - "Access is denied" before the child exists.)
  $log = Join-Path $Root ('log-' + [guid]::NewGuid().ToString('N') + '.txt')
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $HostExe -NoProfile -ExecutionPolicy Bypass -File $Setup @Arguments 2>&1 | Out-File -LiteralPath $log -Encoding utf8
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
  $text = Get-Text $log
  return [pscustomobject]@{ Code = $code; Text = $text }
}

# --- sandbox -----------------------------------------------------------------

if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
New-Item -ItemType Directory -Path $Root -Force | Out-Null

Write-Host ''
Write-Host '  DSH orchestration kit - installer tests' -ForegroundColor White
Write-Host "  kit:  $KitRoot"
Write-Host "  host: $HostExe"

# --- 0. the scripts themselves -------------------------------------------------

Write-Section '0. Script sources are ASCII-only'
foreach ($source in @($Setup, (Join-Path $PSScriptRoot 'test_install.ps1'))) {
  $bytes = @([System.IO.File]::ReadAllBytes($source) | Where-Object { $_ -gt 127 })
  Assert-Equal $bytes.Count 0 ((Split-Path -Leaf $source) + ' has no byte above 0x7F (Windows PowerShell 5.1 reads a BOM-less UTF-8 .ps1 as ANSI, where an em dash decodes to a smart quote that ends a string)')
}

# --- 1. profile listing -------------------------------------------------------

Write-Section '1. -ListProfiles'
$list = Invoke-Setup @('-ListProfiles')
Assert-Equal $list.Code 0 'exits 0'
Assert-Contains $list.Text 'Available profiles' 'prints the heading'
foreach ($name in $ProfileNames) { Assert-Contains $list.Text "  $name" "lists $name" }
$rowCount = ([regex]::Matches($list.Text, '(?m)^  \d  ')).Count
Assert-Equal $rowCount 6 'prints exactly 6 numbered rows'

# --- 2. dry run ---------------------------------------------------------------

Write-Section '2. -DryRun writes nothing'
$t1 = New-TestDir 'dry-run'
$dry = Invoke-Setup @('-Target', $t1, '-Profile', 'pro-max', '-DryRun', '-NonInteractive')
Assert-Equal $dry.Code 0 'exits 0'
Assert-Contains $dry.Text 'Dry run: nothing will be written.' 'announces the dry run'
Assert-Contains $dry.Text 'would write' 'describes the intended writes'
Assert-Absent (Join-Path $t1 '.dsh') 'no .dsh directory created'
Assert-Absent (Join-Path $t1 'AGENTS.md') 'no AGENTS.md created'

# --- 3. real install ----------------------------------------------------------

Write-Section '3. Project-scope install of all components'
$t2 = New-TestDir 'full-install'
$agentsPath = Join-Path $t2 'AGENTS.md'
Set-Content -LiteralPath $agentsPath -Value "# Existing project notes`n`nkeep me`n" -Encoding utf8

$full = Invoke-Setup @('-Target', $t2, '-Profile', 'plus-2-subagents', '-NonInteractive')
Assert-Equal $full.Code 0 'exits 0'

$skillDir = Join-Path $t2 '.dsh\skills\dsh-orchestration'
Assert-True (Test-Path -LiteralPath (Join-Path $skillDir 'SKILL.md')) 'skill body installed'
Assert-True (Test-Path -LiteralPath (Join-Path $skillDir 'references\topologies.md')) 'skill reference installed'
Assert-True (Test-Path -LiteralPath (Join-Path $skillDir 'references\delegation.md')) 'skill reference installed (delegation)'
Assert-True (Test-Path -LiteralPath (Join-Path $skillDir 'assets\work-packet.md')) 'skill asset installed'
Assert-True (Test-Path -LiteralPath (Join-Path $skillDir 'assets\agents-block.md')) 'skill asset installed (agents block)'

foreach ($forbidden in @('tests', 'scripts', 'profiles', 'setup.ps1', 'setup.sh', 'README.md', '.git', '.test-install')) {
  Assert-Absent (Join-Path $skillDir $forbidden) "skill bundle does not carry $forbidden"
}

$orchDir = Join-Path $t2 '.dsh\orchestration'
$installedScript = Join-Path $orchDir 'orchestrate.js'
$installedProfile = Join-Path $orchDir 'profile.json'
Assert-True (Test-Path -LiteralPath $installedScript) 'orchestrate.js installed'
Assert-True (Test-Path -LiteralPath (Join-Path $orchDir 'README.md')) 'orchestration README installed'
Assert-Equal (Get-Hash $installedScript) (Get-Hash (Join-Path $KitRoot 'scripts\orchestrate.js')) 'orchestrate.js is byte-identical to the kit copy'
Assert-Equal (Get-Content -LiteralPath $installedProfile -Raw | ConvertFrom-Json).name 'plus-2-subagents' 'profile.json is the selected profile'

$merged = Get-Text $agentsPath
Assert-Contains $merged $BeginMarker 'AGENTS.md has the begin marker'
Assert-Contains $merged '<!-- dsh-orchestration:end -->' 'AGENTS.md has the end marker'
Assert-Contains $merged '# Existing project notes' 'existing content preserved'
Assert-Contains $merged 'keep me' 'existing content preserved (body)'
Assert-Contains $merged '## Profile in use' 'profile section merged'
Assert-Contains $merged 'Profile: `plus-2-subagents`' 'profile section names the selected profile'
Assert-Contains $merged 'maxActiveSubagents' 'profile section names the Host setting'
Assert-True ($merged.IndexOf($BeginMarker) -lt $merged.IndexOf('## Profile in use')) 'markers enclose the profile section'
Assert-Contains $full.Text 'skill: 5 created, 0 overwritten' 'reports 5 skill files'
Assert-Contains $full.Text 'orchestration: 3 created, 0 overwritten (plus-2-subagents)' 'reports 3 orchestration files'

# --- 4. idempotency -----------------------------------------------------------

Write-Section '4. Re-running the same install is a no-op'
$hashBefore = Get-Hash $agentsPath
$again = Invoke-Setup @('-Target', $t2, '-Profile', 'plus-2-subagents', '-NonInteractive')
Assert-Equal $again.Code 0 'exits 0'
Assert-Equal (Get-Hash $agentsPath) $hashBefore 'AGENTS.md is byte-identical'
Assert-Contains $again.Text 'AGENTS.md: already-present' 'reports the block as already present'
Assert-Contains $again.Text 'WARNING' 'warns before overwriting the component files'

# --- 5. changing profile rewrites only the managed region ---------------------

Write-Section '5. Changing profile updates the region, keeps the rest'
$switch = Invoke-Setup @('-Target', $t2, '-Profile', 'pro-max', '-NonInteractive')
Assert-Equal $switch.Code 0 'exits 0'
$switched = Get-Text $agentsPath
Assert-True ((Get-Hash $agentsPath) -ne $hashBefore) 'AGENTS.md changed'
Assert-Contains $switched 'Profile: `pro-max`' 'names the new profile'
Assert-True (-not $switched.Contains('plus-2-subagents')) 'old profile name is gone'
Assert-Contains $switched 'keep me' 'existing content still preserved'
Assert-Equal (Get-Content -LiteralPath $installedProfile -Raw | ConvertFrom-Json).name 'pro-max' 'installed profile.json replaced'

# --- 6. component subsets -----------------------------------------------------

Write-Section '6. Component subsets write only what was asked for'
$t3 = New-TestDir 'agents-only'
$onlyAgents = Invoke-Setup @('-Target', $t3, '-Components', 'AGENTS.md', '-NonInteractive')
Assert-Equal $onlyAgents.Code 0 'AGENTS.md only: exits 0'
Assert-True (Test-Path -LiteralPath (Join-Path $t3 'AGENTS.md')) 'AGENTS.md only: wrote AGENTS.md'
Assert-Absent (Join-Path $t3 '.dsh') 'AGENTS.md only: wrote nothing else'

$t4 = New-TestDir 'skill-only'
$onlySkill = Invoke-Setup @('-Target', $t4, '-Components', 'skill', '-NonInteractive')
Assert-Equal $onlySkill.Code 0 'skill only: exits 0'
Assert-True (Test-Path -LiteralPath (Join-Path $t4 '.dsh\skills\dsh-orchestration\SKILL.md')) 'skill only: wrote the skill'
Assert-Absent (Join-Path $t4 '.dsh\orchestration') 'skill only: no orchestration directory'
Assert-Absent (Join-Path $t4 'AGENTS.md') 'skill only: no AGENTS.md'

# --- 7. numeric profile -------------------------------------------------------

Write-Section '7. Numeric profile selection'
$t5 = New-TestDir 'numeric-profile'
$numeric = Invoke-Setup @('-Target', $t5, '-Profile', '3', '-Components', 'orchestration', '-NonInteractive')
Assert-Equal $numeric.Code 0 'exits 0'
Assert-Equal (Get-Content -LiteralPath (Join-Path $t5 '.dsh\orchestration\profile.json') -Raw | ConvertFrom-Json).name 'pro-2-subagents' '-Profile 3 maps to the third listed profile'

# --- 8. user scope ------------------------------------------------------------

Write-Section '8. -Scope User honours DSH_HOME'
$userHome = New-TestDir 'user-home'
$savedDshHome = $env:DSH_HOME
$env:DSH_HOME = $userHome
try {
  $user = Invoke-Setup @('-Scope', 'User', '-Profile', 'pro', '-NonInteractive')
} finally {
  $env:DSH_HOME = $savedDshHome
}
Assert-Equal $user.Code 0 'exits 0'
Assert-True (Test-Path -LiteralPath (Join-Path $userHome 'skills\dsh-orchestration\SKILL.md')) 'skill written under DSH_HOME'
Assert-True (Test-Path -LiteralPath (Join-Path $userHome 'orchestration\orchestrate.js')) 'orchestration written under DSH_HOME'
Assert-True (Test-Path -LiteralPath (Join-Path $userHome 'AGENTS.md')) 'user-global AGENTS.md written'
Assert-Absent (Join-Path $userHome '.dsh') 'user scope does not nest a .dsh directory'

# --- 9. refusals --------------------------------------------------------------

Write-Section '9. Refusals exit 1 with a reason'
$badProfile = Invoke-Setup @('-Target', $t2, '-Profile', 'nope', '-NonInteractive')
Assert-Equal $badProfile.Code 1 'unknown profile: exit 1'
Assert-Contains $badProfile.Text 'Setup cancelled: unknown profile' 'unknown profile: message'

$badComponent = Invoke-Setup @('-Target', $t2, '-Components', 'everything', '-NonInteractive')
Assert-Equal $badComponent.Code 1 'unknown component: exit 1'
Assert-Contains $badComponent.Text 'unknown component' 'unknown component: message'

$kitTarget = Invoke-Setup @('-Target', $KitRoot, '-NonInteractive')
Assert-Equal $kitTarget.Code 1 'kit root as target: exit 1'
Assert-Contains $kitTarget.Text 'target must not be the kit directory itself' 'kit root as target: message'

$noTarget = Invoke-Setup @('-NonInteractive')
Assert-Equal $noTarget.Code 1 'missing target: exit 1'
Assert-Contains $noTarget.Text 'Target is required' 'missing target: message'

$missing = Invoke-Setup @('-Target', (Join-Path $Root 'does-not-exist'), '-NonInteractive')
Assert-Equal $missing.Code 1 'nonexistent target: exit 1'
Assert-Contains $missing.Text 'target is not a directory' 'nonexistent target: message'

$fileTarget = Join-Path $Root 'a-file.txt'
Set-Content -LiteralPath $fileTarget -Value 'x' -Encoding utf8
$asFile = Invoke-Setup @('-Target', $fileTarget, '-NonInteractive')
Assert-Equal $asFile.Code 1 'file as target: exit 1'
Assert-Contains $asFile.Text 'target is not a directory' 'file as target: message'

$t6 = New-TestDir 'blocked-skill'
New-Item -ItemType Directory -Path (Join-Path $t6 '.dsh\skills') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $t6 '.dsh\skills\dsh-orchestration') -Value 'not a directory' -Encoding utf8
$blocked = Invoke-Setup @('-Target', $t6, '-Components', 'skill', '-NonInteractive')
Assert-Equal $blocked.Code 1 'file where the skill directory belongs: exit 1'
Assert-Contains $blocked.Text 'exists as a file; expected a directory' 'file where the skill directory belongs: message'
Assert-Equal (Get-Text (Join-Path $t6 '.dsh\skills\dsh-orchestration')).Trim() 'not a directory' 'the blocking file is left untouched'

# --- summary ------------------------------------------------------------------

Write-Host ''
if ($script:Fail -eq 0) {
  Write-Host "  PASS - $($script:Pass)/$($script:Pass) checks passed" -ForegroundColor Green
} else {
  Write-Host "  FAIL - $script:Pass passed, $script:Fail failed" -ForegroundColor Red
  Write-Host "  artifacts kept at $Root" -ForegroundColor Yellow
}

if ($script:Fail -eq 0 -and -not $KeepArtifacts) {
  Remove-Item -LiteralPath $Root -Recurse -Force
} elseif ($script:Fail -eq 0) {
  Write-Host "  artifacts kept at $Root (-KeepArtifacts)" -ForegroundColor Yellow
}

if ($script:Fail -gt 0) { exit 1 }
exit 0
