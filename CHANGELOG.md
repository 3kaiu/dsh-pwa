# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed

- **零常驻:launchd socket activation 改造** — daemon 不再 RunAtLoad/KeepAlive 常驻;launchd 持有监听 socket,首个 TCP 连接自动拉起 daemon(launch_activate_socket),空闲停止 dsh 后 daemon `exit(0)` 自退;后台更新检查改为 daemon 激活时触发并按 `RT_STATE/last_update_check` 时间戳 12h 节流;install.sh 改为 bootout + bootstrap(不再 kickstart);smoke-test 新增 socket-activation 端到端段(激活→自退→再激活)
- **懒启动成为默认** — 登录不再预热 dsh(登录只驻留 ~1MB 守护),首次点 PWA 图标才拉起;`DSH_RT_PREWARM=1` 显式开启预热(旧 `DSH_RT_NO_PREWARM=1` 继续有效);后台更新检查与预热解耦,守护每次启动都会评估(12h 节流)
- **dsh 停止串行化** — `/wake`/`/stop` 改为连接子进程投递命令字节、主进程单线程串行执行启停,消除旧实现中 stop 与并发 wake 的状态文件误删竞态;`/stop` 响应不再阻塞最长 6s
- **`daemon.c` 内部分解 `main()`(不做多文件拆分)** — `main()` 由 237 行收敛为 43 行骨架:启动装配与每 tick 结算拆为 `setup_pipes` / `open_listener` / `reap_children` / `settle_presence` / `maybe_scan_token` / `maybe_mark_ready` / `maybe_retry_wake` / `serve_once`,主循环骨架化为「收割 → 结算 → 扫描 → 就绪 → 重试 → 分派」六步。**刻意只重排原 1154 行之后**,前 1153 行逐字节不变(以 `cmp` 验证),故所有按路径的编译点、`sed` 行范围断言与 `daemon.c:NNN` 注释引用继续有效。多翻译单元拆分经评估**放弃**:它需同步改约 25 处测试断言与 `release.yml`→`.daemon.md5` 的发行指纹契约,收益仅为可读性,决策依据与证据表记入 [docs/AUDIT_HISTORY.md](docs/AUDIT_HISTORY.md)
- **README 精简** — 185 → 134 行(4,832 → 4,204 字符),内容不删只并:「推荐/快速安装」两节合为单一代码块、Requirements 的三条「依据」压成一段、Troubleshooting / Uninstallation / Development 的命令说明改行内注释、`Contributing` 并入 `Development`、删去仅复述首段链接的 Acknowledgements。**顺带补一处漂移**:README 给出的提交前编译命令漏了 `-Wunused-macros` —— 该开关由审计 F11 引入并写进本地 gauntlet,而 CI 用的是不带它的 `-Wall -Wextra -Werror`,故 README 那一段(描述**提交前**门禁)应与本地 gauntlet 对齐而非与 CI 对齐。CHANGELOG 对 README「开发」段与卸载一节的引用均已保留

### Added

