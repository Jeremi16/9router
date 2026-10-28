# install.ps1 - Install a locally-built 9router tarball over the global install.
#
# Why this script exists: `npm install -g <tarball>` fails with EBUSY when
# 9router is running, because the CLI restarts the server and holds file
# handles inside node_modules/9router/app. This script stops 9router, waits for
# the handles to drop, installs, then optionally restarts.
#
# Usage:
#   .\install.ps1                          # install ./9router-*.tgz
#   .\install.ps1 -Tarball path\to.tgz     # explicit tarball
#   .\install.ps1 -NoRestart               # don't start 9router afterwards
#   .\install.ps1 -Force                   # skip the confirmation prompt
#   .\install.ps1 -DryRun                  # show what would happen, change nothing
#
# Exit codes: 0 ok, 1 failure, 2 user aborted.

[CmdletBinding()]
param(
    [string]$Tarball,
    [switch]$NoRestart,
    [switch]$Force,
    [switch]$DryRun,
    [int]$StopTimeoutSec = 20
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK   $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    WARN $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    FAIL $msg" -ForegroundColor Red }

# --- 1. Locate the tarball -------------------------------------------------
Write-Step 'Locating build tarball'

if (-not $Tarball) {
    $candidates = @(Get-ChildItem -Path $PSScriptRoot -Filter '9router-*.tgz' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        Write-Err "No 9router-*.tgz in $PSScriptRoot"
        Write-Host "    Build one first:  npm --prefix cli run pack:cli" -ForegroundColor DarkGray
        exit 1
    }
    $Tarball = $candidates[0].FullName
    if ($candidates.Count -gt 1) {
        Write-Warn2 "$($candidates.Count) tarballs found, using newest: $($candidates[0].Name)"
    }
}

if (-not (Test-Path -LiteralPath $Tarball)) {
    Write-Err "Tarball not found: $Tarball"
    exit 1
}
$tarballItem = Get-Item -LiteralPath $Tarball
Write-Ok "$($tarballItem.Name)  ($([math]::Round($tarballItem.Length / 1MB, 1)) MB)"

# Refuse to install a tarball that predates the current source change.
$expectedMarker = 'codebuddyHeaders'
$expectedVersion = $null
Write-Host "    Checking the bundle carries the CodeBuddy header fix..." -ForegroundColor DarkGray
try {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("9r-check-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    & tar -xzf $tarballItem.FullName -C $tmp 2>$null
    $pkgInTar = Get-ChildItem -Path $tmp -Recurse -Filter 'package.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match 'package$' } |
        Select-Object -First 1
    if ($pkgInTar) {
        $expectedVersion = (Get-Content -LiteralPath $pkgInTar.FullName -Raw | ConvertFrom-Json).version
    }
    $chunk = Get-ChildItem -Path $tmp -Recurse -Filter '*.js' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'chunks' } |
        Select-String -Pattern "$expectedMarker" -List -ErrorAction SilentlyContinue |
        Select-Object -First 1
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($expectedVersion) { Write-Ok "Tarball version: $expectedVersion" }
    if ($chunk) { Write-Ok "Bundle contains '$expectedMarker'" }
    else { Write-Warn2 "Bundle does NOT contain '$expectedMarker' - this build predates the header fix" }
} catch {
    Write-Warn2 "Could not inspect bundle ($($_.Exception.Message)) - continuing"
}

# --- 2. Confirm ------------------------------------------------------------
$existing = $null
try {
    $pkgPath = Join-Path (npm config get prefix) 'node_modules/9router/package.json'
    if (Test-Path -LiteralPath $pkgPath) {
        $existing = (Get-Content -LiteralPath $pkgPath -Raw | ConvertFrom-Json).version
    }
} catch {}

Write-Step 'Install plan'
$existingLabel = if ($existing) { $existing } else { '(not installed)' }
Write-Host "    Target   : 9router@$existingLabel -> tarball" -ForegroundColor DarkGray
Write-Host "    Tarball  : $($tarballItem.FullName)" -ForegroundColor DarkGray
Write-Host "    Restart  : $(if ($NoRestart) { 'no' } else { 'yes' })" -ForegroundColor DarkGray

if ($DryRun) {
    Write-Host "`n[dry-run] Nothing changed." -ForegroundColor Yellow
    exit 0
}

# Installing over a live server is the whole reason this script exists, so the
# stop step below is not optional. -Force only skips the interactive prompt.
if (-not $Force -and -not [Console]::IsInputRedirected) {
    $answer = Read-Host "`nProceed? 9router will be stopped. [y/N]"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host 'Aborted.' -ForegroundColor Yellow
        exit 2
    }
}

# --- 3. Stop every running 9router ----------------------------------------
Write-Step 'Stopping 9router'

function Get-9RouterProcesses {
    # Mirror cli.js's whitelist: a real node process running 9router, or the
    # bundled Next server. Match the *install path* rather than the bare word
    # "9router", so a project folder or editor with that name is never hit.
    #
    # Windows mixes separators in these command lines: the CLI is launched as
    # "...\Roaming\npm/node_modules/9router/cli.js" (mixed) while the Next
    # server uses all backslashes. Normalise both sides to '/' before matching,
    # and guard against a trailing separator in the npm prefix.
    $prefix = (npm config get prefix).TrimEnd('\', '/')
    $needle = ($prefix -replace '\\', '/') + '/node_modules/9router'
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            if (-not $_.CommandLine) { return $false }
            ($_.CommandLine -replace '\\', '/') -like "*$needle*"
        } |
        Select-Object ProcessId, ParentProcessId, CommandLine
}

