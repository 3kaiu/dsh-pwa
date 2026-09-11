# dsh-pwa 全方位深度审计报告

**日期:** 2026-09-11
**审计范围:** 全仓库（`src/daemon.c` 1200 行 + 6 个脚本 + 6 个测试文件 + 2 个 workflow + 2 个 plist + 文档）
**代码规模:** 约 4,765 行代码 / 2,624 行文档
**方法论:** 静态阅读 + **运行时实证**（凡结论均给出可复现的验证命令与实测输出）
**与既有审计的关系:** 本项目已有 4 轮对抗审计（`docs/ADVERSARIAL_AUDIT_*`）。本报告**只列新增或未被修复的问题**，对已记录在案的"已知限制"仅作标注、不重复计入。

---

## 一、总体评价

| 维度 | 评级 | 一句话结论 |
|---|---|---|
| 安全设计 | **良好** | CSRF/Origin/Host/cookie 精确匹配、token 字符集校验、PID 复用核对等纵深防御扎实；主要风险在**发布链路**而非守护本体 |
| 架构设计 | **良好** | 零常驻 socket activation 是亮点；但"产物从未被端到端验证"是结构性盲区 |
| 错误处理 | **中等** | 大量边界已被显式处理并附实证注释；仍有 3 处潜伏缺陷（token 截断、截断请求当完整请求、EAGAIN 忙等） |
| 性能 | **良好** | 守护约 1.3MB RSS、就绪探测单写者、poll 梯度超时等优化到位；无热点问题 |
| 依赖与兼容 | **中等** | Actions 已 SHA pin（好），但 brew 工具、pnpm、dsh 全部浮动；依赖 `python3` 而新 macOS 已不自带 |
| 代码质量 | **中等** | 注释质量罕见地高（多数解释"为什么"而非"是什么"）；但文档冗余、单文件过大、个别兜底是死代码 |

**最关键的发现是一条 P0：README 首推的一行安装命令 `curl … | bash` 恒失败**（两处独立原因，均已实测复现）。它能长期存活，是因为 **CI 从未真正安装过发行包**——这是一条比缺陷本身更值得修的架构性盲区。

---

## 一之二、审计后修正（2026-09-12 复核）

> 本节由事后复核追加。**上面正文是 2026-09-11 的快照，未随代码演进更新**；
> 凡与本节冲突处，以本节为准。追加原因：本报告在 `f4caaf7` 入库时，
> 正文的 S1 已被 `e55263d` 修掉近 5 小时，但入库时未复核，导致一条**已失效的 P0**
> 被继续当作待办传播（`f4caaf7` 的提交信息亦误写「S1(P0) 未修」）。

| 条目 | 正文结论 | 实际状态 | 证据 |
|---|---|---|---|
| **S1**（P0，SHA-256 恒失败） | 未修 | ✅ **已修**（`e55263d`，2026-09-11 19:16） | 见下方复核实测 |
| **A1**（产物未被端到端验证） | 未修 | ✅ **已修**（`884891f`，`release.yml` 增加「解压真实产物跑完整冒烟」） | `release.yml` 打包后 e2e 步骤 |
| **C4**（curl 门禁不校验 `--noproxy`） | 未修 | ✅ 已修（`a81d15b`） | `install-validation.bats` |
| **C1**（`cleanup-deps.sh` 百分比恒空） | — | ✅ 已修（`11b4cdb`，bash 3.2 嵌套引号） | 实机输出 `节省空间: 0MB (0.0%)` |
| 第 1 批第 3 项（**0 个 release**） | 需打 tag | ❌ **仍未解决 —— 这才是当前唯一真实的 P0** | 见下方「S1 之后的真正阻断」 |

### S1 复核实测（2026-09-12）

`install.sh:45-57` 现为**直接比对哈希**，不再用 `shasum -c`。按 `release.yml:73-74`
的生成端忠实复刻（cwd=打包目录、相对文件名 `dsh-pwa.zip`）后实测：

```
生成端清单:  02bdc580…5726  dsh-pwa.zip
校验端目录:  pkg.zip  pkg.zip.sha256

旧实现 shasum -a 256 -c pkg.zip.sha256
  shasum: dsh-pwa.zip: No such file or directory
  dsh-pwa.zip: FAILED open or read
  rc=1                        ← 正文的复现成立

新实现(裸比对哈希)
  期望=02bdc580…5726  实际=02bdc580…5726
  rc=0 ✅ 通过(与文件名无关)
```

