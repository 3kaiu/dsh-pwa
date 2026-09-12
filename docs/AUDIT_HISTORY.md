# dsh-pwa 审计与修复历史

> **这是历史快照,不是现状。** 本文记录各轮审计**当时**的发现与处置;其中的数字、行号、代码片段
> 描述的是那一刻的仓库状态。现状请看代码本身与 CI 门禁,不要以本文的行号或计数为准。
>
> **合并说明(2026-09-12):** 本文由 6 份分散的审计/修复文档合并而成。原文已从工作树删除,
> 但可从 git 历史完整取回:`git show <删除提交>^:docs/<原名>`。合并只做**归并去重与统一体例**,
> **不改写历史结论** —— 各轮原有的计数、严重度、未修项均按原样保留,即使它们与今天的事实不符。
>
> **阅读约定:**
> - 已修复的条目给出**修复提交号**。提交号是不可变的证据,不会过期。
> - 只标注「记录时未修」的条目**不承诺现状** —— 那只是审计当时的状态,不代表今天仍未修。
> - 本文是快照,故**不纳入** `install-validation.bats` 的文档防漂移门禁(该门禁只管活文档)。

---

## 各轮总览

| # | 轮次 / 批次 | 记录日期 | 范围 | 发现数 | 原始文档 |
|---|---|---|---|---|---|
| 1 | 对抗审计(第 1 轮) | 占位日期 | CSRF 防护、测试有效性 | R1–R5 | `ADVERSARIAL_AUDIT_FIX.md` |
| 2 | 对抗审计(第 2 轮) | 占位日期 | 安全 / 可靠性 / 可维护性 / 性能 | 15(S1–S2, M1–M4, L1–L5, R1–R3) | `ADVERSARIAL_AUDIT_ROUND2.md` |
| 3 | 对抗审计(第 3 轮) | 占位日期 | 纵深防御、CI 覆盖 | 4(新 1–新 4) | `ADVERSARIAL_AUDIT_ROUND3_FIX.md` |
| 4 | P0–P3 修复批次 | — | 上游 RC 不稳定性、系统可靠性 | 9 项改进 | `P0_P3_FIXES_IMPLEMENTATION.md` |
| 5 | 全方位深度审计 | 2026-09-11 | 全仓库(代码 + 脚本 + CI + 文档) | S1, A1–A5, E1–E6, C1–C6, D1–D6 | `DEEP_AUDIT_2026-09-11.md` |
| 6 | 冒烟结果复核 | 2026-09-12 | 冒烟真实性与 CI 耗时 | 2 缺陷 + 5 项整改 | `SMOKE_REVIEW_2026-09-12.md` |

> **原始文档自身的缺陷(合并时保留,不修改历史):**
> 1. 第 1 轮报告的表头写「审计轮次:第 2 轮」,与 `ADVERSARIAL_AUDIT_ROUND2.md` 自称的「第 2 轮」冲突;
>    从内容顺序看前者应为第 1 轮,但**未擅自改写**。
> 2. 三份对抗审计报告的日期都是未填的模板占位 `2025-01-XX`。
> 3. 深度审计称「本项目已有 **4** 轮对抗审计」,而当时仓库只有 3 份对抗审计文档。

---

## 一、对抗审计(第 1 轮)—— CSRF 与测试有效性

**状态:** 5 项全部处置完毕(4 修 + 1 记录为已知限制)。

| ID | 严重性 | 问题 | 处置 |
|---|---|---|---|
| R1 | 🔴 阻断 | CSRF 修复破坏了 smoke-test → CI 必挂 | ✅ 已修 |
| R2 | 🟠 中危 | CSRF 只校验前缀、不校验端口,任意 loopback 页面可绕过 | ✅ 已修 |
| R3 | 🟠 中危 | 安全套件假绿:`26/26` 全是 grep 静态检查,无运行时验证 | ✅ 已修 |
| R4 | 🟡 低危 | TOCTOU 文档表述过誉(称「消除」,实为窗口变窄) | ✅ 已修正表述 |
| R5 | 🟡 低危 | 残留风险未变 | 📝 已记录为已知限制 |

### R1 — CSRF 防护把 smoke-test 打挂

`smoke-test.sh` 的 POST 不带 `Origin` 头,撞上新增的 CSRF 防护返回 403,CI 必红。
修法:为 `/stop` 与 `/wake` 补 `-H "Origin: http://127.0.0.1:$SMOKE_PORT"`。

