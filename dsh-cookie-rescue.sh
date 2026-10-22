#!/usr/bin/env bash
# ============================================================================
# dsh startup crash rescue - clear accumulated dsh-auth cookies (macOS/Linux)
# ============================================================================
#
# WHEN TO RUN THIS
#   Only when the startup patch has failed AND dsh is crashing on launch.
#   Normally you never touch it. The dsh-http-header-limit plugin in this same
#   directory is the day-to-day fix: it raises the Host request-header ceiling
#   from 16 KB to 256 KB on every launch, so the 431 should not happen at all.
#   This script is the emergency fallback for when that path is unavailable.
#
# SYMPTOM
#   The window fails to open; the log says
#   "desktop welcome: Web authentication failed".
#   The real status is HTTP 431 (request header too large), which the shell
#   reports as a generic authentication failure.
#
# WHY IT HAPPENS
#   The dsh desktop Host binds a random port on every launch, and its session
#   cookie is named dsh-auth-<sha256("127.0.0.1:<port>")>. A new port means a
#   new cookie name, so each launch adds one more cookie and never overwrites
#   an old one. Cookies live 30 days and the shell never prunes them. Chromium
#   sends every 127.0.0.1 cookie regardless of port, so around 71 cookies
#   (~16.4 KB) the request crosses Node's default 16384-byte header limit and
#   the Host answers 431.
#
# WHAT THIS SCRIPT DOES
#   Backs up the Cookies database, then deletes ONLY rows where
#   host_key = '127.0.0.1' AND name LIKE 'dsh-auth-%', then runs an integrity
#   check and verifies the row count matches expectation. It deletes no files,
#   does not touch plugin config, and does not touch account login state.
#
# PRECONDITION (checked automatically)
#   dsh must be fully exited. The database is locked while the app runs, so
#   writes would fail with "database is locked".
#
# NO PYTHON REQUIRED
#   Uses Node's built-in node:sqlite (Node >= 22.5). Runtime lookup order:
#     1. the DSH_NODE environment variable, if set
#     2. node on PATH
#     3. the Electron binary of an installed DeepSeek Harness, used as Node
#
# USAGE
#   chmod +x dsh-cookie-rescue.sh   # once
#   ./dsh-cookie-rescue.sh
#
#   Preview what would be deleted without changing anything:
#     ./dsh-cookie-rescue.sh --dry-run
#
# UPSTREAM ISSUE: deepseek-ai/deepseek-harness#9924
# ============================================================================

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --help|-h)
      echo "Usage: $0 [--dry-run]"
      echo "  --dry-run   count what would be deleted; change nothing"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--dry-run]" >&2
      exit 2
      ;;
  esac
done

echo ""
echo "=== dsh startup rescue: clear dsh-auth cookies ==="
if [ "$DRY_RUN" -eq 1 ]; then
  echo "(DryRun: preview only, nothing will be changed)"
fi
echo ""

# -- 1. Locate the cookie database -------------------------------------------
# Chromium stores this under the app's userData directory, which differs by
# platform. Both are derived from the environment, never hard-coded per user.
case "$(uname -s)" in
  Darwin)
    BASE_DIR="$HOME/Library/Application Support/@deepseek-ai/dsh-desktop"
    ;;
  Linux)
    BASE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/@deepseek-ai/dsh-desktop"
    ;;
  *)
    echo "Unsupported platform: $(uname -s)" >&2
    echo "Use dsh-cookie-rescue.ps1 on Windows." >&2
    exit 1
    ;;
esac

COOKIES="$BASE_DIR/Network/Cookies"

if [ ! -f "$COOKIES" ]; then
  echo "Not found: $COOKIES" >&2
  echo "Confirm the dsh desktop app is installed and has started at least once." >&2
  exit 1
fi

echo "Cookie database: $COOKIES"

# -- 2. dsh must be fully exited ---------------------------------------------
# The database is exclusively locked while running, so a write fails.
if pgrep -f -i "deepseek harness" >/dev/null 2>&1 || pgrep -f -i "dsh-desktop" >/dev/null 2>&1; then
  echo "dsh is still running. Quit it completely first, then retry." >&2
  pgrep -af -i "deepseek harness|dsh-desktop" 2>/dev/null | head -10 >&2 || true
  exit 1
fi

echo "dsh is not running; safe to proceed."

# -- 3. Find a Node runtime with node:sqlite ---------------------------------
# node:sqlite is built in from Node 22.5. The probe imports it for real, so an
# older Node is rejected up front instead of failing halfway through a delete.
PROBE_JS="$(mktemp "${TMPDIR:-/tmp}/dsh-sqlite-probe.XXXXXX.js")"
trap 'rm -f "$PROBE_JS"' EXIT
cat > "$PROBE_JS" <<'PROBE'
try {
  const { DatabaseSync } = require("node:sqlite");
  if (typeof DatabaseSync !== "function") process.exit(1);
  process.stdout.write("OK");
} catch {
  process.exit(1);
}
PROBE

