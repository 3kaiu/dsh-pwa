# dsh-pwa 全方位深度审计（2026-09-12）

> **这是快照，不是现状。** 本文记录 2026-09-12 这一轮审计**当时**的发现与证据。
> 按 `AUDIT_HISTORY.md` 的既定体例：已修项请补修复提交号；未修项只记「记录时状态」，不承诺现状。
> 与既有 6 轮审计的关系：**只列新增或仍未闭合的问题**，已修项不重复计入。
>
> **不纳入**活文档防漂移门禁（同 `AUDIT_HISTORY.md`，理由：审计报告含必要的快照数字）。

## 审计对象与环境

| 项 | 值 |
|---|---|
| 工作树 HEAD | `17d5330`（`docs: CHANGELOG Homebrew 条目标注为…`） |
| `git describe` | `v0.3.3-31-g17d5330` |
| **工作树状态** | **不干净** —— `src/daemon.c` 有 4 行未提交改动（见 F11）。本文所有结论针对**工作树** |
| 被审面 | `src/daemon.c` 1512 行 · 9 个 `scripts/*.sh` · 2 个 workflow · 2 个 plist · 7 个 `.bats` · 4 个 `tests/*.sh` · Homebrew formula · 6 份文档 |
| 方法论 | 静态阅读 + **运行时实证**（每条结论给出可复现命令与实测输出）；代码引用一律用**符号锚点**，不用行号 |

### 本轮已跑过的门禁（全绿，作为基线）

```
clang -O2 -Wall -Wextra -Werror -o /tmp/dsh_audit src/daemon.c   → 零告警
shellcheck -S warning scripts/*.sh tests/*.sh tests/lib/*.sh      → 零告警
bash -n（全部 .sh）                                               → 通过
bats -c tests/unit/*.bats                                        → 78
bats tests/unit/*.bats（逐文件跑）                                → 78/78 ok，not ok = 0
bash tests/security-verification.sh                              → 33/33 通过
```

> 结论：**既有门禁本身没有红**。本轮的发现全部落在门禁**看不见的地方** —— 这正是最值得记的部分。

---

## 一、优先级总表

| 优先级 | ID | 一句话 | 维度 |
|---|---|---|---|
| **P0** | F1 | 守护 plist 无条件注入 `NODE_OPTIONS=--use-system-ca`，在 Node 22.0–22.14 上让 dsh **100% 起不来**，且无任何门禁覆盖 | 兼容性 / 可用性 |
| **P1** | F4 | `launchd/com.dshpwa.daemon.plist` 是**零门禁**产物（F1 的根因） | 测试可信度 |
| **P1** | F2 | 安全套件对 SHA-256 的断言命中的是**注释**，不是实现 | 测试可信度 |
| **P1** | F3 | `python3` 缺失时 `realpath` 静默失败，会把**会话级临时** fnm 路径写进 `run.json` | 依赖 / 边界 |
| **P1** | F5 | 守护无 `SIGTERM` 处理，`bootout`/`kickstart -k` 会留下孤儿 dsh | 健壮性 |
| **P2** | F7 | 安全套件有 4 处断言**永不可能失败**（`info` 而非 `fail`） | 测试可信度 |
| **P2** | F8 | 断言与 CHANGELOG 里仍保留**已撤回的结论**（「TOCTOU 已消除」） | 规范性 |
| **P2** | F6 | 清理脚本按**目录名**删 `test`/`tests`/`examples` 与 `*.md`（S1 同族） | 健壮性 |
| **P2** | F9 | 多个门禁只断言「没红」，不断言「跑了多少」 | 测试可信度 |
| **P2** | F10 | `sed` 行范围抽函数体做静态断言，存在静默失配面 | 测试可信度 |
| **P3** | F11 | 工作树有半截重构：3 个 `Content-Type` 宏，2 个从未使用 | 代码质量 |
| **P3** | F13 | release 构建缺 `-Werror`，比 CI 门禁松 | 规范性 |
| **P3** | F15 | plist 注入路径做的是 2 字符黑名单，非 XML 安全白名单 | 安全 / 边界 |
| **P3** | F16 | `cleanup-deps.sh` 的空值兜底是**死代码**（C1 同族） | 代码质量 |
| **P3** | F12 | 活文档漂移（数字类门禁覆盖不到的部分） | 规范性 |
| **P3** | F14 | 每个透传请求多两次系统调用组（可缓存） | 性能 |

---

## 二、P0：F1 —— 守护 plist 的 `NODE_OPTIONS` 会让一部分用户的 dsh 永远起不来

### 位置

`launchd/com.dshpwa.daemon.plist` 的 `EnvironmentVariables`：

```xml
<key>NODE_OPTIONS</key><string>--use-system-ca</string>
```

**这一行是无条件的**（模板里没有占位符，`install.sh` 的 `sed` 原样拷贝）。

### 证据链（四段，全部可复现）

