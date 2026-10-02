<#
.SYNOPSIS
  Install the DSH-native orchestration kit into a project, or into your DSH home.

.DESCRIPTION
  Installs three components, each confirmed separately:

    skill          <target>/.dsh/skills/dsh-orchestration/   (SKILL.md + references + assets)
    orchestration  <target>/.dsh/orchestration/             (orchestrate.js + the chosen profile)
    AGENTS.md      <target>/AGENTS.md                        (merge, never clobber)

  With -Scope User the destinations move under $DSH_HOME (default ~/.dsh):
  skills\ and orchestration\, plus the user-global AGENTS.md that DSH reads first.

  DSH has no project config file and no agent registry, so this installer writes
  no configuration. It writes files DSH actually reads, and prints the two Host
  settings the kit depends on but cannot set for you.

.EXAMPLE
  pwsh -File setup.ps1 -Target C:\work\my-app -Profile pro

.EXAMPLE
  pwsh -File setup.ps1 -Target C:\work\my-app -Profile plus-2-subagents -Components skill,AGENTS.md -NonInteractive

.EXAMPLE
  pwsh -File setup.ps1 -Scope User -Profile pro-exec-max -NonInteractive

.EXAMPLE
  pwsh -File setup.ps1 -Target C:\work\my-app -DryRun
#>
[CmdletBinding()]
param(
  [string]$Target,
  [string]$Profile = 'pro',
  [ValidateSet('Project', 'User')]
  [string]$Scope = 'Project',
  [string[]]$Components,
  [switch]$NonInteractive,
  [switch]$DryRun,
  [switch]$ListProfiles
)

$ErrorActionPreference = 'Stop'
$KitRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ProfileOrder = @('pro', 'plus', 'pro-2-subagents', 'plus-2-subagents', 'pro-max', 'pro-exec-max')
$ComponentNames = @('skill', 'orchestration', 'AGENTS.md')
$BeginMarker = '<!-- dsh-orchestration:begin -->'
$EndMarker = '<!-- dsh-orchestration:end -->'

function Write-Step([string]$message) { Write-Host "  $message" }
function Write-Head([string]$message) { Write-Host "`n$message" -ForegroundColor Cyan }

function Get-Profiles {
  $dir = Join-Path $KitRoot 'profiles'
  if (-not (Test-Path -LiteralPath $dir)) { throw "profiles directory not found at $dir" }
  $list = @()
  foreach ($entry in Get-ChildItem -LiteralPath $dir -Directory) {
    $file = Join-Path $entry.FullName 'profile.json'
    if (Test-Path -LiteralPath $file) {
      $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
      $list += [pscustomobject]@{ Name = $entry.Name; Path = $file; Data = $data }
    }
  }
  return ($list | Sort-Object { $ProfileOrder.IndexOf($_.Name) })
}