且新实现对清单格式**不敏感**，三种写法均可：`<hash>  name`（当前生成端）、
`<hash>`（裸哈希）、`<hash> *name`（GNU 二进制模式）。篡改追加一个字节后哈希改变、
fail-closed 分支正常触发。**S1 可以关闭。**

### S1 之后的真正阻断：`releases/latest` 是 404

修好校验后 `curl | bash` **仍然装不上**，但失败点前移到了**下载步**：

```
gh api repos/3kaiu/dsh-pwa/releases --jq length   →  0
远端 tag: 16 个（v0.3.0 / v0.3.1 / v0.3.2 …）

releases/latest/download/dsh-pwa.zip                 → 404
releases/next/download/dsh-pwa.zip                   → 404
releases/download/v0.3.1/dsh-pwa.zip                 → 404
releases/download/v0.3.1/dsh-pwa.zip.sha256          → 404
releases/tag/v0.3.1                                  → 200  ← 只是 tag 页面，非 release
api.github.com/repos/3kaiu/dsh-pwa/releases/tags/v0.3.1 → 404
```

**release 曾经存在过，后来消失了。** 证据链：

1. Release workflow 运行 `32546682958`（`event=push`，tag `v0.3.1`，sha `4cd66a6`）
   属于 `3kaiu/dsh-pwa`，其「发布到 GitHub Releases」步骤结论是 **success**；
2. 该步骤日志明确打印了 `https://github.com/3kaiu/dsh-pwa/releases/tag/v0.3.1`
   —— 即 `gh release create` 真的创建成功了（若失败会走 `||` 的 `gh release upload` 分支，
   日志中未见）；
3. 而现在该仓库的 release 列表是 **0**。

删除者与时间无法从现有数据判定（仓库 events API 只覆盖最近 100 条事件，个人仓库无审计日志）。
**但修复动作与原因无关**：只要重新产出一次 release（`workflow_dispatch` 触发
`release.yml`，或推一个新 `v*` tag），`curl | bash` 即可打通。

**新的门禁缺口（建议）**：`884891f` 补上了「产物端到端」，但**没有任何测试验证
「release 资产真的可下载」**——CI 从不访问 `releases/*/download/*`。
一条极便宜的守护即可堵住这类静默失效：

```yaml
# 定时(如每日)或 ci-enhanced 的可选 job
- run: |
    curl -fsSL --max-time 30 -o /dev/null \
      https://github.com/3kaiu/dsh-pwa/releases/latest/download/dsh-pwa.zip \
      || { echo "::error::latest release 资产不可下载 —— curl|bash 已失效"; exit 1; }
```

---

## 二、严重度定义

| 等级 | 含义 |
|---|---|
| **P0** | 阻断：主流程不可用 / 数据丢失 / 安全边界被突破 |
| **P1** | 高危：特定条件下可被触发，或使安全/可靠性保证失效 |
| **P2** | 中危：功能受损、资源泄漏、可维护性显著下降 |
| **P3** | 低危：健壮性、一致性、文档准确性 |

---

## 三、P0 — 阻断级

### S1. 发行包 SHA-256 校验恒失败，`curl | bash` 安装 100% 失败

> **状态：✅ 已修复（`e55263d`，2026-09-11 19:16）。** 以下为问题发现时的原始记录，
> 保留以说明复现方法。修复方式为「直接比对哈希」，复核见 §一之二。

**位置:** `scripts/install.sh:40-47`（校验端） + `.github/workflows/release.yml:74`（生成端）

**根因:** 生成与校验两侧的**文件名不一致**。

```bash
# release.yml:73-74  （cwd = /tmp/pkg）
cd /tmp/pkg && zip -qr dsh-pwa.zip .
shasum -a 256 dsh-pwa.zip > dsh-pwa.zip.sha256
# → 文件内容形如：  <hash>  dsh-pwa.zip     ← 记录了文件名 dsh-pwa.zip

# install.sh:40-47
curl -fsSL --max-time 300 -o "$PKG_TMP/pkg.zip" "$DL_URL"          # 下载为 pkg.zip
curl -fsSL --max-time 60  -o "$PKG_TMP/pkg.zip.sha256" "$SHA_URL"  # 校验文件另存为 pkg.zip.sha256
( cd "$PKG_TMP" && shasum -a 256 -c pkg.zip.sha256 >/dev/null 2>&1 ) \
  || { warn "发行包 SHA-256 校验失败"; rm -rf "$PKG_TMP"; exit 1; }
```

