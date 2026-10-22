/**
 * dsh-http-header-limit — raise the Host HTTP request-header ceiling.
 *
 * WHY THIS EXISTS
 * ---------------
 * dsh's desktop Host binds a RANDOM port every launch (`--port 0`), and its
 * browser-auth cookie is named `dsh-auth-<sha256(authority)>` where authority is
 * `127.0.0.1:<port>`. A new port therefore means a new cookie NAME, so each
 * launch adds one cookie to the Electron cookie jar for 127.0.0.1, and nothing
 * ever removes the old ones (`cookieMaxAgeDays` defaults to 30 days).
 *
 * Chromium sends every cookie for the host on every request, so the Cookie
 * header grows ~228 bytes per launch. Node's http server rejects a request whose
 * header block exceeds `maxHeaderSize` (16384 bytes) with HPE_HEADER_OVERFLOW
 * (431). The shell treats that as "Web authentication failed" and the app exits
 * on startup — the symptom is a window that flashes and disappears.
 *
 * Measured on the real jar: 70 cookies ≈ 16190 bytes of headers (passes),
 * 71 cookies ≈ 16416 bytes (overflows). At ~16 launches/day during plugin work
 * that ceiling is reached in under a week.
 *
 * WHAT THIS DOES
 * --------------
 * Raises `maxHeaderSize` on the Host's http.Server instance. It does NOT delete
 * cookies and does NOT modify the installed application, so it survives app
 * updates.
 *
 * WHY AN INSTANCE PATCH AND NOT A PROTOTYPE PATCH
 * -----------------------------------------------
 * Measured on this build:
 *   - a getter on `http.Server.prototype` only helps if it is installed BEFORE
 *     the server object is constructed; installed afterwards the same request
 *     still returns 431;
 *   - assigning `maxHeaderSize` on the live instance DOES take effect, and keeps
 *     taking effect for connections opened later (the HTTP parser reads the
 *     value per connection), even when the server is already listening.
 * A prototype patch installed at plugin time would therefore do nothing for the
 * already-constructed server, and worse: with a getter/setter pair in place,
 * `server.maxHeaderSize = LIMIT` would hit the setter instead of creating the
 * own property the parser actually reads. So this plugin sets the INSTANCE
 * property only, and installs no prototype accessor.
 *
 * TIMING
 * ------
 * `webServer.port` is `undefined` until `listen()` binds (dsh-host-webserver's
 * `get port()`), so polling it is a real readiness signal rather than a fixed
 * sleep or an assumption about where this row sits in the profile tree.
 */

import { mkdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'

export const name = 'dsh-http-header-limit'
// `webServer` is deliberately NOT declared here. An undeclared hard dependency
// would stop this plugin from loading on a Host without a web server, where
// there is nothing to patch anyway; ctx.inject() opens the child plugin only
// when the service actually appears.
export const inject = []

/** Ceiling to install. 256 KiB holds ~1100 cookies, far beyond any real jar. */
const LIMIT = 262144

/** One-line proof file under the DSH home, rewritten on each launch. */
const STAMP_FILE = 'http-header-limit.json'

/** How long to wait for the webserver to bind before reporting a miss. */
const WAIT_TIMEOUT_MS = 60000
const WAIT_STEP_MS = 200

/**
 * Resolve the DSH home the same way the harness does: an explicit DSH_HOME
 * wins, otherwise `~/.dsh`. Hard-coding `~/.dsh` would write the stamp to the
 * wrong place for anyone who relocated their home.
 *
 * Mirrors the harness's own precedence (configured path, then $DSH_HOME, then
 * ~/.dsh) and its two normalizations: a leading `~` is expanded, and the result
 * is made absolute. A blank or whitespace-only DSH_HOME counts as unset, so an
 * empty override never resolves the home to the working directory.
 * @param {NodeJS.ProcessEnv} env - environment to read.
 * @param {string} home - the OS user home directory.
 * @returns {string} absolute DSH home directory.
 */
function resolveDshHome(env = process.env, home = homedir()) {
  const configured = env.DSH_HOME
  const raw = typeof configured === 'string' && configured.trim().length > 0
    ? configured.trim()
    : join(home, '.dsh')

  let expanded = raw
  if (raw === '~') expanded = home
  else if (raw.startsWith('~/') || raw.startsWith('~\\')) expanded = join(home, raw.slice(2))

  return resolve(expanded)
}

/**
 * Install the ceiling on one server instance and verify it stuck.
 * @param {object} server - a node:http or node:https Server.
 * @returns {boolean} true when the instance now reports the raised value.
 */
function installLimit(server) {
  if (!server || typeof server !== 'object') return false
  if (server.maxHeaderSize === LIMIT) return true
  try {
    server.maxHeaderSize = LIMIT
  } catch {
    return false
  }
  return server.maxHeaderSize === LIMIT
}

/**
 * Wait for `webServer.port` to appear, then patch that service's server.
 * @param {object} webServer - the Host's webServer service.
 * @returns {Promise<string>} a one-line status for the log.
 */
async function patchWhenListening(webServer) {
  const deadline = Date.now() + WAIT_TIMEOUT_MS
  while (Date.now() < deadline) {
    if (webServer.port !== undefined) {
      const server = webServer.server
      if (installLimit(server)) {
        return `maxHeaderSize=${LIMIT} on 127.0.0.1:${String(webServer.port)}`
      }
      return `webServer.server is not patchable (type ${typeof server})`
    }
    await new Promise((resolve) => setTimeout(resolve, WAIT_STEP_MS))
  }
  return 'webServer did not bind within the wait window'
}

/**
 * Host plugin entry.
 * @param {object} ctx - cordis context.
 */
export function apply(ctx) {
  ctx.inject(['webServer'], (webCtx) => {
    const webServer = webCtx.webServer
    if (!webServer) return

    webCtx.effect(() => {
      let cancelled = false
      patchWhenListening(webServer).then((status) => {
        if (cancelled) return
        // This Host's logger reaches neither stdout nor stderr, so a log line
        // alone would leave no evidence that the patch ran — and "did it
        // actually apply?" is the one question this plugin exists to answer.
        // A one-line file is the proof: it is read by a human or by me later,
        // never by the Host, and it is rewritten (not appended) each launch.
        const stamp = {
          at: new Date().toISOString(),
          limit: LIMIT,
          status,
        }
        const line = `dsh-http-header-limit: ${status}`
        try {
          const logger = webCtx.logger
          if (typeof logger?.warn === 'function') logger.warn(line)
        } catch {
          /* logging is best effort; the stamp below is the durable record */
        }
        try {
          const dir = resolveDshHome()
          mkdirSync(dir, { recursive: true })
          writeFileSync(join(dir, STAMP_FILE), JSON.stringify(stamp) + '\n', 'utf8')
        } catch {
          /* a read-only home must not break startup */
        }
      })
      return () => {
        cancelled = true
      }
    }, 'dsh-http-header-limit: raise maxHeaderSize')
  })
}

export { LIMIT, installLimit, patchWhenListening, resolveDshHome, STAMP_FILE }