**(1) 该选项有版本下限。** Node 官方文档「`--use-system-ca` 版本历史」写明
`新增于: v23.8.0, v22.15.0`（`v23.9.0` 才支持非 Windows/非 macOS 平台）。
即 **Node 22.0.0 – 22.14.x 上这个选项不存在**。

**(2) `install.sh` 会接受这些版本。** `MIN_NODE=22`，判定是 `[ "$M" -ge "$MIN_NODE" ]`，
只比较 **major**，于是 22.0.0 与 22.14.9 都会被复用为运行时并写进 `run.json`。

**(3) 非法选项会让 node 直接拒绝启动。** 本机实测（node v22.22.2）：

```
$ NODE_OPTIONS=--totally-bogus-flag node -e 'console.log("ran ok")'
node: --totally-bogus-flag is not allowed in NODE_OPTIONS
rc=9                      ← 一行代码都没执行
$ NODE_OPTIONS=--use-system-ca node -e 'console.log("ran ok")'
ran ok  rc=0              ← 22.22.2 上合法，故问题只出现在旧 minor 上
```

**(4) 守护确实把 `NODE_OPTIONS` 原样传给了 dsh。** 用一个「假 node」记录自己看到的环境，
放进 `run.json`，让守护去 spawn：

```
$ DSH_RT_HOME=… NODE_OPTIONS=--use-system-ca ./daemon     # 模拟 plist 注入的环境
$ curl -X POST -H 'Origin: http://127.0.0.1:39999' …/wake
=== 被 spawn 的 dsh 实际看到的环境 ===
argv=/tmp/nodetest/fakedsh.js web --no-open --host 127.0.0.1 --port 52743
NODE_OPTIONS=--use-system-ca          ← 继承自守护（即来自 plist）
NODE_COMPILE_CACHE=/tmp/nodetest/state/node-cache
=== 守护日志 ===
daemon: 唤醒 dsh(pid 23634, 端口 52743)
daemon: dsh 已退出(pid 23634,退出码 9),清理状态    ← 用户侧表现：引导页永远转圈
```

### 为什么这是「同一个仓库里，一处防住了、另一处没防」

`scripts/update-dsh.sh` 的 `check_wrapper_version` 上方有一段注释，**逐字描述了这个危害**，
并配了能力探测：

```sh
#   NODE_OPTIONS 中的非法选项会让 node 直接拒绝启动(实测 rc≠0、一行代码都不执行),
#   而该选项是 Node 22.15.0 才引入的,install.sh 只要求 major >= 22(MIN_NODE=22)。
if "$NODE_BIN" --use-system-ca -e '' >/dev/null 2>&1; then
  NODE_OPTIONS="--use-system-ca${NODE_OPTIONS:+ $NODE_OPTIONS}"
```

**同一个危害，同一份代码库：`update-dsh.sh` 探测后按需加，`daemon.plist` 无条件加。**
D4 的修复只覆盖了 updater 侧（且是脚本侧），漏掉了产品主路径。

### 为什么至今没被发现

- **CI 不会遇到**：CI 跑 `macos-latest`，其 node 是新的；`smoke-test.sh` 与 `install.sh` 的暖机
  **都在前台模式启动守护、不带 `NODE_OPTIONS`** —— 只有 launchd 渲染出的 plist 带它。
- **`dsh-probe.sh` 不会遇到**：它同样在前台起守护。
- **没有门禁**：`grep -rn com.dshpwa.daemon.plist tests/` 只有 `auto-update-checklist.md` 里一句
  `rm -f`；`plutil -lint` 在本仓库只作用于 **updater** plist（`auto-update-verify.sh`）
  与冒烟自建的 SA plist（`smoke-test.sh`）。

### 影响

受影响用户点 PWA → 守护拉起 dsh → dsh 立即 exit 9 → 守护按「连续 3 次快速崩溃」进入 60s 冷却
→ 循环重试。用户侧是**引导页永远停在「正在启动 DeepSeek Harness…」**，10 分钟后才显示超时提示；
日志里只有 `退出码 9`，不指向 `NODE_OPTIONS`。

### 改进建议（按代价从低到高）

1. **最小改法（推荐）**：`install.sh` 渲染 plist 时按目标 node 的能力决定是否写这个键 ——
   与 `update-dsh.sh` 用同一条探测（`"$NODE_BIN" --use-system-ca -e ''`），不支持的版本就
   把该键整段删掉（而不是写个空值）。
2. **纵深防御**：`spawn_dsh()` 在 `execl` 前做一次廉价能力探测，不支持则从子进程环境里
   `unsetenv("NODE_OPTIONS")` 里摘掉该选项。这样即使 plist 被手工改坏，dsh 仍能起来。
3. **顺带修 `MIN_NODE`**：要么把 `MIN_NODE` 提到 22.15，要么把「能力探测」作为唯一判据
   —— 但注意 `NODE_COMPILE_CACHE` 需要 22.1+，三个能力门槛目前散落在三处。

