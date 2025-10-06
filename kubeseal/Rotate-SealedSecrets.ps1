# <#
# .SYNOPSIS
#   Rotates Kubernetes SealedSecrets by generating a fresh controller keypair and resealing all app manifests.
#
# .DESCRIPTION
#   This script automates the end-to-end rotation of SealedSecrets for the MLX home clusters. It validates the
#   required tooling (`openssl`, `kubeseal`, and PowerShell 7+ YAML cmdlets), stages base and overlay manifests,
#   unseals them with the existing controller private key, reseals them with a newly generated certificate, and
#   writes the updated encrypted payloads back to the appropriate app overlays or base files. A companion TLS
#   Secret manifest is emitted for manual application to the cluster. Temporary working directories (00/01/02) are
#   recreated on each execution to keep artifacts isolated and repeatable.
#
# .PARAMETER Env
#   Target environment to process. Must be either `dev` or `prd` to match the overlay layout under `apps/`.
#   Alias: `-e`.
#
# .PARAMETER CurrentCertPrivateKey
#   Path to the existing SealedSecrets controller private key (PEM). Can be absolute, relative to the current
#   directory, or relative to the environment working folder. Outputs will be written alongside this key.
#   Aliases: `-Key`, `-k`.
#
# .PARAMETER NewAlgorithm
#   RSA key size for the new controller certificate. Defaults to `RSA4096`; supports `RSA2048`, `RSA3072`,
#   and `RSA4096`. (Ed25519 is intentionally disabled until upstream `kubeseal` gains support.)
#   Aliases: `-Algorithm`, `-a`.
#
# .PARAMETER Clean
#   When supplied, the script simply resets the staging directories for the selected environment and exits without
#   performing a rotation. Useful for clearing stale artifacts between runs.
#   Alias: `-c`.

# .PARAMETER Help
#   Displays this help information and exits without making changes.
#   Alias: `-h`.
#
# .EXAMPLE
#   ./Rotate-SealedSecrets.ps1 -Env dev -CurrentCertPrivateKey "C:\secrets\dev-controller.key"
#     Performs a full rotation for the dev environment using the provided key, emitting the new key, cert, and TLS
#     manifest next to the supplied path.
#
# .EXAMPLE
#   ./Rotate-SealedSecrets.ps1 -Env prd -Clean
#     Clears the `kubeseal/prd/00_sealed`, `01_unsealed`, and `02_resealed` directories and exits.
#
# .NOTES
#   The script should be executed from a machine that holds the current controller private key and has access to the
#   repository. Review the generated TLS Secret manifest before applying it to the cluster to ensure the namespace and
#   metadata align with your deployment practices.
# #>
[CmdletBinding()]
param(
  [Parameter(ParameterSetName = 'Rotate', Mandatory = $true)]
  [Parameter(ParameterSetName = 'Clean', Mandatory = $true)]
  [ValidateSet("dev", "prd")]
  [Alias('e')]
  [string]$Env,

  [Parameter(ParameterSetName = 'Rotate', Mandatory = $true)]
  [Alias('k')]
  [string]$Key,

  [Parameter(ParameterSetName = 'Rotate')]
  [ValidateSet("RSA2048", "RSA3072", "RSA4096")]
  [Alias('a')]
  [string]$Algorithm = "RSA4096",

  [Parameter(ParameterSetName = 'Clean', Mandatory = $true)]
  [Alias('c')]
  [switch]$Clean
,

  [Parameter(ParameterSetName = 'Help', Mandatory = $true)]
  [Alias('h')]
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSCmdlet.ParameterSetName -eq 'Help') {
  try {
    Get-Help -Name $MyInvocation.MyCommand.Path -Detailed | Out-Host
  } catch {
    Write-Host "Detailed help unavailable; displaying basic synopsis." -ForegroundColor Yellow
    Get-Help -Name $MyInvocation.MyCommand.Path | Out-Host
  }
  return
}

function Test-CommandAvailable {
  param([string]$Name)
  if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' was not found on PATH. Please install it before rerunning."
  }
}

function Set-DirectoryPresent {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    $null = New-Item -ItemType Directory -Path $Path -Force
  }
}

function Set-CleanDirectories {
  param([string[]]$Directories)
  foreach ($dir in $Directories) {
    Set-DirectoryPresent -Path $dir
    if (Test-Path -LiteralPath $dir) {
      Get-ChildItem -LiteralPath $dir -Force | ForEach-Object {
        if (-not ($_.PSIsContainer -eq $false -and $_.Name -eq '.gitkeep')) {
          Remove-Item -LiteralPath $_.FullName -Recurse -Force
        }
      }
    }
  }
}

