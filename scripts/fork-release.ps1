<#
.SYNOPSIS
    Build, sign and publish a Gale fork release.

.DESCRIPTION
    One command for the mechanical half of a fork release:
      1. (optionally) set the app version in the three files that carry it
      2. build the MSI with the updater signing key
      3. make sure the MSI has a .sig
      4. write latest.json (the in-app updater endpoint payload)
      5. create the GitHub release with the MSI, the .sig and latest.json

    The version must be MSI-compatible: major.minor.patch or
    major.minor.patch-number (the WiX bundler rejects anything else).
    The fork wording lives on the tag, e.g. v1.23.3-fork.1.

.PARAMETER Tag
    Release tag, e.g. v1.23.3-fork.1

.PARAMETER Version
    App version to write into package.json, src-tauri/Cargo.toml and
    src-tauri/tauri.conf.json before building. Omit to use the version
    already in tauri.conf.json.

.PARAMETER KeyPath
    Updater private key generated with `pnpm tauri signer generate`.

.PARAMETER SkipBuild
    Reuse the MSI already in src-tauri/target/release/bundle/msi.

.PARAMETER Draft
    Create the release as a draft (note: /releases/latest/ will not point
    at it, so the in-app updater will not see it).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/fork-release.ps1 -Version 1.23.3-1 -Tag v1.23.3-fork.1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Tag,

    [string]$Version = '',
    [string]$KeyPath = "$env:USERPROFILE\Desktop\Work\gale-release-key\gale-updater.key",
    [string]$Repo = 'Niko666233/gale',
    [switch]$SkipBuild,
    [switch]$Draft
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Fail([string]$Message) {
    Write-Host "error: $Message" -ForegroundColor Red
    exit 1
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# pnpm.ps1 can be blocked by execution policy; the .cmd shim never is.
$pnpm = 'pnpm'
if (Get-Command pnpm.cmd -ErrorAction SilentlyContinue) { $pnpm = 'pnpm.cmd' }

$confPath = Join-Path $root 'src-tauri\tauri.conf.json'

# ---------------------------------------------------------------- version ---
if ($Version -ne '') {
    if ($Version -notmatch '^\d+\.\d+\.\d+(-\d+)?$') {
        Fail "version '$Version' is not MSI-compatible: use major.minor.patch or major.minor.patch-build, e.g. 1.23.3-1"
    }

    Write-Host "setting app version -> $Version" -ForegroundColor Cyan

    $targets = @(
        @{ Path = (Join-Path $root 'package.json'); Pattern = '("version"\s*:\s*)"[^"]*"'; Lang = 'json' },
        @{ Path = (Join-Path $root 'src-tauri\Cargo.toml'); Pattern = '(?m)^version = "[^"]*"'; Lang = 'toml' },
        @{ Path = $confPath; Pattern = '("version"\s*:\s*)"[^"]*"'; Lang = 'json' }
    )

    foreach ($t in $targets) {
        $text = [System.IO.File]::ReadAllText($t.Path)
        $re = New-Object System.Text.RegularExpressions.Regex($t.Pattern)
        if (-not $re.IsMatch($text)) { Fail "could not find the version field in $($t.Path)" }
        if ($t.Lang -eq 'json') {
            $new = $re.Replace($text, ('$1"' + $Version + '"'), 1)
        }
        else {
            $new = $re.Replace($text, ('version = "' + $Version + '"'), 1)
        }
        Write-Utf8NoBom $t.Path $new
    }
    # Cargo.lock follows on the next build.
    Write-Host '  package.json, src-tauri/Cargo.toml, src-tauri/tauri.conf.json updated' -ForegroundColor DarkGray
}

$conf = Get-Content $confPath -Raw | ConvertFrom-Json
$appVersion = $conf.version
if ($appVersion -notmatch '^\d+\.\d+\.\d+(-\d+)?$') {
    Fail "app version '$appVersion' is not MSI-compatible (numeric only)"
}
Write-Host "app version: $appVersion    tag: $Tag" -ForegroundColor Cyan

# -------------------------------------------------------------------- key ---
if (-not (Test-Path $KeyPath)) { Fail "updater signing key not found: $KeyPath" }
$keyFull = (Resolve-Path $KeyPath).Path

# ------------------------------------------------------------------ build ---
if (-not $SkipBuild) {
    Write-Host 'building MSI (this takes a few minutes)' -ForegroundColor Cyan
    $env:TAURI_SIGNING_PRIVATE_KEY_PATH = $keyFull
    $env:TAURI_SIGNING_PRIVATE_KEY = [System.IO.File]::ReadAllText($keyFull)
    # --ci is what keeps the build from blocking on a hidden password prompt:
    # an empty password cannot be passed to `tauri build`, and PowerShell drops
    # empty native arguments, so an unencrypted key only signs in CI mode.
    & $pnpm tauri build --bundles msi --ci
    if ($LASTEXITCODE -ne 0) { Fail 'tauri build failed' }
}

# --------------------------------------------------------------- artifacts ---
$msiDir = Join-Path $root 'src-tauri\target\release\bundle\msi'
if (-not (Test-Path $msiDir)) { Fail "bundle directory missing: $msiDir" }

$msi = Get-ChildItem -Path $msiDir -Filter "Gale_${appVersion}_*_en-US.msi" | Select-Object -First 1
if (-not $msi) { Fail "no MSI for version $appVersion found in $msiDir" }
$sigPath = $msi.FullName + '.sig'

if (-not (Test-Path $sigPath)) {
    Write-Host 'MSI has no signature yet, signing it' -ForegroundColor Cyan
    # `-f` conflicts with an inherited TAURI_SIGNING_PRIVATE_KEY, so clear it.
    $env:TAURI_SIGNING_PRIVATE_KEY = $null
    # PowerShell 5.1 drops empty native arguments, so `-p ""` has to go through
    # cmd, which keeps it. A temp .cmd is the reliable way to do that.
    $tmpCmd = Join-Path $env:TEMP ("gale-sign-" + [guid]::NewGuid().ToString('N') + '.cmd')
    $lines = @(
        '@echo off',
        ('cd /d "' + $root + '"'),
        ('pnpm exec tauri signer sign -f "' + $keyFull + '" -p "" "' + $msi.FullName + '"')
    )
    Write-Utf8NoBom $tmpCmd ($lines -join "`r`n")
    & cmd /c $tmpCmd
    $signExit = $LASTEXITCODE
    Remove-Item $tmpCmd -ErrorAction SilentlyContinue
    if ($signExit -ne 0) { Fail 'signing failed' }
    if (-not (Test-Path $sigPath)) { Fail "signing produced no .sig at $sigPath" }
}

$hash = (Get-FileHash $msi.FullName -Algorithm SHA256).Hash.ToLower()
Write-Host "MSI: $($msi.Name)  $($msi.Length) bytes  sha256 $hash" -ForegroundColor DarkGray

# -------------------------------------------------------------- latest.json ---
$signature = ([System.IO.File]::ReadAllText($sigPath)).Trim()
$url = "https://github.com/$Repo/releases/download/$Tag/$($msi.Name)"
$pubDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

$latest = [ordered]@{
    version   = $appVersion
    notes     = "Fork release: readme level 1 headings can be shown again, and the system proxy can be turned off. See the release notes on GitHub."
    pub_date  = $pubDate
    platforms = [ordered]@{
        'windows-x86_64'     = [ordered]@{ signature = $signature; url = $url }
        'windows-x86_64-msi' = [ordered]@{ signature = $signature; url = $url }
    }
}

$latestPath = Join-Path $msiDir 'latest.json'
Write-Utf8NoBom $latestPath ($latest | ConvertTo-Json -Depth 5)
Write-Host "wrote $latestPath" -ForegroundColor DarkGray

# ------------------------------------------------------------ release notes ---
$changelogPath = Join-Path $root 'CHANGELOG.md'
$notesPath = Join-Path $msiDir 'release-notes.md'
$notes = ''

if (Test-Path $changelogPath) {
    $changelog = [System.IO.File]::ReadAllText($changelogPath)
    $m = [regex]::Match($changelog, '(?ms)^## ' + [regex]::Escape($appVersion) + '\b.*?(?=^## )')
    if ($m.Success) {
        $notes = ($m.Value -replace '^## .*?(\r?\n)+', '').Trim()
    }
}

if ($notes -eq '') {
    $notes = "Fork release $appVersion, based on upstream Gale."
}

$notes += "`n`n---`n`n**SHA256** (``$($msi.Name)``): ``$hash``"
Write-Utf8NoBom $notesPath $notes

# ---------------------------------------------------------------- publish ---
$ghArgs = @(
    'release', 'create', $Tag,
    '--repo', $Repo,
    '--target', 'master',
    '--title', $Tag,
    '--notes-file', $notesPath
)
if ($Draft) { $ghArgs += '--draft' }
$ghArgs += @($msi.FullName, $sigPath, $latestPath)

Write-Host 'creating GitHub release' -ForegroundColor Cyan
& gh @ghArgs
if ($LASTEXITCODE -ne 0) { Fail 'gh release create failed' }

# --------------------------------------------------------------- verify ---
Write-Host 'verifying published release' -ForegroundColor Cyan
$meta = & gh release view $Tag --repo $Repo --json tagName,isDraft,isPrerelease,assets | ConvertFrom-Json
if ($meta.isDraft -or $meta.isPrerelease) {
    Write-Host '  WARNING: draft/prerelease - /releases/latest/ will not resolve to it' -ForegroundColor Yellow
}
$names = @($meta.assets | ForEach-Object { $_.name })
foreach ($expected in @($msi.Name, ($msi.Name + '.sig'), 'latest.json')) {
    if ($names -notcontains $expected) { Fail "asset missing from the release: $expected" }
}
Write-Host "  assets ok: $($names -join ', ')" -ForegroundColor Green

$endpoint = "https://github.com/$Repo/releases/latest/download/latest.json"
$probe = Invoke-WebRequest -Uri $endpoint -UseBasicParsing -TimeoutSec 60
# the asset is served as application/octet-stream, so .Content can be byte[]
if ($probe.Content -is [byte[]]) {
    $jsonText = [System.Text.Encoding]::UTF8.GetString($probe.Content)
}
else {
    $jsonText = [string]$probe.Content
}
$remote = $jsonText | ConvertFrom-Json
if ($remote.version -ne $appVersion) {
    Fail "/releases/latest/download/latest.json reports version '$($remote.version)', expected $appVersion (is another release newer?)"
}
Write-Host "  endpoint ok: $endpoint -> $($remote.version)" -ForegroundColor Green
Write-Host "done: https://github.com/$Repo/releases/tag/$Tag" -ForegroundColor Green