- **第七轮深度审计报告** — 新增 [docs/DEEP_AUDIT_2026-09-12.md](docs/DEEP_AUDIT_2026-09-12.md):覆盖代码质量与规范性、架构设计合理性、安全漏洞、性能瓶颈、依赖版本风险、错误处理与边界条件六个维度,每条结论给出可复现命令与实测输出,代码引用一律用**符号锚点**而非行号。报告含逐项处置收口与双向控制方法,并显式列出仍未由 CI 覆盖的盲区(macOS 版本下限;需真实安装后文件系统状态的自动更新用例)
- **docs/ 审计文档合并** — 把分散的审计/修复记录(对抗审计三轮、P0-P3 批次、全方位深度审计、冒烟复核)合并为单一 [docs/AUDIT_HISTORY.md](docs/AUDIT_HISTORY.md):按轮次归并去重、统一体例;**已修项一律标注修复提交号**(提交号是不可变证据,不会过期),未修项只记「记录时未修」而不承诺现状,并显式标注「这是快照,不是现状」。原文从工作树删除但可由 git 历史完整取回。docs/ 由 8 份收敛为 3 份(3,001 → 1,095 行)
- **自动更新体系** — 新增 `scripts/update-dsh.sh`(npm view 解析 dist-tag 真实版本 → 与本地实际版本比较 → pnpm 增量更新,失败回滚保持当前版本,绝不回退 npm);updater LaunchAgent(`com.dshpwa.updater`)每天凌晨 2:30 定时触发;daemon 激活时后台触发(12h 节流,延迟 10s 不阻塞启动);与 install.sh 共用 `.install.lock`(mkdir 原子锁 + pid 存活检测 + TOCTOU claim 防护);更新前活跃度探测(dsh 运行中跳过本轮,等用户不在场);update.log 超 2MB 自动轮转(保留 update.log.1);release 打包补齐 updater 组件(update-dsh.sh + updater plist);node 路径优先从 `RT_HOME/run.json` 解析(launchd 环境无用户 PATH),PATH 前置 node 所在目录
- **Host 头校验(防 DNS rebinding)** — 所有请求(引导页/控制端点/透传)统一在最前面校验 Host 精确等于 `127.0.0.1:PORT`/`localhost:PORT`,否则 403;防止 evil.com 解析到 127.0.0.1 后以"同源"身份读 `/health` 窃取 dsh token
- **dsh 0.1.5+ 启动 token 捕获与端点** — daemon 主进程增量扫描 dsh 日志捕获 launch token,经 `/health` 交给引导页完成 `/?token=` 握手种下持久会话 cookie;新增 `POST /ping`(在场心跳续租)与 `POST /goodbye`(页面关闭信标,GOODBYE_GRACE 后快停);token 握手请求(`GET /?token=…`)放行透传,解决引导页无限 reload 死循环;守护重启 adopt 运行中的 dsh 时补扫 token
- **NODE_COMPILE_CACHE** — dsh 子进程启用 Node 原生编译缓存(落盘 `RT_STATE/node-cache`,0700),二次启动跳过 JS 编译阶段明显提速;旧版 node 忽略该变量无害
- **bats 单元测试体系** — `tests/unit/install-validation.bats`(端口校验/编译/体积/语法/CI 门禁自检等安装侧用例)与 `tests/unit/daemon-cases.bats`(守护黑盒用例,不依赖真实 dsh,复用 `tests/lib/daemon-helpers.sh` 探测助手);安全验证套件 `tests/security-verification.sh` 扩充断言(含真实编译+启动+curl 的运行时 CSRF/Host 验证);测试数量一律以运行器输出为准(见 README「开发」段),文档不手写数量
- 自动更新人工验收清单(`tests/auto-update-checklist.md`)
- **活文档防漂移门禁** — 文档不再手写测试数量(手写值必然漂移,且没人负责更新):数量一律以运行器输出为准(README「开发」段给出 `bats -c tests/unit/*.bats`,只统计不执行);新增 bats 门禁扫描 README / CHANGELOG / docs 下的设计文档,出现「数字+量词」即失败,并带正反双向自检(合成违规样本必须命中、合法内容不得误报)。带日期的历史审计快照不纳入 —— 改动它们等于篡改记录
- **`main()` 结构门禁** — 新增 bats 用例守住 `main()` 的上界(60 行)与反空转:范围抽取必须真的命中,锚点漂移时 `n=0` 要报错,否则 `n=0` 会「通过」任何上界而使门禁恒绿。已用负控验证 —— 72 行的 `main` 与无锚点文件都必须 FAIL,现状 43 行 PASS
- **`cleanup-deps.sh --dry-run`** — 支持 `--dry-run`(`-n`)只打印将被删除的路径、不做改动。设计上把「选谁」(各段 `find` 谓词)与「怎么处置」(唯一的 `del` 出口)分开,故 dry-run 的选中集合与真实删除**必然一致**,不会出现「dry-run 对、真删错」这种两套逻辑各写一遍导致的假保证

### Fixed

