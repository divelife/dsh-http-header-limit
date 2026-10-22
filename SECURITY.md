# Security Policy

## Reporting a vulnerability

Report privately via [GitHub private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability).
Include the affected version, platform, DSH/Electron/Node versions, and a
minimal reproduction if you have one.

## Security-relevant behaviour

**The plugin raises an HTTP header limit.** It sets `maxHeaderSize` on the Host's
`http.Server` from 16384 to 262144 bytes. That limit partly bounds the memory a
single request can consume before parsing finishes, so raising it widens the
per-request ceiling. The Host binds `127.0.0.1` only, so this applies to local
clients, and 262144 is still a finite bound: larger requests are rejected with
431. The constant is `LIMIT` in `index.js`.

**The rescue scripts delete rows from the app's cookie database.** They remove
only rows matching `host_key = '127.0.0.1' AND name LIKE 'dsh-auth-%'`, after
copying the database to a backup directory, and they refuse to run while dsh is
running. They delete no files, do not modify plugin configuration, and never
read or transmit a cookie value.

## What this project does not do

- No network access, no telemetry.
- Never reads a cookie value: the plugin only raises a number, and the scripts
  match rows by name and host and print counts only.
- Never modifies the installed application (`app.asar`).

## Supported versions

Only the latest release receives fixes.

| Version | Supported |
| ------- | --------- |
| 1.x     | Yes       |
