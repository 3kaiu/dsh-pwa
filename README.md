# dsh-pwa

macOS 上一键安装 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh)(官方 npm 包 `@deepseek-ai/dsh`)并把它变成桌面 PWA:零常驻架构(launchd socket activation)——登录后没有任何用户态进程,点 PWA 图标时 launchd 自动拉起守护进程与 dsh,关闭页面后 dsh 与守护进程全部退出;Safari「添加到程序坞」即得全屏 Web App。

## 平台支持

**仅支持 macOS。** 这不是「暂时没适配」,而是架构前提 —— 零常驻承诺直接建立在 macOS 独有机制上:

- **launchd socket activation** — 零常驻的核心:launchd 持有监听 socket,首个连接才拉起守护进程,空闲即自退
- **LaunchAgent + Aqua 会话** — 安装需 `launchctl bootstrap` 注册守护与更新器,必须在**已登录的图形会话内**执行(在 SSH/CI 等非 Aqua 上下文中会返回 `5: Input/output error`)
- **Universal binary** — 守护进程预编译为 arm64 + x86_64,免本地编译

**Linux / Windows 明确不在范围内**(无适配计划):两者没有等价于 launchd socket activation 的机制,
要做到「空闲即自退」就得常驻一个监督进程,零常驻的卖点随之消失。需要跨平台时,请把 dsh 本身作为独立服务运行。

## 安装

### 推荐方式（两步安装）

```bash
# 1. 下载安装脚本（给你 review 机会）
curl -fsSL -o install.sh https://raw.githubusercontent.com/3kaiu/dsh-pwa/main/scripts/install.sh

# 2. 检查后执行
bash install.sh
```

### 快速安装（管道执行）

```bash
curl -fsSL https://raw.githubusercontent.com/3kaiu/dsh-pwa/main/scripts/install.sh | bash
```

⚠️ **安全提示:** 管道执行会直接运行脚本，建议生产环境使用两步安装方式。

升级 = 重跑同一条命令(已最新则秒级跳过)。

**版本固定:**

```bash
# 固定到特定版本（强烈推荐）
DSH_RT_RELEASE_TAG=v1.0.0 bash install.sh
```

**供应链完整性保障:**
- ✅ 发行包 SHA-256 校验(fail-closed,校验失败则中止安装)
- ✅ Node.js 二进制 SHA-256 校验(来自 nodejs.org 官方)
- ✅ 支持版本固定(`DSH_RT_RELEASE_TAG`)
- ✅ Universal binary(arm64 + x86_64,免本地编译)

**版本策略:**
- 默认自动跟随 `@deepseek-ai/dsh@latest`(dsh 官方稳定标签)
- 出现问题时可回退到已知版本: `DSH_VERSION=0.1.1-rc.2 bash install.sh`
- 冒烟测试作为安全网,breaking change 会在安装后立即发现

## 性能优化

- **体积优化:** 自动清理跨平台冗余文件，安装后体积 ~178MB (相比原始 212MB 减少 16%)
- **清理内容:**
  - node-pty Win32/Linux 预编译二进制 (~23MB)
  - @img/sharp WASM 备用方案 (~9MB)
  - sourcemap/文档/测试文件 (~2MB)
- **daemon 极简:** 117KB universal binary (arm64 + x86_64)，运行时仅占 ~1.3MB RSS,且仅在活跃会话期间存在(零常驻,空闲即退出)

## 卸载

```bash
launchctl bootout "gui/$(id -u)/com.dshpwa.daemon"
launchctl bootout "gui/$(id -u)/com.dshpwa.updater"
rm -f ~/Library/LaunchAgents/com.dshpwa.daemon.plist
rm -f ~/Library/LaunchAgents/com.dshpwa.updater.plist
rm -rf ~/.local/share/dsh-runtime ~/.local/state/dsh-runtime

# 可选: 清理 dsh 用户数据(会话历史等,删除前请确认无需保留)
rm -rf ~/.dsh

# 可选: 清理 pnpm store(释放磁盘空间,累积历史版本可能占数GB)
pnpm store prune
```

## 安全特性