- **深度审计 F1–F16 处置** — 报告见 [docs/DEEP_AUDIT_2026-09-12.md](docs/DEEP_AUDIT_2026-09-12.md)。用户可见的修复:
  - **F1(唯一会让整条产品路径失效的问题)** — LaunchAgent plist 把「引导页内联的启动选项」原样写进 node 环境,其中 `--use-system-ca` 需要 Node ≥ 22.15,而安装脚本的最低版本检查**只比较 major**(22.0–22.14 全部通过),于是这些用户的 node **直接拒绝启动**(实测 rc=9,一行代码都没执行)⇒ PWA 永久白屏。改为**按能力探测**后再决定是否注入(与 `update-dsh.sh` 同一套探测),不支持时整行留空;并在子进程以 9 退出时把 `NODE_OPTIONS` 从后续启动中摘掉。
  - **F5 卸载/重启不再留孤儿 dsh** — 守护原先没有 `SIGTERM` 处理,而 plist 声明了 `AbandonProcessGroup=true`(launchd 不清理进程组)、dsh 又由 `setsid()` 自成会话 ⇒ 退出时 dsh 必然成为孤儿,而它的 `node_modules` 随后被删,留下一个「还在跑但依赖已没了」的进程。现捕获 `SIGTERM`/`SIGINT`,先有界地优雅停止 dsh 再 `exit(0)`;README 卸载一节补 `pkill -f` 兜底(必须在 `rm -rf` 之前)。
  - **F3 安装不再静默落一个坏路径** — 路径解析的兜底依赖 `python3`,而 macOS 12.3+ 不再自带;解析失败原先静默退化,现改为显式告警。
  - **F15 plist 路径校验改为白名单** — 原先只黑 `|` 与 `&`(理由是 sed 语义),而 `<` `>` `"` 换行同样会产出非法 plist,launchd **静默不加载**。改为白名单(允许的可见 ASCII + 全部非 ASCII 字节,故含中文的路径不被误拒),控制字符单独挡。
  - **F6 `cleanup-deps.sh` 删除面显式分级** — 把「确认安全」与「按名字猜」两类分开,后者在 `--dry-run` 里逐行打上风险标签,让 review 有明确着力点。
  - **F14 热路径少一次回环连接** — `/health` 是引导页轮询最频繁的端点,而它只用内存状态、从不读「dsh 是否在监听」的结果;原先每次都要白付一次 TCP connect,现已挪到提前返回之后。
  - **F11 / F16 规范与死代码** — 响应体媒体类型宏重构补完(原先只定义未使用,而 `-Wall -Wextra` **不报未使用宏**);`cleanup-deps.sh` 的 `du` 兜底移进命令替换内部(否则 `set -e` + `pipefail` 会让「下一行的兜底」永远不执行)。
  - **F8 / F12 文档与实现对齐** — CHANGELOG 的「TOCTOU 已消除」改为「窗口收窄,非互斥」(与同文件另一处的「残余窗口」表述本就矛盾);`docs/TOOLS_INTEGRATION.md` 的体积阈值与统计、README 的 macOS 版本下限、`docs/AUTO_UPDATE_IMPLEMENTATION.md` 的过期页脚逐一对齐,并把「该下限未经 CI 验证」显式写明。
