# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed

- **零常驻:launchd socket activation 改造** — daemon 不再 RunAtLoad/KeepAlive 常驻;launchd 持有监听 socket,首个 TCP 连接自动拉起 daemon(launch_activate_socket),空闲停止 dsh 后 daemon `exit(0)` 自退;后台更新检查改为 daemon 激活时触发并按 `RT_STATE/last_update_check` 时间戳 12h 节流;install.sh 改为 bootout + bootstrap(不再 kickstart);smoke-test 新增 socket-activation 端到端段(激活→自退→再激活)
- **懒启动成为默认** — 登录不再预热 dsh(登录只驻留 ~1MB 守护),首次点 PWA 图标才拉起;`DSH_RT_PREWARM=1` 显式开启预热(旧 `DSH_RT_NO_PREWARM=1` 继续有效);后台更新检查与预热解耦,守护每次启动都会评估(12h 节流)
- **dsh 停止串行化** — `/wake`/`/stop` 改为连接子进程投递命令字节、主进程单线程串行执行启停,消除旧实现中 stop 与并发 wake 的状态文件误删竞态;`/stop` 响应不再阻塞最长 6s

### Added

- **自动更新体系** — 新增 `scripts/update-dsh.sh`(npm view 解析 dist-tag 真实版本 → 与本地实际版本比较 → pnpm 增量更新,失败回滚保持当前版本,绝不回退 npm);updater LaunchAgent(`com.dshpwa.updater`)每天凌晨 2:30 定时触发;daemon 激活时后台触发(12h 节流,延迟 10s 不阻塞启动);与 install.sh 共用 `.install.lock`(mkdir 原子锁 + pid 存活检测 + TOCTOU claim 防护);更新前活跃度探测(dsh 运行中跳过本轮,等用户不在场);update.log 超 2MB 自动轮转(保留 update.log.1);release 打包补齐 updater 组件(update-dsh.sh + updater plist);node 路径优先从 `RT_HOME/run.json` 解析(launchd 环境无用户 PATH),PATH 前置 node 所在目录
- **Host 头校验(防 DNS rebinding)** — 所有请求(引导页/控制端点/透传)统一在最前面校验 Host 精确等于 `127.0.0.1:PORT`/`localhost:PORT`,否则 403;防止 evil.com 解析到 127.0.0.1 后以"同源"身份读 `/health` 窃取 dsh token
- **dsh 0.1.5+ 启动 token 捕获与端点** — daemon 主进程增量扫描 dsh 日志捕获 launch token,经 `/health` 交给引导页完成 `/?token=` 握手种下持久会话 cookie;新增 `POST /ping`(在场心跳续租)与 `POST /goodbye`(页面关闭信标,GOODBYE_GRACE 后快停);token 握手请求(`GET /?token=…`)放行透传,解决引导页无限 reload 死循环;守护重启 adopt 运行中的 dsh 时补扫 token
- **NODE_COMPILE_CACHE** — dsh 子进程启用 Node 原生编译缓存(落盘 `RT_STATE/node-cache`,0700),二次启动跳过 JS 编译阶段明显提速;旧版 node 忽略该变量无害
- **bats 单元测试体系** — `tests/unit/install-validation.bats`(端口校验/编译/体积/语法等 8 用例)与 `tests/unit/daemon-cases.bats`(守护黑盒用例,不依赖真实 dsh,复用 `tests/lib/daemon-helpers.sh` 探测助手);安全验证套件 `tests/security-verification.sh` 扩充至 33 项断言(含真实编译+启动+curl 的运行时 CSRF/Host 验证)
- 自动更新人工验收清单(`tests/auto-update-checklist.md`)

### Fixed

- **P0-P3 修复批次** — dsh 版本策略回退为跟随 `@latest`(`DSH_VERSION` 可覆盖);探测超时梯度调优(快速启动提速 ~50%,探测逻辑抽到 `tests/lib/daemon-helpers.sh`);dsh 崩溃自愈演进为非阻塞 `cooldown_until` 冷却(连续 3 次快速崩溃后 60s 冷却期内拒绝拉起,主循环照常服务引导页,不再 `sleep(60)` 卡住全部请求);release.yml 增加 pnpm-lock.yaml diff 检查
- **本轮审计修复(自动更新链路)** — update-dsh.sh 从 `run.json` 解析 node 绝对路径(修复 launchd 环境无 PATH 导致更新静默失败)、PATH 前置 node 目录(npm/pnpm shebang `env node` 不再恒失败)、更新彻底失败时回滚恢复更新前依赖树、dsh 运行中(守护 `/health` 报 dsh:true)跳过本轮更新避免杀掉在用会话
- **token 相关修复** — 守护重启 adopt 运行中 dsh 时补扫日志 token(修复 token 死循环导致的引导页 401);更新子进程退出误减活跃连接计数导致 WS 独占时误停 dsh 的竞态
- **停止竞态修复** — `/stop` 与并发 `/wake` 的状态文件误删竞态(停止串行化,见 Changed);锁竞态(install.lock 抢占的 TOCTOU claim 防护)