function Invoke-ExternalCommand {
  param(
    [string]$FileName,
    [string[]]$Arguments,
    [string]$InputText = $null,
    [switch]$CaptureOutput
  )

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $FileName
  foreach ($arg in $Arguments) {
    [void]$psi.ArgumentList.Add($arg)
  }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardError = $true
  if ($CaptureOutput) {
    $psi.RedirectStandardOutput = $true
  }
  if ($InputText) {
    $psi.RedirectStandardInput = $true
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $psi
  $null = $process.Start()

  if ($InputText) {
    $process.StandardInput.Write($InputText)
    $process.StandardInput.Close()
  }

  $stdOut = $null
  if ($CaptureOutput) {
    $stdOut = $process.StandardOutput.ReadToEnd()
  }
  $stdErr = $process.StandardError.ReadToEnd()

  $process.WaitForExit()

  if ($process.ExitCode -ne 0) {
    throw "Command '$FileName $($Arguments -join ' ') failed with exit code $($process.ExitCode): $stdErr"
  }

  return [PSCustomObject]@{
    ExitCode = $process.ExitCode
    StdOut   = $stdOut
    StdErr   = $stdErr
  }
}

function Get-YamlDocument {
  param([string]$Path)
  $content = Get-Content -Raw -Path $Path
  if (-not $content) {
    return $null
  }
  $docs = ConvertFrom-Yaml -Yaml $content -AllDocuments
  if ($docs -is [System.Collections.IEnumerable]) {
    $docList = @()
    foreach ($doc in $docs) { $docList += $doc }
    if ($docList.Count -gt 0) { return $docList[0] }
  }
  return $docs
}

function Set-YamlDocument {
  param(
    [string]$Path,
    [object]$Document
  )
  $yaml = ConvertTo-Yaml -Data $Document
  Set-Content -Path $Path -Value $yaml -Encoding utf8
}

function Copy-Hashtable {
  param([hashtable]$Table)
  if (-not $Table) { return $null }
  $clone = [ordered]@{}
  foreach ($item in $Table.Keys) {
    $clone[$item] = $Table[$item]
  }
  return $clone
}

function Set-EncryptedDataSection {
  param(
    [string]$Path,
    [hashtable]$EncryptedData
  )

  $lines = Get-Content -Path $Path
  if (-not $lines) {
    throw "File '$Path' is empty; cannot update encryptedData."
  }

  $startIndex = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*encryptedData:\s*$') {
      $startIndex = $i
      break
    }
  }

  $indent = 0
  $endIndex = $lines.Count

  if ($startIndex -ge 0) {
    $indent = ($lines[$startIndex] -replace '(^\s*).*','$1').Length
    for ($j = $startIndex + 1; $j -lt $lines.Count; $j++) {
      $line = $lines[$j]
      if ([string]::IsNullOrWhiteSpace($line)) {
        continue
      }
      $lineIndent = ($line -replace '(^\s*).*','$1').Length
      if ($lineIndent -le $indent) {
        $endIndex = $j
        break
      }
    }
  } else {
    # Insert after spec:
    $specIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^\s*spec:\s*$') {
        $specIndex = $i
        break
      }
    }
    if ($specIndex -lt 0) {
      throw "Unable to locate 'spec:' block in '$Path' while updating encryptedData."
    }
    $indent = ($lines[$specIndex] -replace '(^\s*).*','$1').Length + 2
    $startIndex = $specIndex + 1
    $endIndex = $startIndex
  }

  $newSection = @()
  $newSection += (' ' * $indent) + 'encryptedData:'
  foreach ($item in $EncryptedData.Keys) {
    $newSection += (' ' * ($indent + 2)) + "${item}: $($EncryptedData[$item])"
  }

  $updated = New-Object System.Collections.Generic.List[string]

  if ($startIndex -gt 0) {
    for ($k = 0; $k -lt $startIndex; $k++) {
      $updated.Add($lines[$k]) | Out-Null
    }
  }

  foreach ($line in $newSection) {
    $updated.Add($line) | Out-Null
  }

  if ($endIndex -lt $lines.Count) {
    for ($k = $endIndex; $k -lt $lines.Count; $k++) {
      $updated.Add($lines[$k]) | Out-Null
    }
  }

  [System.IO.File]::WriteAllLines($Path, $updated)
}

# Validate tooling availability
Test-CommandAvailable -Name 'openssl'
Test-CommandAvailable -Name 'kubeseal'
Test-CommandAvailable -Name 'ConvertFrom-Yaml'
Test-CommandAvailable -Name 'ConvertTo-Yaml'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..') | Select-Object -ExpandProperty Path
$envRoot = Join-Path $scriptRoot $Env
$appsRoot = Join-Path $repoRoot 'apps'