`shasum -c` 按**清单里记录的名字**去找文件，即去找 `dsh-pwa.zip`；而目录里只有 `pkg.zip`。

**实测复现（忠实复刻 install.sh 的目录状态）:**

```
$ ls -1
dsh-pwa.zip.sha256
pkg.zip
pkg.zip.sha256
$ shasum -a 256 -c pkg.zip.sha256
shasum: dsh-pwa.zip: No such file or directory
dsh-pwa.zip: FAILED open or read
shasum: WARNING: 1 listed file could not be read
rc=1                     ← fail-closed 分支被触发 → "发行包 SHA-256 校验失败" → exit 1
```

**影响:** `README.md:11` 与 `README.md:20` 记录的两种安装方式（`curl -o install.sh && bash install.sh`、`curl | bash`）都会走到该分支并**必然失败**。

**当前还有第二重阻断:** 仓库有 11 个 tag 但 **release 数为 0**（`gh api repos/3kaiu/dsh-pwa/releases` → `0`；`releases/latest/download/dsh-pwa.zip` → **HTTP 404**）。故今天执行该命令会先在下载步就失败（`curl -f` → rc 22 → "发行包下载失败"）。

**修复建议（两条任选其一，推荐第 1 条）:**

1. **校验端对齐文件名**（改动最小、最稳）：
   ```bash
   ( cd "$PKG_TMP" && shasum -a 256 -c <(sed 's/dsh-pwa\.zip/pkg.zip/' pkg.zip.sha256) >/dev/null 2>&1 )
   ```
   或直接把下载目标改名为 `dsh-pwa.zip`（`-o "$PKG_TMP/dsh-pwa.zip"`），让两侧天然一致。
2. **生成端改为裸哈希**：`shasum -a 256 dsh-pwa.zip | awk '{print $1}' > dsh-pwa.zip.sha256`，校验端改用 `echo "$(cat x.sha256)  pkg.zip" | shasum -c -`。

**并必须补一条门禁**（见 A1）——否则同类问题还会再犯。

---

## 四、P1 / P2 — 架构与安全

### A1. 发布产物从未被端到端验证（**本次 P0 能存活的根因**）

**位置:** `.github/workflows/release.yml:55-58`、`scripts/smoke-test.sh:30`

```yaml
# release.yml:55  —— 冒烟在「打包之前」、且跑的是仓库源码树
- name: 冒烟测试(打包前置:install → 守护 → 唤醒 → 透传 → 空闲自停)
  run: bash scripts/smoke-test.sh
```

```bash
# smoke-test.sh:7,30 —— INSTALL 默认指向仓库内的 install.sh
INSTALL="${1:-$ROOT/scripts/install.sh}"
bash "$INSTALL"
```

因为**仓库里恒存在 `src/daemon.c`**，`install.sh:30` 的自动下载分支

```bash
if [ ! -f "$ROOT/src/daemon.c" ] && [ ! -f "$ROOT/daemon.c" ] && [ ! -f "$ROOT/daemon" ]; then
```

在 CI 中**永不可达**。发行包解压后的真实布局（`install.sh` 在包根 + 包内 `daemon` 预编译）从未被安装过。

**建议:** 新增一个 job，**先 `zip` 打包，再解压到临时目录，用 `SMOKE_ROOT` 指向它跑 `smoke-test.sh`**（该脚本已支持 `SMOKE_ROOT` 与 `[install.sh 路径]` 参数，改动量很小）。这是本次审计中**性价比最高的一条改进**。

### A2. 零常驻可被"阻塞写"破坏（`active` 永不归零）

**位置:** `src/daemon.c:705-722`（`connect_upstream` 未设发送/接收超时）、`src/daemon.c:668-674`（`write_all`）、`src/daemon.c:676-703`（`relay`）

`relay()` 给**客户端** socket 设了 `SO_RCVTIMEO`（`:851`），但上游 socket 由 `connect_upstream()` 建立，**未设 `SO_SNDTIMEO`/`SO_RCVTIMEO`**；客户端的发送方向同样无超时。于是：

- 上游（dsh）不读时，`write_all(u, …)` 可无限期阻塞在 `write(2)`；
- 客户端不读时，`write_all(c, …)` 同理。

`relay()` 的 `IDLE_LIMIT = 1800s` 只在 `poll()` 超时路径生效，**覆盖不到卡在 `write` 里的情形**。子进程不退出 → `waitpid` 不收 → `active` 恒 > 0 → 空闲停机判定（`:1075` `if (dsh_port > 0 && active == 0)`）永不成立 → **dsh 不停、守护不自退，零常驻设计失效**。

