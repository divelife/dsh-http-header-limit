// 离线验证插件逻辑：假 webServer + 真 node:http server，检查时序与生效性
import http from 'node:http'
import { installLimit, patchWhenListening, LIMIT } from './index.js'

let pass = 0, fail = 0
function check(label, cond, extra = '') {
  if (cond) { pass++; console.log('  PASS', label) }
  else { fail++; console.log('  FAIL', label, extra) }
}

// 1. installLimit 对正常 server 生效
const srv = http.createServer((q, r) => { r.writeHead(200); r.end('ok') })
check('installLimit 返回 true', installLimit(srv) === true)
check('实例属性等于 LIMIT', srv.maxHeaderSize === LIMIT)

// 2. 幂等
check('重复调用仍 true', installLimit(srv) === true)

// 3. 不可补的对象不抛
check('null 返回 false', installLimit(null) === false)
check('普通对象可赋值', installLimit({}) === true)

// 4. patchWhenListening：port 未定义时应等待，定义后才打补丁
const fakeServer = http.createServer((q, r) => { r.writeHead(200); r.end('ok') })
const webServer = { server: fakeServer, port: undefined }
const pending = patchWhenListening(webServer)
setTimeout(() => { webServer.port = 12345 }, 500)   // 模拟 listen 完成
const status = await pending
check('等待后拿到状态', typeof status === 'string', status)
check('状态里带端口', status.includes('12345'), status)
check('fakeServer 已打补丁', fakeServer.maxHeaderSize === LIMIT, String(fakeServer.maxHeaderSize))

// 5. 真实验证：打完补丁后 40KB 头能过
srv.listen(0, '127.0.0.1', async () => {
  const port = srv.address().port
  const send = (n) => new Promise((res) => {
    const q = http.request({ host: '127.0.0.1', port, path: '/', headers: { 'X-Big': 'x'.repeat(n) } }, (r) => {
      res(r.statusCode); r.resume()
    })
    q.on('error', () => res('ERR')); q.end()
  })
  const small = await send(1000)
  const big = await send(40000)
  const huge = await send(300000)
  check('1KB 头 -> 200', small === 200, String(small))
  check('40KB 头 -> 200 (补丁生效)', big === 200, String(big))
  check('300KB 头 -> 431 (仍有限制)', huge === 431, String(huge))
  srv.close(); fakeServer.close()
  console.log(`\n结果: ${pass} 通过, ${fail} 失败`)
  process.exit(fail === 0 ? 0 : 1)
})