if (-not (Test-Path -LiteralPath $appsRoot)) {
  throw "Apps folder not found at '$appsRoot'."
}

Set-DirectoryPresent -Path $envRoot
$stageSealedDir = Join-Path $envRoot '00_sealed'
$stageUnsealedDir = Join-Path $envRoot '01_unsealed'
$stageResealedDir = Join-Path $envRoot '02_resealed'
Set-CleanDirectories -Directories @($stageSealedDir, $stageUnsealedDir, $stageResealedDir)

if ($PSCmdlet.ParameterSetName -eq 'Clean') {
  Write-Verbose "Clean flag provided. Working folders reset; exiting."
  return
}

$resolvedPath = $null

if ([System.IO.Path]::IsPathRooted($Key)) {
  if (Test-Path -LiteralPath $Key) {
    $resolvedPath = Resolve-Path -LiteralPath $Key
  }
} else {
  try {
    $resolvedPath = Resolve-Path -Path $Key -ErrorAction Stop
  } catch {
    $resolvedPath = $null
  }

  if (-not $resolvedPath) {
    $candidate = Join-Path $envRoot $Key
    if (Test-Path -LiteralPath $candidate) {
      $resolvedPath = Resolve-Path -LiteralPath $candidate
    }
  }
}

if (-not $resolvedPath) {
  throw "Current sealed secret private key not found at '$Key'."
}

$currentKeyPath = $resolvedPath.Path
$currentKeyDirectory = Split-Path -Parent $currentKeyPath
Set-DirectoryPresent -Path $currentKeyDirectory

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$newKeyBaseName = "{0}_{1}_{2}_Secret" -f $Env, $timestamp, $Algorithm
$newKeyPath = Join-Path $currentKeyDirectory ("{0}.key" -f $newKeyBaseName)
$newCertPath = Join-Path $currentKeyDirectory ("{0}.crt" -f $newKeyBaseName)
$newTlsSecretPath = Join-Path $currentKeyDirectory ("{0}.yaml" -f $newKeyBaseName)

$rsaBits = $null
switch ($Algorithm) {
  'RSA2048' { $rsaBits = 2048; break }
  'RSA3072' { $rsaBits = 3072; break }
  'RSA4096' { $rsaBits = 4096; break }
  'Ed25519' {
    # Keeping the Ed25519 implementation for future enablement when kubeseal supports it.
    Write-Verbose "Generating Ed25519 keypair."
    Invoke-ExternalCommand -FileName 'openssl' -Arguments @('genpkey','-algorithm','Ed25519','-out',$newKeyPath) | Out-Null
    Invoke-ExternalCommand -FileName 'openssl' -Arguments @('req','-new','-x509','-key',$newKeyPath,'-out',$newCertPath,'-days','365','-subj','/CN=sealed-secrets') | Out-Null
    break
  }
  default {
    throw "Unsupported algorithm '$Algorithm'."
  }
}

if ($rsaBits) {
  Write-Verbose "Generating RSA$rsaBits keypair."
  Invoke-ExternalCommand -FileName 'openssl' -Arguments @(
    'req','-x509','-nodes','-newkey',"rsa:$rsaBits",'-days','365',
    '-keyout',$newKeyPath,'-out',$newCertPath,'-subj','/CN=sealed-secrets'
  ) | Out-Null
}

$newKeyPath = (Resolve-Path -LiteralPath $newKeyPath).Path
$newCertPath = (Resolve-Path -LiteralPath $newCertPath).Path
$certBytes = [System.IO.File]::ReadAllBytes($newCertPath)
$keyBytes = [System.IO.File]::ReadAllBytes($newKeyPath)
$certBase64 = [System.Convert]::ToBase64String($certBytes)
$keyBase64 = [System.Convert]::ToBase64String($keyBytes)
$tlsSecretName = $newKeyBaseName
$tlsSecretMetadataName = ($tlsSecretName -replace '_','-').ToLowerInvariant()
$tlsSecretContent = @(
  'apiVersion: v1',
  'kind: Secret',
  'type: kubernetes.io/tls',
  'metadata:',
  "  name: $tlsSecretMetadataName",
  '  namespace: kube-system',
  'data:',
  "  tls.crt: $certBase64",
  "  tls.key: $keyBase64"
)
[System.IO.File]::WriteAllLines($newTlsSecretPath, $tlsSecretContent)

$baseSealedFiles = Get-ChildItem -Path $appsRoot -Recurse -File -Filter '*_SealedSecret*.yaml' |
  Where-Object { $_.FullName -match "[\\/]base[\\/]" }

