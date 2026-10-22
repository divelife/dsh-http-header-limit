# dsh-http-header-limit

修复 dsh 桌面版重启次数多了之后启动崩溃的问题。

dsh 每次启动绑随机端口，会话 cookie 名跟着端口变，所以每次启动都多一条 `dsh-auth-*` cookie，旧的永不覆盖、30 天内也不清理。攒到约 71 条（16.4 KB）就超过 Node 默认 16 KB 的请求头上限，Host 返回 431，桌面壳报成：

```
Error: desktop welcome: Web authentication failed
```

表现为窗口一闪即退。这个插件把 Host 的 `maxHeaderSize` 抬到 256 KB，可容纳约 1148 条 cookie。不删 cookie，不改安装文件，升级应用不会丢。

> 上游 issue：[deepseek-ai/deepseek-harness#9924](https://github.com/deepseek-ai/deepseek-harness/discussions/9924)。这是临时绕过，不是根治。

## 安装

```bash
dsh plugin --profile desktop add dsh-http-header-limit
```

从本地目录装：

```bash
dsh plugin --profile desktop add link:<本目录绝对路径>
```

**装完需要完全退出 dsh（含托盘）再启动**，插件在启动时加载。

## 使用

装好就不用管了，每次启动自动生效。

确认它在工作，看标记文件：

```bash
cat ~/.dsh/http-header-limit.json
# {"at":"...","limit":262144,"status":"maxHeaderSize=262144 on 127.0.0.1:49677"}
```

`status` 里的端口应该和当次 Host 端口一致。文件不存在就是插件没跑起来。

## 急救脚本

补丁失效、且已经启动崩溃时用。**必须先完全退出 dsh。**

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File dsh-cookie-rescue.ps1 -DryRun   # 先预览
powershell -ExecutionPolicy Bypass -File dsh-cookie-rescue.ps1           # 真删
```

macOS / Linux：

```bash
chmod +x dsh-cookie-rescue.sh
./dsh-cookie-rescue.sh --dry-run
./dsh-cookie-rescue.sh
```

只删 `host_key='127.0.0.1'` 且名字以 `dsh-auth-` 开头的记录，删前自动备份，删后校验条数和完整性。不需要 Python，用 Node 内置 `node:sqlite`（Node ≥ 22.5）。

## 注意

启动失败时**别点**弹窗里的「Disable third-party plugins」。它会改名 `cordis.patch.yml` 并把 `dsh.profile.bundles` 砍到只剩两个官方包，但修不好这个 bug，只会丢配置。

## License

MIT
