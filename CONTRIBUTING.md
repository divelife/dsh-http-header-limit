# Contributing

This is a small workaround for one upstream defect, so the scope is deliberately
narrow. The durable fix belongs upstream in
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness/discussions/9924),
not here.

## Before opening an issue

1. Check `$DSH_HOME/http-header-limit.json` (default `~/.dsh`). If its `status`
   names the current port, the patch ran.
2. Confirm the failure is really the 431 overflow. The shell reports every
   non-2xx as `Web authentication failed`, so a plugin activation error looks
   identical in the dialog.
3. Don't press "Disable third-party plugins" in the crash dialog: it renames
   `cordis.patch.yml` and rewrites `dsh.profile.bundles` without fixing this.

Include the DSH version, Electron/Node version, the stamp's `status` line, and
the relevant log under `%APPDATA%\@deepseek-ai\dsh-desktop\logs\`.

## Development

There is no build step; `index.js` is the entry.

```bash
node smoke.mjs        # offline: installLimit semantics, real http.Server behaviour

# integration: real cordis, fake webServer, full apply/inject/effect chain.
# cordis ships with DSH, and a plain node cannot read paths inside app.asar,
# so point at it explicitly and use the app's Electron binary as Node:
DSH_CORDIS=<DSH>/app.asar/dsh/node_modules/@deepseek-ai/cordis/lib/index.js \
  ELECTRON_RUN_AS_NODE=1 "<DeepSeek Harness.exe>" integration.mjs
```

## Testing expectations

- The patch must be verified against a **real** `node:http` server receiving an
  oversized request, not only by asserting the property value.
- Anything touching the rescue scripts must be tested with decoy rows: a
  same-named cookie on another host, and a differently-named cookie on
  `127.0.0.1`. Both must survive.

## Style

- Comments explain *why*, not *what*.
- No new runtime dependencies. The plugin stays loadable with no build step, and
  the rescue scripts use Node built-ins only.
- The rescue scripts must stay free of user-specific paths.

## Out of scope

- Deleting cookies from the plugin. It runs in the Host process, which has no
  Electron API access, and the cookie database is locked by the Electron main
  process while running.
- Modifying the installed application (`app.asar`); such changes are lost on
  every update.

## License

By contributing you agree your work is released under the MIT License in
[LICENSE](./LICENSE).
