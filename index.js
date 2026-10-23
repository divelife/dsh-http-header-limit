/**
 * dsh-http-header-limit — raise the Host HTTP request-header ceiling.
 *
 * Must be set on the live server instance, not on http.Server.prototype: a
 * prototype accessor installed after construction has no effect on the existing
 * server, and its setter would shadow the own property the parser reads.
 */

import { mkdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'

export const name = 'dsh-http-header-limit'

// Not declared as a dependency: a Host without a web server has nothing to
// patch, and a hard dependency would stop this plugin loading there.
export const inject = []

/** 256 KiB holds ~1100 cookies, far beyond any real jar. */
const LIMIT = 262144

/** One-line proof file under the DSH home, rewritten each launch. */
const STAMP_FILE = 'http-header-limit.json'

const WAIT_TIMEOUT_MS = 60000
const WAIT_STEP_MS = 200

/**
 * Resolve the DSH home like the harness does: DSH_HOME, then ~/.dsh.
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
 * Wait for `webServer.port` (undefined until listen binds), then patch.
 * @param {object} webServer - the Host's webServer service.
 * @returns {Promise<string>} one-line status.
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
        // The Host's logger reaches neither stdout nor stderr, so the stamp
        // file is the only durable evidence that the patch ran.
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
