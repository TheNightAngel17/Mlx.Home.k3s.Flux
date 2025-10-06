param(
  [switch]$Verbose,
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"

$Root = Join-Path (Get-Location) "apps"

# Abbreviation map (extend as needed)
$AbbrMap = @{
  "PersistentVolumeClaim"      = "PVC"
  "PersistentVolume"           = "PV"
  "CustomResourceDefinition"   = "CRDS"
}

# Toggle copy vs rename
$CopyMode = $false  # set $true if you want to keep originals

function Write-VerboseMsg { param($msg) if ($Verbose) { Write-Host $msg } }
function Write-Failure { param($msg) Write-Host $msg }

function Get-YamlKinds {
  param([string]$Content)
  $kinds = @()
  # Split multi-docs on lines that are just --- (allow leading/trailing spaces)
  $docs = ($Content -split "(?m)^[\s-]{3,}\s*$")
  foreach ($doc in $docs) {
    if (-not ($doc -match '(?m)^\s*kind:\s*\S')) { continue }
    $m = [regex]::Match($doc, '(?m)^\s*kind:\s*("?)([A-Za-z0-9]+)\1\s*$')
    if ($m.Success) {
      $val = $m.Groups[2].Value
      if ($kinds -notcontains $val) { $kinds += $val }
    }
  }
  # Force array semantics even if single element so callers can rely on .Count
  return ,$kinds
}

function KindToken {
  param($kind)
  if ($AbbrMap.ContainsKey($kind)) { return $AbbrMap[$kind] }
  return $kind  # already PascalCase in manifests
}

function Update-KustomizationFile {
  param(
    [string]$KustomPath,
    [string]$OldName,
    [string]$NewName,
    [switch]$DryRun
  )
  if (-not (Test-Path $KustomPath)) { return }
  $orig = Get-Content -Raw -Path $KustomPath
  if ($orig -notmatch [regex]::Escape($OldName)) { return }
  # Replace only whole resource list entries (lines containing - <filename>)
  $updated = ($orig -split "`n") | ForEach-Object {
    if ($_ -match "^\s*-\s*$([regex]::Escape($OldName))\s*$") {
      $_ -replace [regex]::Escape($OldName), $NewName
    } else {
      $_
    }
  }
  if ($DryRun) {
    Write-Host "[DRYRUN] Would update kustomization: $(Split-Path -Leaf $KustomPath) ($OldName -> $NewName)"
    return
  }
  $newContent = $updated -join "`n"
  if ($newContent -ne $orig) {
    $newContent | Set-Content -Path $KustomPath -NoNewline
    Write-VerboseMsg "updated kustomization: $(Split-Path -Leaf $KustomPath)"
  }
}

$yamlFiles = Get-ChildItem -Path $Root -Recurse -File |
  Where-Object { $_.Extension -in '.yaml', '.yml' -and $_.Name -ne 'kustomization.yaml' }

foreach ($fileInfo in $yamlFiles) {
  $file = $fileInfo.FullName
  $oldName = $fileInfo.Name
  $content = Get-Content -Raw -Path $file
  $kinds = Get-YamlKinds -Content $content

  $relativeShort = $file.Substring($Root.Length+1)

  if (-not $kinds -or $kinds.Count -eq 0) {
    Write-Failure "SKIP (no kind): $relativeShort"
    continue
  }

  # Build kind token: single kind uses direct token; multi-kind concatenates tokens with '_'
  if ($kinds.Count -eq 1) {
    $kindToken = KindToken -kind $kinds[0]
  } else {
    $kindToken = ($kinds | ForEach-Object { KindToken -kind $_ }) -join '_'
    Write-VerboseMsg "Multi-kind detected [$($kinds -join ',')] => $kindToken"
  }

  # app name = top-level app folder (after /apps/)
  $relative = $file.Substring($Root.Length).TrimStart('\','/')
  $parts = $relative -split '[\\/]'
  $appName = $parts[0]

  # env detection
  $env = $null
  if ($relative -match '[\\/]overlays[\/](dev|prd)[\\/]') {
    $env = $Matches[1]
  }

  $dir = Split-Path -Parent $file
  $newBase = if ($env) { "${appName}_${kindToken}_${env}" } else { "${appName}_${kindToken}" }
  $newName = "$newBase.yaml"
  if ($oldName -eq $newName) {
    Write-VerboseMsg "OK (already): $relative"
    continue
  }

  $target = Join-Path $dir $newName
  if (Test-Path $target) {
    Write-Failure "SKIP (target exists): $relative -> $newName"
    continue
  }

  if ($DryRun) {
    $operation = if ($CopyMode) { "COPY" } else { "RENAME" }
  Write-Host "[DRYRUN] Would ${operation}: $relative -> $newName"
  } elseif ($CopyMode) {
    Copy-Item -Path $file -Destination $target
    Write-VerboseMsg "COPY: $relative -> $newName"
  } else {
    Rename-Item -Path $file -NewName $newName
    Write-VerboseMsg "RENAME: $relative -> $newName"
  }

  # Update kustomization in same dir
  $kustom = Join-Path $dir "kustomization.yaml"
  Update-KustomizationFile -KustomPath $kustom -OldName $oldName -NewName $newName -DryRun:$DryRun

  # Also check parent overlay/base directory kustomization (one level up)
  $parentKustom = Join-Path (Split-Path -Parent $dir) "kustomization.yaml"
  if ($parentKustom -ne $kustom) {
    Update-KustomizationFile -KustomPath $parentKustom -OldName $oldName -NewName $newName -DryRun:$DryRun
  }
}

Write-VerboseMsg "Done."