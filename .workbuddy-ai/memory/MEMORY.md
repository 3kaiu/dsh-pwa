# dsh-pwa 项目长期记忆

> 踩坑全集（门禁假绿 / curl / macOS 工具 / 验证方法论 / CI 孤儿 / install.sh）在
> **`.workbuddy-ai/memory/TRAPS.md`** —— 动手前先读它。本文件只放定位、约定、架构。

## 项目
macOS PWA wrapper 包装 DeepSeek Harness（dsh）。**零常驻**：launchd socket activation，TCP 连接到达才
拉起 daemon，空闲即退，socket 由 launchd 持有。
仓库 `github.com/3kaiu/dsh-pwa`(main)；`src/daemon.c`；`scripts/`；`tests/`。
提交用 Conventional Commits + 中文 subject。

## 提交前 gauntlet（改完必跑）
```bash
clang -O2 -Wall -Wextra -Werror -o /tmp/dsh_verify src/daemon.c   # 必须零告警
shellcheck -S warning scripts/*.sh tests/*.sh tests/lib/*.sh
for f in scripts/*.sh tests/*.sh tests/lib/*.sh; do bash -n "$f"; done
bats tests/unit/            # 当前 67 项；本沙箱须**分文件**跑（TRAPS 13）
# 只有**系统** python3 带 PyYAML（托管版没有）；本机 ruby 被 rbenv 指向未安装版本
/opt/homebrew/opt/python@3.13/libexec/bin/python3 -c "import yaml,glob;[yaml.safe_load(open(p)) for p in glob.glob('.github/workflows/*.yml')]"
node ~/.workbuddy-ai/skills/ci-gate-hardening/scripts/check_run_blocks.mjs .github/workflows
```
再跑一轮运行时 curl 回归（`/health` `/stop` `/wake`、Origin/Host、cookie）。

## 硬约定（都已固化为门禁）
- curl 一律带 `--max-time`；回环加 `--noproxy '*'`。
- 每个 workflow job 显式 `timeout-minutes`（缺省 360min）。
- 脚本退出不得留守护：trap 在**首次启动守护之前**注册，按 pid 与**二进制路径**各收一遍；workflow 里
  后台起守护须置 `DSH_RT_NO_AUTO_UPDATE=1`。
- 「尽力而为」的步骤必须给可观测判据（marker / 断言 / 非零退出），否则绿 ≠ 可用。

## 架构要点

**daemon 安全模型（勿回退）**
- CSRF：Origin / Host **精确匹配**（防跨站与 DNS rebinding）。
- Cookie：精确匹配 `dsh-auth=` 名，不可 `strncmp(ck,"dsh-auth",8)`（会放行 `dsh-auth-evil`）。
- 请求头：循环 recv 至 `\r\n\r\n`；未见空行一律 400，不完整头不得进入判定 / 透传。
- 上游与客户端 socket 都要设 `SO_SNDTIMEO`/`SO_RCVTIMEO`；`write_all` 遇 EAGAIN 必须 `poll` 有界等待，
  **不可裸 continue**（否则 100% CPU 自旋）。否则「零常驻」承诺失效。
- token 嵌 JSON 先过字符集校验；缓冲撞上限须判为截断并**拒绝缓存**。
- 引导页缓冲 8192，且截断必须可观测（E4）。

**包装器自我版本（阶段 3，勿回退设计）**
包装器此前没有自己的版本号（`DSH_VERSION` 是 dsh 的，自动更新也只更新 dsh）。分工：
`install.sh` 写 `$RT_HOME/.wrapper-version`；`update-dsh.sh` 按 12h 节流写 `$RT_STATE/wrapper.latest`；
`daemon.c` **只做比较**（它是 C、没有 TLS，网络不能在它里面做），`/health` 暴露
`wrapper_version` / `wrapper_latest` / `wrapper_outdated`。
- **「落后」与「未知」必须分开**：任一文件缺失都不报该字段；远端取不到一律静默。拿不到 ≠ 落后。
- 取 tag 用 `releases/latest` 的 302 + `%{url_effective}`，并要求形如 `v<数字>`：**无 release 时该 URL
  落到 `.../releases`，末段是字面量 "releases"**，不挡住就会把每个用户都标成落后。
- 版本来源不写死常量：包内 `VERSION` > `git describe` > `DSH_RT_RELEASE_TAG` > `unknown`。

**A5 依赖树锚点**
首次安装带 `--frozen-lockfile`（增量 `update` 不带）；缺锁显式告警；`DSH_VERSION` 指定具体版本时跳过
冻结。`release.yml` 生成 lock 用的 package.json 必须与 `install.sh` **逐字一致**（已有门禁）。

## 测试接缝（写 fail-before 用例时用）
- `DSH_DAEMON_SRC` 指向另一份 `daemon.c`：`git show HEAD:src/daemon.c > /tmp/old.c` 复验旧实现。
- `WRAPPER_UPDATE_SRC`、`SECURITY_SRC`、`WARMUP_INSTALL_SRC` 指向改动前的副本。
- `dsh-probe.sh` 与 update-dsh.sh 的版本检查都有**本地桩服务器**驱动，不依赖真网络。
