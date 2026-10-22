/**
 * dsh-http-header-limit — raise the Host HTTP request-header ceiling.
 *
 * dsh's desktop Host binds a random port each launch, and its session cookie is
 * named after the authority (which includes the port), so every launch adds a
 * new `dsh-auth-*` cookie that is never overwritten or pruned. Chromium sends
 * all loopback cookies, so around 71 cookies (~16.4 KB) the request crosses
 * Node's default 16384-byte header limit and the Host answers 431, which the
 * shell reports as "Web authentication failed".
 *
 * The value must be set on the live server INSTANCE, not on
 * `http.Server.prototype`: a prototype accessor installed after construction has
 * no effect on the existing server, and its setter would shadow the own property
 * the parser reads. An instance assignment works even after listen().
 *
 * `webServer.port` is undefined until listen() binds, so polling it is a real
 * readiness signal rather than a sleep or an ordering assumption.
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
