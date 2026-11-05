[CmdletBinding()]
param(
  [switch]$Source,
  [switch]$Release,
  [string]$Tag = "",
  [string]$BinDir = "$env:LOCALAPPDATA\fin\bin"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$Repo = "fin-hq/fin-releases"
$SourceRepo = "fin-hq/fin"
$PublicKeyBase64 = "/cpK6+QVcSRIrZvkXAn0sSGT6BAuivC4y2a7iHoc0Us="

function Require-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "$Name is required" }
}

function Require-Fields($Value, [string[]]$Names) {
  if ($null -eq $Value -or $Value -isnot [System.Management.Automation.PSCustomObject]) { throw "invalid manifest object" }
  $actual = @($Value.PSObject.Properties.Name | Sort-Object)
  $expected = @($Names | Sort-Object)
  if (($actual -join ',') -cne ($expected -join ',')) { throw "invalid manifest fields" }
}

function Decode-Base64($Value) {
  if ($Value -isnot [string] -or $Value.Length -eq 0 -or $Value.Length % 4 -ne 0 -or $Value -cnotmatch '\A[A-Za-z0-9+/]+={0,2}\z') { throw "invalid manifest encoding" }
  return [Convert]::FromBase64String($Value)
}

function Place([string]$File) {
  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
  $destination = Join-Path ([IO.Path]::GetFullPath($BinDir)) "fin.exe"
  if (Test-Path -LiteralPath $destination) {
    $existing = Get-Item -Force -LiteralPath $destination
    if ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "destination must be a regular file" }
  }
  $staged = Join-Path ([IO.Path]::GetDirectoryName($destination)) (".fin-install-" + [Guid]::NewGuid() + ".exe")
  $backup = Join-Path ([IO.Path]::GetDirectoryName($destination)) (".fin-backup-" + [Guid]::NewGuid() + ".exe")
  $replaced = $false
  try {
    Copy-Item -LiteralPath $File -Destination $staged
    & $staged version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "candidate executable failed its version check" }
    if (Test-Path -LiteralPath $destination) {
      [IO.File]::Replace($staged, $destination, $backup)
      $replaced = $true
    } else {
      [IO.File]::Move($staged, $destination)
    }
    try {
      & $destination version | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "installed executable failed its version check" }
    } catch {
      if ($replaced) { [IO.File]::Replace($backup, $destination, $null) }
      else { Remove-Item -Force -LiteralPath $destination }
      throw
    }
    if (Test-Path -LiteralPath $backup) { Remove-Item -Force -LiteralPath $backup }
    Write-Host "installed $destination"
    if (-not (($env:Path -split ";") -contains $BinDir)) { Write-Host "note: add $BinDir to PATH" }
  } finally {
    if (Test-Path -LiteralPath $staged) { Remove-Item -Force -LiteralPath $staged }
  }
}