> **这条同时是 F4 的动机**：只要 daemon plist 仍无门禁，同类缺陷还会再来一次。

---

## 三、P1：测试与门禁自身的可信度

> 本轮最有价值的发现集中在这一类。既有 6 轮审计的基调是「静态 grep 不算验证」，
> 而下面几条说明：**断言写得像验证，但验证的不是它声称的东西。**

### F4 —— `launchd/com.dshpwa.daemon.plist` 零门禁（P1）

**问题**：这个 plist 是「产品能不能用」的单点（`ProgramArguments` / `Sockets` /
`EnvironmentVariables` 任一写错，守护就不会被激活，且**没有任何用户可见的错误**），
却没有任何用例渲染、lint 或断言过它。

**现状盘点**：

| 对象 | 有无门禁 |
|---|---|
| `com.dshpwa.updater.plist` | ✅ `auto-update-verify.sh` 渲染 + `plutil -lint` + 断言无残留占位符 |
| 冒烟自建的 SA plist | ✅ `smoke-test.sh` 用 `PlistBuddy` 改后 `plutil -lint` |
| **`com.dshpwa.daemon.plist`** | ❌ **无** |

**建议**：新增一个用例（可放 `tests/unit/`），做四件事：

1. `install.sh` 同款 `sed` 渲染到临时文件；
2. `plutil -lint` 通过；
3. 断言无残留 `__*__` 占位符（照抄 updater 的写法）；
4. 断言关键键存在且值合法：`Label` / `ProgramArguments[0]` 指向已安装 daemon /
   `Sockets.Listeners.SockServiceName` == 端口 / **`EnvironmentVariables` 里每个 node 选项
   都被目标 node 接受**（F1 的回归门就挂在这里）。

> 第 4 项的第 4 小点即「从被测对象本身推导需求」的做法（与 CSP 覆盖门禁同一思路），
> 而不是把选项名抄第二遍。

### F2 —— 安全套件的 SHA-256 断言命中的是注释（P1）

**位置**：`tests/security-verification.sh` 第 1.3 项。

```sh
if grep -q "shasum -a 256 -c pkg.zip.sha256" scripts/install.sh; then
  ok "install.sh 验证 SHA256 校验和"
```

**证据**：该字符串在 `install.sh` 中**只出现一次，且是注释** —— S1 修复留下的说明：

```
$ grep -n 'shasum -a 256 -c pkg.zip.sha256' scripts/install.sh
46:  # 直接比对哈希,而不是 `shasum -a 256 -c pkg.zip.sha256`:后者按清单里记录的**文件名**
```

真实实现是裸比对，与这个字符串无关：

```sh
EXPECTED_SHA="$(awk 'NF {print $1; exit}' "$PKG_TMP/pkg.zip.sha256" …)"
ACTUAL_SHA="$(shasum -a 256 "$PKG_TMP/pkg.zip" …)"
if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then … exit 1; fi
```

**两个方向的危害**：

- **假绿**：把校验整段删掉、只留注释，该断言照样 `ok` —— 而套件仍打印「33/33 全部通过」，
  读者会读成「SHA 校验已被验证」。
- **误报**：有人清理掉这句解释性注释（它解释的是**不该做什么**），门禁反而变红。

这正是 TRAPS §一.15「探针文本污染被测面」的**镜像**：那次是探针被自己写的字面量满足，
这次是**门禁被解释性注释满足**。两处都在提醒同一件事：
**断言必须锚定行为，不能锚定文本。**

**建议**：改为断言真实实现的存在性与失败路径 ——
`grep -q 'EXPECTED_SHA' scripts/install.sh && grep -q 'ACTUAL_SHA' scripts/install.sh`
且校验分支内含 `exit 1`；并配反空转（把实现换成旧写法时断言必须变红）。

### F7 —— 4 处断言永不可能失败（P2）

**位置**：`tests/security-verification.sh` 的第 5.3、6.2、6.3、7.3 项，
`else` 分支走的是 `info` 而不是 `fail`：

```sh
if sed -n '/^static int http_probe/,/^}/p' src/daemon.c | grep -q "char b\[512\]"; then
  ok "HTTP 探测使用足够大的缓冲区(512 字节)"
else
  info "HTTP 探测缓冲区可能需要扩大"      # ← 不计数、不影响退出码
fi
```

这四条（探测缓冲、HTML 转义、JSON 转义、二进制体积）**在任何情况下都不会让套件变红**。

**依据**：项目自身教训 —— TRAPS §一.5「失败只 warn 不阻断 ＝ 空转门禁」，
并已因此给暖机补了 marker 与断言。同一原则没有回灌到安全套件。

**建议**：二选一 ——（a）改成 `fail`；（b）若确属「仅信息」，就**从断言列表里删掉**并在
输出里明确标注为「信息项，不构成门禁」。现在的写法最坏：它既占着「33 项测试」的名额，
又永远为绿。

