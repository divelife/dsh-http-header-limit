#!/usr/bin/env bash
# ============================================================================
# dsh startup crash rescue - clear accumulated dsh-auth cookies (macOS/Linux)
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
#   ./dsh-cookie-rescue.sh --dry-run
#   ./dsh-cookie-rescue.sh
#
# Upstream issue: deepseek-ai/deepseek-harness#9924
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
# platform and by build, so probe several known layouts instead of one.
case "$(uname -s)" in
  Darwin)
    CANDIDATES="$HOME/Library/Application Support/@deepseek-ai/dsh-desktop/Network/Cookies
$HOME/.dsh/electron-user-data/Network/Cookies"
    ;;
  Linux)
    CANDIDATES="${XDG_CONFIG_HOME:-$HOME/.config}/@deepseek-ai/dsh-desktop/Network/Cookies
$HOME/.dsh/electron-user-data/Network/Cookies"
    ;;
  *)
    echo "Unsupported platform: $(uname -s)" >&2
    echo "Use dsh-cookie-rescue.ps1 on Windows." >&2
    exit 1
    ;;
esac

COOKIES=""
# An explicit override always wins, so a non-standard install still works.
if [ -n "${DSH_COOKIES_DB:-}" ] && [ -f "${DSH_COOKIES_DB}" ]; then
  COOKIES="${DSH_COOKIES_DB}"
else
  OLD_IFS="$IFS"; IFS='
'
  for candidate in $CANDIDATES; do
    if [ -f "$candidate" ]; then COOKIES="$candidate"; break; fi
  done
  IFS="$OLD_IFS"
fi

if [ -z "$COOKIES" ]; then
  echo "Could not find the cookie database. Looked in:" >&2
  OLD_IFS="$IFS"; IFS='
'
  for candidate in $CANDIDATES; do echo "  $candidate" >&2; done
  IFS="$OLD_IFS"
  echo "Set DSH_COOKIES_DB to its full path if you know where it is." >&2
  exit 1
fi

echo "Cookie database: $COOKIES"

# -- 2. dsh must be fully exited ---------------------------------------------
# The database is exclusively locked while running, so a write fails.
# Process names differ between builds ("DeepSeek Harness", "DSH NEXT"), so
# match every likely spelling rather than one literal name.
DSH_PROC_RE="deepseek harness|deepseek-harness|dsh-desktop|dsh next|dsh-next"
if pgrep -f -i "$DSH_PROC_RE" >/dev/null 2>&1; then
  echo "dsh is still running. Quit it completely first, then retry." >&2
  pgrep -af -i "$DSH_PROC_RE" 2>/dev/null | head -10 >&2 || true
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
      # Names vary by build ("DeepSeek Harness", "DSH NEXT"), so try each.
      for name in "DeepSeek Harness" "DSH NEXT" "DSH"; do
        ELECTRON_CANDIDATES+=(
          "/Applications/$name.app/Contents/MacOS/$name"
          "$HOME/Applications/$name.app/Contents/MacOS/$name"
        )
      done
      ;;
    Linux)
      ELECTRON_CANDIDATES+=(
        "/opt/DeepSeek Harness/deepseek-harness"
        "/usr/lib/deepseek-harness/deepseek-harness"
        "$HOME/.local/bin/deepseek-harness"
        "/opt/dsh-next/dsh-next"
        "$HOME/.local/bin/dsh-next"
      )
      # A .desktop entry records where the launcher actually points, which
      # covers AppImages and custom prefixes that the fixed list above misses.
      for desktop in "$HOME/.local/share/applications"/*.desktop \
                     "/usr/share/applications"/*.desktop \
                     "/usr/local/share/applications"/*.desktop; do
        [ -f "$desktop" ] || continue
        grep -qiE 'deepseek|dsh' "$desktop" 2>/dev/null || continue
        exec_line="$(sed -n 's/^Exec=//p' "$desktop" | head -1)"
        # Strip field codes (%U, %f, ...) and any leading arguments, keeping
        # the first token that is an existing executable path.
        for token in $exec_line; do
          case "$token" in
            %*) continue ;;
            /*) [ -x "$token" ] && ELECTRON_CANDIDATES+=("$token") ;;
          esac
        done
      done
      # An AppImage unpacked in place still carries the app; DSH_APPIMAGE
      # names it directly when the path is unusual.
      [ -n "${DSH_APPIMAGE:-}" ] && ELECTRON_CANDIDATES+=("$DSH_APPIMAGE")
      for appimage in "$HOME/Applications"/*.AppImage "$HOME/Downloads"/*.AppImage; do
        [ -x "$appimage" ] || continue
        case "$(basename "$appimage")" in
          *eepSeek*|*DSH*|*dsh*) ELECTRON_CANDIDATES+=("$appimage") ;;
        esac
      done
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
