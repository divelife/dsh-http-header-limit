# ============================================================================
# dsh startup crash rescue - clear accumulated dsh-auth cookies
# ============================================================================
#
# Emergency fallback for when the dsh-http-header-limit patch is unavailable and
# dsh crashes on launch with "desktop welcome: Web authentication failed"
# (really HTTP 431: the accumulated dsh-auth-* cookies overflow Node's default
# 16384-byte request header limit).
#
# Deletes ONLY rows where host_key = '127.0.0.1' AND name LIKE 'dsh-auth-%',
# after backing up the database, then verifies the row count and integrity.
# Deletes no files, does not touch plugin config or account login state.
#
# dsh must be fully exited: the database is locked while it runs.
# Needs Node 22.5+ (built-in node:sqlite), no Python. Runtime lookup order:
# DSH_NODE, then node on PATH, then an installed DeepSeek Harness Electron
# binary used as Node.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File dsh-cookie-rescue.ps1 -DryRun
#   powershell -ExecutionPolicy Bypass -File dsh-cookie-rescue.ps1
#
# Upstream issue: deepseek-ai/deepseek-harness#9924
# ============================================================================

[CmdletBinding()]
param(
    # Count what would be deleted; change nothing.
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== dsh startup rescue: clear dsh-auth cookies ===" -ForegroundColor Cyan
if ($DryRun) { Write-Host "(DryRun: preview only, nothing will be changed)" -ForegroundColor Yellow }
Write-Host ""

# -- 1. Locate the cookie database -------------------------------------------
# %APPDATA% expands per user, so no user name is hard-coded.
$netDir  = Join-Path $env:APPDATA "@deepseek-ai\dsh-desktop\Network"
$cookies = Join-Path $netDir "Cookies"

if (-not (Test-Path -LiteralPath $cookies)) {
    Write-Host "Not found: $cookies" -ForegroundColor Red
    Write-Host "Confirm the dsh desktop app is installed and has started at least once." -ForegroundColor Yellow
    exit 1
}

Write-Host "Cookie database: $cookies" -ForegroundColor Gray

# -- 2. dsh must be fully exited ---------------------------------------------
# The database is exclusively locked while running, so a write fails.
# The real process name is "DeepSeek Harness"; *DeepSeek* covers it.
$running = @(Get-Process -ErrorAction SilentlyContinue |
             Where-Object { $_.ProcessName -like "*DeepSeek*" })
if ($running.Count -gt 0) {
    Write-Host "dsh is still running ($($running.Count) processes)." -ForegroundColor Red
    Write-Host "Exit it completely first: tray icon -> right-click -> Quit." -ForegroundColor Yellow
    Write-Host ""
    $running | Select-Object Id, ProcessName, StartTime | Format-Table -AutoSize
    exit 1
}

Write-Host "dsh is not running; safe to proceed." -ForegroundColor Green

# -- 3. Find a Node runtime with node:sqlite ---------------------------------
# node:sqlite is built in from Node 22.5. The probe imports it for real, so an
# older Node is rejected up front instead of failing halfway through a delete.
#
# The probe is written to a FILE and run by path, not passed through -e. A
# quoted inline program gets mangled by PowerShell's argument handling (the
# double quotes around "node:sqlite" are stripped, turning it into an
# identifier), which silently made every probe fail.
$probeJs = @'
try {
  const { DatabaseSync } = require("node:sqlite");
  if (typeof DatabaseSync !== "function") process.exit(1);
  process.stdout.write("OK");
} catch {
  process.exit(1);
}
'@
$probePath = Join-Path $env:TEMP "dsh-sqlite-probe-$PID.js"
Set-Content -LiteralPath $probePath -Value $probeJs -Encoding utf8

function Test-NodeRuntime {
    param([string]$Exe)
    # The Electron binary is a GUI-subsystem executable: PowerShell's `&` call
    # operator starts it without a console and captures nothing, so a probe run
    # that way always looks like a failure. Start-Process with redirected
    # stdout reads it correctly. Measured on Windows 11 with DeepSeek Harness
    # 0.2.1-rc.2: `&` returns empty, Start-Process returns "OK".
    $outFile = Join-Path $env:TEMP "dsh-sqlite-probe-$PID-out.txt"
    $errFile = Join-Path $env:TEMP "dsh-sqlite-probe-$PID-err.txt"
    try {
        $proc = Start-Process -FilePath $Exe -ArgumentList @($probePath) `
                    -Wait -NoNewWindow -PassThru `
                    -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                    -ErrorAction Stop
        if ($proc.ExitCode -ne 0) { return $false }
        $out = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        return ($out -eq "OK")
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

$nodeExe = $null

# Candidate 1: explicit override
if ($env:DSH_NODE -and (Test-Path -LiteralPath $env:DSH_NODE)) {
    if (Test-NodeRuntime -Exe $env:DSH_NODE) { $nodeExe = $env:DSH_NODE }
}

# Candidate 2: node on PATH. This also skips the Microsoft Store redirector
# stub, which cannot import node:sqlite and so fails the probe.
if (-not $nodeExe) {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        if (Test-NodeRuntime -Exe $cmd.Source) { $nodeExe = $cmd.Source }
    }
}

# Candidate 3: the Electron binary shipped with DeepSeek Harness, run as Node.
# Anyone who hit this bug has the app installed, so this exists even when Node
# itself does not. Paths are discovered from environment variables, never
# hard-coded per user.
if (-not $nodeExe) {
    $electronCandidates = @()
    if ($env:DSH_ELECTRON) { $electronCandidates += $env:DSH_ELECTRON }

    $roots = @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
             Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($root in $roots) {
        $electronCandidates += (Join-Path $root "DeepSeek Harness\DeepSeek Harness.exe")
        $electronCandidates += (Join-Path $root "Programs\DeepSeek Harness\DeepSeek Harness.exe")
    }

    $env:ELECTRON_RUN_AS_NODE = "1"
    foreach ($exe in $electronCandidates) {
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        if (Test-NodeRuntime -Exe $exe) { $nodeExe = $exe; break }
    }
    if (-not $nodeExe) { Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue }
}

if (-not $nodeExe) {
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
    Write-Host "No Node runtime with node:sqlite was found." -ForegroundColor Red
    Write-Host "Options:" -ForegroundColor Gray
    Write-Host "  - install Node 22.5+ (node:sqlite is built in), or" -ForegroundColor Gray
    Write-Host "  - set DSH_NODE to a node.exe path, or" -ForegroundColor Gray
    Write-Host "  - set DSH_ELECTRON to the DeepSeek Harness.exe path." -ForegroundColor Gray
    exit 1
}

Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue

Write-Host "Using runtime: $nodeExe" -ForegroundColor Gray

# -- 4. Back up (skipped in DryRun, since nothing changes) -------------------
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:USERPROFILE ".dsh\repair-backups\$stamp-cookie-fix"

if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Copy-Item -LiteralPath $cookies -Destination (Join-Path $backupDir "Cookies.bak") -Force
    if (Test-Path -LiteralPath "$cookies-journal") {
        Copy-Item -LiteralPath "$cookies-journal" -Destination (Join-Path $backupDir "Cookies-journal.bak") -Force
    }
    Write-Host "Backed up to: $backupDir" -ForegroundColor Green
}

# -- 5. Clean and verify -----------------------------------------------------
# The path travels through an environment variable so no Windows path is ever
# spliced into JavaScript source, where backslashes would need escaping.
$cleanJs = @'
const { DatabaseSync } = require("node:sqlite");

const db  = process.env.DSH_COOKIES_DB;
const dry = process.env.DSH_DRYRUN === "1";

const WHERE = "host_key = '127.0.0.1' AND name LIKE 'dsh-auth-%'";

let conn;
try {
  conn = new DatabaseSync(db);
} catch (error) {
  console.log("Could not open the database: " + error.message);
  console.log("If dsh is running, quit it completely (including the tray icon) and retry.");
  process.exit(1);
}

const totalBefore = Number(conn.prepare("SELECT COUNT(*) AS n FROM cookies").get().n);
const hitBefore   = Number(conn.prepare("SELECT COUNT(*) AS n FROM cookies WHERE " + WHERE).get().n);

console.log("Total cookies: " + totalBefore);
console.log("dsh-auth cookies for 127.0.0.1: " + hitBefore);

if (hitBefore === 0) {
  console.log("Nothing to clean.");
  conn.close();
  process.exit(0);
}

if (dry) {
  console.log("DryRun: would delete " + hitBefore + " rows; no changes made.");
  conn.close();
  process.exit(0);
}

const result = conn.prepare("DELETE FROM cookies WHERE " + WHERE).run();
conn.exec("VACUUM");

const ok    = conn.prepare("PRAGMA integrity_check").get();
const after = Number(conn.prepare("SELECT COUNT(*) AS n FROM cookies").get().n);
conn.close();

const integrity = ok && ok.integrity_check;

console.log("");
console.log("Deleted dsh-auth cookies: " + Number(result.changes));
console.log("Remaining cookies: " + after);
console.log("Integrity check: " + integrity);

if (integrity !== "ok") {
  console.log("Integrity check FAILED. Restore from the backup taken above.");
  process.exit(1);
}

const expected = totalBefore - hitBefore;
if (after !== expected) {
  console.log("Row count mismatch: expected " + expected + ", got " + after);
  process.exit(1);
}
'@

$tmpJs = Join-Path $env:TEMP "dsh-cookie-fix-$stamp.js"
Set-Content -LiteralPath $tmpJs -Value $cleanJs -Encoding utf8

$env:DSH_COOKIES_DB = $cookies
if ($DryRun) { $env:DSH_DRYRUN = "1" } else { $env:DSH_DRYRUN = "0" }

# Same GUI-subsystem caveat as the probe: when the runtime is the Electron
# binary, `&` produces no output at all, so the real run also goes through
# Start-Process with redirected streams. Output is echoed afterwards so the
# user still sees it.
$outFile = Join-Path $env:TEMP "dsh-cookie-fix-$stamp-out.txt"
$errFile = Join-Path $env:TEMP "dsh-cookie-fix-$stamp-err.txt"

$code = 0
try {
    $proc = Start-Process -FilePath $nodeExe -ArgumentList @($tmpJs) `
                -Wait -NoNewWindow -PassThru `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                -ErrorAction Stop
    $code = $proc.ExitCode

    if (Test-Path -LiteralPath $outFile) {
        Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue | Write-Host
    }
    if (Test-Path -LiteralPath $errFile) {
        $errText = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        if ($errText -and $errText.Trim()) {
            Write-Host $errText -ForegroundColor DarkYellow
        }
    }
} catch {
    Write-Host "Could not start the runtime: $($_.Exception.Message)" -ForegroundColor Red
    $code = 1
} finally {
    Remove-Item -LiteralPath $tmpJs, $outFile, $errFile -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\DSH_COOKIES_DB       -ErrorAction SilentlyContinue
    Remove-Item Env:\DSH_DRYRUN           -ErrorAction SilentlyContinue
    Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
}

Write-Host ""
if ($code -ne 0) {
    Write-Host "Cleaning failed (exit code $code). The database was not confirmed changed." -ForegroundColor Red
    if (-not $DryRun) { Write-Host "Backup: $backupDir" -ForegroundColor Yellow }
    exit $code
}

if ($DryRun) {
    Write-Host "DryRun finished; the database was not modified." -ForegroundColor Yellow
    Write-Host "Re-run without -DryRun to actually clean." -ForegroundColor Gray
} else {
    Write-Host "Done. You can start dsh again." -ForegroundColor Green
    Write-Host "Database backup: $backupDir" -ForegroundColor Gray
    Write-Host "(Safe to delete once dsh starts normally.)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "If the dsh-http-header-limit patch also failed, check the status line in:" -ForegroundColor Yellow
    Write-Host "  %USERPROFILE%\.dsh\http-header-limit.json" -ForegroundColor Yellow
}
Write-Host ""