### F8 —— 断言与 CHANGELOG 仍保留已撤回的结论（P2）

**位置 A**：`tests/security-verification.sh` 第 4.3 项：

```sh
ok "daemon.c 使用端口预留机制(消除 TOCTOU)"
```

而 E5 已把 `pick_port_fd` 的**函数头注释按实现改写**为「只缩小窗口，非互斥」
（`5503968`）。测试文案还停在旧结论上，且 `grep -q "pick_port_fd"` 这种「函数名存在」
本身也不构成机制验证。

**位置 B**：`CHANGELOG.md` 的「Attack Surface Reduction」表写
`Port allocation: Medium → Low (TOCTOU eliminated)`，
而同一份 CHANGELOG 的 M3 条目写 `Narrow window remains (5 lines)`。**同一文档自相矛盾。**

**建议**：两处文案统一为「窗口显著收窄，非互斥」；把 4.3 改成断言真实时序
（「`close(reserve_fd)` 发生在 dsh `bind()` 之前」），而不是函数名存在。

### F9 —— 只断言「没红」，不断言「跑了多少」（P2）

**位置**：`ci-enhanced.yml` 的 bats 步骤、`tests/security-verification.sh`、
`tests/auto-update-verify.sh`。

**依据**：TRAPS §一.16 / §一.18 —— 只设上界的门禁会被空提取满足；
`bats --filter` 的正则元字符、非 ASCII 测试名都会让用例**静默不执行**，而 `rc=0 + not ok=0`
极易被读成「全部通过」。

**现状**：`bats tests/unit/*.bats` 在 CI 里不比对 `1..N`；两个 `.sh` 套件打印 `PASS` 数但不设下界。

**建议**：CI 里 `N=$(bats -c tests/unit/*.bats)` 并对 `$N` 设下界（下界值随用例增减人工上调）；
两个 `.sh` 套件同样给 `PASS` 设下界并在失败信息里打印实际值。

### F10 —— `sed` 行范围抽函数体的静默失配面（P2）

**位置**：`tests/security-verification.sh` 的两处：

```sh
sed -n '/^static int http_probe/,/^}/p' src/daemon.c | grep -q "char b\[512\]"
sed -n '/^static void stop_dsh/,/^}/p'  src/daemon.c | grep -q "kill(pid, 0)"
```

范围抽取的终点是**第一行以 `}` 开头的行**。只要被抽函数体内出现一行列 0 的 `}`
（例如将来把某段大括号换行写），抽取就被**静默截断**，而 `grep -q` 恒假 ——
`ok` 或 `fail` 都会给出与真实结构无关的结论。

**依据**：项目已因完全同类的理由把 `daemon.c:NNN` 行号引用**全部**换成符号锚点，
并加了门禁（`file references use symbol anchors, never line numbers`，处置阶段 16 由
「只认 `daemon.c`」推广为全仓库 `路径:行号`）。
`sed` 行范围是同一个「位置描述随编辑漂移且无信号」的家族，只是没被那次整治覆盖。

**建议**：改用 `awk` 按函数名 + 花括号配平抽取；并在抽取后**先断言抽到的行数 > N**
（「抽取失败」必须与「结构合规」可区分，即 §一.16 的下界要求）。

---

## 四、P1：依赖与边界

### F3 —— `python3` 缺失时，`run.json` 会落一个**会话级临时** node 路径（P1）

**位置**：`install.sh` 的 `SYS_NODE` 解析段：

```sh
# 解析 fnm/volta 等 shim 符号链接到真实二进制(fnm 的 multishell 临时目录会随 shell 退出失效)
CAND="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$CAND" 2>/dev/null || echo "$CAND")"
```

以及 `update-dsh.sh` 的 node 解析段（同一写法）。

**证据（本机即命中该形态）**：

```
$ command -v node
/Users/seeu/.local/state/fnm_multishells/1197_1789215933663/bin/node
                  ^^^^^^^^^^^^^^^^^^^ 正是 fnm 的每会话临时目录
```

- 注释自己写明「fnm 的 multishell 临时目录会随 shell 退出失效」——即解析是**必要的**；
- 但 `|| echo "$CAND"` 使解析失败时**静默**退回未解析的 shim 路径；
- 该路径被 `install.sh` 写进 `run.json`，而 `run.json` 是守护 spawn dsh 的**单一事实源**。

**后果**：会话结束后目录被 fnm 清掉 → 守护 exec 一个不存在的路径 → `_exit(127)` →
与 F1 同样的用户侧表现（引导页永远转圈），日志里只有 `退出码 127`。