**建议:** 在 `connect_upstream()` 中对返回的 socket 设 `SO_SNDTIMEO`/`SO_RCVTIMEO`（如 30s）；或在 `relay` 中改用 `poll(POLLOUT)` 门控写，并为 `write_all` 增加截止时间参数。

### A3. 透传路径的 CSRF 校验可被流水线请求绕过

**位置:** `src/daemon.c:949-955`（只校验首个请求头）、`src/daemon.c:959-961`（`write_all(u, buf, blen)` 后进入裸字节 `relay`）

`relay()` 是纯字节管道，**不解析后续请求**。因此：

```
GET / HTTP/1.1\r\nHost: 127.0.0.1:3080\r\n\r\n      ← 首个请求:GET 不触发 Origin 校验,放行
POST /api/<副作用> HTTP/1.1\r\nHost: …\r\n\r\n      ← 流水线第二请求:完全绕过 Origin 校验
```

浏览器难以构造（`fetch` 不流水线），但**命令行可**。缓解因素：能直连 `127.0.0.1:3080` 的本机进程本就可直接访问 dsh，且 `dsh` 自身有 cookie 鉴权。故定级 P2 而非 P1。

**建议:** 若需封堵，可在 `relay` 中对客户端→上游方向做极轻量的请求行嗅探（仅识别 `\r\n` 后的方法名），或干脆明确接受该风险并写入威胁模型。

### A4. 自动更新缺"更新后健康校验 / 启动失败回滚"

**位置:** `scripts/update-dsh.sh:195-266`

现有回滚只覆盖**安装失败**（`pnpm update` 与 `pnpm install` 均失败 → 从 `.bak` 恢复）。但"**装成功了、版本号也对、启动即崩**"（上游发坏版本、ABI 不兼容等）没有任何检测与回滚：`UPDATE_OK=1 && NEW == REMOTE` 即宣告成功（`:217`），随后不做任何启动探测。凌晨 2:30 无人值守更新到坏版本 → 用户次日打开 PWA 只见引导页。

**建议:** 更新成功后用与守护相同的判定做一次最小启动探测（`timeout 20 node <DSH_BIN> web --no-open --port 0` 之类，或拉起后 `http_probe`），失败则自动回滚到 `.bak`。这是"过夜服务消失"的唯一剩余入口。

### A5. 更新链路无完整性固定（供应链）

**位置:** `scripts/install.sh:233,237,251`、`scripts/update-dsh.sh:188,192`

- 仓库**不跟踪任何 lockfile**（`git ls-files` 无 `pnpm-lock.yaml`/`package-lock.json`）；
- `npx_pnpm()` 用 `--package=pnpm@10`（浮动大版本）；
- `@deepseek-ai/dsh@latest`（浮动）。

`release.yml:21-30` 会现场生成 lock 并打进发行包，但**仓库内安装（`bash scripts/install.sh`）不经过该 lock**（`install.sh:252` 的 `[ -f "$ROOT/pnpm-lock.yaml" ]` 恒为假），因此每次都现场解析依赖树，无 integrity 锚点。

**建议:** 至少把 `release.yml` 生成的 `pnpm-lock.yaml` 纳入版本控制，或在 `install.sh` 中启用 `--frozen-lockfile` 并校验 `pnpm-lock.yaml` 的存在（缺失即告警而非静默现场解析）。

---

## 五、P2 / P3 — 守护本体（`src/daemon.c`）

### E1. token 超过 63 字符时被静默截断且永久缓存（潜伏）

**位置:** `src/daemon.c:383-392`

```c
size_t i = 0;
while (v[i] && i < sizeof dsh_token - 1 && (…字符集…)) i++;
if (v[i] != 0) { // 值完整结束于本次读取窗口内
  memcpy(dsh_token, v, i); dsh_token[i] = 0;
```

当 token 长度 **≥ 64** 时，循环因 `i < 63` 上界退出，而 `v[63]` 仍是合法 token 字符（非 0），于是**误判为"完整结束"**，把一个 63 字符的**前缀**当作完整 token 缓存下来；又因 `scan_token()` 开头 `if (dsh_token[0]) return;`（`:370`），**永不重扫**。引导页随后用错误 token 握手 → dsh 拒绝 → 401 → 引导页循环 reload。

**实测当前 token 长度为 43**（本机 `daemon.log` 记录 `token(长度 43`，`dsh.log` 中 `?token=` 值长 43），故**当前未触发**，属潜伏缺陷：dsh 一旦把 token 加长到 ≥64 即命中。

