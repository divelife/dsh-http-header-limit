# Changelog

## [1.0.0] - 2026-10-22

### Added

- Host plugin raising `maxHeaderSize` on the dsh desktop Host's HTTP server from
  Node's 16384-byte default to 262144 bytes, so an accumulated `dsh-auth-*`
  cookie jar cannot overflow the request header limit and crash startup with
  `desktop welcome: Web authentication failed` (HTTP 431).
- Covers both request paths that share the limit: the welcome handshake and the
  account WebSocket handshake.
- Status stamp at `$DSH_HOME/http-header-limit.json` recording the applied limit
  and the bound port.
- `dsh-cookie-rescue.ps1` (Windows) and `dsh-cookie-rescue.sh` (macOS/Linux):
  manual fallback that deletes only `host_key = '127.0.0.1' AND name LIKE
  'dsh-auth-%'` rows, with a backup, an integrity check, and a row-count check.
  `-DryRun` / `--dry-run` previews the deletion count.
- Unit tests (`smoke.mjs`) and a cordis integration test (`integration.mjs`).

### Notes

- The rescue scripts need Node 22.5+ for `node:sqlite` and no Python. They
  refuse to run while dsh is running, because the cookie database is locked.
- This is a workaround for an upstream defect, not a permanent fix. See
  [deepseek-ai/deepseek-harness#9924](https://github.com/deepseek-ai/deepseek-harness/discussions/9924).