- **门禁可信度整批加固** — 本轮审计最集中的一类问题是**门禁自身空转**:断言永不可能失败、断言匹配的是解释性注释而非实现、抽取失败被当成结构合规。逐项改为锚定实现,并配**双向控制**(每条新门禁都必须先在旧代码上变红):
  - **F2** `install.sh` 的 SHA 校验断言原先把「解释为什么不用 `shasum -c`」的**注释**当成了实现;删掉实现只留注释,断言照样通过。改为切出真实实现块并用夹具驱动(哈希相符必须放行、不符必须中止、空清单必须 fail-closed)。
  - **F7** 安全套件里若干断言的 `else` 分支是 `info` 而非 `fail` —— 即**永不可能失败**。
  - **F4** 新增 LaunchAgent plist 门禁:渲染两份分支并用 `plutil -lint` 校验,补上「关键产物零门禁」这个 F1 的根因。
  - **F9** 两套 shell 套件补断言数下界(原先只断言「没有红」,而「一条都没跑到」也满足它);CI 校验 bats 的实际执行数。
  - **F10** 用 `extract_fn`(符号锚点 + 花括号配平,默认剥离注释)取代 `sed` 行范围抽取 —— 后者在函数体内出现列 0 的 `}` 时会**静默截断**,而 `grep -q` 恒假。
  - **F13** `release.yml` 补 `-Werror`,与 `ci-enhanced.yml` 对齐(`workflow_dispatch` 是一条绕过路径)。
  - **行号引用门禁由 `daemon.c` 专用推广到全仓库「路径:行号」** — 原先只认一种文件,而其余文件里的同类引用漂移方式完全相同却免疫。扫描面内的引用逐条**按内容**核对(只核「行号 ≤ 某行」不够)后改写为符号/原文锚点,并补**误报反控**(`主机:端口` 是广义正则最容易误伤的形状,一旦误报,门禁只会被逼着放宽到失明)。
  - **断言数下界改为环境无关** — 下界原先是「在本机数出来的」,而其中含一条依赖 `shellcheck` 的能力相关断言;CI runner 没装 shellcheck ⇒ 计数少一 ⇒ **必然误红**,且报的是「有用例被静默跳过」这种指错方向的话。现把必需能力(真实 node)写成显式前置条件、可选能力按探测结果加回下界,并补「吞掉一条断言仍必须变红」的反空转控制。
- **P0-P3 修复批次** — dsh 版本策略回退为跟随 `@latest`(`DSH_VERSION` 可覆盖);探测超时梯度调优(快速启动提速 ~50%,探测逻辑抽到 `tests/lib/daemon-helpers.sh`);dsh 崩溃自愈演进为非阻塞 `cooldown_until` 冷却(连续 3 次快速崩溃后 60s 冷却期内拒绝拉起,主循环照常服务引导页,不再 `sleep(60)` 卡住全部请求);release.yml 增加 pnpm-lock.yaml diff 检查
- **本轮审计修复(自动更新链路)** — update-dsh.sh 从 `run.json` 解析 node 绝对路径(修复 launchd 环境无 PATH 导致更新静默失败)、PATH 前置 node 目录(npm/pnpm shebang `env node` 不再恒失败)、更新彻底失败时回滚恢复更新前依赖树、dsh 运行中(守护 `/health` 报 dsh:true)跳过本轮更新避免杀掉在用会话
- **token 相关修复** — 守护重启 adopt 运行中 dsh 时补扫日志 token(修复 token 死循环导致的引导页 401);更新子进程退出误减活跃连接计数导致 WS 独占时误停 dsh 的竞态
- **停止竞态修复** — `/stop` 与并发 `/wake` 的状态文件误删竞态(停止串行化,见 Changed);锁竞态(install.lock 抢占的 TOCTOU claim 防护)
- **审计未闭合项复核与修复** — 逐条回到代码核对(审计报告是快照,不是现状),修掉 5 处:E5 `pick_port_fd` 函数头注释按实现改写(端口预留只缩小窗口、不构成互斥);C3 `install.sh` 的 `A && B || C` 补显式括号,把左结合语义写死;D2/D3 取 node LTS 版本依赖 `python3`(macOS 12.3+ 不再自带)且失败时**静默**落到硬编码兜底,改为两条失败路径都显式告警;D5 `release.yml` 用 `github.ref_name` 同时作 VERSION 与 release tag,而 `workflow_dispatch` 下它是**分支名**(会建出名为 `main` 的 release),改为显式 `inputs.tag` + 形状校验。A3(流水线请求只校验第一个)复核后确认影响有界,按审计给出的另一选项写入 README 的「已知限制(威胁模型)」
- **`daemon.c` 引用改为符号锚点** — 复核发现 `scripts/` 与 `tests/` 里 13 处 `daemon.c:NNN` 行号引用**系统性漂移**:只有 4 处仍指向所称内容,其余指向无关代码。根因是行号描述**位置**,而位置随任何一次编辑改变且改变后**没有任何信号**。全部改为符号锚点(`read_run` / `update_locked` / `spawn_dsh` / `stop_dsh` / `trigger_background_update` / `maybe_scan_token` 等),并新增门禁禁止行号引用回归(带正反自检与扫描面反空转)
- **`cleanup-deps.sh` 删除面纳入门禁(审计 C2)** — 该脚本在安装与更新两条路径上**真删文件**,而此前唯一的把关是 `bash -n`(只查语法),没有任何用例覆盖「它到底删了什么」。新增 `tests/unit/cleanup-deps.bats`:用合成 fixture 同时放入「该删」与「必须存活」两类做**双向**断言,dry-run 与真跑各测一遍(「选中」≠「真的删掉了」),并带两条反空转(空树不得报告删除项、缺 node_modules 应静默跳过)。已用负控验证 —— 从谓词里去掉 `! -name "README.md"` 后 dry-run 与真跑**两条**用例都 FAIL 并点名该文件