**建议:** 把截断与"值结束"两个条件分开判断——当 `i == sizeof dsh_token - 1` 时按"被截断"处理（记 `::warning` 并拒绝缓存），而不是走完成分支。

### E2. 截断的请求头被当作完整请求处理

**位置:** `src/daemon.c:834-848`（`read_request_head`）、`:854-855`（`handle_conn`）

```c
int blen = read_request_head(c, buf, sizeof buf);
if (blen <= 0) return;          // ← 只判 <=0,未区分"读满/超时"与"读到空行"
```

`read_request_head` 在三种情况下返回正数：读到 `\r\n\r\n`、**缓冲区读满 8192**、**`SO_RCVTIMEO`(2s) 超时**。后两种都属于"头不完整"，但 `handle_conn` 会照常做 Host/Origin/路径判定并透传。

**影响:** 攻击者可让守护基于截断数据做安全判定（与 A3 组合即形成绕过链）。定级 P2。

**建议:** 返回"是否见到空行"的标志位，未见空行则 400 关闭，而非继续处理。

### E3. `write_all` 对 `EAGAIN` 忙等

**位置:** `src/daemon.c:668-674`

```c
ssize_t w = write(fd, b, n);
if (w < 0) { if (errno == EINTR || errno == EAGAIN) continue; return; }
```

`continue` 在 `EAGAIN` 时不退让，是 100% CPU 自旋。当前 socket 均为**阻塞模式**（仅设 `SO_RCVTIMEO`，未设 `O_NONBLOCK`），故不易触发；但一旦为配合 A2 引入非阻塞/超时，这里就会变成热点。

**建议:** `EAGAIN` 分支改为 `poll(POLLOUT)` 等待或 `usleep`，不要裸 `continue`。

### E4. `build_boot` 的 `snprintf` 静默截断

**位置:** `src/daemon.c:618-622`（`BOOT_PAGE[4096]`）

实测（编译期常量 + `build_boot()` 实测）：

```
TPL_HEAD      = 1869
TPL_TAIL      = 1562
sum           = 3431
BOOT_PAGE cap = 4096
BOOT_PAGE len = 3472      ← 85% 占用
TRUNCATED     = no
```

当前未截断，但余量仅 624 字节，而占位符是**用户可控的 `LOG_DIR`**（`$HOME/.local/state/dsh-runtime/logs`）。`HOME` 异常长时会截掉 `</script></body></html>`，得到一个**静默损坏的引导页**。同一文件里 `respond()` 有显式截断守卫（`:631-632`），此处却没有，属不一致。

**建议:** 对 `snprintf` 返回值做与 `respond()` 相同的越界断言；或把 `BOOT_PAGE` 提到 8192。

### E5. `pick_port_fd` 的"端口预留"实际不存在（注释与实现不符）

**位置:** `src/daemon.c:174-188`（注释声称"返回保持 bind 的 socket fd 以防窗口期被占"） vs `:320`（父进程 `close(reserve_fd)`）与 `:333`（子进程 `close(reserve_fd)`）

父、子进程都在 **dsh 真正 bind 之前**关闭了预留 socket，因此 `bind → close → dsh bind` 之间是真实竞态窗口。前轮审计已把"TOCTOU 表述过誉"记为低危（`ADVERSARIAL_AUDIT_FIX.md` R4），此处为**残留**：要么修注释，要么真的把 fd 传给 dsh（较难，node 无 `--preserve-fd` 语义）。

**建议:** 修正注释以反映实际行为（低成本、消除误导），并在 `spawn_dsh` 失败路径上补一条"端口被抢"的日志以便诊断。

### E6. 其余低危项

| 编号 | 位置 | 问题 | 建议 |
|---|---|---|---|
| E6a | `daemon.c:625-635` | 响应缺 `X-Content-Type-Options: nosniff` 等安全头；引导页内联 JS 无 CSP | 加 `nosniff` + 最小 CSP |
| E6b | `daemon.c:626-630` | `Content-Type` 来自参数（当前均为字面量）。若未来传入用户数据即成 CRLF 注入面 | 加白名单断言 |
| E6c | `daemon.c:94-116` | `extract_str` 用 `strstr("\"key\"")` 做 JSON 解析，值内含同名子串可误匹配 | run.json 由本仓库写入，风险低；可改用严格解析或校验键序 |
| E6d | `daemon.c:1176-1195` | 每连接 `fork`，**无并发上限**（仅 `EMFILE` 时退避 100ms） | 加 `active` 上限（如 256），超限直接 503 |
| E6e | `daemon.c:150-158` | `stop_dsh` 对非本进程 spawn 的 pid 仅校验"可执行文件是 node"，可被诱导 kill 任意 node 进程（需先能写 `dsh.pid`，同用户） | 增加启动时间/端口交叉校验（成本高，可按已知限制接受） |
| E6f | `daemon.c:1046-1070` | 僵尸回收仅在 `poll` 返回后执行，最长滞留 `poll_ms`(≤1s) | 影响有限，可接受 |