function Show-Profiles($profiles) {
  Write-Host "`nAvailable profiles`n" -ForegroundColor Cyan
  foreach ($profile in $profiles) {
    $index = $ProfileOrder.IndexOf($profile.Name) + 1
    $data = $profile.Data
    Write-Host ("  {0}  {1,-17} root {2}/{3}  exec {4}/{5}  review {6}/{7}  max {8}" -f `
      $index, $profile.Name, `
      $data.root.model, $data.root.reasoning_effort, `
      $data.execution.model, $data.execution.reasoning_effort, `
      $data.reviewer.model, $data.reviewer.reasoning_effort, `
      $data.host.maxActiveSubagents)
  }
  Write-Host ''
}

function Test-ReparsePoint([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  $item = Get-Item -LiteralPath $path -Force
  return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Read-TextFile([string]$path) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  if ($hasBom) { $text = $text.TrimStart([char]0xFEFF) }
  return @{ Text = $text; HasBom = $hasBom }
}

function Write-TextFile([string]$path, [string]$text, [bool]$withBom) {
  $encoding = New-Object System.Text.UTF8Encoding($withBom)
  [System.IO.File]::WriteAllText($path, $text, $encoding)
}

function Get-NormalizedText([string]$text) {
  $flat = $text -replace "`r`n", "`n"
  $lines = $flat -split "`n" | ForEach-Object { $_.TrimEnd() }
  return (($lines -join "`n").Trim())
}

function Confirm-Component([string]$name, [string]$detail) {
  if ($NonInteractive) { return $true }
  $answer = Read-Host "Install $name ($detail)? [Y/n]"
  if ([string]::IsNullOrWhiteSpace($answer)) { return $true }
  $normalized = $answer.Trim().ToLowerInvariant()
  return ($normalized -eq 'y' -or $normalized -eq 'yes')
}

function New-CopyItem([string]$source, [string]$relative, [string]$text) {
  return [pscustomobject]@{ Source = $source; Relative = $relative; Text = $text }
}

function Get-ComponentItems([string]$source, [string[]]$items) {
  $list = @()
  foreach ($item in $items) {
    $full = Join-Path $source $item
    if (-not (Test-Path -LiteralPath $full)) { throw "kit is incomplete: $full is missing" }
    if (Test-Path -LiteralPath $full -PathType Container) {
      foreach ($file in Get-ChildItem -LiteralPath $full -Recurse -File) {
        $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
        $list += (New-CopyItem $file.FullName $relative '')
      }
    } else {
      $list += (New-CopyItem $full $item '')
    }
  }
  return $list
}

function Assert-WritableTarget([string]$dest) {
  if (Test-ReparsePoint $dest) { throw "refusing to write through a symlink or junction at $dest" }
  if (Test-Path -LiteralPath $dest -PathType Leaf) { throw "$dest exists as a file; expected a directory" }
}

function Get-OverwriteWarning($items, [string]$dest) {
  if (-not (Test-Path -LiteralPath $dest)) { return @() }
  $existing = @()
  foreach ($item in $items) {
    if (Test-Path -LiteralPath (Join-Path $dest $item.Relative)) { $existing += $item.Relative }
  }
  return $existing
}

function Copy-ComponentItems($items, [string]$dest) {
  Assert-WritableTarget $dest
  if (-not (Test-Path -LiteralPath $dest)) {
    if ($DryRun) { Write-Step "would create $dest" } else { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
  }
  $created = 0
  $overwritten = 0
  foreach ($item in $items) {
    $target = Join-Path $dest $item.Relative
    $exists = Test-Path -LiteralPath $target
    if ($exists -and (Test-ReparsePoint $target)) { throw "refusing to overwrite a symlink at $target" }
    if ($DryRun) {
      Write-Step "would write $($item.Relative)"
    } else {
      $parent = Split-Path -Parent $target
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
      if ($item.Text) { Write-TextFile $target $item.Text $false } else { Copy-Item -LiteralPath $item.Source -Destination $target -Force }
    }
    if ($exists) { $overwritten++ } else { $created++ }
  }
  return @{ Created = $created; Overwritten = $overwritten }
}

function Install-AgentsBlock([string]$dest, [string]$block, [bool]$confirmed) {
  if (-not $confirmed) { return @{ Action = 'skipped' } }
  if (Test-ReparsePoint $dest) { throw "refusing to write through a symlink at $dest" }

  if (-not (Test-Path -LiteralPath $dest)) {
    if ($DryRun) { Write-Step "would create $dest" } else { Write-TextFile $dest $block $false }
    return @{ Action = 'created' }
  }

  $existing = Read-TextFile $dest
  $text = $existing.Text
  $startIndex = $text.IndexOf($BeginMarker)
  $endIndex = $text.IndexOf($EndMarker)

  if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
    if ((Get-NormalizedText $text.Substring($startIndex, $endIndex - $startIndex + $EndMarker.Length)) -eq (Get-NormalizedText $block)) {
      return @{ Action = 'already-present' }
    }
    $rebuilt = $text.Substring(0, $startIndex) + $block + $text.Substring($endIndex + $EndMarker.Length)
    if ($DryRun) { Write-Step "would replace the dsh-orchestration block in $dest" } else { Write-TextFile $dest $rebuilt $existing.HasBom }
    return @{ Action = 'updated' }
  }

  if ((Get-NormalizedText $text).Contains((Get-NormalizedText $block))) {
    return @{ Action = 'already-present' }
  }

  $merged = $text.TrimEnd() + "`n`n" + $block + "`n"
  if ($DryRun) { Write-Step "would append the dsh-orchestration block to $dest (existing content preserved)" } else { Write-TextFile $dest $merged $existing.HasBom }
  return @{ Action = 'appended' }
}

function New-ProfileSection($profile) {
  $data = $profile.Data
  $lines = @(
    '## Profile in use',
    '',
    "Profile: ``$($data.name)`` - $($data.displayName)",
    '',
    '| Node | Model | Requested effort | Access |',
    '| --- | --- | --- | --- |',
    "| root (you) | $($data.root.model) | $($data.root.reasoning_effort) | orchestrates and integrates |",
    "| explorer, researcher, worker, tester | $($data.execution.model) | $($data.execution.reasoning_effort) | read-only, write, test artifacts |",
    "| reviewer | $($data.reviewer.model) | $($data.reviewer.reasoning_effort) | read-only |",
    '',
    "Concurrency: keep at most $($data.host.maxActiveSubagents) subagents alive (Host setting ``maxActiveSubagents``)."
  )
  return ($lines -join "`n")
}

function Resolve-Target([string]$requested) {
  if ([string]::IsNullOrWhiteSpace($requested)) {
    if ($NonInteractive) { throw 'Target is required when -NonInteractive is used (or pass -Scope User).' }
    $requested = (Read-Host 'Target repository path').Trim().Trim('"')
  }
  if (-not (Test-Path -LiteralPath $requested -PathType Container)) { throw "target is not a directory: $requested" }
  $resolved = (Resolve-Path -LiteralPath $requested).Path.TrimEnd('\')
  $kit = (Resolve-Path -LiteralPath $KitRoot).Path.TrimEnd('\')
  if ($resolved -ieq $kit) { throw 'target must not be the kit directory itself; choose the project you are installing into' }
  return $resolved
}

try {
  Write-Host ''
  Write-Host '  DSH orchestration kit - installer' -ForegroundColor White
  Write-Host '  Astra/Luna two-tier topology for DeepSeek Harness'

  $profiles = Get-Profiles
  if ($profiles.Count -eq 0) { throw 'no profiles found under profiles/' }

  if ($ListProfiles) {
    Show-Profiles $profiles
    exit 0
  }

  if ($Profile -match '^\d+$') {
    $index = [int]$Profile
    if ($index -lt 1 -or $index -gt $ProfileOrder.Count) { throw "profile number must be between 1 and $($ProfileOrder.Count)" }
    $Profile = $ProfileOrder[$index - 1]
  }
  $selected = $profiles | Where-Object { $_.Name -ieq $Profile }
  if (-not $selected) { throw "unknown profile '$Profile'. Available: $((($profiles | ForEach-Object { $_.Name }) -join ', '))" }
  $selected = @($selected)[0]

  if (-not $Components -or $Components.Count -eq 0) { $Components = $ComponentNames }
  foreach ($component in $Components) {
    if ($ComponentNames -notcontains $component) {
      throw "unknown component '$component'. Available: $($ComponentNames -join ', ')"
    }
  }

  $scopeRoot = if ($Scope -eq 'User') { if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' } } else { Resolve-Target $Target }
  $skillSource = $KitRoot
  $orchestrationSource = Join-Path $KitRoot 'scripts'
  $agentsSource = Join-Path $KitRoot 'assets\agents-block.md'

  foreach ($required in @((Join-Path $KitRoot 'SKILL.md'), (Join-Path $KitRoot 'references'), (Join-Path $KitRoot 'assets'), (Join-Path $orchestrationSource 'orchestrate.js'), $agentsSource)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "kit is incomplete: $required is missing" }
  }

  $skillDest = if ($Scope -eq 'User') { Join-Path $scopeRoot 'skills\dsh-orchestration' } else { Join-Path $scopeRoot '.dsh\skills\dsh-orchestration' }
  $orchestrationDest = if ($Scope -eq 'User') { Join-Path $scopeRoot 'orchestration' } else { Join-Path $scopeRoot '.dsh\orchestration' }
  $agentsDest = Join-Path $scopeRoot 'AGENTS.md'

  Write-Head "Scope:    $Scope ($scopeRoot)"
  Write-Head "Profile:  $($selected.Name)"
  Write-Step "skill          -> $skillDest"
  Write-Step "orchestration  -> $orchestrationDest"
  Write-Step "AGENTS.md      -> $agentsDest"
  if ($DryRun) { Write-Host "`n  Dry run: nothing will be written." -ForegroundColor Yellow }

  $results = @()

  if ($Components -contains 'skill') {
    $skillItems = Get-ComponentItems $skillSource @('SKILL.md', 'references', 'assets')
    $overwrites = Get-OverwriteWarning $skillItems $skillDest
    if ($overwrites.Count -gt 0) {
      Write-Host "`n  WARNING: $($overwrites.Count) existing file(s) under $skillDest will be overwritten:" -ForegroundColor Yellow
      foreach ($file in $overwrites) { Write-Step "  $file" }
    }
    if (Confirm-Component 'skill' 'SKILL.md, references, assets') {
      $copy = Copy-ComponentItems $skillItems $skillDest
      $results += "skill: $($copy.Created) created, $($copy.Overwritten) overwritten"
    } else {
      $results += 'skill: skipped'
    }
  }

  if ($Components -contains 'orchestration') {
    $note = @(
      "# Orchestration profile: $($selected.Name)",
      '',
      "$($selected.Data.description)",
      '',
      'Use `orchestrate.js` by pasting it into the `workflow` tool''s `script` argument, with args:',
      '',
      '    { objective: "...", profile: "' + $selected.Name + '", requirements: [...], writePaths: "..." }',
      '',
      'The profile records which model and requested effort each node runs at. The script pins the',
      'model per node; reasoning effort is a request written into the prompt, because the workflow',
      'tool exposes no effort override.',
      '',
      'Reasoning effort values DSH accepts: off | low | high | max (default high).'
    ) -join "`n"
    $orchItems = @(
      (New-CopyItem (Join-Path $orchestrationSource 'orchestrate.js') 'orchestrate.js' ''),
      (New-CopyItem $selected.Path 'profile.json' ''),
      (New-CopyItem '' 'README.md' $note)
    )
    $overwrites = Get-OverwriteWarning $orchItems $orchestrationDest
    if ($overwrites.Count -gt 0) {
      Write-Host "`n  WARNING: $($overwrites.Count) existing file(s) under $orchestrationDest will be overwritten:" -ForegroundColor Yellow
      foreach ($file in $overwrites) { Write-Step "  $file" }
    }
    if (Confirm-Component 'orchestration' 'orchestrate.js + the selected profile') {
      $copy = Copy-ComponentItems $orchItems $orchestrationDest
      $results += "orchestration: $($copy.Created) created, $($copy.Overwritten) overwritten ($($selected.Name))"
    } else {
      $results += 'orchestration: skipped'
    }
  }

  if ($Components -contains 'AGENTS.md') {
    $block = (Read-TextFile $agentsSource).Text.TrimEnd() + "`n`n" + (New-ProfileSection $selected) + "`n" + $EndMarker + "`n"
    $block = $BeginMarker + "`n" + $block
    $merge = Install-AgentsBlock $agentsDest $block (Confirm-Component 'AGENTS.md' 'merge into instructions DSH reads')
    $results += "AGENTS.md: $($merge.Action)"
  }

  Write-Head 'Summary'
  foreach ($line in $results) { Write-Step $line }

  Write-Head 'Two Host settings this kit depends on'
  Write-Step '1. Enable subagent model selection so a subagent can be pinned to a model.'
  Write-Step '   Without it, model pins only apply through the workflow tool (which always supports them).'
  Write-Step ("2. If you use profile {0}, set maxActiveSubagents to {1}." -f $selected.Name, $selected.Data.host.maxActiveSubagents)
  Write-Step '   Open the DSH settings panel to change both; no file in this repo controls them.'

  Write-Head 'Next'
  Write-Step 'Restart the session if the skill does not appear: DSH discovers skills at <project>/.dsh/skills.'
  if ($DryRun) { Write-Host "`n  Dry run complete: nothing was written." -ForegroundColor Yellow } else { Write-Host "`n  Installed." -ForegroundColor Green }
  exit 0
} catch {
  Write-Host "`nSetup cancelled: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
