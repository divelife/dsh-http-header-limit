# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-22

First release.

### Added

- Host plugin that raises `maxHeaderSize` on the DSH desktop Host's HTTP
  server from Node's 16384-byte default to 262144 bytes, so an accumulated
  `dsh-auth-*` cookie jar cannot overflow the request header limit and crash
  startup with `desktop welcome: Web authentication failed` (HTTP 431).
- Covers both request paths that share that limit: the welcome handshake
  (`net.fetch`) and the account WebSocket handshake.
- Per-launch status stamp at `%USERPROFILE%\.dsh\http-header-limit.json`
  recording the applied limit and the bound port, so the patch is verifiable
  after the fact. The Host's logger reaches neither stdout nor stderr, so a
  log line alone would leave no evidence.
- `dsh-cookie-rescue.ps1`: emergency script for Windows that deletes only
  `host_key = '127.0.0.1' AND name LIKE 'dsh-auth-%'` rows, with a database
  backup, an integrity check, and a row-count assertion.
- `dsh-cookie-rescue.sh`: the same rescue flow for macOS and Linux.
- `-DryRun` / `--dry-run` switch on the rescue scripts to preview the deletion
  count.
- Offline unit tests (`smoke.mjs`) and a cordis integration test
  (`integration.mjs`).

### Notes

- The plugin sets the value on the live `http.Server` instance rather than on
  `http.Server.prototype`. Measured on Electron 44.7.0 / Node 24.21.0: a
  prototype accessor installed after the server is constructed does not take
  effect, while the instance property does, including after `listen()`.
- The rescue scripts require Node 22.5+ for the built-in `node:sqlite` module
  and need no Python. They refuse to run while dsh is running, because the
  cookie database is exclusively locked.
- The rescue scripts locate the runtime in this order: `DSH_NODE`, then `node`
  on PATH, then the Electron binary of an installed DeepSeek Harness (used as
  Node). The Electron binary is a GUI-subsystem executable, so it is invoked
  with redirected stdout rather than the shell's call operator, which captures
  nothing from it.
- The status stamp honours `DSH_HOME`, matching the harness's own precedence
  (configured path, then `$DSH_HOME`, then `~/.dsh`), with `~` expanded and the
  result made absolute.
- This is a workaround for an upstream defect, not a permanent fix. See
  upstream discussion `deepseek-ai/deepseek-harness#9924`.
