# dsh-http-header-limit

抬高 dsh 桌面版 Host 的 HTTP 请求头上限，让累积的 `dsh-auth-*` cookie 不再把启动打崩。

## 症状

桌面版窗口一闪即退，日志里是：

```
Error: desktop welcome: Web authentication failed
    at connectDesktopWelcome (.../lib/main.js:8886)
```

## 病根（在上游，不是配置问题）

1. 桌面 Host 每次启动都绑**随机端口** —— `args: ['--no-open', '--host', '127.0.0.1', '--port', '0']`
2. 会话 cookie 名按 **authority** 算 —— `dsh-auth-<base64url(sha256("127.0.0.1:<端口>"))>`，端口变了名字就变
3. cookie 活 **30 天** —— `cookieMaxAgeDays` 默认 30，`Max-Age=2592000`
4. 桌面壳**从不清理** —— `apps/desktop/src` 里没有任何 `cookies.remove`
5. Chromium 发**所有** `127.0.0.1` 的 cookie，与端口无关 → 每次启动多叠一条
6. 攒到约 **71 条 / 16.4 KB**，越过 Node http 服务端默认 **16384 字节**头上限 → `431 HPE_HEADER_OVERFLOW`
7. 桌面壳把任何非 2xx 都报成 `Web authentication failed`，弹窗里看不到 431

对运行中的 Host 发合成 Cookie 头，边界实测：

| Cookie 头 | 结果 |
|---|---|
| ≤ 16 309 B | 401（能解析，只是 cookie 无效）|
| ≥ 16 409 B | **431**（溢出）|

按启动频率推算：20+ 次/天约 **3 天**触及上限；3–8 次/天约 9–23 天。

## 修法

把 `maxHeaderSize` 抬到 **256 KiB**（够放约 1100 条 cookie）。

**不删 cookie、不改安装目录**，所以：

- 官方升级不会把它冲掉（对比：改 `app.asar` 一升级就丢）
- 不需要重装、不需要清理数据

同一条补丁**同时覆盖两条受影响的路径**：

- welcome 握手（`connectDesktopWelcome` 的 `net.fetch`）
- 账号 WebSocket 握手（`desktopAccountBackend` 里 `new WebSocket(url, { headers: { cookie } })`）

## 为什么打实例属性而不是原型

在 Electron 44.7.0 / Node 24.21.0 上对照：

| 做法 | 效果 |
|---|---|
| 建 server **前**在 `http.Server.prototype` 装 getter | 有效 |
| 建 server **后**装原型 getter | **无效**，仍 431 |
| 给**实例**赋 `maxHeaderSize` | **有效**，listen 之后也有效，对后续连接持续有效 |

原型 getter 装上后反而有害：`server.maxHeaderSize = LIMIT` 会走 setter 而不是创建解析器真正读取的自有属性。所以本插件只设置实例属性。

`webServer.port` 在 `listen()` 完成前是 `undefined`（见 `dsh-host-webserver` 的 `get port()`），拿它当就绪信号，比固定 sleep 或假设行序可靠。

## 怎么确认它在工作

每次启动会重写一个标记文件（`$DSH_HOME` 下的 `http-header-limit.json`，默认 `~/.dsh`）：

内容形如：

```json
{"at":"2026-01-01T00:00:00.000Z","limit":262144,"status":"maxHeaderSize=262144 on 127.0.0.1:<端口>"}
```

`status` 里的端口应与当次 Host 端口一致。没有这个文件 = 插件没跑到。

也可以直接对 Host 端口探测：带 20 KB 的 `Cookie` 头请求 `/`，补丁生效应返回 **401**（而不是 431）。

## 两个文件的分工

| 文件 | 角色 | 何时生效 |
|---|---|---|
| `index.js`（插件） | **主力**，自动 | 每次启动，无需干预 |
| `dsh-cookie-rescue.ps1` | **急救**（Windows），手动 | 只在补丁失效且启动崩溃时跑一次 |
| `dsh-cookie-rescue.sh` | **急救**（macOS / Linux），手动 | 同上 |

平常只需要知道插件在工作，**不用管脚本**。脚本是那条路走不通时的后备手段。

## 急救脚本用法

**Windows**

```powershell
# 先预览会删多少条，不改动任何数据
powershell -ExecutionPolicy Bypass -File "dsh-cookie-rescue.ps1" -DryRun

# 确认后真正清理
powershell -ExecutionPolicy Bypass -File "dsh-cookie-rescue.ps1"
```

**macOS / Linux**

```bash
chmod +x dsh-cookie-rescue.sh   # 只需一次
./dsh-cookie-rescue.sh --dry-run
./dsh-cookie-rescue.sh
```

**前提：dsh 必须完全退出（含托盘图标）**，脚本会自己检查并拒绝在运行时执行。

