# dsh-pwa

macOS 上一键安装 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) 并把它变成桌面 PWA。零常驻架构：登录后没有任何用户态进程常驻，点 PWA 图标时自动拉起，关闭页面后全部退出。

## Features

- **零常驻** — 基于 launchd socket activation，空闲时守护进程与 dsh 全部退出，不消耗内存
- **一键安装** — `curl | bash` 或两步安装，自动下载 Node.js、安装 dsh、注册 LaunchAgent
- **自动更新** — 后台异步检查（12h 节流），用户不在场时自动更新，失败自动回滚
- **PWA 体验** — Safari「添加到程序坞」即得全屏 Web App，支持桌面通知与离线缓存
- **安全默认** — CSRF/Origin 校验、Host 头防 DNS rebinding、文件权限 0700/0600、仅监听 127.0.0.1
- **Universal Binary** — arm64 + x86_64 双架构，免本地编译

## Requirements

| 项 | 下限 | 依据 / 验证状态 |
|---|---|---|
| **macOS** | 10.15（Catalina） | 依赖 launchd socket activation（`launch_activate_socket`）。**该下限未经 CI 验证**：CI 只跑 `macos-latest`，更低版本从未被测过 |
| **Node.js** | 22 | 由安装脚本的 `MIN_NODE=22` 强制（**只比较 major**）。不满足时不复用系统 node，改用包内自带的 node |
| **图形会话** | 已登录的 Aqua 会话 | 安装脚本需在 Terminal 中执行；非 Aqua 会话下 `launchctl bootstrap` 必然失败 |

**Node 能力门槛**（都按版本开关，不是硬要求 —— 低于门槛只会少一项优化，不会不可用）：

- `--use-system-ca` 需要 **Node ≥ 22.15**。install.sh 在生成 LaunchAgent 前**探测**该选项，
  不支持则整行留空，因此 Node 22.0–22.14 也能正常使用（只是不走系统证书链）。
- `NODE_COMPILE_CACHE` 需要 **Node ≥ 22.1**。更旧的 node 会忽略这个环境变量（无害），
  只影响二次启动速度。

> 想确认某个版本可用：跑 `bash tests/security-verification.sh` 与 `bash scripts/smoke-test.sh`
> —— 两者都不依赖 CI 的 macOS 版本，可在目标机器上直接验证。

> Linux / Windows 明确不在支持范围内 —— 零常驻依赖 macOS 独有的 launchd socket activation 机制。

## Installation

### 推荐方式（两步安装，可 review）

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/3kaiu/dsh-pwa/main/scripts/install.sh
bash install.sh
```

### 快速方式（管道执行）

```bash
curl -fsSL https://raw.githubusercontent.com/3kaiu/dsh-pwa/main/scripts/install.sh | bash
```

> ⚠️ 生产环境建议使用两步安装方式。

升级 = 重跑同一条命令（已最新则秒级跳过）。

**版本固定：**

```bash
DSH_RT_RELEASE_TAG=v1.0.0 bash install.sh
```

**回退到已知版本：**

```bash
DSH_VERSION=0.1.1-rc.2 bash install.sh
```

## Usage

安装完成后：

1. 在 Safari 中打开 `http://127.0.0.1:<PORT>/`（PORT 由安装脚本分配，默认 3080）
2. 点击 Safari 菜单「文件 → 添加到程序坞」
3. 从 Dock 点击图标即可启动全屏 PWA

首次启动会自动唤醒 dsh（下载依赖、编译缓存），约 5–15 秒。后续启动复用编译缓存，秒级就绪。

## Configuration

| 环境变量 | 说明 | 默认值 |
|---|---|---|
| `DSH_RT_PORT` | 守护监听端口 | `3080` |
| `DSH_RT_HOME` | 运行时主目录 | `~/.local/share/dsh-runtime` |
| `DSH_RT_STATE` | 状态与日志目录 | `~/.local/state/dsh-runtime` |
| `DSH_RT_IDLE_STOP_SECS` | 空闲后停止 dsh 的秒数 | `30` |
| `DSH_RT_MAX_CONN` | 并发连接上限 | `256` |
| `DSH_RT_NO_AUTO_UPDATE` | 禁用自动更新 | — |
| `DSH_RT_PREWARM` | 登录时预热 dsh | — |
| `DSH_VERSION` | 固定 dsh 版本（覆盖 `@latest`） | — |

