# Security Policy

## Reporting a vulnerability

Please report security issues privately rather than in a public issue. Use
GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
for this repository, or contact the maintainer directly if that is unavailable.

Include: affected version, the platform and DSH/Electron/Node versions, a
description of the impact, and a minimal reproduction if you have one.

## What this project does that is security-relevant

**It raises an HTTP header limit.** The plugin sets `maxHeaderSize` on the Host's
`http.Server` from 16384 bytes to 262144 bytes. That limit exists partly to bound
the memory a single request can consume before parsing completes, so raising it
does widen the per-request ceiling.

Context for that trade-off:

- The Host binds `127.0.0.1` only. It is not reachable from the network, so the
  ceiling applies to local clients.
- The overflow it works around is caused by the app's own cookie jar growing
  without bound, which the limit turns into a startup crash.
- 262144 bytes is still a finite bound, not an unlimited one. A request beyond
  it is still rejected with 431.

If you believe this ceiling is too high for a specific deployment, note that the
constant is a single value (`LIMIT` in `index.js`) and lowering it trades
headroom for accumulated cookies against a smaller per-request ceiling.

**The rescue script deletes rows from the app's cookie database.** It removes
only rows matching `host_key = '127.0.0.1' AND name LIKE 'dsh-auth-%'`, after
copying the database to a backup directory, and it refuses to run while dsh is
running. It does not delete files, does not modify plugin configuration, and
does not read or transmit any cookie value.

## What this project deliberately does not do

- **No network access.** Neither the plugin nor the script makes outbound
  requests.
- **No credential handling.** The plugin never reads a cookie value; it only
  raises a numeric limit. The script matches rows by name and host, and prints
  counts only — never cookie contents.
- **No modification of the installed application.** `app.asar` is untouched, so
  the patch cannot be silently carried across an update in a modified state.
- **No telemetry.**

## Supported versions

The project tracks DSH desktop releases. Only the latest released version
receives fixes.

| Version | Supported |
| ------- | --------- |
| 1.x     | Yes       |