---

## 六、P2 / P3 — 脚本、CI 与文档

### C1. `cleanup-deps.sh` 的兜底是死代码

**位置:** `scripts/cleanup-deps.sh:15-16`

```bash
BEFORE=$(du -sm "$APP_DIR/node_modules" 2>/dev/null | awk '{print $1}')
BEFORE="${BEFORE:-0}"   # du 失败/目录瞬时消失时兜底…
```

脚本顶部是 `set -euo pipefail`。**实测:**

```
$ bash -c 'set -euo pipefail; BEFORE=$(false | awk "{print 1}"); BEFORE="${BEFORE:-0}"; echo survived'
rc=1                                   ← 未走到第 16 行,set -e 先退出
$ bash -c 'set -eu;  …同样代码…'
survived with BEFORE=[0]  rc=0         ← 去掉 pipefail 才生效
```

即 `du` 失败时第 16 行的兜底**不可达**，注释所述场景仍会让脚本异常退出。

**建议:** 改为 `BEFORE="$(du -sm … | awk '{print $1}' || echo 0)"`，把 `|| true` 放进 `$( )` 内部（与本会话在 `tests/security-verification.sh` 中确立的写法一致）。

### C2. `cleanup-deps.sh` 的删除面远大于探针覆盖

**位置:** `scripts/cleanup-deps.sh:33-50`

删除了全树任意深度的 `*.map`、`tsconfig.json`、`.eslintrc*`、`jest.config.*`、`*.md`（除 LICENSE/README），以及任意名为 `test`/`tests`/`__tests__`/`examples`/`coverage`/`.nyc_output` 的**目录**。前轮审计（S1）已判定"过于激进"，缓解措施是 `install.sh:316` / `update-dsh.sh:225` 的探针——但**探针只覆盖 `sharp` 与 `node-pty`**。若删除破坏了其它包（例如某 CLI 在运行时读取自身 `test/fixtures` 或 `tsconfig.json`），不会被告警。

**建议:** 把探针从"两个包"升级为"dsh 能否 `--version` 启动"（行为级），覆盖面大得多且成本相近。

### C3. `install.sh:250` 的布尔优先级无括号

**位置:** `scripts/install.sh:250`

```bash
if [ -n "$LATEST" ] && [ "$CUR_DSH" != "$LATEST" ] || [ -z "$CUR_DSH" ]; then
```

`&&`/`||` 在 shell 中**同级且左结合**，故实际等价于 `(A && B) || C`——恰好是意图，但依赖隐式规则。后续任何一次编辑都可能改变语义。

**建议:** 显式加括号 `if { [ -n "$LATEST" ] && [ "$CUR_DSH" != "$LATEST" ]; } || [ -z "$CUR_DSH" ]; then`。

### C4. 新增的 curl 门禁不校验 `--noproxy`，CI 自身违反约定

**位置:** `tests/unit/install-validation.bats`（`every curl in CI-executed scripts and workflows carries a timeout`） vs `.github/workflows/ci-enhanced.yml:130`

该门禁只断言 `--max-time`。实测全仓库 `--noproxy` 出现位置：

```
scripts/smoke-test.sh:17   scripts/benchmark.sh:1   scripts/update-dsh.sh:3
scripts/install.sh:4       tests/security-verification.sh:7   tests/auto-update-verify.sh:1
                                    ← .github/workflows/ 完全没有
```

而 `ci-enhanced.yml:130` 的回环 curl 正是：

```yaml
curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:3080/health" 2>/dev/null && break
```

**这是"门禁给出了超出其实际覆盖的保证"的典型**——正是本项目一直警惕的"假门禁"模式。实际影响有限（GitHub runner 默认无 `http_proxy`，且有 `-f` 兜底），故定级 P3。

**建议:** 把门禁的 `--noproxy` 检查补上（仅对含回环主机的 curl 行要求），并修掉该处调用。