**与 D2 修复的不一致**：D2 已为「取 LTS 版本号」的 `python3` 缺失加了显式告警
（`warn "未找到 python3,无法从 nodejs.org 解析最新 LTS 版本"`），
**但这条后果更重的 `realpath` 依赖没有告警**。且 macOS 上 `python3` 常常只是 CLT 存根：
`command -v python3` 能命中，执行却失败 —— 此时连「缺 python3」都判不出来。

**建议**：

1. 探测 `python3` 的真实可用性（`python3 -c '' >/dev/null 2>&1`，而不是 `command -v`）；
2. 不可用且 `CAND` 落在已知 shim 目录（`fnm_multishells` / `volta` / `.nvm`）时
   **显式告警并拒绝写入**，提示用户用 `DSH_RT_NO_SYSTEM_NODE=1` 或先装系统 node；
3. 或改用纯 bash 逐级 `readlink` 解析（不依赖解释器）。

---

## 五、P1：健壮性

### F5 —— 守护无 `SIGTERM` 处理，`bootout` 会留下孤儿 dsh（P1）

**位置**：`main()` 只注册了 `signal(SIGPIPE, SIG_IGN)`，没有 `SIGTERM` / `SIGINT` 处理。

**为什么后果是孤儿**：

- plist 声明 `AbandonProcessGroup=true` → launchd **明确不清理**该 job 的进程组；
- `spawn_dsh()` 里 dsh 又 `setsid()` **自成会话/进程组** → 本来就不在守护的组里。

两条叠加：守护被信号杀死时，**dsh 必然存活**，继续监听内部端口。

**触发场景**：`launchctl bootout`（安装脚本的升级路径、README 的卸载路径）、
`launchctl kickstart -k`、崩溃后的 launchd 重启。

**缓解（已实现，故定为 P1 而非 P0）**：下次激活时 `main()` 读 `dsh.json` + `dsh_up()`
会**收养**这个 dsh（`daemon-cases.bats` 的 `daemon restart adopts running dsh …` 已覆盖）。
所以多数情况自愈。

**残留风险**：

- README「卸载」一节只 `bootout` + 删目录，**没有先停 dsh** → 卸载后仍有一个 dsh 在跑，
  且它的 `node_modules` 已被 `rm -rf`；
- 升级路径依赖「旧守护仍注册着」才能经 `/stop` 优雅停 —— 若用户手工 `bootout` 过，
  这条兜底就没了。

**建议**：`main()` 注册 `SIGTERM`/`SIGINT` → `stop_dsh()` → `exit(0)`；
README / `AUTO_UPDATE_IMPLEMENTATION.md` 的卸载步骤补一步
`curl -X POST -H "Origin: …" …/stop`（或 `pkill -f "$RT_HOME/app"`）。

---

## 六、P2：依赖清理的删除面

### F6 —— 按**目录名**删除仍是 S1 的同族风险（P2）

**位置**：`cleanup-deps.sh` 的第 3、4 段谓词：

```sh
find "$NM" -type f \( -name "*.map" … -o \( -name "*.md" ! -name "LICENSE*.md" ! -name "README.md" \) \)
find "$NM" -type d \( -name test -o -name tests -o -name __tests__ -o -name examples -o -name coverage -o -name .nyc_output \)
```

**依据**：S1 的教训是「**看起来像文档 ≠ 是文档**」（`yaml/doc/directives.js` 是运行时代码，
删掉后 dsh 直接起不来）。当前对 `doc`/`docs` 已改为白名单，但 `test`/`tests`/`examples`
**仍是按名字删**，`*.md` 也是「除两个白名单名之外全删」。

**现有兜底及其边界**：`require('sharp'); require('node-pty')` 探针只覆盖两个包
—— 它能抓住 S1 那一类（yaml 是 sharp 的传递依赖？实际不是，故其实抓不住），
对「某个包在 `test/` 里放了运行时代码」是**结构性盲区**。

**建议**：

1. 把「按名字删」整体收紧为**白名单包**（只删实测确认安全的包），或
2. 保留名字匹配但**先出候选、再逐包 `require` 冒烟**（`find` 出候选 → 对候选所在包做一次
   `node -e "require('<pkg>')"`），把「猜」换成「测」；
3. 至少在 `--dry-run` 输出里标注「按目录名删除，存在误删运行时代码的风险」，
   让 review 的人知道该看什么。

> 该脚本已有 `--dry-run` 与删除面门禁（`cleanup-deps.bats`），**测试是够的** ——
> 缺的是「选中集合本身是否安全」的判断依据，测试无法替代。

---

## 七、P3：代码质量与规范性

### F11 —— 工作树有半截重构：3 个宏，2 个从未使用

`git status` 显示 `M src/daemon.c`（相对 `17d5330` 新增 4 行）。新增：

```c
#define CT_HTML    "text/html; charset=utf-8"
#define CT_PLAIN   "text/plain; charset=utf-8"
#define CT_JSON    "application/json"
```