### R2 — CSRF 端口校验过宽

旧实现只比前缀:

```c
if (strncmp(origin, "http://127.0.0.1:", 17) == 0) csrf_ok = 1;   // 不校验端口
```

于是 `Origin: http://127.0.0.1:31399` 可以驱动运行在 `:3080` 的守护(实测返回 500 而非 403,即已通过 CSRF)。
修法:按 `PORT` 拼出 `http://127.0.0.1:<PORT>` 与 `http://localhost:<PORT>` 做精确比较。

### R3 — 测试套件假绿(本轮最有价值的发现)

旧套件 **26/26 全部是 `grep` 静态检查**,只验证「代码里有这行」,不验证行为 ——
因此 R1/R2 两个真实缺陷在套件里全是绿灯。另有第 167 行 `grep … | grep …` 的逻辑错误(两个独立 grep 用管道串联)。

修法:新增**真运行时**用例 —— 编译临时守护、起进程、用 curl 断言
「无 Origin → 403 / 错误端口 → 403 / 正确 Origin → 200」。套件自 26 项增至 29 项。

> 这条奠定了此后所有审计的基调:**静态 grep 不算验证**。

### R4 — TOCTOU 表述过誉

CHANGELOG 称端口竞态「Eliminated」,实际子进程在 `close(reserve_fd)` 与 dsh `bind()` 之间
仍有约 5 行代码的窗口。改为「Significantly reduced … Narrow window remains」。
(报告初稿引用的 `SECURITY_AUDIT.md` 从未入库,修正并入 `CHANGELOG.md`。)

### R5 — 残留风险(已知限制,非本项目可修)

1. `curl | bash` 从 main 分支执行 —— 缓解手段是 `DSH_RT_RELEASE_TAG` 固定版本;
2. 守护仅 ad-hoc 签名,无 Developer ID,无法在 Gatekeeper 严格模式运行;
3. 透传路径依赖 localhost 隔离,dsh 自身 API 无额外鉴权。

---

## 二、对抗审计(第 2 轮)—— 依赖完整性与供应链

**状态:** 15 项。P0 两项与 P1 的 M3 已修;其余见下方各条。

| ID | 严重性 | 问题 | 记录时状态 |
|---|---|---|---|
| S1 | 🔴 严重 | `cleanup-deps.sh` 过于激进,删掉运行时必需的代码目录 | ✅ 已修 |
| S2 | 🔴 严重 | `install.sh` 管道执行风险未缓解 | ✅ 已文档化缓解 |
| M1 | 🟠 中危 | 守护日志不限容量(磁盘耗尽风险) | 见下 |
| M2 | 🟠 中危 | `spawn_dsh` 无超时保护(僵尸进程) | 见下 |
| M3 | 🟠 中危 | CSRF `Referer` 回退可被绕过 | ✅ 已修 |
| M4 | 🟡 低危 | `codesign` ad-hoc 签名无实际安全价值 | 见下 |
| L1 | 🟡 低危 | `PORT` 解析无错误处理 | 见下 |
| L2 | 🟡 低危 | HTTP 探测缓冲区可能溢出 | 见下 |
| L3 | 🟡 低危 | 临时目录泄漏 | 见下 |
| L4 | 🟡 低危 | 守护主循环无心跳日志 | 见下 |
| L5 | 🟡 低危 | `relay()` 无连接超时 | ✅ 后经复核确认生效 |
| R1 | 📋 建议 | 二进制内加版本信息 | 见下 |
| R2 | 📋 建议 | 提供卸载脚本 | ✅ 已有卸载节 |
| R3 | 📋 建议 | 结构化日志 | 见下 |

### S1 — 清理脚本删掉了运行时必需的 `doc/` 目录(最有教育意义的一条)

`cleanup-deps.sh` 把 `node_modules` 下的 `doc` 目录当作文档盲删,而 `yaml` 包的
`doc/directives.js` 是**运行时必需代码**。后果是 dsh 直接起不来:

```
dsh: fatal load failure: Error: Cannot find module '../doc/directives.js'
Require stack:
- /tmp/.../node_modules/yaml/dist/compose/composer.js
```

清理后体积确实减少 94MB(32.6%),但把运行时删坏了。修法:从盲删名单移除 `doc`/`docs`,
改为**白名单**(只删经实测确认安全的包)。