function Install-Source {
  Require-Command "go"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("fin-" + [Guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $src = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
    if (-not (Test-Path (Join-Path $src "go.mod")) -or -not (Select-String -Quiet -Path (Join-Path $src "go.mod") -Pattern "^module github.com/fin-hq/fin$")) {
      Require-Command "gh"
      $arguments = @("repo", "clone", $SourceRepo, (Join-Path $tmp "src"), "--", "--depth", "1")
      if ($Tag) { $arguments += @("--branch", $Tag) }
      & gh @arguments | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "source clone failed" }
      $src = Join-Path $tmp "src"
    }
    Push-Location $src
    $previousCGO = $env:CGO_ENABLED
    try {
      $version = "dev"
      if (Get-Command git -ErrorAction SilentlyContinue) {
        $candidate = (& git describe --tags --always --dirty 2>$null)
        if ($LASTEXITCODE -eq 0 -and $candidate) { $version = $candidate }
      }
      $env:CGO_ENABLED = "0"
      & go build -trimpath -ldflags "-s -w -X github.com/fin-hq/fin/internal/cli/app.Version=$version" -o (Join-Path $tmp "fin.exe") ./cmd/fin
      if ($LASTEXITCODE -ne 0) { throw "go build failed" }
    } finally {
      $env:CGO_ENABLED = $previousCGO
      Pop-Location
    }
    Place (Join-Path $tmp "fin.exe")
  } finally { Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

function Download([string]$Url, [string]$File, [long]$Limit) {
  & curl.exe -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-redirs 5 --connect-timeout 15 --max-time 300 --retry 2 --max-filesize $Limit --output $File $Url
  if ($LASTEXITCODE -ne 0) { throw "download failed" }
}

function Install-Release {
  Require-Command "curl.exe"
  if ($Tag -and $Tag -cnotmatch '\Av[0-9]+\.[0-9]+\.[0-9]+\z') { throw "tag must be vX.Y.Z" }
  Require-Command "openssl"
  $architecture = $env:PROCESSOR_ARCHITEW6432
  if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
  $arch = switch ($architecture) { "AMD64" { "amd64" } "ARM64" { "arm64" } default { throw "unsupported architecture: $architecture" } }
  $platform = "windows_$arch"
  $asset = "fin_$platform.exe"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("fin-" + [Guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $manifestPath = Join-Path $tmp "manifest.json"
    $manifestUrl = "https://github.com/$Repo/releases/latest/download/manifest.json"
    if ($Tag) { $manifestUrl = "https://github.com/$Repo/releases/download/$Tag/manifest.json" }
    Download $manifestUrl $manifestPath 1048576
    if (-not (Test-Path -LiteralPath $manifestPath) -or (Get-Item -LiteralPath $manifestPath).Length -gt 1048576) { throw "manifest is missing or exceeds size limit" }
    $envelope = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Require-Fields $envelope @("payload", "signature")
    [byte[]]$payloadBytes = Decode-Base64 $envelope.payload
    [byte[]]$signatureBytes = Decode-Base64 $envelope.signature
    if ($payloadBytes.Length -eq 0 -or $signatureBytes.Length -ne 64) { throw "invalid manifest payload or signature" }
    [byte[]]$prefix = @(0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00)
    [byte[]]$publicKey = [Convert]::FromBase64String($PublicKeyBase64)
    $payloadPath = Join-Path $tmp "payload.json"
    $signaturePath = Join-Path $tmp "signature.bin"
    $keyPath = Join-Path $tmp "key.der"
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    [IO.File]::WriteAllBytes($signaturePath, $signatureBytes)
    [IO.File]::WriteAllBytes($keyPath, [byte[]]($prefix + $publicKey))
    & openssl pkeyutl -verify -pubin -keyform DER -inkey $keyPath -rawin -in $payloadPath -sigfile $signaturePath *> $null
    if ($LASTEXITCODE -ne 0) { throw "manifest signature verification failed" }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $payload = $utf8.GetString($payloadBytes) | ConvertFrom-Json
    Require-Fields $payload @("version", "artifacts")
    if ($payload.version -isnot [string] -or $payload.version -cnotmatch '\Av?[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?\z') { throw "invalid signed release version" }
    if ($Tag -and ($Tag -creplace '^v', '') -cne ($payload.version -creplace '^v', '')) { throw "signed version differs from requested tag" }
    if ($payload.artifacts -isnot [System.Management.Automation.PSCustomObject]) { throw "invalid signed artifact map" }
    $property = $payload.artifacts.PSObject.Properties[$platform]
    if ($null -eq $property) { throw "signed manifest has no entry for $platform" }
    $entry = $property.Value
    Require-Fields $entry @("url", "sha256", "size")
    if ($entry.sha256 -isnot [string] -or $entry.sha256 -cnotmatch '\A[0-9a-f]{64}\z') { throw "invalid signed digest" }
    if (($entry.size -isnot [long] -and $entry.size -isnot [int]) -or $entry.size -lt 1 -or $entry.size -gt 134217728) { throw "invalid signed artifact size" }
    if ($entry.url -isnot [string] -or -not $entry.url.StartsWith("https://", [StringComparison]::Ordinal)) { throw "invalid signed artifact URL" }
    $artifactPath = Join-Path $tmp $asset
    if ($entry.url -cne "https://github.com/$Repo/releases/download/$($payload.version)/$asset") { throw "artifact URL does not match signed version" }
    Download $entry.url $artifactPath $entry.size
    if (-not (Test-Path -LiteralPath $artifactPath) -or (Get-Item -LiteralPath $artifactPath).Length -ne $entry.size) { throw "artifact size mismatch" }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
    if ($actual -cne $entry.sha256) { throw "artifact SHA-256 mismatch" }
    Write-Host "signature, size, and checksum verified"
    Place $artifactPath
  } finally { Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

if ($Source -and $Release) { throw "choose one of -Source or -Release" }
if ($Source) { Install-Source }
else { Install-Release }