- **守护低危项 E6 逐条处置(审计 E6a–E6f)** — 审计原文只写「其余低危项」,本身不可执行;本轮回到当前代码逐条复核后分别处置。**E6d 并发上限:** 旧实现每连接 `fork` 且**无上限**,只有 fd 耗尽(`EMFILE`)才退避 —— 即「已经太晚」之后才降速;现加 `MAX_CONN`(默认 256,`DSH_RT_MAX_CONN` 可覆盖),超限在 **`fork()` 之前**直接回 `503`。判定必须在 fork 之前,否则限额退化成「限制子进程存活数」而无界 fork 本身才是要堵的洞;且父进程手里的 accepted socket 是**阻塞**的(超时只在子进程 `handle_conn` 里设),故 503 路径先设 `SO_SNDTIMEO` 再写 —— 否则「加限额」反而引入与 A2 同类的挂死面。**E6a 安全响应头:** `respond()` 是全站唯一响应出口,故 `X-Content-Type-Options: nosniff` 与最小 CSP 集中加一次即覆盖全部响应;CSP 按引导页**真实需求**逐条放开(内联 script/style + 同源 fetch/sendBeacon + `/icon.svg` + `/manifest.webmanifest`),其余 `default-src 'none'`。**E6b:** `Content-Type` 参数做 CR/LF 净化(而非断言 —— 生产里断言等于崩溃),堵住将来传入用户数据时的响应头注入面。**E6c/E6e/E6f** 记为已知限制并写入 README 威胁模型
- **引导页 CSP 覆盖门禁** — CSP 一旦漏掉引导页需要的来源,页面就是**白屏且没有任何信号**(与 E4 静默截断同类失效)。新增门禁从**引导页模板本身推导**所需指令与来源(而不是把指令名抄第二遍,那样模板一改两边一起错),再核对真实响应头,于是「模板加了新资源类型却忘了改 CSP」在 CI 变红而不是在用户浏览器里变白屏。该门禁细到**源列表**:只查「指令是否存在」会漏掉「指令在、但只有 `'unsafe-inline'` 而缺 `'self'`」这一真实白屏场景(外链 `<script src>`)。带负控:合成模板驱动推导函数,并另用**真实模板变异体**(给引导页插一个外链脚本)验证门禁确实变红
- **`respond()` 响应头缓冲扩容且截断可观测** — 仅 CSP 一条就约 190 字节,旧 `hdr[256]` 装不下会静默截断成**畸形响应头**(不是少一个头,而是整块被切断);扩容并让截断打印告警,与 `build_boot` 的 E4 处理保持一致

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

- 自动化安全验证套件(`tests/security-verification.sh`)
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
- Port allocation: Medium → Low (窗口显著收窄;**非互斥** —— 残余窗口见 M3)

**Residual Risk:**
- Install script fetched from `main` branch (recommend branch protection + signed commits)
- Daemon uses ad-hoc signature (recommend Developer ID + notarization for production)