> 教训:**「看起来像文档」不等于「是文档」**;按目录名删除依赖必须逐个验证。

### S2 — 管道执行风险

`curl -fsSL …/install.sh | bash` 从 main 分支取脚本,攻击者拿下 GitHub 账号即可影响所有新装用户;
管道执行还绕过浏览器下载扫描与 Gatekeeper。修法:README 增加安全警告与**两步安装**(先下载、给 review 机会),
长期方案为 Developer ID 签名。

### M3 — CSRF `Referer` 回退

`Origin` 缺失时回退校验 `Referer` 会引入绕过面。修法:移除回退,**强制要求 `Origin` 头**,
并同步更新安全套件。

---

## 三、对抗审计(第 3 轮)—— 纵深防御

**状态:** 4 项全部已修。本轮先复核上轮 R1–R3,再列新发现。

### 上轮问题复核

| 问题 | 结论 | 证据 |
|---|---|---|
| R1 smoke-test 被 CSRF 弄挂 | ✓ 已修 | `/stop` 与并发双 `/wake` 均带 `Origin` |
| R2 端口通配绕过 | ✓ 已修 | 无 Origin→403;`Origin` 为其他端口→403;`https://evil.com`→403 |
| R3 grep 假绿套件 | ✓ 部分修复 | 套件扩到 318 行,新增真运行时 CSRF 用例,本地 `29/29` 通过 |

### 新 1 — CSRF 前缀匹配残留(低危)

`strncmp(origin, expected, strlen(expected))` 理论上可被 `http://127.0.0.1:31408.evil.com` 绕过
(实际浏览器 URL 解析器会拒绝该格式,故定为低危)。修法:比对后追加**后缀校验** ——
下一字符必须是 `\0` / `/` / `?` / `#` 之一。

### 新 2 — 透传代理缺 CSRF 门禁(中危)

`/wake`、`/stop` 有 Origin 校验,但 dsh 就绪后的**透传路径**没有:任意跨域页面发起的
POST/PUT/DELETE/PATCH 会被转发给 dsh 执行。响应虽被同源策略挡住,但**副作用已经发生**。

修法:透传前对全部状态改变方法强制 Origin 校验;GET/HEAD/OPTIONS 保持透明代理。

### 新 3 — `cleanup-deps` 缺验证探针(中危)

清理脚本会删除 `@img/sharp-wasm32` 等回退产物,若某架构原生绑定缺失,dsh 图像功能会在**运行时**才失败。
修法:install.sh 清理后加依赖探针,失败则回退重装(fail-closed)。

> 📝 **勘误(2026-09-11):** 探针此后已演进 —— 不再是顶层 `require('@img/sharp')`
> (pnpm 隔离布局下 sharp/node-pty 是传递依赖,从 `APP_DIR` 顶层解析必失败),
> 改为 `cd "$APP_DIR/node_modules/@deepseek-ai/dsh"` 后同时探测 `sharp` 与 `node-pty`。

### 新 4 — CI 不跑安全套件(中危)

CI 只跑 smoke-test,不跑 `tests/security-verification.sh`,于是 R2 类回归无法被自动拦截。
修法:工作流增加安全套件步骤。

> 📝 **勘误(2026-09-11):** 工作流文件此后由 `ci.yml` 更名/整合为
> `.github/workflows/ci-enhanced.yml`。**安全测试数量也从 29 项增至 33 项。**

---

## 四、P0–P3 修复批次

针对 dsh 上游 RC 版本不稳定与系统可靠性问题,按优先级系统性实施 9 项改进:
P0 阻塞 2 项、P1 高价值 2 项、P2 体验 2 项、P3 可观测性 1 项。

| 编号 | 内容 |
|---|---|
| P0-1 | dsh 版本固定(阻塞合并) |
| P0-2 | token 解析鲁棒性(防御未来 dsh 输出格式变化) |
| P1-4 | 探测超时梯度调优(快速启动提速 50%) |
| P1-5 | dsh 崩溃自愈(避免守护僵死) |
| P2-6 | pnpm store 清理提示(释放磁盘空间) |
| P2-8 | 冒烟覆盖 token 场景(未来变更早发现) |
| P3-9 | `release.yml` 加 `pnpm-lock.yaml` diff 检查(依赖树变化可见) |

