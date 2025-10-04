[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("dev", "prd")]
  [string]$Env,

  [Parameter(ParameterSetName = 'Rotate', Mandatory = $true)]
  [string]$CurrentCertPrivateKey,

  [Parameter(ParameterSetName = 'Rotate', Mandatory = $true)]
  [ValidateSet("RSA4096", "Ed25519")]
  [string]$NewAlgorithm,

  [Parameter(ParameterSetName = 'Clean', Mandatory = $true)]
  [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    if (Test-Path -LiteralPath $dir) {
      Remove-Item -LiteralPath $dir -Recurse -Force
    }
    Set-DirectoryPresent -Path $dir
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
  foreach ($key in $Table.Keys) {
    $clone[$key] = $Table[$key]
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
  foreach ($key in $EncryptedData.Keys) {
    $newSection += (' ' * ($indent + 2)) + "${key}: $($EncryptedData[$key])"
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

if (-not [System.IO.Path]::IsPathRooted($CurrentCertPrivateKey)) {
  $currentKeyPath = Join-Path $envRoot $CurrentCertPrivateKey
} else {
  $currentKeyPath = $CurrentCertPrivateKey
}

if (-not (Test-Path -LiteralPath $currentKeyPath)) {
  throw "Current sealed secret private key not found at '$currentKeyPath'."
}

$currentKeyPath = (Resolve-Path -LiteralPath $currentKeyPath).Path

$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
$newKeyBaseName = "{0}_{1}_{2}_SealedSecret" -f $Env, $timestamp, $NewAlgorithm
$newKeyPath = Join-Path $envRoot ("{0}.key" -f $newKeyBaseName)
$newCertPath = Join-Path $envRoot ("{0}.cert" -f $newKeyBaseName)
$newTlsSecretPath = Join-Path $envRoot ("{0}.yaml" -f $newKeyBaseName)

switch ($NewAlgorithm) {
  'RSA4096' {
    Write-Verbose "Generating RSA4096 keypair."
    Invoke-ExternalCommand -FileName 'openssl' -Arguments @(
      'req','-x509','-nodes','-newkey','rsa:4096','-days','365',
      '-keyout',$newKeyPath,'-out',$newCertPath,'-subj','/CN=sealed-secrets'
    ) | Out-Null
  }
  'Ed25519' {
    Write-Verbose "Generating Ed25519 keypair."
    Invoke-ExternalCommand -FileName 'openssl' -Arguments @('genpkey','-algorithm','Ed25519','-out',$newKeyPath) | Out-Null
    Invoke-ExternalCommand -FileName 'openssl' -Arguments @('req','-new','-x509','-key',$newKeyPath,'-out',$newCertPath,'-days','365','-subj','/CN=sealed-secrets') | Out-Null
  }
  default {
    throw "Unsupported algorithm '$NewAlgorithm'."
  }
}

$newKeyPath = (Resolve-Path -LiteralPath $newKeyPath).Path
$newCertPath = (Resolve-Path -LiteralPath $newCertPath).Path
$certBytes = [System.IO.File]::ReadAllBytes($newCertPath)
$keyBytes = [System.IO.File]::ReadAllBytes($newKeyPath)
$certBase64 = [System.Convert]::ToBase64String($certBytes)
$keyBase64 = [System.Convert]::ToBase64String($keyBytes)
$tlsSecretName = "sealed-secrets-key{0}" -f ([System.Guid]::NewGuid().ToString('N').Substring(0,6))
$tlsSecretContent = @(
  'apiVersion: v1',
  'kind: Secret',
  'type: kubernetes.io/tls',
  'metadata:',
  "  name: $tlsSecretName",
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
