# dsh-pwa 项目长期记忆

> 动手前先读 **`.workbuddy-ai/memory/TRAPS.md`**：踩坑全集 + **提交前 gauntlet 命令清单**。
> 本文件只放定位、硬约定、架构不变量。

## 项目
macOS PWA wrapper 包装 DeepSeek Harness（dsh）。**零常驻**：launchd socket activation，TCP 连接到达才
拉起 daemon，空闲即退，socket 由 launchd 持有。仓库 `github.com/3kaiu/dsh-pwa`(main)。
提交用 Conventional Commits + 中文 subject。

## 硬约定（均已固化为门禁）
- curl 一律带 `--max-time`；回环加 `--noproxy '*'`。
- 每个 workflow job 显式 `timeout-minutes`（缺省 360min）。
- 脚本退出不得留守护：trap 在**首次启动守护之前**注册，按 pid 与**二进制路径**各收一遍；workflow 里
  后台起守护须置 `DSH_RT_NO_AUTO_UPDATE=1`。
- 「尽力而为」步骤必须有可观测判据（marker / 断言 / 非零退出）；活文档不手写测试数量。

## 架构不变量

**daemon 安全模型（勿回退）**
- CSRF：Origin / Host **精确匹配**（防跨站与 DNS rebinding）。
- Cookie：精确匹配 `dsh-auth=` 名；不可 `strncmp(ck,"dsh-auth",8)`（会放行 `dsh-auth-evil`）。
- 请求头：循环 recv 至 `\r\n\r\n`；未见空行一律 400，不完整头不得进入判定 / 透传。
- 上游与客户端 socket 均设 `SO_SNDTIMEO`/`SO_RCVTIMEO`；`write_all` 遇 EAGAIN 必须 `poll` 有界等待，
  **不可裸 continue**（否则 100% CPU 自旋，零常驻承诺失效）。
- token 嵌 JSON 先过字符集校验；缓冲撞上限判为截断并**拒绝缓存**。引导页缓冲 8192，截断须可观测。

**包装器自我版本（阶段 3，勿回退）** `DSH_VERSION` 是 dsh 的、自动更新也只更新 dsh，故包装器另有自版本：
`install.sh` 写 `$RT_HOME/.wrapper-version`，`update-dsh.sh` 按 12h 节流写 `$RT_STATE/wrapper.latest`，
`daemon.c` **只比较**（C、无 TLS），`/health` 暴露 `wrapper_version`/`wrapper_latest`/`wrapper_outdated`。
- **「落后」≠「未知」**：任一文件缺失都不报该字段；远端取不到一律静默。
- 取 tag 必须校验形如 `v<数字>`：**无 release 时 `releases/latest` 的 302 落到末段字面量 "releases"**，
  不挡住会把每个用户标成落后。
- 版本来源不写死：包内 `VERSION` > `git describe` > `DSH_RT_RELEASE_TAG` > `unknown`。

**A5 依赖树锚点** 首次安装带 `--frozen-lockfile`（增量 `update` 不带）；缺锁显式告警；指定
`DSH_VERSION` 时跳过冻结。`release.yml` 生成 lock 用的 package.json 必须与 `install.sh` **逐字一致**。

## 测试接缝
- `DSH_DAEMON_SRC` 指向另一份 `daemon.c`：`git show HEAD:src/daemon.c > /tmp/old.c` 复验旧实现。
- `WRAPPER_UPDATE_SRC`、`SECURITY_SRC`、`WARMUP_INSTALL_SRC` 指向改动前副本。
- `dsh-probe.sh` 与 update-dsh.sh 的版本检查有**本地桩服务器**驱动，不依赖真网络。