### 后续演进(2026-09-11 追加的更新说明,以本节为准)

- **P0-1 已回退:** 固定到 `0.1.1-rc.2` 的策略由 `47f9ae3` 撤销,当前跟随
  `@deepseek-ai/dsh@latest`(`DSH_VERSION` 仍可覆盖为指定版本)。
- **P0-2 已根本变化:** dsh 0.1.5+ 引入 token 鉴权后,守护**实际实现**了 token 解析
  (`scan_token()`:增量扫描 dsh 日志捕获 launch token,经 `/health` 交给引导页完成握手;
  守护重启 adopt 运行中的 dsh 时补扫)。原报告「未实际添加 token 解析代码」的表述已过时。
- **P1-5 已演进:** `sleep(60)` 阻塞冷却改为非阻塞 `cooldown_until` 时间戳 ——
  冷却期内直接拒绝拉起并立即返回,主循环照常服务引导页,不再卡住全部请求 60s。
- **P1-4 已抽取:** 梯度探测逻辑移入 `tests/lib/daemon-helpers.sh` 的 `daemon_wait_health()`
  (前 10 次 0.5s → 50 次 1s → 其余 2s),单测与冒烟共用。
- **P2-6 已移除:** `update-dsh.sh` 不再打印 pnpm store 提示;README 卸载节仍保留可选的
  `pnpm store prune`。

---

## 五、全方位深度审计(2026-09-11)

**范围:** `src/daemon.c` 1200 行 + 6 个脚本 + 6 个测试文件 + 2 个 workflow + 2 个 plist + 文档。
**方法论:** 静态阅读 + **运行时实证**(凡结论均给出可复现命令与实测输出)。
**与既有审计的关系:** 只列**新增或未被修复**的问题;已记录在案的「已知限制」仅标注、不重复计入。

### 总体评价(当时)

| 维度 | 评级 | 一句话结论 |
|---|---|---|
| 安全设计 | 良好 | CSRF/Origin/Host/cookie 精确匹配等纵深防御扎实;风险主要在**发布链路**而非守护本体 |
| 架构设计 | 良好 | 零常驻 socket activation 是亮点;但「产物从未被端到端验证」是结构性盲区 |
| 错误处理 | 中等 | 仍有 3 处潜伏缺陷(token 截断、截断请求当完整请求、EAGAIN 忙等) |
| 性能 | 良好 | 约 1.3MB RSS;无热点问题 |
| 依赖与兼容 | 中等 | Actions 已 SHA pin(良好实践),但 brew/pnpm/dsh 全部浮动;依赖 `python3` 而新 macOS 已不自带 |
| 代码质量 | 中等 | 注释罕见地解释「为什么」而非「是什么」;但文档冗余、单文件过大、个别兜底是死代码 |

> 最关键的发现是一条 P0:README 首推的 `curl … | bash` **恒失败**(两处独立原因)。
> 它能长期存活,是因为 **CI 从未真正安装过发行包** —— 这比缺陷本身更值得修。

### S1(P0)—— 发行包 SHA-256 校验恒失败

生成端(`release.yml:73-74`)在打包目录内以**相对名** `dsh-pwa.zip` 生成清单,而校验端用
`shasum -a 256 -c` 且 cwd 与文件名不匹配,于是**校验 100% 失败**,`curl | bash` 完全不可用。

复刻验证(cwd=打包目录,仅 `pkg.zip` + `pkg.zip.sha256`):

```
旧实现 shasum -a 256 -c pkg.zip.sha256
  shasum: dsh-pwa.zip: No such file or directory
  dsh-pwa.zip: FAILED open or read
  rc=1
新实现(裸比对哈希)
  期望=02bdc580…5726  实际=02bdc580…5726   rc=0 ✅
```

**修复:** `e55263d` —— 改为**直接比对哈希**,不再依赖文件名。新实现对清单格式不敏感
(`<hash>  name` / 裸 `<hash>` / `<hash> *name` 三种均可),篡改一个字节即触发 fail-closed。

> **重要教训(来自本条的复核):** 本报告在 `f4caaf7` 入库时,S1 其实已在**近 5 小时前**的
> `e55263d` 修好,但入库时未复核,导致一条**已失效的 P0 被继续当待办传播**。
> **审计报告是快照,不是现状;当待办用之前必须逐条验证**
> (`git log -S '<片段>' -- <文件>` 可直接定位修复提交)。

