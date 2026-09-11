# dsh-pwa 项目长期记忆

## 项目定位
macOS PWA wrapper，包装 DeepSeek Harness（dsh）。核心是**零常驻**架构：launchd socket activation，仅在 TCP 连接到达时拉起 daemon，空闲即退出，socket 由 launchd 持有。

- 仓库：`https://github.com/3kaiu/dsh-pwa`，主分支 `main`
- 核心源码：`src/daemon.c`（C 守护进程）；脚本在 `scripts/`；测试在 `tests/`

## 提交约定
Conventional Commits，中文 subject。历史风格举例：
- `fix: 审计批次二 — ...`
- `feat: P0-P3 全面优化 + 测试体系接入`
- `test: 自动更新验收自动化 + ...`
- `perf(daemon): 去过度工程化 — ...`
- `chore: remove ...`

## 提交前验证 gauntlet（改完必跑）
```bash
clang -O2 -Wall -Wextra -Werror -o /tmp/dsh_verify src/daemon.c   # 必须零告警
shellcheck -S warning scripts/*.sh tests/*.sh tests/lib/*.sh      # 与 CI 同范围
for f in scripts/*.sh tests/*.sh tests/lib/*.sh; do bash -n "$f"; done
bats tests/unit/                                                   # 当前 43 项
# workflow：PyYAML 真实解析 + 21 个 run block 语法检查
# 注意本机 `ruby` 被 rbenv 指向未安装的 3.1.0 而不可用；用**系统** python3（带 PyYAML），
# 托管版 python 没有 PyYAML。
/opt/homebrew/opt/python@3.13/libexec/bin/python3 -c "import yaml,glob;[yaml.safe_load(open(p)) for p in glob.glob('.github/workflows/*.yml')]"
node ~/.workbuddy-ai/skills/ci-gate-hardening/scripts/check_run_blocks.mjs .github/workflows
```
再加一轮运行时 curl 回归（`/health`、`/stop`、`/wake`、Origin/Host 校验、cookie 校验）。

**约定**：
- 脚本/测试/workflow 里所有 curl 都必须带 `--max-time N`；回环请求还要绕过代理
  （`--noproxy '*'`，或脚本只压本机时顶部 `unset http_proxy …`）。
- 每个 workflow job 都必须显式声明 `timeout-minutes`（不声明＝GitHub 默认 **360min**）。
- 以上两条都已固化为门禁，见 `install-validation.bats` 的
  `every curl in CI-executed scripts and workflows carries a timeout` 与
  `every workflow job declares timeout-minutes`。

## 踩过的坑（通用 shell / CI 陷阱）
1. **`file -b` 对 universal/fat 二进制逐架构输出一行** → `grep -c arm64` 恒为 2，`= 1` 永不成立。判断架构要用子串匹配：`[[ "$(file -b "$BIN")" == *"$(uname -m)"* ]]`。
2. **`clang --analyze` 永远 exit 0**，静态分析默认不是门禁。必须补 `grep -Eq 'warning:|error:'` 才成为真实 gate。
3. **bats 1.14 + bash 3.2：测试名含非 ASCII 时会静默执行 0 个测试**（假绿）。已在 `install-validation.bats` 加 ASCII 守护。新增 `@test` 名务必全 ASCII。
4. **本仓库不跟踪 `pnpm-lock.yaml`** → 任何 lock-diff 类 CI 步骤都是空转。改为校验 lock 非空才是真门禁。
5. **shellcheck SC2034**：`for i in $(seq ...)` 中 `i` 未使用时改写作 `_`。
6. **回环 curl 必须带 `--max-time` + 绕过代理**（实测 curl 8.7.1）。
   - 无超时：守护「已 bind 未 listen」时 macOS **丢弃 SYN**（不回 RST），curl 挂到作业级
     `timeout-minutes`（30min），真实原因被藏成「卡住」。
   - 不绕代理：curl **默认不豁免回环**，会把 `127.0.0.1` 交给 `http_proxy`
     （`curl -v` 打印 `* Uses proxy env variable http_proxy` 即铁证）。此时**服务已死返回代理的
     `502` 且 `rc=0`**——只看退出码的门禁会误报成功；比对精确码则会报出守护永不可能返回的 502。
   - 超时或连不上时 `%{http_code}` 是 **`000`（不是空串）**，故失败信息可以保持准确。
7. **`set -e` 下 `X=$(curl …)` 失败会终止整个脚本**（后续断言不跑、fixture 不清理）。
   必须写 `X=$(curl … || true)`，`|| true` 放在 `$( )` **内部**，再由断言报错。
8. **`BATS_TEST_TIMEOUT` 不可依赖**：bats 的超时逻辑要调 `/bin/ps`，该 helper 不可用
   （沙箱/受限环境）时**静默空转**，测试照样跑满。凡是委托外部 helper 的门禁，都要验证它真的生效。