### C5. 权限声明与实现不符

**位置:** `README.md:73` 声称"日志与状态目录 0700、**文件 0600**"

实测本机：

```
drwx------  /Users/seeu/.local/state/dsh-runtime          ← 目录 0700 ✓
-rw-r--r--  …/logs/daemon.log                              ← 0644 ✗
-rw-r--r--  …/logs/update.log                              ← 0644 ✗
-rw-r--r--  …/logs/updater.log                             ← 0644 ✗
-rw-------  …/logs/dsh.log                                 ← 0600 ✓
```

`daemon.log`/`updater.log` 由 **launchd** 依 `StandardOutPath` 创建，继承 launchd 的 umask，故为 0644；只有守护自己 `open(…, 0600)` 的 `dsh.log` 是 0600。**被 0700 父目录缓解**（其他用户无法穿越），但文档声明不准确。

**建议:** 要么在 `install.sh` 中对已存在的日志 `chmod 0600`（与 `chmod 0700 "$RT_STATE" "$LOG_DIR"` 同一处），要么修正 README 措辞。

### C6. 依赖与兼容性

| 编号 | 位置 | 问题 | 等级 |
|---|---|---|---|
| D1 | `ci-enhanced.yml:44,69,104` | `brew install bats-core/shellcheck/hyperfine` **不固定版本** → 构建非确定，上游破坏性更新会让 CI 红绿翻转 | P2 |
| D2 | `install.sh:172,195`、`update-dsh.sh:56` | 依赖 `python3`；**macOS 12.3+ 不再自带**。缺失时静默降级（realpath 退化为原值、LTS 版本回退硬编码），不报错 | P2 |
| D3 | `install.sh:196` | 硬编码回退 `LTS_VER="24.19.0"`，会随时间陈旧且无告警 | P3 |
| D4 | `launchd/com.dshpwa.updater.plist` | 缺 `NODE_OPTIONS=--use-system-ca`（`daemon.plist` 有）→ 企业 TLS 检查代理下，更新器的 `npm view` 可能因证书失败而**静默永不更新**（只写日志） | P3 |
| D5 | `release.yml:80` | `workflow_dispatch` 触发时 `github.ref_name` 是分支名，`gh release create "$TAG"` 会建出以分支名命名的 release | P3 |
| D6 | 全仓库 | 无 `package.json`（非 node 项目），故"依赖"实为 Actions / brew / 外部二进制三层；Actions 已 SHA pin（**良好实践**） | — |

---

## 七、优先级排序（改进路线）

### 第 1 批 — 立即（阻断主流程）

> **状态（2026-09-12 复核）**：第 1、2 项**已完成**（`e55263d` / `884891f`）；
> **第 3 项仍未解决，且已升级为本仓库当前唯一真实的 P0** ——
> 校验修好之后，`curl | bash` 的失败点前移到了下载步（`releases/latest` → 404）。
> 详见 §一之二。

| # | 项 | 位置 | 工作量 | 状态 |
|---|---|---|---|---|
| 1 | **修 SHA-256 文件名不匹配**（S1） | `install.sh:40-47` 或 `release.yml:74` | 极小 | ✅ `e55263d` |
| 2 | **补"发行包端到端安装"门禁**（A1）——否则 1 会再犯 | `release.yml` + 复用 `smoke-test.sh` | 小 | ✅ `884891f` |
| 3 | 打通首个 release（当前 0 个，`curl\|bash` 必然 404） | 打 tag 走 `release.yml` | 小 | ❌ **未解决（当前 P0）** |

### 第 2 批 — 本周（可靠性）

| # | 项 | 位置 | 工作量 |
|---|---|---|---|
| 4 | 上游/客户端 socket 加发送超时，封堵 `active` 永不归零（A2） | `daemon.c:705-722`、`668-674` | 小 |
| 5 | token 截断误判为完整（E1，潜伏） | `daemon.c:383-392` | 小 |
| 6 | 截断请求头按不完整处理（E2） | `daemon.c:834-855` | 小 |
| 7 | 更新后健康校验 + 失败回滚（A4） | `update-dsh.sh:217` 后 | 中 |
| 8 | `cleanup-deps.sh` 死兜底 + 探针升级为行为级（C1、C2） | `cleanup-deps.sh:15-16`、`install.sh:316` | 小 |

### 第 3 批 — 下个版本（健壮性与一致性）