### A1 —— 发布产物从未被端到端验证(「本次 P0 能存活的根因」)

`smoke-test.sh` 默认指向**仓库源码树**里的 `install.sh`,而仓库恒有 `src/daemon.c`,
因此「从发行包安装」这条分支**永远不可达** —— S1 这类缺陷再怎么改校验逻辑也没人会发现。
**修复:** `884891f` —— `release.yml` 打包后解压**真实产物**跑完整冒烟。

### A2 —— 零常驻可被「阻塞写」破坏

上游 socket 未设超时 → `write_all()` 在 `write(2)` 上永久阻塞 → 连接子进程不退出 →
`waitpid` 不返回 → `active` 永不归零 → 空闲自停永不触发,**零常驻承诺失效**。
**修复:** `421d605` —— 上游/客户端 socket 加 `SO_SNDTIMEO`/`SO_RCVTIMEO`,
`write_all` 的 `EAGAIN` 分支改为 `poll(POLLOUT, WRITE_WAIT_MS)`(同批修掉 E3 的忙等)。

### A3 —— 透传路径的 CSRF 校验可被流水线请求绕过

同一 TCP 缓冲区内的**流水线请求**只有第一个会进入 Origin 校验。
**记录时状态:未修**(列为 P3:或封堵、或明确写入威胁模型)。

### A4 —— 自动更新缺「更新后健康校验 / 启动失败回滚」

更新成功仅代表 pnpm 返回 0,不代表 dsh 能起来;一旦新版本起不来,用户次日发现「服务消失」。
**修复:** `f0b2e74` —— 更新后做真实启动探测,三态退出码(0 就绪保留 / 1 不就绪回滚 / 2 无法探测保留)。

### A5 —— 更新链路无完整性固定(供应链)

**修复:** `b9dde78` —— 首次安装路径启用 `--frozen-lockfile`,缺锁时显式告警。

### 守护本体(P2/P3)

| ID | 问题 | 处置 |
|---|---|---|
| E1 | token 超 63 字符被**静默截断且永久缓存**(潜伏) | ✅ `b9dde78`(缓冲 64→256 + 截断即拒绝缓存) |
| E2 | 截断的请求头被当作完整请求处理 | ✅ `b9dde78`(不完整即 400) |
| E3 | `write_all` 对 `EAGAIN` **忙等**(100% CPU) | ✅ `421d605` |
| E4 | `build_boot` 的 `snprintf` 静默截断 | ✅ `b9dde78`(缓冲 4096→8192 + 截断告警) |
| E5 | `pick_port_fd` 的「端口预留」实际不存在(注释与实现不符) | 记录时未修 |
| E6 | 其余低危项(含连接数上限 E6d) | 记录时未修 |

> E5 复核备注(2026-09-12):函数头注释称「返回保持 bind 的 socket fd 以防窗口期被占」,
> 但父子进程都在 dsh `bind()` **之前**就 `close(reserve_fd)`,故预留不构成真实互斥 ——
> 窗口只是比原版窄得多。行内注释已如实说明释放时机,函数头表述仍偏乐观。

### 脚本 / CI / 文档(P2/P3)

| ID | 问题 | 处置 |
|---|---|---|
| C1 | `cleanup-deps.sh` 的兜底是**死代码**(`set -e` 下 `X=$(false \| awk …)` 直接终止) | ✅ `11b4cdb`(并修掉百分比恒为空的 bash 3.2 引号问题) |
| C2 | `cleanup-deps.sh` 删除面远大于探针覆盖 | 记录时未修 |
| C3 | `install.sh:250` 布尔优先级无括号 | 记录时未修 |
| C4 | 新增的 curl 门禁不校验 `--noproxy`,**CI 自身违反约定** | ✅ `a81d15b` |
| C5 | 权限声明与实现不符(README 称 0600,实测 0644) | ✅ 已收紧(umask 077 + 目录 0700 + 日志文件 0600) |
| C6 | 依赖与兼容性(见 D 组) | 部分处置 |