它做什么：备份数据库 → 只删 `host_key='127.0.0.1' AND name LIKE 'dsh-auth-%'` → 完整性校验 → 校验删除条数与预期一致。

**它不会**：删任何文件、改插件配置、动账号登录态。

**不需要 Python**：两个脚本都用 Node 内置的 `node:sqlite`（Node ≥ 22.5）。runtime 按顺序查找：`DSH_NODE` 环境变量 → PATH 里的 `node` → **DSH 自带的 Electron**（用了这个插件的人必然装了 DSH）。

安全约束：只删 `host_key = '127.0.0.1'` 且名字以 `dsh-auth-` 开头的行，别的 host 的同名 cookie、本机的其他 cookie 都不动。删除前后核对条数，并跑 `PRAGMA integrity_check`；任何一项不符就报错退出，不会“删了但不告诉你”。

## 为什么插件不能自动删 cookie

实测确认的硬约束：插件跑在 **Host 进程**（纯 Node，没有 `electron` 模块），而 cookie 库归 **Electron 主进程**管。dsh 运行时对 `Cookies` 文件直接读取返回 `Permission denied`，SQLite 只读连接也失败。

所以“删 cookie”永远做不到自动、实时——它只能在 dsh 关闭后手动执行。这也正是为什么主力方案选择“抬上限”而不是“清数据”：**只有前者能做到每次启动自动生效。**

## 安装

插件自带 `cordis.patch.yml` 挂载声明，装完即可用，**不需要手工改 profile**：

```bash
# 从 npm 安装（发布后）
dsh plugin --profile desktop add dsh-http-header-limit

# 从本地目录安装（开发时）
dsh plugin --profile desktop add link:<本目录绝对路径>
```

如果不用 CLI，也可以手工在 profile 的 `cordis.patch.yml` 里插入一行，把 `name` 写成**本目录的绝对路径**：

```yaml
- insert:
    - id: dsh-http-header-limit
      name: /absolute/path/to/dsh-http-header-limit/index.js
```

绝对路径会被 `anchorInsertedPluginNames` 转成 `file://` URL，不需要 `pnpm install`。

## 测试

```bash
# 单元：installLimit 语义 + 真 server 的 40KB/300KB 行为
node smoke.mjs

# 集成：真 cordis，假 webServer，验证 apply→inject→effect→补丁 全链路
# cordis 随 DSH 发布、不是本包的依赖。从 asar 内部加载需要 Electron 的 Node：
DSH_CORDIS="<DSH 安装目录>/app.asar/dsh/node_modules/@deepseek-ai/cordis/lib/index.js" \
  ELECTRON_RUN_AS_NODE=1 "<DeepSeek Harness.exe>" integration.mjs
```

普通 `node` 读不了 `app.asar` 内部路径，所以集成测试在桌面版上必须借 Electron 的 Node 跑；`smoke.mjs` 无此限制。

当前：单元 11/11，集成 9/9。

## 上游状态

- 讨论：`deepseek-ai/deepseek-harness#9924`（多人独立复现）
- 该讨论中有人逐字节比对 `0.2.1-rc.2` 与 master：`main.ts`、`welcome-backend.ts` 相同，`createServer(listener)` 仍未传 `maxHeaderSize`，`cookieMaxAgeDays` 仍是 30，cookie 名仍按 authority —— **master 上同样可复现**
- 截至本插件编写，npm 上 `dsh-client-connection@0.2.1-rc.2` 的代码**仍无修复**
- 该讨论中建议的四种修法（握手前清理 / 抬 maxHeaderSize / 按 host 命名 / 缩短有效期）**均停留在文字，无人实现**

## 升级后怎么办

- 官方若修了此 bug（比如改成按 host 命名 cookie，或握手只带当前凭据），本插件仍然无害：抬高的上限只是不再需要。
- 官方若改了 `webServer` 的内部结构导致 `webServer.server` 取不到，`status` 会写成 `webServer.server is not patchable` —— 届时把标记文件里的 status 发到 issue 即可。

## 另一个坑：别按「Disable third-party plugins」

启动失败时弹窗的第三个按钮走 `sanitizeProfile()`：把 `cordis.patch.yml` 改名成 `.bak-<时间戳>`，并把 `dsh.profile.bundles` 重写成只剩 `@deepseek-ai/dsh-base` 和 `@deepseek-ai/dsh-web-app`。

**它修不好这个 bug**（病根是 cookie 不是插件），但会**清空你的配置**。该讨论中已有人实测连按 5 次仍持续失败，只是 patch 被清成 `[]`。这正是把人带进重装循环的原因。

遇到启动失败，先看 `http-header-limit.json` 有没有正常写出，别急着点那个按钮。