probe_runtime() {
  local exe="$1"
  [ -x "$exe" ] || return 1
  local out
  out="$("$exe" "$PROBE_JS" 2>/dev/null)" || return 1
  [ "$out" = "OK" ]
}

NODE_EXE=""

# Candidate 1: explicit override
if [ -n "${DSH_NODE:-}" ] && probe_runtime "$DSH_NODE"; then
  NODE_EXE="$DSH_NODE"
fi

# Candidate 2: node on PATH
if [ -z "$NODE_EXE" ]; then
  if command -v node >/dev/null 2>&1 && probe_runtime "$(command -v node)"; then
    NODE_EXE="$(command -v node)"
  fi
fi

# Candidate 3: the Electron binary of an installed DeepSeek Harness, used as
# Node. Anyone who hit this bug has the app installed, so this exists even when
# Node itself does not.
if [ -z "$NODE_EXE" ]; then
  ELECTRON_CANDIDATES=()
  [ -n "${DSH_ELECTRON:-}" ] && ELECTRON_CANDIDATES+=("$DSH_ELECTRON")

  case "$(uname -s)" in
    Darwin)
      ELECTRON_CANDIDATES+=(
        "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness"
        "$HOME/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness"
      )
      ;;
    Linux)
      ELECTRON_CANDIDATES+=(
        "/opt/DeepSeek Harness/deepseek-harness"
        "/usr/lib/deepseek-harness/deepseek-harness"
        "$HOME/.local/bin/deepseek-harness"
      )
      ;;
  esac

  for exe in "${ELECTRON_CANDIDATES[@]}"; do
    [ -x "$exe" ] || continue
    if ELECTRON_RUN_AS_NODE=1 probe_runtime "$exe"; then
      NODE_EXE="$exe"
      export ELECTRON_RUN_AS_NODE=1
      break
    fi
  done
fi

if [ -z "$NODE_EXE" ]; then
  echo "No Node runtime with node:sqlite was found." >&2
  echo "Options:" >&2
  echo "  - install Node 22.5+ (node:sqlite is built in), or" >&2
  echo "  - set DSH_NODE to a node executable, or" >&2
  echo "  - set DSH_ELECTRON to the DeepSeek Harness executable." >&2
  exit 1
fi

echo "Using runtime: $NODE_EXE"

# -- 4. Back up (skipped in DryRun, since nothing changes) -------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.dsh/repair-backups/$STAMP-cookie-fix"

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$BACKUP_DIR"
  cp -p "$COOKIES" "$BACKUP_DIR/Cookies.bak"
  if [ -f "$COOKIES-journal" ]; then
    cp -p "$COOKIES-journal" "$BACKUP_DIR/Cookies-journal.bak"
  fi
  echo "Backed up to: $BACKUP_DIR"
fi

# -- 5. Clean and verify -----------------------------------------------------
# The path travels through an environment variable so no path is spliced into
# JavaScript source.
CLEAN_JS="$(mktemp "${TMPDIR:-/tmp}/dsh-cookie-fix.XXXXXX.js")"
trap 'rm -f "$PROBE_JS" "$CLEAN_JS"' EXIT
cat > "$CLEAN_JS" <<'CLEAN'
const { DatabaseSync } = require("node:sqlite");

const db  = process.env.DSH_COOKIES_DB;
const dry = process.env.DSH_DRYRUN === "1";

const WHERE = "host_key = '127.0.0.1' AND name LIKE 'dsh-auth-%'";

let conn;
try {
  conn = new DatabaseSync(db);
} catch (error) {
  console.log("Could not open the database: " + error.message);
  console.log("If dsh is running, quit it completely and retry.");
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
CLEAN

DSH_COOKIES_DB="$COOKIES" DSH_DRYRUN="$DRY_RUN" "$NODE_EXE" "$CLEAN_JS"
CODE=$?

echo ""
if [ "$CODE" -ne 0 ]; then
  echo "Cleaning failed (exit code $CODE). The database was not confirmed changed." >&2
  [ "$DRY_RUN" -eq 0 ] && echo "Backup: $BACKUP_DIR" >&2
  exit "$CODE"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DryRun finished; the database was not modified."
  echo "Re-run without --dry-run to actually clean."
else
  echo "Done. You can start dsh again."
  echo "Database backup: $BACKUP_DIR"
  echo "(Safe to delete once dsh starts normally.)"
  echo ""
  echo "If the dsh-http-header-limit patch also failed, check the status line in:"
  echo "  ${DSH_HOME:-$HOME/.dsh}/http-header-limit.json"
fi
echo ""