| ID | 问题 | 处置 |
|---|---|---|
| D2 | 依赖 `python3`,而 macOS 12.3+ 不再自带;缺失时**静默降级** | 记录时未修 |
| D3 | 硬编码回退 `LTS_VER="24.19.0"`,会随时间陈旧且无告警 | 记录时未修 |
| D4 | updater plist 缺 `NODE_OPTIONS=--use-system-ca` → 企业 TLS 代理下更新器可能**静默永不更新** | ✅ `b9dde78`(update-dsh.sh 加能力探测后按需追加) |
| D5 | `workflow_dispatch` 触发时 `github.ref_name` 是**分支名**,会建出以分支名命名的 release | 记录时未修 |
| D6 | 无 `package.json`;「依赖」实为 Actions / brew / 外部二进制三层,Actions 已 SHA pin(良好实践) | — |

### 已核实「无问题」的方面(避免后续审计误报)

- **Host 校验**精确匹配 `127.0.0.1:PORT`/`localhost:PORT`,阻断 DNS rebinding;plist 只 bind IPv4 回环。
- **Cookie 校验**用 `p[nl] == '='` 精确匹配,`dsh-auth-evil` 前缀绕过已封堵。
- **Origin 校验**后缀仅允许 `/ ? #`,`127.0.0.1:3080.evil.com` 前缀绕过已封堵。
- **`token_json_safe`** 对 token 字符集二次校验,防畸形 JSON(纵深防御)。
- **`set -e` + `A && B`**:实测 `[ -x /nonexistent ] && …` 不会因 `set -e` 退出,非缺陷。
- **`relay` 无数据总时限**(1800s):前轮 L5 已修,确认生效。
- **`install.sh` 端口占用检测**:bootout 后复查一次,避免误报。
- **CI 的 `clang --analyze` 门禁**:已补 `grep -Eq 'warning:|error:'`,不是假门禁。
- **`--max-time` 全覆盖**:所有 curl 均已带超时(由 `install-validation.bats` 门禁保证)。

### 审计方法(可复现性)

| 结论 | 验证手段 |
|---|---|
| S1 恒失败 | 在 `/tmp` 忠实复刻 install.sh 的目录状态,执行 `shasum -a 256 -c` → rc=1 |
| A1 分支不可达 | 读 `smoke-test.sh` 分支条件,确认仓库恒有 `src/daemon.c` |
| C1 死兜底 | `bash -c 'set -euo pipefail; X=$(false \| awk …)'` → rc=1;对照 `set -eu` → rc=0 |
| E4 缓冲余量 | `#define main …; #include "src/daemon.c"` 编译桩,实测模板与引导页长度 |
| E1 token 长度 | 本机日志实测 token 长 **43** |
| C5 权限 | `stat -f '%Sp %N'` 实测 0644,与 README 声明的 0600 不符 |
| C4 noproxy 缺口 | 全仓库检索 `--noproxy` 命中分布,确认 workflows 为 0 命中 |
| 发布状态 | `gh api repos/3kaiu/dsh-pwa/releases` → **0**;`releases/latest/download/dsh-pwa.zip` → **404** |

### 一之二、审计后修正(2026-09-12 复核)

> 追加原因:本报告入库时未复核,把一条已失效的 P0 继续当待办传播(见 S1 的教训)。

| 条目 | 正文结论 | 实际状态 | 证据 |
|---|---|---|---|
| S1(P0,SHA-256 恒失败) | 未修 | ✅ 已修 | `e55263d` |
| A1(产物未端到端验证) | 未修 | ✅ 已修 | `884891f` |
| C4(curl 门禁不校验 `--noproxy`) | 未修 | ✅ 已修 | `a81d15b` |
| C1(百分比恒空) | — | ✅ 已修 | `11b4cdb` |
| 第 1 批第 3 项(0 个 release) | 需打 tag | ✅ 已解决 | `v0.3.3` |

### S1 之后的真正阻断:`releases/latest` 是 404

修好校验后 `curl | bash` **仍然装不上**,失败点前移到下载步:

```
gh api repos/3kaiu/dsh-pwa/releases --jq length   →  0
远端 tag: 16 个(v0.3.0 / v0.3.1 / v0.3.2 …)
releases/latest/download/dsh-pwa.zip              → 404
releases/download/v0.3.1/dsh-pwa.zip              → 404
releases/tag/v0.3.1                               → 200  ← 只是 tag 页面,非 release
api.github.com/repos/3kaiu/dsh-pwa/releases/tags/v0.3.1 → 404
```

