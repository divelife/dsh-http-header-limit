// Real cordis integration test: loads this plugin through @deepseek-ai/cordis,
// mounts a fake webServer service, and verifies the full
// apply() -> inject -> effect -> patch chain.
//
// HOW TO RUN
//   `@deepseek-ai/cordis` is not a dependency of this package; it ships with the
//   DSH installation. Point the test at that installation when it is not
//   resolvable from here:
//
//     DSH_CORDIS=<path to .../@deepseek-ai/cordis/lib/index.js> \
//       node integration.mjs
//
//   On a normal DSH desktop install that file lives inside app.asar, and Node
//   can load it from there directly. When DSH_CORDIS is unset the test falls
//   back to a plain import, which works if cordis is resolvable (a monorepo
//   checkout, or a profile that has it installed).
import http from 'node:http'
import { pathToFileURL } from 'node:url'
import * as plugin from './index.js'

let cordis
try {
  // pathToFileURL handles Windows drive letters and spaces; hand-building a
  // file:// string from a Windows path produces a URL Node cannot resolve.
  cordis = process.env.DSH_CORDIS
    ? await import(pathToFileURL(process.env.DSH_CORDIS).href)
    : await import('@deepseek-ai/cordis')
} catch (error) {
  console.error('Cannot load @deepseek-ai/cordis.')
  console.error('Set DSH_CORDIS to the cordis entry inside your DSH installation, e.g.')
  console.error('  DSH_CORDIS=/path/to/app.asar/dsh/node_modules/@deepseek-ai/cordis/lib/index.js')
  console.error(`Original error: ${error.message}`)
  process.exit(2)
}

const { Context, Service } = cordis

// Redirect the status stamp into a throwaway directory. The plugin writes it
// under DSH_HOME, so without this the test would overwrite the real user's
// stamp with a fake port and make "is the patch running?" unanswerable.
import { mkdtempSync, rmSync, existsSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const STAMP_HOME = mkdtempSync(join(tmpdir(), 'dsh-header-limit-test-'))
process.env.DSH_HOME = STAMP_HOME
process.on('exit', () => {
  try { rmSync(STAMP_HOME, { recursive: true, force: true }) } catch { /* best effort */ }
})

let pass = 0, fail = 0
const check = (label, cond, extra = '') => {
  if (cond) { pass++; console.log('  PASS', label) }
  else { fail++; console.log('  FAIL', label, extra) }
}

// 假 webServer 服务：模仿 dsh-host-webserver 的形状（port getter + server 字段）
class FakeWebServer extends Service {
  constructor(ctx) {
    super(ctx, 'webServer')
    this.server = http.createServer((q, r) => { r.writeHead(200); r.end('ok') })
    this.listenedPort = undefined
  }
  get port() { return this.listenedPort }
}

const ctx = new Context()
const logs = []
ctx.logger = { info: (m) => logs.push(['info', m]), warn: (m) => logs.push(['warn', m]), error: (m) => logs.push(['error', m]) }

// 先不挂 webServer：插件应当安静等待，不报错
await ctx.plugin(plugin, {})
check('无 webServer 时不崩溃', true)
await new Promise(r => setTimeout(r, 300))
check('无 webServer 时不产生补丁日志', logs.length === 0, JSON.stringify(logs))

// 现在挂上 webServer（触发 ctx.inject 的 child plugin）
await ctx.plugin(FakeWebServer)
const fake = ctx.get("webServer")
check('webServer 已挂载', typeof fake.port === 'undefined' || fake.port === undefined)
check('listen 前 maxHeaderSize 未设置', fake.server.maxHeaderSize === undefined, String(fake.server.maxHeaderSize))

// 模拟 listen 完成
fake.listenedPort = 54321
await new Promise(r => setTimeout(r, 600))

check('listen 后实例被补丁', fake.server.maxHeaderSize === plugin.LIMIT, String(fake.server.maxHeaderSize))
check('产生了日志', logs.length > 0, JSON.stringify(logs))
check('日志内容含端口', JSON.stringify(logs).includes('54321'), JSON.stringify(logs))
console.log('  日志:', JSON.stringify(logs))

// The stamp must land inside the redirected home, never in the real ~/.dsh.
const stampPath = join(STAMP_HOME, plugin.STAMP_FILE)
check('标记文件写进 DSH_HOME', existsSync(stampPath), stampPath)
if (existsSync(stampPath)) {
  const stamp = JSON.parse(readFileSync(stampPath, 'utf8'))
  check('标记里的端口正确', stamp.status.includes('54321'), JSON.stringify(stamp))
  check('标记里的上限正确', stamp.limit === plugin.LIMIT, String(stamp.limit))
}

// 真实验证：40KB 头能过
const port = await new Promise(res => { fake.server.listen(0, '127.0.0.1', () => res(fake.server.address().port)) })
const send = (n) => new Promise((res) => {
  const q = http.request({ host: '127.0.0.1', port, path: '/', headers: { 'X-Big': 'x'.repeat(n) } }, (r) => { res(r.statusCode); r.resume() })
  q.on('error', () => res('ERR')); q.end()
})
check('40KB 头 -> 200', (await send(40000)) === 200)
check('300KB 头 -> 431', (await send(300000)) === 431)

fake.server.close()
console.log(`\n结果: ${pass} 通过, ${fail} 失败`)
process.exit(fail === 0 ? 0 : 1)