- **CSRF 防护:** 控制端点(`/wake`/`/stop` 等)与透传的状态变更请求(POST/PUT/DELETE/PATCH)必须携带精确匹配本守护端口的 Origin 头,拒绝跨域请求
- **安全文件权限:** 日志与状态目录 0700、文件 0600(用户私有,install.sh 安装时显式收紧)
- **端口验证:** 仅接受 1024-65535 范围的端口配置
- **Localhost 绑定:** 守护进程仅监听 127.0.0.1，不暴露到网络
- **Host 头校验:** 所有请求 Host 必须精确等于 `127.0.0.1:PORT`/`localhost:PORT`,防 DNS rebinding 窃取 dsh token
- **进程隔离:** dsh 运行在独立进程，崩溃不影响守护进程

## 自动更新

- **后台异步更新:** daemon 激活时触发后台版本检查(12h 节流,不阻塞启动)
- **定时自动更新:** LaunchAgent 每天凌晨 2:30 自动检查并更新到 `@deepseek-ai/dsh@latest`
- **活跃会话保护:** dsh 正在运行(用户可能在使用)时跳过本轮更新,等下一轮用户不在场时再做
- **增量更新优化:** 仅下载变化的包，节省 70-85% 流量和时间
- **失败回滚:** 网络失败时静默跳过、使用现有版本;更新失败时自动回滚到更新前的依赖树,保持当前版本可用
- **禁用开关:** 安装时设 `DSH_RT_NO_AUTO_UPDATE=1` 跳过 updater 注册;已装系统需向 daemon plist 注入该环境变量或卸载 updater(详见 [docs/AUTO_UPDATE_IMPLEMENTATION.md](docs/AUTO_UPDATE_IMPLEMENTATION.md)「环境变量控制」)

## 故障排查

日志统一在 `~/.local/state/dsh-runtime/logs/`:

- `daemon.log` — 守护进程日志(launchd 重定向,含 dsh 启动输出与 token)
- `update.log` — 自动更新脚本日志(超 2MB 自动轮转为 `update.log.1`)
- `updater.log` — updater LaunchAgent 的 stdout/stderr

常见排查:
```bash
tail -50 ~/.local/state/dsh-runtime/logs/daemon.log    # 守护是否正常拉起/停止 dsh
tail -50 ~/.local/state/dsh-runtime/logs/update.log   # 自动更新是否成功/失败/回滚
launchctl print "gui/$(id -u)/com.dshpwa.daemon"      # launchd 注册状态
```

## 开发

```bash
bash scripts/smoke-test.sh              # 隔离目录真实安装 → 幂等重跑 → 端口占用检测 → 守护(引导页/自动唤醒/就绪门控/token 握手/透传) → 并发双唤醒幂等 → 空闲自停 → socket activation 端到端(激活→自退→再激活)
bash tests/security-verification.sh     # 验证所有安全控制是否按预期工作
bats tests/unit/                        # 单元测试:守护黑盒 / 安装校验 / 包装器版本 / 探测脚本(不依赖真实 dsh)
bats -c tests/unit/*.bats               # 只统计不执行:打印当前单元测试数量
```

> 测试数量一律以运行器输出为准(如 `bats -c tests/unit/*.bats`),文档不手写数量 —— 手写值必然漂移,已由 `tests/unit/install-validation.bats` 的门禁守护。

## 参考文档

- [docs/TOOLS_INTEGRATION.md](docs/TOOLS_INTEGRATION.md) — 开发工具链(shellcheck/hyperfine/bats)、性能剖析、故障排查
- [docs/AUTO_UPDATE_IMPLEMENTATION.md](docs/AUTO_UPDATE_IMPLEMENTATION.md) — 自动更新机制设计(pnpm 增量、12h 节流、安装锁互斥)
- [docs/P0_P3_FIXES_IMPLEMENTATION.md](docs/P0_P3_FIXES_IMPLEMENTATION.md) — P0-P3 修复实施记录
- [docs/ADVERSARIAL_AUDIT_FIX.md](docs/ADVERSARIAL_AUDIT_FIX.md) / [docs/ADVERSARIAL_AUDIT_ROUND2.md](docs/ADVERSARIAL_AUDIT_ROUND2.md) / [docs/ADVERSARIAL_AUDIT_ROUND3_FIX.md](docs/ADVERSARIAL_AUDIT_ROUND3_FIX.md) — 三轮安全审计与修复记录
- [tests/auto-update-checklist.md](tests/auto-update-checklist.md) — 自动更新人工验收清单