**release 曾经存在过,后来消失了。** 证据链:Release workflow 运行 `32546682958`
(`event=push`,tag `v0.3.1`)的「发布到 GitHub Releases」步骤结论是 **success**,
日志也明确打印了 release URL,而事后 release 列表为 **0**。删除者与时间无法判定
(仓库 events API 只覆盖最近 100 条事件,个人仓库无审计日志)。

**修复动作与原因无关:** 重新产出一次 release 即可打通 —— 已由附注 tag `v0.3.3` 解决,
发布后实测 `releases/latest/download/dsh-pwa.zip` 返回 **200(149133B)**,哈希与清单一致。

**新增门禁:** `b0d6aff` —— `release.yml` 在发布后新增「校验发布资产真的可下载」步骤,
带 5 次重试下载两个资产并**三方比对**(清单哈希 = 下载物哈希 = 本地构建物哈希),不一致即让作业变红。
放在 release 作业内(而非定时任务)的好处:只验「自己刚发的东西」,不会天天红。
仍缺的一环:**资产事后被删除**只有定时巡检才能发现(暂未加,避免常态噪声)。

> 教训:**`gh release create` 成功 ≠ 资产可下载**;判断 release 是否存在要同时看
> `gh api .../releases` 与 `api .../releases/tags/<tag>`,**只看网页 200 会误判**
> (`releases/tag/...` 是 tag 页面)。

---

## 六、冒烟结果复核(2026-09-12)

**复核对象:** CI run `34631617230`(`main` @ `8c34bbe`),job 7m3s。
**结论:** `SMOKE OK` 当时为真(已执行断言全过),但**掩盖了一个 100% 必失败的缺陷**。

### 缺陷 1(高)—— 暖机 100% 必失败(构造性死结)

现象:4/4 次全部「暖机超时(dsh 未在 60s 内就绪)」,job 白涨约 4m40s,而 CI 全绿。

根因:`install.sh` **整个运行期都持 `$RT_HOME/.install.lock`**,而守护的 `update_locked()`
正是读这个文件 —— 持锁者 pid 存活即判「更新进行中」并**拒绝 spawn dsh**:

```
daemon: 更新进行中(install.lock 持有存活 pid),本轮不拉起 dsh
... (共 26 行,全部是这一条)
```

即 dsh **一次都没被 fork**。同一把锁既做「安装互斥」,又被守护读作「node_modules 处于半更新状态」,
于是「在 install.sh 内部启动守护去拉起 dsh」在构造上必然失败 —— 与机器快慢、网络、环境均无关。

**修复:** `6f7eeb3` —— 暖机实例改用**独立的无锁临时 `RT_HOME`**(`mktemp -d`),
复制 `daemon` + `run.json` 进去;`RT_STATE` 仍指向真实目录(预热目标正是
`$RT_STATE/node-cache`,守护按 RT_STATE 计算 `NODE_COMPILE_CACHE`),
并置 `DSH_RT_NO_AUTO_UPDATE=1`。

> 该修复成立的前提:守护从 RT_HOME 只读三处 —— `run.json`、`.install.lock`、`scripts/update-dsh.sh`,
> 已逐一核对。

**关键证据:** 修复前那次失败留下的日志(由本次新增的「失败保留日志」才可见)
`$RT_STATE/logs/warmup.log` 里 26 行全是上面那条 —— 这也解释了为何此前
「清缓存后暖机 3s 就绪、生成 1307 个缓存文件」的说法无法复现:
那些缓存来自日常 PWA 使用,不是暖机产物。

### 缺陷 2(低-中)—— `cleanup-deps.sh:66` 百分比恒为空

CI 打印 `节省空间: 62MB (%)   节省空间: 62MB (%)`。根因是 **bash 3.2** 下
「双引号串内嵌 `$( )`、`$( )` 内再用转义双引号」解析错乱:内层 `\"` 破坏外层引号,
`echo` 收到 **2 个参数**(整行打印两遍),`awk` 被调用 **2 次**且程序被截断,`$( )` 结果为空。
实测 `argc=2`;fish / bash 5 不复现。命令替换的非零退出不影响 `echo` 的退出码,故 `set -e` 也拦不住;
`shellcheck -S warning` 不报。**修复:** `11b4cdb` —— 先算进变量再拼进 echo
(该形状仓库中仅此一处,`install.sh` 的单引号写法安全)。

### 其余整改