## Security

- **CSRF 防护** — 控制端点与状态变更请求必须携带精确匹配本端口的 Origin 头
- **Host 头校验** — 拒绝非 `127.0.0.1:PORT` / `localhost:PORT` 的请求，防 DNS rebinding
- **Cookie 精确匹配** — `dsh-auth=` 全名匹配，防止前缀绕过
- **文件权限** — 状态目录 0700、日志文件 0600，用户私有
- **Localhost 绑定** — 仅监听 127.0.0.1，不暴露到网络
- **并发上限** — 超限时直接 503 拒绝，防止 fork 耗尽

### Known Limitations

- **流水线请求只校验第一个** — 同 TCP 连接内的后续请求原样透传给 dsh，不再经守护校验。浏览器不会这样发包，构造该流量需本机 socket 写权限，已等同本机访问权限。
- **透传鉴权在 dsh** — 守护的 Origin 校验是额外一层，不替代 dsh 的 token/cookie 鉴权。
- **发行包完整性依赖发布方** — `curl | bash` 路径下 SHA-256 校验的信任根是 GitHub 发布者账号，非独立签名密钥。

完整审计历史见 [docs/AUDIT_HISTORY.md](docs/AUDIT_HISTORY.md)。

## Troubleshooting

日志统一在 `~/.local/state/dsh-runtime/logs/`：

```bash
# 守护是否正常拉起/停止 dsh
tail -50 ~/.local/state/dsh-runtime/logs/daemon.log

# 自动更新是否成功/失败/回滚
tail -50 ~/.local/state/dsh-runtime/logs/update.log

# launchd 注册状态
launchctl print "gui/$(id -u)/com.dshpwa.daemon"
```

## Uninstallation

```bash
launchctl bootout "gui/$(id -u)/com.dshpwa.daemon"
launchctl bootout "gui/$(id -u)/com.dshpwa.updater"

# bootout 会向守护发 SIGTERM，守护收到后**先停 dsh 再退出**，不会留下孤儿 dsh。
# 但这一步只在「守护确实还注册着」时生效：若之前手工 bootout 过、或守护已被强杀，
# dsh 可能仍在跑。故用下面这条兜底 —— **必须在 rm -rf 之前**，否则会留下一个
# 还在跑、但 node_modules 已被删掉的 dsh。
pkill -f "$HOME/.local/share/dsh-runtime/app" 2>/dev/null || true

# 确认无残留（应无输出）
pgrep -fl "dsh-runtime" || true

rm -f ~/Library/LaunchAgents/com.dshpwa.*.plist
rm -rf ~/.local/share/dsh-runtime ~/.local/state/dsh-runtime

# 可选：清理 dsh 用户数据（会话历史等）
rm -rf ~/.dsh

# 可选：清理 pnpm store（累积历史版本可能占数 GB）
pnpm store prune
```

## Development

```bash
# 冒烟测试（端到端：安装 → 启动 → 透传 → 空闲自停 → socket activation）
bash scripts/smoke-test.sh

# 安全验证套件
bash tests/security-verification.sh

# 单元测试（不依赖真实 dsh）
bats tests/unit/

# 只统计用例数
bats -c tests/unit/*.bats
```

开发工具链与详细指引见 [docs/TOOLS_INTEGRATION.md](docs/TOOLS_INTEGRATION.md)。

本地若出现一个**未被跟踪**的 `.workbuddy-ai/` 目录，那是开发时的本地笔记（踩坑清单与每日记录），
已列入 `.gitignore`。它不参与构建与测试，克隆后不存在是正常的。

## Contributing

欢迎 issue 和 PR。提交前请运行：

```bash
clang -O2 -Wall -Wextra -Werror -o /tmp/dsh_verify src/daemon.c
shellcheck -S warning scripts/*.sh tests/*.sh tests/lib/*.sh
for f in scripts/*.sh tests/*.sh tests/lib/*.sh; do bash -n "$f"; done
bats tests/unit/
```

提交信息使用 Conventional Commits，subject 用中文。

## License

MIT License — 详见 [LICENSE](LICENSE)。

## Acknowledgements

- [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) — DeepSeek 官方提供的 Web IDE
