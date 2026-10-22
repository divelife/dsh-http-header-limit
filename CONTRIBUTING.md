# Contributing

Thanks for looking at this project. It is a small, focused workaround for one
upstream defect, so the contribution surface is deliberately narrow.

## What this project is

A DSH (DeepSeek Harness) desktop plugin that raises the Host HTTP request-header
ceiling, plus an emergency script that clears stale session cookies. It exists
because of upstream discussion
[`deepseek-ai/deepseek-harness#9924`](https://github.com/deepseek-ai/deepseek-harness/discussions/9924).

**This is a workaround, not a fix for the root cause.** The durable fix belongs
upstream: key the session cookie by host instead of authority, prune stale
session cookies before the handshake, or send only the current credential on
the welcome/WebSocket handshakes. Please do not turn this project into a
permanent fork of DSH behaviour.

## Before you open an issue

1. Check `%USERPROFILE%\.dsh\http-header-limit.json`. If it exists and its
   `status` names the current port, the patch ran.
2. Confirm the failure is actually the 431 overflow. The shell reports every
   non-2xx as `Web authentication failed`, so a plugin activation error looks
   identical in the dialog.
3. **Do not** press "Disable third-party plugins" in the crash dialog. It
   renames `cordis.patch.yml` and rewrites `dsh.profile.bundles`, which wipes
   configuration without fixing this failure.

Include in the report: DSH version, Electron/Node version, the `status` line
from the stamp file, and the relevant crash log under
`%APPDATA%\@deepseek-ai\dsh-desktop\logs\`.

## Development

There is no build step; `index.js` is the plugin entry.

```bash
# Offline unit tests: installLimit semantics, real http.Server behaviour
node smoke.mjs

# Integration test: real cordis, fake webServer, full apply/inject/effect chain
# Needs a cordis that Node can resolve. Inside an asar archive that requires
# Electron's Node:
ELECTRON_RUN_AS_NODE=1 "<path to DeepSeek Harness.exe>" integration.mjs
```

For the integration test, `DSH_CORDIS` points at the cordis entry in a DSH
installation. A plain `node` cannot read paths inside `app.asar`, so use the
app's Electron binary as Node there.

## Testing expectations

Behavioural changes need a test that would fail before the change. In
particular:

- The patch must be verified against a **real** `node:http` server receiving a
  real oversized request, not only by asserting the property value.
- Anything touching the rescue script must be tested with decoy rows: a
  same-named cookie on another host, and a differently-named cookie on
  `127.0.0.1`. Both must survive.

## Style

- Comments explain *why*, not *what*. If a decision looks arbitrary, the reason
  (usually a measurement) belongs next to it.
- No new runtime dependencies. The plugin must stay loadable with no build step,
  and the rescue script must stay dependency-free (Node built-ins only).
- Keep the rescue script free of user-specific paths. It must work on a machine
  that has never seen this repository.

## Scope

Welcome, but please open an issue first:

- Additional affected request paths that share the same header limit.
- Diagnostics that make the failure distinguishable from an auth failure.

Out of scope:

- Deleting cookies automatically from the plugin. The plugin runs in the Host
  process, which has no Electron API access; the cookie database is locked by
  the Electron main process while running. This is a measured constraint, not a
  design preference.
- Modifying the installed application (`app.asar`). Such changes are lost on
  every update.

## License

By contributing you agree your work is released under the MIT License in
[LICENSE](./LICENSE).