| 项 | 内容 |
|---|---|
| 可观测性 | 暖机留下互斥 marker(`warmup.ok`/`warmup.failed`/`warmup.skipped`);失败**保留日志**到 `$LOG_DIR/warmup.log`(旧实现无条件 `rm`),CI 内补 `::warning` |
| 幂等重跑 | 缓存已填充且 dsh 版本未变 → 免做(版本一变缓存即失效,故按版本判定,不能只看目录非空) |
| 暖机预算 | 新增 `DSH_RT_WARMUP_TIMEOUT_SECS`(默认 60,非法值回退);冒烟用 25s |
| 2b / 冲突后重装 | 置 `DSH_INSTALL_NO_WARMUP=1`(这两步验的是端口冲突,与暖机无关) |
| 步骤 2 文案 | 「已装同版应秒过」→「已重入应成功且不破坏既有安装」(原描述与 74s 实测不符) |
| 日志噪声 | 占位监听器 kill 前 `disown`,消除 `Terminated: 15` 作业控制通知 |
| Actions | `checkout` v4.2.2 → v7.0.1、`upload-artifact` v4.6.2 → v7.0.1(均声明 `node24`),消除 Node 20 弃用注解 |

### 验证证据

| 验证 | 结果 |
|---|---|
| 暖机块 harness(真实切片,非重写) | 新代码 **20/20 PASS**;旧代码 **6 PASS / 14 FAIL**(fail-before 成立) |
| 端到端冒烟(修复前) | `SMOKE OK`,但 `暖机:失败`,全程 4m0s |
| 端到端冒烟(修复后) | `✓ 暖机完成(编译缓存已填充:1416 个文件)`;重跑免做;`SMOKE_RC=0`,全程 **2m0s** |
| 幂等重跑耗时 | **16.7s**(修复前同一路径 49.9s;CI 上 74s) |
| `cleanup-deps.sh` | `节省空间: 9MB (90.0%)`,只打印一次,stderr 为空 |
| bats | **43/43** |
| workflow | PyYAML 通过;`check_run_blocks.mjs`:**22** 个 run block,0 语法错误 |

### 环境说明(复核时的干扰项,**不是**产品缺陷)

1. `find` 是 toybox 0.8.13 的 shim(非 macOS `/usr/bin/find`)。toybox 的 `-delete` 隐含 `-print`,
   故本地 `cleanup-deps.sh` 会打印 4365 行被删路径;CI(真 BSD find)为 0 行。**不要为此改脚本。**
2. `ps` 被拒、无可用 launchd GUI 会话 → 冒烟 3b 与 5/5 走 `[SKIP]` 并在收尾点名(行为正确)。

---

## 七、记录时仍未闭合的事项

> 以下为**审计当时**未修或未闭合的条目汇总。**不承诺现状** —— 请以代码与门禁为准。

| 来源 | 条目 | 备注 |
|---|---|---|
| 深审 A3 | 透传路径 CSRF 可被流水线请求绕过 | 或封堵、或写入威胁模型(P3) |
| 深审 E5 | `pick_port_fd` 函数头注释与实现不符 | 表述层面 |
| 深审 E6 | 其余低危项(含连接数上限 E6d) | P3 |
| 深审 C2 | `cleanup-deps.sh` 删除面大于探针覆盖 | P2 |
| 深审 C3 | `install.sh` 布尔优先级无括号 | P3 |
| 深审 D2 | 依赖 `python3`,缺失时静默降级 | P2 |
| 深审 D3 | 硬编码回退 LTS 版本,会陈旧且无告警 | P3 |
| 深审 D5 | `workflow_dispatch` 会用分支名建 release | P3 |
| 深审 §七 第 4 批 | `daemon.c` 单文件拆分(1,200 行,`main()` 约 230 行) | P3,技术债 |
| 深审 §七 第 4 批 | `docs/` 审计文档合并 | ✅ **本文即该条目的产物** |
| 对抗 R5 / 深审 | 管道执行、ad-hoc 签名、透传无鉴权 | 已知限制,非本项目可修 |
| 深审 §一之二 | release 资产**事后被删除**只能靠定时巡检发现 | 暂不加,避免常态噪声 |

---

**合并来源与取回方式:** 原文 6 份已随本次合并从工作树删除,可用
`git log --diff-filter=D --name-only -- docs/` 找到删除提交后
`git show <该提交>^:docs/<原名>` 取回。
**最后更新:** 2026-09-12(合并时仅归并去重,未改写历史结论)。