但 `grep -nE 'CT_HTML|CT_PLAIN|CT_JSON' src/daemon.c` 只命中**定义处**与 `CT_PLAIN`
的一个使用点（`respond()` 的 CR/LF 净化分支）。**18 个 `respond()` 调用点仍是字面量**，
且字面量本身不一致（`"text/plain"` 与 `"text/plain; charset=utf-8"` 并存）。

**为什么值得记**：`-Wall -Wextra -Werror` **不报未使用宏**，所以这是「编译全绿的死代码」。
按本项目对「静默」的敏感度，应当收口。

**建议**：要么完成替换（顺带统一 `charset`），要么回退这 4 行；
并把 `-Wunused-macros` 加进本地 gauntlet（clang 支持，本机验证无额外告警）。

### F13 —— release 构建比 CI 门禁松

`.github/workflows/release.yml` 的编译步骤：

```
clang -O2 -Wall -Wextra -arch arm64 -arch x86_64 -o /tmp/daemon src/daemon.c
```

而 `ci-enhanced.yml` 的三个 job 全部带 `-Werror`。release 可被 `workflow_dispatch`
单独触发，于是**存在一条绕过 CI 直接产出带告警发行包的路径**。

**建议**：与 CI 对齐加 `-Werror`。

### F15 —— plist 注入路径是 2 字符黑名单

`install.sh`：

```sh
for _P in "$HOME" "$RT_HOME" "$RT_STATE"; do
  case "$_P" in *'|'*|*'&'*) echo "路径含 | 或 &,无法生成 LaunchAgent 配置:$_P" >&2; exit 1 ;; esac
done
```

`sed` 的分隔符是 `|`，替换串里 `&` 有特殊含义 —— 这两个是对的。但目标产物是 **XML**：
`<` `>` `"` 换行同样会破坏 plist，而它们不在黑名单里。

**建议**：改为**允许字符白名单**（如 `[A-Za-z0-9._/ -]`）—— 与本项目在别处
（token 字符集、版本串字符集、CSP 源列表）一贯采用的「白名单而非黑名单」保持一致；
或渲染后直接 `plutil -lint`（复用 F4 的用例）。

### F16 —— `cleanup-deps.sh` 的空值兜底是死代码（C1 同族）

```sh
BEFORE=$(du -sm "$NM" 2>/dev/null | awk '{print $1}')
BEFORE="${BEFORE:-0}"   # 注释称：du 失败/目录瞬时消失时兜底
```

脚本开头是 `set -euo pipefail`。**`pipefail` 下 `du` 失败会让整条赋值的退出码非零**，
`set -e` 立即终止脚本 —— 下一行的兜底**永不执行**。注释承诺的兜底没有生效。

这与已修的 C1（`X=$(false | awk …)` 兜底是死代码）是同一家族，
只是当时只修了百分比那一处。

**建议**：`BEFORE="$(du -sm "$NM" 2>/dev/null | awk '{print $1}' || true)"`（`AFTER` 同理）。

### F12 —— 活文档漂移（数字类门禁覆盖不到的部分）

防漂移门禁只认「阿拉伯数字 + 项/个/条/款」，下列漂移全部漏网：

| 文档 | 现状 | 实际 |
|---|---|---|
| `docs/TOOLS_INTEGRATION.md` | 体积回归「>90KB 警告」；Pre-commit 示例同样 90KB | 代码里是 **150KB**（`analyze-binary.sh` / `ci-enhanced.yml` / bats 三处一致） |
| 同上 | 性能表「二进制 83KB / 目标 <90KB」 | 实测约 **120KB**（`security-verification.sh` 自报 120040 字节） |
| 同上 | 「安全测试通过率 100% (33/33)」 | 数字手写（`33/33` 无「量词」，门禁不匹配）；当前恰好正确 |
| `docs/AUTO_UPDATE_IMPLEMENTATION.md` | 「审核状态：待测试」「下一步：编译验证 + smoke test」 | 该功能早已上线并迭代多轮 |
| 同上 | 「代码变更统计」快照（6 files / 163 insertions） | 实现期快照，与现状无关 |

另外 `README.md` 声明「macOS 10.15 或更高」，而 CI 只跑 `macos-latest`，
该下限**从未被验证**；而 `NODE_COMPILE_CACHE`（≥22.1）、`--use-system-ca`（≥22.15）
等能力都按版本开关。

**建议**：阈值改为引用脚本常量或直接删掉数字；两份实现期文档补「这是实现期快照」抬头
（照 `AUDIT_HISTORY.md` 的做法）；README 把「最低 macOS + 最低 Node」写成一条可验证的兼容矩阵。

---

## 八、P3：性能

> 总体结论：**没有热点问题**。零常驻设计成立，空闲路径已收敛（socket-activated 模式下
> 空闲即 `exit(0)` 交还 socket，由 `settle_presence` 的兜底分支覆盖「激活后从未拉起 dsh」）。
> 下面只有优化空间，不是瓶颈。

