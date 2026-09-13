# dsh-pwa

macOS 上一键安装 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh)（DeepSeek 官方 Web IDE），并把它变成桌面 PWA。

**零常驻**：登录后没有任何用户态进程常驻 —— launchd 持有监听 socket，首个 TCP 连接才拉起守护，关闭页面后守护与 dsh 全部退出。

## Features

- **零常驻** — 空闲时不留任何进程，不占内存
- **一键安装** — `curl | bash`，自动下载 Node.js、安装 dsh、注册 LaunchAgent
- **自动更新** — 后台检查（12h 节流），用户不在场时更新，失败自动回滚
- **PWA 体验** — Safari「添加到程序坞」即得全屏 Web App，支持通知与离线缓存
- **安全默认** — CSRF/Host 校验、0700/0600 权限、仅监听 127.0.0.1
- **免本地编译** — 发行包为 arm64 + x86_64 双架构二进制

## Requirements

| 项 | 下限 | 依据 |
|---|---|---|
| **macOS** | 10.15（Catalina） | 依赖 launchd socket activation。**该下限未经 CI 验证**：CI 只跑 `macos-latest` |
| **Node.js** | 22 | 安装脚本的 `MIN_NODE=22`（**只比较 major**）；不满足时不复用系统 node，改用包内自带的 |
| **图形会话** | 已登录的 Aqua 会话 | 非 Aqua 会话下 `launchctl bootstrap` 必然失败 |

`--use-system-ca`（Node ≥ 22.15）与 `NODE_COMPILE_CACHE`（Node ≥ 22.1）都是**按能力探测**后启用；低于门槛只是少一项优化，不影响可用。

Linux / Windows 明确不在支持范围内 —— 零常驻依赖 macOS 独有的 launchd socket activation。
想确认某台机器可用：跑 `bash scripts/smoke-test.sh` 与 `bash tests/security-verification.sh`（都不依赖 CI 的 macOS 版本）。

## Installation

```bash
# 推荐：两步安装，先 review 再执行
curl -fsSL -o install.sh https://raw.githubusercontent.com/3kaiu/dsh-pwa/main/scripts/install.sh
bash install.sh

# 或快速方式（管道执行）
curl -fsSL https://raw.githubusercontent.com/3kaiu/dsh-pwa/main/scripts/install.sh | bash
```

升级 = 重跑同一条命令（已最新则秒级跳过）。也可固定版本：

```bash
DSH_RT_RELEASE_TAG=v1.0.0 bash install.sh   # 固定发行版
DSH_VERSION=0.1.1-rc.2 bash install.sh      # 固定 dsh 版本
```

## Usage

1. Safari 打开 `http://127.0.0.1:<PORT>/`（PORT 由安装脚本分配，默认 3080）
2. Safari 菜单「文件 → 添加到程序坞」
3. 从 Dock 点击图标即全屏启动

首次启动会唤醒 dsh（下载依赖、编译缓存），约 5–15 秒；后续复用缓存，秒级就绪。

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

- **CSRF** — 控制端点与状态变更请求必须携带精确匹配本端口的 `Origin`
- **Host 校验** — 拒绝非 `127.0.0.1:PORT` / `localhost:PORT`，防 DNS rebinding
- **Cookie** — `dsh-auth=` 全名匹配，防前缀绕过
- **权限与网络** — 状态目录 0700、日志 0600；仅监听 127.0.0.1；并发超限直接 503

### Known Limitations

- **流水线请求只校验第一个** — 同 TCP 连接内的后续请求原样透传给 dsh，不再经守护校验。浏览器不会这样发包；构造该流量需本机 socket 写权限，已等同本机访问权限。
- **透传鉴权在 dsh** — 守护的 Origin 校验是额外一层，不替代 dsh 的 token/cookie 鉴权。
- **发行包完整性依赖发布方** — `curl | bash` 路径下 SHA-256 校验的信任根是 GitHub 发布者账号，非独立签名密钥。

完整审计历史见 [docs/AUDIT_HISTORY.md](docs/AUDIT_HISTORY.md)。

## Troubleshooting

日志在 `~/.local/state/dsh-runtime/logs/`：

```bash
tail -50 ~/.local/state/dsh-runtime/logs/daemon.log   # 守护是否正常拉起/停止 dsh
tail -50 ~/.local/state/dsh-runtime/logs/update.log   # 自动更新成功/失败/回滚
launchctl print "gui/$(id -u)/com.dshpwa.daemon"      # launchd 注册状态
```

## Uninstallation

```bash
launchctl bootout "gui/$(id -u)/com.dshpwa.daemon"
launchctl bootout "gui/$(id -u)/com.dshpwa.updater"

# 兜底：bootout 只在守护确实还注册着时生效。**必须在 rm -rf 之前**执行，
# 否则会留下一个还在跑、但 node_modules 已被删掉的 dsh。
pkill -f "$HOME/.local/share/dsh-runtime/app" 2>/dev/null || true
pgrep -fl "dsh-runtime" || true   # 确认无残留（应无输出）

rm -f ~/Library/LaunchAgents/com.dshpwa.*.plist
rm -rf ~/.local/share/dsh-runtime ~/.local/state/dsh-runtime
rm -rf ~/.dsh        # 可选：dsh 用户数据（会话历史等）
pnpm store prune     # 可选：pnpm store（累积历史版本可能占数 GB）
```

## Development

```bash
bash scripts/smoke-test.sh           # 端到端冒烟（安装 → 启动 → 透传 → 空闲自停 → socket activation）
bash tests/security-verification.sh  # 安全验证套件
bats tests/unit/                     # 单元测试（不依赖真实 dsh）
bats -c tests/unit/*.bats            # 只统计用例数
```

欢迎 issue 和 PR。提交前请跑完整门禁：

```bash
clang -O2 -Wall -Wextra -Werror -Wunused-macros -o /tmp/dsh_verify src/daemon.c
shellcheck -S warning scripts/*.sh tests/*.sh tests/lib/*.sh
for f in scripts/*.sh tests/*.sh tests/lib/*.sh; do bash -n "$f"; done
bats tests/unit/
```

提交信息用 Conventional Commits，subject 用中文。开发工具链与详细指引见 [docs/TOOLS_INTEGRATION.md](docs/TOOLS_INTEGRATION.md)。

本地若出现**未被跟踪**的 `.workbuddy-ai/`，那是开发笔记，已列入 `.gitignore`，克隆后不存在是正常的。

## License

MIT License — 详见 [LICENSE](LICENSE)。
