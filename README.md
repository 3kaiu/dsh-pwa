# dsh-pwa

macOS 上一键安装 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh)(官方 npm 包 `@deepseek-ai/dsh`)并把它变成常驻的桌面 PWA:登录即启动一个 ~1.3MB 守护进程(LaunchAgent),Safari「添加到程序坞」即得全屏 Web App;dsh 空闲自动停止,不占资源。

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
- 默认自动跟随 `@deepseek-ai/dsh@next`(dsh 官方开发分支)
- 出现问题时可回退到已知版本: `DSH_VERSION=0.1.1-rc.2 bash install.sh`
- 冒烟测试作为安全网,breaking change 会在安装后立即发现

完整的安全审计报告见 [`SECURITY_AUDIT.md`](SECURITY_AUDIT.md)。

## 性能优化

- **体积优化:** 自动清理跨平台冗余文件，安装后体积 ~178MB (相比原始 212MB 减少 16%)
- **清理内容:**
  - node-pty Win32/Linux 预编译二进制 (~23MB)
  - @img/sharp WASM 备用方案 (~9MB)
  - sourcemap/文档/测试文件 (~2MB)
- **daemon 极简:** 85KB universal binary (arm64 + x86_64)，运行时仅占 ~672KB 内存

## 卸载

```bash
launchctl bootout "gui/$(id -u)/com.dshpwa.daemon"
launchctl bootout "gui/$(id -u)/com.dshpwa.updater"
rm -f ~/Library/LaunchAgents/com.dshpwa.daemon.plist
rm -f ~/Library/LaunchAgents/com.dshpwa.updater.plist
rm -rf ~/.local/share/dsh-runtime ~/.local/state/dsh-runtime

# 可选: 清理 pnpm store(释放磁盘空间,累积历史版本可能占数GB)
pnpm store prune
```

## 性能优化

- **体积优化:** 自动清理跨平台冗余文件，安装后体积 ~178MB (相比原始 212MB 减少 16%)
- **清理内容:**
  - node-pty Win32/Linux 预编译二进制 (~23MB)
  - @img/sharp WASM 备用方案 (~9MB)
  - sourcemap/文档/测试文件 (~2MB)
- **daemon 极简:** 85KB universal binary (arm64 + x86_64)，运行时仅占 ~672KB 内存

## 安全特性

- **CSRF 防护:** 控制端点(`/wake`, `/stop`)验证 Origin/Referer 头，拒绝跨域请求
- **安全文件权限:** 日志和状态文件使用 0600 权限(用户私有)
- **端口验证:** 仅接受 1024-65535 范围的端口配置
- **Localhost 绑定:** 守护进程仅监听 127.0.0.1，不暴露到网络
- **进程隔离:** dsh 运行在独立进程，崩溃不影响守护进程

## 自动更新

- **后台异步更新:** 守护进程启动后延迟 10 秒触发后台版本检查，不阻塞启动
- **定时自动更新:** LaunchAgent 每天凌晨 2:30 自动检查并更新到 `@deepseek-ai/dsh@latest`
- **增量更新优化:** 仅下载变化的包，节省 70-85% 流量和时间
- **故障降级:** 网络失败或更新失败时静默跳过，使用现有版本
- **禁用开关:** 设置 `DSH_RT_NO_AUTO_UPDATE=1` 可完全禁用自动更新

## 开发

```bash
bash scripts/smoke-test.sh              # 隔离目录真实安装 → 幂等重跑 → 自动唤醒/就绪门控/透传 → 空闲自停
bash tests/security-verification.sh     # 验证所有安全控制是否按预期工作
```