| # | 项 | 位置 | 工作量 |
|---|---|---|---|
| 9 | `write_all` 的 `EAGAIN` 忙等（E3） | `daemon.c:671` | 小 |
| 10 | `build_boot` 截断断言 / 缓冲提到 8192（E4） | `daemon.c:618-622` | 小 |
| 11 | 补 `--noproxy` 门禁并修 CI 调用（C4） | `install-validation.bats`、`ci-enhanced.yml:130` | 小 |
| 12 | 日志文件 `chmod 0600` 或修 README（C5） | `install.sh:93` 附近 | 极小 |
| 13 | lockfile 纳入版本控制 / `--frozen-lockfile`（A5） | `install.sh`、仓库根 | 中 |
| 14 | 连接数上限（E6d） | `daemon.c:1183` | 小 |
| 15 | brew 工具版本固定、`python3` 前置探测（D1、D2） | `ci-enhanced.yml`、`install.sh` | 小 |
| 16 | 修正 `pick_port_fd` 注释、`install.sh:250` 加括号（E5、C3） | 对应位置 | 极小 |

### 第 4 批 — 技术债（择机）

17. `docs/` 下 5 份审计/实现文档（约 2,300 行）与 `CHANGELOG.md` 大量重叠且部分结论已过时，建议合并为单一 `AUDIT.md` + 历史归档（P3）
18. `daemon.c` 单文件 1,200 行、`main()` 约 230 行，可按 `http.c`/`state.c`/`relay.c` 拆分（P3）
19. 透传流水线 CSRF 绕过（A3）：或封堵、或明确写入威胁模型（P3）

---

## 八、已核实"无问题"的方面（避免误报）

审计中主动验证并**确认良好**的部分，供后续审计复用：

- **Host 校验**（`:815-827`）：精确匹配 `127.0.0.1:PORT`/`localhost:PORT`，成功阻断 DNS rebinding；`launchd` plist 亦只 bind IPv4 回环（`SockNodeName=127.0.0.1`，`SockFamily=IPv4`），不暴露到网络。
- **Cookie 校验**（`:773-787`）：`p[nl] == '='` 精确匹配，`dsh-auth-evil` 前缀绕过已被封堵。
- **Origin 校验**（`:792-808`）：后缀仅允许 `/ ? #`，`127.0.0.1:3080.evil.com` 前缀绕过被封堵。
- **`token_json_safe`**（`:403-410`）：token 字符集二次校验，防畸形 JSON（纵深防御）。
- **`set -e` + `A && B`**：实测 `[ -x /nonexistent ] && …` 不会因 `set -e` 退出（`:191` 安全），非缺陷。
- **`relay` 无数据总时限**（`:681`，1800s）：前轮 L5 已修，确认生效。
- **`install.sh` 端口占用检测**（`:427-434`）：bootout 后复查一次，避免误报。
- **CI 的 `clang --analyze` 门禁**（`ci-enhanced.yml:78-85`）：已补 `grep -Eq 'warning:|error:'`，不是假门禁。
- **`--max-time` 全覆盖**：`scripts/`、`tests/`、workflows 中所有 curl 均已带超时（由 `install-validation.bats` 门禁保证）。

---

## 九、审计方法与可复现性

| 结论 | 验证手段 |
|---|---|
| S1 恒失败 | 在 `/tmp` 忠实复刻 install.sh 的目录状态（仅 `pkg.zip` + `pkg.zip.sha256`），执行 `shasum -a 256 -c` → **rc=1** |
| A1 分支不可达 | 阅读 `smoke-test.sh:7,30` + `install.sh:30` 的分支条件；确认仓库恒有 `src/daemon.c` |
| C1 死兜底 | `bash -c 'set -euo pipefail; X=$(false \| awk …)'` → **rc=1**，对照 `set -eu` → rc=0 |
| E4 缓冲余量 | `#define main …; #include "src/daemon.c"` 编译桩，实测 `TPL_HEAD/TPL_TAIL/BOOT_PAGE` 长度 |
| E1 token 长度 | 本机 `~/.local/state/dsh-runtime/logs/{dsh,daemon}.log` 实测 token 长 **43** |
| C5 权限 | `stat -f '%Sp %N'` 实测 0644 vs README 声明的 0600 |
| C4 noproxy 缺口 | 全仓库检索 `--noproxy` 命中分布；确认 workflows 为 0 命中 |
| 发布状态 | `gh api repos/3kaiu/dsh-pwa/releases` → **0**；`releases/latest/download/dsh-pwa.zip` → **404** |

> 本次审计**未修改任何源码**，仅新增本报告文件。