9. **BWK(macOS) awk 的 `[^-A-Za-z0-9_]` 会漏掉 `-`**：`-A` 被解析成范围，`-` 落进否定类。
   曾让 `install-validation.bats` 的 curl 门禁对**所有 `curl -flag` 行静默失明**，却仍报 0 违规。
   改为 `substr` 取首字符逐个判断。教训：**门禁要对它声称覆盖的每种写法都植入违规验证**，
   只测一两种形状会得到「通过」的假结论（前两次探针恰好用了坏字符类能匹配的形状）。
   同理，按主机名（`127.0.0.1`/`localhost`）过滤会漏掉写成变量的 URL（`curl -fsS "$ENDPOINT"`）。
10. **workflow job 不声明 `timeout-minutes` ⇒ 默认 360min**：一步卡住白烧 6 小时 runner。
    本仓库既有约定是显式声明，已固化为门禁。判定时**只认 4 空格缩进的 job 级声明**
    （step 级是 8 空格，不能算数），且只在 `jobs:` 之后计数（否则 `on:` 下的
    `push:`/`pull_request:` 会被当成 job）。
11. **BSD grep 的 `\|` 不是「或」而是字面量**（技能里记过，我仍踩了两次）：`grep '^a:\|^b:'`
    在 macOS 上静默无输出。**一律用 `grep -E`**。
12. **不要用管道判定结果**：`gh run watch --exit-status | grep | head -N` 拿到的是 `head`
    的退出码（恒 0），run 还在 `in_progress` 也会「通过」。要 `cmd > log 2>&1; echo $?`。
13. **bash 3.2 里「双引号串内嵌 `$( )`、`$( )` 内再用转义双引号」会解析错乱**。
    `echo "x: ${A}MB ($(awk "BEGIN {printf \"%.1f\", $A*100/$B}")%)"` 在 macOS
    `/bin/bash`(3.2.57) 下：内层 `\"` 破坏外层引号 → `echo` 收到 **2 个参数**（同一行被打印
    两遍），`awk` 被调用 **2 次**且程序被截断 → 两次 `syntax error`，`$( )` 结果为空。
    fish / bash 5 不这样。**修法：先算进变量，不做嵌套**——
    `PCT="$(awk "BEGIN {printf \"%.1f\", $A*100/$B}")"; echo "  x: ${A}MB (${PCT}%)"`。
    实测：`cleanup-deps.sh:66` 中招（CI 打印 `节省空间: 62MB (%)   节省空间: 62MB (%)`），
    `install.sh:59` 的单引号 awk 写法安全。**shellcheck -S warning 不报此问题**，bats 也不覆盖。
14. **「失败只 warn 不阻断」＝ 空转门禁（error swallowing）**。`install.sh` 第 4c 步暖机
    失败只 `warn "暖机超时…不影响使用"`，且**成功与否没有任何测试断言**——于是 CI 全绿
    而该特性 4/4 次全部失败（见 2026-09-12 日志）。凡是新增「尽力而为」步骤，必须同时给出
    可观测的成功判据（marker 文件 / 断言 / 非零退出），否则绿 ≠ 可用。
15. **`$RT_HOME/.install.lock` 是「安装互斥」与「守护的更新期判定」共用的同一把锁**。
    守护 `update_locked()`（daemon.c:255）读该锁，持锁者 pid 存活即判「更新进行中」并
    **拒绝 spawn dsh**（daemon.c:296）。install.sh 整个运行期都持这把锁，所以**任何在
    install.sh 内部启动守护去拉起 dsh 的步骤都会 100% 失败**——暖机（4c）正是这样踩死的：
    不是环境问题、不是慢，是构造性死结。修法是给该守护实例一个**独立的无锁临时 RT_HOME**
    （守护从 RT_HOME 只读三处：`run.json`(119)、`.install.lock`(257)、
    `scripts/update-dsh.sh`(539)，故复制 run.json + daemon 即可，并置
    `DSH_RT_NO_AUTO_UPDATE=1`）。**`RT_STATE` 必须保持真实路径**，因为
    `NODE_COMPILE_CACHE` 是按 RT_STATE 算的（daemon.c:348），指错就白暖。
16. **诊断「超时」类缺陷前先想：日志被谁删了**。暖机旧实现无条件 `rm -f /tmp/dsh-warmup.log`，
    使 CI 里 4 次「超时」彻底无从诊断；本次只在失败分支加了一句 `cp … $LOG_DIR/warmup.log`，
    根因（陷阱 15）当场自现。**失败路径保留现场，比任何日志级别调整都值钱。**

## daemon 安全模型（勿回退）
- CSRF：Origin / Host 头**精确匹配**，防跨站与 DNS rebinding。
- Cookie：必须精确匹配 `dsh-auth=` 名，不可用 `strncmp(ck, "dsh-auth", 8)`（会放行 `dsh-auth-evil`）。
- 请求头：必须循环 recv 至 `\r\n\r\n`，一次性 recv 遇分片会误判 403。
- token 嵌 JSON：先过 `token_json_safe()` 字符集校验。