$round = 0
$maxRounds = 6
while ($round -lt $maxRounds) {
    $procs = @(Get-9RouterProcesses)
    if ($procs.Count -eq 0) { break }
    $round++
    Write-Host "    Round $round : stopping $($procs.Count) process(es)" -ForegroundColor DarkGray
    foreach ($p in $procs) {
        try {
            # /T also takes the child tree (the Next server under the CLI).
            & taskkill /F /T /PID $p.ProcessId 2>&1 | Out-Null
        } catch {}
    }
    Start-Sleep -Milliseconds 700
}

# The terminal that launched `9router` can respawn it; give it a moment and
# report honestly instead of pretending the handles are free.
$deadline = (Get-Date).AddSeconds($StopTimeoutSec)
while ((Get-Date) -lt $deadline) {
    if (@(Get-9RouterProcesses).Count -eq 0) { break }
    Start-Sleep -Milliseconds 500
}

$survivors = @(Get-9RouterProcesses)
if ($survivors.Count -gt 0) {
    Write-Err "9router is still running ($($survivors.Count) process(es)) - it keeps respawning."
    Write-Host "    This usually means a terminal is supervising it." -ForegroundColor DarkGray
    foreach ($s in $survivors) {
        Write-Host "      PID $($s.ProcessId)  parent $($s.ParentProcessId)" -ForegroundColor DarkGray
    }
    Write-Host "`n    Press Ctrl+C in that terminal (or close the tab), then re-run this script." -ForegroundColor Yellow
    exit 1
}
Write-Ok 'All 9router processes stopped'

# Windows can hold the rename target briefly after the processes die.
Write-Host '    Waiting for file handles to release...' -ForegroundColor DarkGray
Start-Sleep -Seconds 2

$lockProbe = Join-Path (npm config get prefix) 'node_modules/9router/app/custom-server.js'
if (Test-Path -LiteralPath $lockProbe) {
    $released = $false
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $fs = [System.IO.File]::Open($lockProbe, 'Open', 'ReadWrite', 'None')
            $fs.Close()
            $released = $true
            break
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if ($released) { Write-Ok 'app/ is unlocked' }
    else { Write-Warn2 'app/ still locked - install may fail with EBUSY' }
}

# --- 4. Install ------------------------------------------------------------
Write-Step 'Installing'

$npmLog = Join-Path ([System.IO.Path]::GetTempPath()) '9router-install.log'
# Capture npm's exit code immediately: piping through Tee-Object/ForEach-Object
# overwrites $LASTEXITCODE with the cmdlet's status, which would report a
# successful install as a failure.
& npm install -g $tarballItem.FullName --loglevel=error 2>&1 | Tee-Object -FilePath $npmLog | ForEach-Object {
    Write-Host "    $_" -ForegroundColor DarkGray
}
$npmExit = $LASTEXITCODE
if ($npmExit -ne 0) {
    Write-Err "npm install failed (exit $npmExit)"
    Write-Host "    Full log: $npmLog" -ForegroundColor DarkGray
    if (Select-String -Path $npmLog -Pattern 'EBUSY' -Quiet -ErrorAction SilentlyContinue) {
        Write-Host "    EBUSY = a file is still open. Close the terminal running 9router and retry." -ForegroundColor Yellow
    }
    exit 1
}
Write-Ok 'Installed'

# --- 5. Verify -------------------------------------------------------------
Write-Step 'Verifying'

$pkgPath = Join-Path (npm config get prefix) 'node_modules/9router/package.json'
if (Test-Path -LiteralPath $pkgPath) {
    $installedVersion = (Get-Content -LiteralPath $pkgPath -Raw | ConvertFrom-Json).version
    if ($installedVersion -eq $expectedVersion) {
        Write-Ok "Installed version: $installedVersion"
    } else {
        Write-Err "Installed version is $installedVersion, expected $expectedVersion"
        exit 1
    }
} else {
    Write-Err 'package.json missing after install'
    exit 1
}

$bundledHook = Get-ChildItem -Path (Join-Path (npm config get prefix) 'node_modules/9router/app') -Recurse -Filter '*.js' -ErrorAction SilentlyContinue |
    Select-String -Pattern $expectedMarker -List -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($bundledHook) { Write-Ok "CodeBuddy header hook present in installed build" }
else { Write-Warn2 "CodeBuddy header hook not found in installed build" }

$cmd = Get-Command 9router -ErrorAction SilentlyContinue
if ($cmd) { Write-Ok "CLI on PATH: $($cmd.Source)" }
else { Write-Warn2 '9router not on PATH - open a new terminal' }

# --- 6. Restart ------------------------------------------------------------
if ($NoRestart) {
    Write-Step 'Not restarting (-NoRestart)'
    Write-Host "    Start it with:  9router" -ForegroundColor DarkGray
} else {
    Write-Step 'Starting 9router'
    Write-Host "    Launching in tray mode; open the dashboard when it is ready." -ForegroundColor DarkGray
    try {
        Start-Process -FilePath '9router' -ArgumentList '--tray', '--skip-update' -WindowStyle Hidden
        Write-Ok 'Started (tray mode)'
    } catch {
        Write-Warn2 "Could not auto-start: $($_.Exception.Message)"
        Write-Host "    Start it manually:  9router" -ForegroundColor DarkGray
    }
}

Write-Host "`nDone." -ForegroundColor Green
exit 0