### Security

#### 🔴 High-Risk Fixes

- **H1: Supply-Chain Integrity**
  - Added SHA-256 verification for release artifacts with fail-closed validation
  - Release workflow now generates and publishes `.sha256` checksum files
  - Install script verifies package integrity before extraction
  - Added version pinning support via `DSH_RT_RELEASE_TAG` environment variable
  - Default behavior remains `latest`, but production users can pin to specific versions

- **H2: CSRF Protection**
  - Control endpoints (`/wake`, `/stop`) now validate `Origin`/`Referer` headers
  - Blocks cross-origin POST requests with 403 Forbidden
  - Prevents remote websites from triggering daemon control actions
  - Only accepts requests from `http://127.0.0.1:<port>` and `http://localhost:<port>`

#### 🟠 Medium-Risk Fixes

- **M1: Secure File Permissions**
  - Log files (`dsh.log`) now created with 0600 mode (user-private)
  - Log directory created with 0700 mode (user-only access)
  - State files (`dsh.json`, `dsh.pid`) use 0600 mode
  - Prevents local privilege escalation via log snooping

- **M2: Universal Binary Support**
  - Release workflow now builds universal binaries (arm64 + x86_64)
  - Fixes installation degradation for Intel Mac users
  - Eliminates dependency on local Command Line Tools for x86_64 users

- **M3: Port Allocation Race Condition**
  - Significantly reduced TOCTOU window in port selection
  - `pick_port_fd()` holds socket reservation through fork, released in child before execl
  - Narrow window remains (5 lines) between child's close() and dsh's bind()
  - Much safer than original implementation but not completely eliminated

- **M4: Robust HTTP Readiness Probe**
  - Increased timeout from 1s to 3s (covers p95 cold start)
  - Added strict HTTP/1.x protocol validation (rejects HTTP/0.9)
  - Enlarged buffer from 256 to 512 bytes for verbose response headers
  - Fixes PWA blank screen on slow dsh startup

#### 🟡 Low-Risk Hardening

- **L1: Port Configuration Validation**
  - Install script validates port range (1024-65535)
  - Daemon validates `DSH_RT_PORT` and rejects invalid values
  - Prevents binding to privileged ports or random ports via `atoi(0)`

- **L2: PID Validation**
  - `stop_dsh()` now verifies PID existence before sending signals
  - Prevents accidental kill of recycled PIDs (low probability, defense-in-depth)

- **L3: HTML Escaping**
  - `build_boot()` now HTML-escapes `LOG_DIR` in boot page
  - Prevents XSS injection via malicious `RT_STATE` paths (user-controlled, low risk)

- **L4: JSON Escape Handling**
  - `extract_str()` now handles `\\` and `\"` escape sequences
  - Improves robustness for paths containing quotes

### Added

- 自动化安全验证套件(`tests/security-verification.sh`,33 项断言)
- README 中的版本固定说明与安全特性章节

### Changed

- Release workflow generates SHA-256 checksums for all artifacts
- Install script defaults to `latest` but supports version pinning
- Daemon C code enhanced with defense-in-depth controls
- All runtime state files now user-private (0600/0700)

### Documentation

- Added supply-chain integrity verification workflow
- Documented CSRF protection mechanism
- Added security best practices for production deployments
- Included residual risk assessment and future hardening recommendations

---

## Security Audit Details

**Audit Date:** 2026-09-09  
**Scope:** Full supply-chain, runtime security, and defense-in-depth review  
**Test Coverage:** 33/33 security verification tests passing  
**Binary Size:** ~85KB (universal binary, arm64 + x86_64)  
**Compilation:** Zero warnings with `-Wall -Wextra -Werror`

**Attack Surface Reduction:**
- Supply-chain: High → Low (SHA-256 verification, version pinning)
- CSRF: High → Low (Origin/Referer validation)
- Filesystem: Medium → Low (0600/0700 permissions)
- Port allocation: Medium → Low (TOCTOU eliminated)

**Residual Risk:**
- Install script fetched from `main` branch (recommend branch protection + signed commits)
- Daemon uses ad-hoc signature (recommend Developer ID + notarization for production)