if (-not $baseSealedFiles) {
  throw "No base SealedSecret files were found under '$appsRoot'."
}

$entries = @()
foreach ($baseFile in $baseSealedFiles) {
  $basePath = $baseFile.FullName
  $relativeFromApps = [System.IO.Path]::GetRelativePath($appsRoot, $basePath)
  $stageSealedPath = Join-Path $stageSealedDir $relativeFromApps
  Set-DirectoryPresent -Path (Split-Path -Parent $stageSealedPath)
  Copy-Item -LiteralPath $basePath -Destination $stageSealedPath -Force

  $appRoot = Split-Path -Parent (Split-Path -Parent $basePath)
  $appName = Split-Path -Leaf $appRoot
  $overlayPath = Join-Path $appRoot (Join-Path 'overlays' (Join-Path $Env $baseFile.Name))
  $overlayExists = Test-Path -LiteralPath $overlayPath

  if ($overlayExists) {
    Write-Verbose "Applying overlay encryptedData for $appName ($Env)."
    $baseDoc = Get-YamlDocument -Path $stageSealedPath
    $overlayDoc = Get-YamlDocument -Path $overlayPath
    if ($overlayDoc -and $overlayDoc.spec -and $overlayDoc.spec.encryptedData) {
      $baseDoc.spec.encryptedData = Copy-Hashtable -Table $overlayDoc.spec.encryptedData
      Set-YamlDocument -Path $stageSealedPath -Document $baseDoc
    } else {
      Write-Warning "Overlay file '$overlayPath' found but no spec.encryptedData detected. Using base data."
    }
  }

  $stageUnsealedPath = Join-Path $stageUnsealedDir ($relativeFromApps -replace '_SealedSecret','_Secret')
  Set-DirectoryPresent -Path (Split-Path -Parent $stageUnsealedPath)

  $stageResealedPath = Join-Path $stageResealedDir $relativeFromApps
  Set-DirectoryPresent -Path (Split-Path -Parent $stageResealedPath)

  $entries += [PSCustomObject]@{
    AppName       = $appName
    BasePath      = $basePath
    OverlayPath   = if ($overlayExists) { $overlayPath } else { $null }
    StageSealed   = $stageSealedPath
    StageUnsealed = $stageUnsealedPath
    StageResealed = $stageResealedPath
    UpdateMode    = if ($overlayExists) { 'Overlay' } else { 'Base' }
  }
}

foreach ($entry in $entries) {
  Write-Verbose "Unsealing: $($entry.AppName) -> $(Split-Path -Leaf $entry.StageSealed)"
  $sealedContent = Get-Content -Raw -Path $entry.StageSealed
  $result = Invoke-ExternalCommand -FileName 'kubeseal' -Arguments @(
    '--format=yaml','--recovery-unseal','--recovery-private-key',$currentKeyPath
  ) -InputText $sealedContent -CaptureOutput
  Set-Content -Path $entry.StageUnsealed -Value $result.StdOut -Encoding utf8
}

foreach ($entry in $entries) {
  Write-Verbose "Resealing: $($entry.AppName) -> $(Split-Path -Leaf $entry.StageResealed)"
  $unsealedContent = Get-Content -Raw -Path $entry.StageUnsealed
  $result = Invoke-ExternalCommand -FileName 'kubeseal' -Arguments @(
    '--format=yaml','--cert',$newCertPath
  ) -InputText $unsealedContent -CaptureOutput
  Set-Content -Path $entry.StageResealed -Value $result.StdOut -Encoding utf8
}

foreach ($entry in $entries) {
  Write-Verbose "Writing updated sealed secret for $($entry.AppName) [$Env]."
  $resealedDoc = Get-YamlDocument -Path $entry.StageResealed
  if (-not ($resealedDoc -and $resealedDoc.spec -and $resealedDoc.spec.encryptedData)) {
    throw "Resealed file '$($entry.StageResealed)' does not contain spec.encryptedData."
  }

  if ($entry.UpdateMode -eq 'Overlay' -and $entry.OverlayPath) {
    $newEncrypted = Copy-Hashtable -Table $resealedDoc.spec.encryptedData
    Set-EncryptedDataSection -Path $entry.OverlayPath -EncryptedData $newEncrypted
  } else {
    Copy-Item -LiteralPath $entry.StageResealed -Destination $entry.BasePath -Force
  }
}

Write-Host "Rotation complete." -ForegroundColor Green
Write-Host "New key:  $newKeyPath"
Write-Host "New cert: $newCertPath"
Write-Host "New TLS Secret manifest: $newTlsSecretPath"