### F14 —— 每个透传请求多两次系统调用组

**位置**：`handle_conn()` 开头，**每个请求**都执行：

```c
refresh_port();   // open + read + close  dsh.json
int up = dsh_up(); // socket + connect + close（一次完整 TCP 往返）
```

`ready_port` 已经采用「单一写者 + 子进程只读继承」的缓存模式；`dsh_port` / `up`
理论上也可在 `spawn_pid` 与 `ready_port` 未变时跳过。当前设计有正当理由
（dsh 可能被外部重启，需跟随），但可以做成「仅当 `ready_port != dsh_port` 或收到
`spawn_pid` 变更信号时才重探」。

**影响**：本地 SPA 请求量大时是纯开销；属可测量但非热点。

### 其他可调项（记录，不建议现在动）

| 项 | 说明 |
|---|---|
| `relay()` 的 `char cb[65536], ub[65536]` | 每连接子进程 128KB 栈缓冲；`MAX_CONN=256` 时理论上限约 32MB dirty page。降到 16KB 即可满足 localhost，或改为堆上共享。 |
| 启动期 `poll_ms = 150` | 冷启动（项目自述实测约 115s）期间约 6.7 次/秒唤醒 × 6 个每 tick 步骤 ≈ 770 次。CPU 可忽略，但可改为「探测未就绪时 150ms、已就绪未捕获 token 时 500ms」。 |
| `respond()` 分两次 `write_all`（头 + 体） | 两次 `write(2)`，可能拆成两个 TCP 段；`writev` 可合一次。收益微小。 |

---

## 九、安全维度小结

**结论：守护本体的安全设计仍然扎实，本轮**未发现新的可利用漏洞**。**
CSRF / Host / Cookie 三处精确匹配、`token_json_safe` 纵深防御、
「响应头缓冲截断可观测」、CSP 与引导页需求联动 —— 这些都在，且都有运行时用例。
本轮未发现新的绕过路径（复核了折叠头、流水线、方法大小写、query 拆分、路径前缀等面）。

以下是**已知限制的补充说明**，建议写进 README 的威胁模型（现在只写了流水线一条）：

1. **`/health` 的 `token` 是本机任意进程可读的 bearer 凭据。** Host 校验挡住了 DNS rebinding、
   无 CORS 头挡住了跨源读取，但**同用户的任意本机进程**都能拿到 token 并接管 dsh 会话。
   信任级别与 `dsh.log`（0600）相同，故不构成新洞，但 dsh 是具备文件/命令执行能力的
   agentic IDE，这条边界值得**明写**而不是留给读者推断。
2. **`GET /` 会触发 `request_wake()`，且不校验 Origin。** 任意网页可用 `<img>`/`<script>`
   让守护拉起 dsh（GET 不满足「状态变更」的定义，但副作用是真实的）。
   影响仅限本机资源占用，且拉起 dsh 本就是用户意图 —— 记录即可。
3. **`GET /health` 泄露 dsh 的内部 `port` 与 `pid`**，无实际危害，仅信息面。
4. F15（plist 注入的字符黑名单）是本节唯一的**可操作**项。

---

## 十、已核实「无问题」的方面（避免后续审计误报）

- **CSRF / Origin**：后缀仅允许 `/ ? #`，`127.0.0.1:3080.evil.com` 前缀绕过已封堵（用例 23）。
- **Host**：精确匹配 `127.0.0.1:PORT` / `localhost:PORT`，大小写不敏感（用例 17/26/28）。
- **Cookie**：`p[nl] == '='` 精确匹配，`dsh-auth-evil` 前缀绕过已封堵。
- **请求头读取**：未见 `\r\n\r\n` 一律 400，不完整头不进入判定、不透传（用例 36）。
- **折叠头（obs-fold）** 无法伪造 Host：续行以空格开头，`strncasecmp` 不匹配字段名。
- **`write_all` 的 EAGAIN** 走 `poll(POLLOUT, WRITE_WAIT_MS)`，不裸 `continue`（A2/E3 已修，用例 33）。
- **`MAX_CONN` 判定在 `fork()` 之前**，且 503 路径先设 `SO_SNDTIMEO`（E6d 的两个要点都在，用例 46）。
- **`cleanup-deps.sh` 的 `--dry-run` 与真删共用同一「选中集合」**，门禁双向断言 + 反空转。
- **install.sh 的锁抢占**：`O_EXCL` claim + 复读 pid，TOCTOU 防护到位（`auto-update-verify.sh` 用例 6）。
- **`shasum -a 256 -c -` 空输入 fail-closed**：实测 `rc=1`，故 node tarball 的 SHASUMS 校验在
  「grep 没匹配到任何行」时也是拒绝而非放行。
- **`--noproxy '*'` / `--max-time` 约定**：由 `install-validation.bats` 的门禁保证，实测零违规
  （该门禁本身带正反自检，且已修过「BWK awk 字符类漏 `-`」的失明 bug）。
- **无行号引用**：门禁 `file references use symbol anchors, never line numbers`
  （处置阶段 16 由 `daemon.c` 专用推广到全仓库 `路径:行号`；扫描面覆盖 `scripts/`、`tests/`、
  `src/`、`.github/workflows/`，另带文件数下界防 glob 漂移）带正反自检、
  **误报反控**（`主机:端口`）与扫描面断言。
- **零常驻不变量**：空闲自退有三条出口（残留清理 / dsh 已停 / 从未拉起），冒烟 5/5 端到端覆盖。

---

## 十一、建议的处置顺序

| 顺序 | 动作 | 理由 |
|---|---|---|
| 1 | 修 **F1**（plist 按能力注入 `NODE_OPTIONS`） | 唯一会让**整条产品路径失效**的问题，且已有现成修法（照抄 `update-dsh.sh` 的探测） |
| 2 | 补 **F4**（daemon plist 门禁，含 F1 的回归门） | F1 的根因是「关键产物零门禁」；不补，同类必再来 |
| 3 | 修 **F2**（SHA 断言改为锚定实现） | 一条会误导所有后续审计的假绿 |
| 4 | 修 **F3**（`realpath` 的 python3 依赖显式化） | 与 F1 同类的「静默落一个坏路径」 |
| 5 | 修 **F5**（`SIGTERM` → `stop_dsh`）+ 卸载文档 | 消除孤儿 dsh |
| 6 | 清理 **F7 / F8 / F9 / F10** | 门禁可信度；都是一次性小改 |
| 7 | 评估 **F6**（清理删除面） | 需要判断依据，不是纯代码改动 |
| 8 | 收口 **F11 / F12 / F13 / F15 / F16 / F14** | 规范性，可与下一次功能改动同批 |

> **提交前请按 TRAPS §零 的 gauntlet 全跑一遍**，并在修 F1/F4 时用
> `WRAPPER_UPDATE_SRC` 式的「改动前副本」做 fail-before 对照 ——
> 本项目的既有纪律是：**新门禁必须先在旧代码上变红**。

---

## 十二、处置收口（2026-09-12）

上文 F1–F16 **已全部处置完毕**，逐项记录见 `.workbuddy-ai/memory/2026-09-12.md`（阶段 11–16）。
每条修复都做了**双向控制**：新门禁在语义变异体下按预期变红，且**同一个变异体让改动前的旧产物保持绿色**
（证明旧门禁原本是空转的）。

| 项 | 结论 |
|---|---|
| F1 | plist 按能力探测注入 `NODE_OPTIONS`；新增 daemon plist 门禁（含 F1 回归门） |
| F2 | SHA 断言改为锚定实现（不再断言注释） |
| F3 | `realpath` 的 python3 依赖显式化 |
| F4 | `daemon-plist.bats`：渲染两份分支并用 `plutil -lint` 校验 |
| F5 | `SIGTERM` → `stop_dsh_wait()`（6s 优雅停机）+ 卸载文档补 `pkill -f` 兜底 |
| F6 | `cleanup-deps.sh` 删除面分「确认安全 / 按名字猜」两类，dry-run 逐行打标签 |
| F7/F8 | 门禁断言改为锚定实现；CHANGELOG 的「TOCTOU 已消除」改为「窗口收窄，非互斥」 |
| F9 | 两套 shell 套件补**断言数下界**；CI 增加 `bats -c` 数量校验 |
| F10 | `extract_fn` 取代 `sed` 行范围抽取（符号锚点 + 花括号配平 + 默认剥离注释） |
| F11 | `CT_*` 宏重构**做完整**（17 个调用点全部替换）；gauntlet 补 `-Wunused-macros` |
| F12 | 三份活文档的体积阈值/统计数字/兼容矩阵与实现对齐 |
| F13 | `release.yml` 补 `-Werror`（`workflow_dispatch` 是绕过路径） |
| F14 | `handle_conn` 的 `dsh_up()` 移到 `/health` 提前返回之后 |
| F15 | plist 路径校验由 2 字符黑名单改为白名单（放行非 ASCII，单独挡控制字符） |
| F16 | `cleanup-deps.sh` 的 `du` 兜底移进命令替换内部（`set -e` + `pipefail` 死兜底） |

**超出本报告范围的追加收口（阶段 16）**：行号引用门禁由 `daemon.c` 专用推广到全仓库
`路径:行号`（扫描面内当时共 4 处，逐条按内容核对后改写为符号/原文锚点），门禁更名
`file references use symbol anchors, never line numbers`。详见 TRAPS §一.34、§一.35。

**仍未由 CI 覆盖的**：macOS 版本下限（CI 只跑 `macos-latest`，见 README 兼容矩阵的显式声明）；
`auto-update-verify.sh` 的 9 项 SKIP（需真实安装后的文件系统状态，保留人工验证）。
