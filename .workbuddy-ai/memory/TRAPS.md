# dsh-pwa 踩坑全集（由 MEMORY.md 指向；动手前先读）

# 零、提交前 gauntlet（改完必跑）
```bash
clang -O2 -Wall -Wextra -Werror -o /tmp/dsh_verify src/daemon.c   # 必须零告警
shellcheck -S warning scripts/*.sh tests/*.sh tests/lib/*.sh
for f in scripts/*.sh tests/*.sh tests/lib/*.sh; do bash -n "$f"; done
bats tests/unit/   # 数量以 `bats -c tests/unit/*.bats` 为准，不手写；沙箱须分文件跑（见 §一.13）
# PyYAML 只在**系统** python3；本机 ruby 被 rbenv 指向未安装版本
/opt/homebrew/opt/python@3.13/libexec/bin/python3 -c "import yaml,glob;[yaml.safe_load(open(p)) for p in glob.glob('.github/workflows/*.yml')]"
node ~/.workbuddy-ai/skills/ci-gate-hardening/scripts/check_run_blocks.mjs .github/workflows
```
再跑一轮运行时 curl 回归（`/health` `/stop` `/wake`、Origin/Host 校验、cookie 校验）。

# 一、门禁假绿（最常见，先怀疑这里）
1. BSD `grep`/`sed` 的 `\|` 是字面量不是「或」→ macOS 上**静默无输出**。一律 `grep -E` / `sed -E`。
   **静默无输出 = 先怀疑分隔符语法，别先怀疑被测对象。**
2. 探针不能被「记录探针本身的文本」满足：Actions 回显整个 `run:` block（含注释），`grep "Terminate
   orphan process"` 命中的是我自己写的注释。要锚定真实格式 `Terminate orphan process: pid \([0-9]+\)`。
3. 探针必须锚定被测对象：`grep 'shasum -a 256 -c'` 命中的是**校验 node 包**那行。**报异常先打印
   原文核对再下结论。**
4. 门禁要对**每种写法**植入违规验证：BWK awk 的 `[^-A-Za-z0-9_]` 漏掉 `-` → curl 门禁对所有
   `curl -flag` 行失明却报 0 违规（改 `substr` 逐字符判）。按主机名过滤会漏掉 `curl -fsS "$ENDPOINT"`。
5. **「失败只 warn 不阻断」＝ 空转门禁**：暖机失败只 warn 且无断言 → CI 全绿而该特性 4/4 全挂。
   「尽力而为」步骤必须有可观测判据（marker / 断言 / 非零退出）。
6. 别用管道判定结果：`gh run watch --exit-status | grep | head -N` 拿到的是 `head` 的退出码（恒 0）。
   要 `cmd > log 2>&1; echo $?`。
7. `clang --analyze` 永远 exit 0，须补 `grep -Eq 'warning:|error:'`。
8. `BATS_TEST_TIMEOUT` 不可依赖（依赖 `/bin/ps`，不可用时静默空转）。
9. bats 1.14 + bash 3.2：`@test` 名含非 ASCII → **静默执行 0 个测试**。名字务必全 ASCII。
10. 仓库不跟踪 `pnpm-lock.yaml` → lock-diff 步骤是空转；校验 lock 非空才算门禁。
11. **「必须没有」的断言一定要配正控**，否则它在修复前也会通过。断言「不含 injected」前必须补
    「换成合法值后字段必须出现」；「没有残留」要配「它确实起过」的反空转断言。
12. **把待测代码块当子进程跑，赋值必须 export / 用 `env` 前缀**。`( VAR=x; bash block.sh )` 里 VAR
    不会传下去 → 块内为空、写文件全失败，而「文件必须不存在」的断言**恰好因此通过**：全绿却什么都没测。
13. **沙箱 safe-delete 阈值会让 bats 误报**：单条命令内删除超阈值后 `rm -rf` 被拦，
    `harness-cleanup.bats` 的 `security-verification.sh leaves no daemon behind` 报 exit=2。
    **勘误（2026-09-12）：计数不是「每次调用重置」，而是跨会话累积** —— 实测「逐文件跑」的循环
    （6 个独立 bats 进程，harness-cleanup 排第 3）**照样**踩中，故旧结论「分文件跑即正常」不成立。
    正确判据：**把报错的那个文件单独在一条新命令里跑**（harness-cleanup 3/3、security 33/33 rc=0 即
    证明是环境而非产品）。凡见到 exit=2 / `safe-delete` 字样，先按此复验再下结论。
14. **长套件在沙箱被 SIGKILL（exit 137），日志停在某个 `ok` 之后**：`daemon-cases.bats`（42 例）
    单进程跑到第 41 例被杀，日志只留 40 个 `ok`。**判据：用改动前源码跑同一文件**
    （`DSH_DAEMON_SRC=/tmp/old_daemon.c`，见 §四）—— 停在**同一处**即环境限制，与本次改动无关。
    剩余用例用 `bats --filter "<用例名>" <文件>` 单独跑补齐。**exit 137 不是测试失败。**
    补充：被杀的位置**不固定**（实测 40 / 34 两次不同）—— 故「停在同一处」不总是成立；
    更可靠的判据是 **`not ok` 计数为 0**，再用 `--filter` 补齐尾部用例。
15. **探针文本不得污染被测面**：写「反空转正控」时如果把违规字面量直接写进门禁文件，
    而门禁**又扫描该文件自身**，就会自己触发自己（`grep` 命中探针而非被测对象）。
    修法：用变量拼出字面量（`C=':'; printf 'daemon.c%s339' "$C"`），使违规串不以字面形式存在。
    同类：注释里写 `daemon.c:NNN` 也会被行号门禁命中 —— 注释同样在扫描面内。

# 二、回环 curl（curl 8.7.1）
- 无 `--max-time`：守护「已 bind 未 listen」时 macOS **丢 SYN**（不回 RST）→ 挂到作业级 timeout，
  真相被藏成「卡住」。
- 不 `--noproxy '*'`：curl 默认把 127.0.0.1 交给 `http_proxy` → **服务已死也返回代理 502 且 rc=0**，
  只看退出码会误报成功；比对精确码则会报出守护永不可能返回的 502。
- 超时/连不上时 `%{http_code}` 是 **`000`**（不是空串），故失败信息可以保持准确。
- `set -e` 下 `X=$(curl …)` 失败会终止整个脚本 → 写 `X=$(curl … || true)`，`|| true` 在 `$( )` **内部**。

# 三、macOS 工具差异
- `file -b` 对 universal 二进制逐架构输出一行 → `grep -c arm64` 恒为 2；判架构用子串匹配
  `[[ "$(file -b "$BIN")" == *"$(uname -m)"* ]]`。
- bash 3.2：`echo "x ($(awk "…\"%.1f\"…"))"` 解析错乱（echo 收 2 参数、awk 调 2 次、结果空）。
  **先算进变量再拼**。shellcheck / bats 都不覆盖。
- 单个路径分量不得超 NAME_MAX=255（拼长路径做边界测试时要拆段）。
- SC2034：`for i in $(seq …)` 中 `i` 未用 → 改写 `_`。

# 四、验证方法论
- **「dry-run」必须与真实路径共用同一段「选择」逻辑**，否则它只是**另一套实现**，
  它的正确性不构成真实路径的保证。2026-09-12 做 `cleanup-deps.sh` 的删除面门禁时，
  把「选谁」（`find` 谓词）与「怎么处置」（唯一的 `del()` 出口）分开 —— 于是 dry-run 打印的
  集合与真实删除**必然一致**，测试覆盖 dry-run 的选中集合即覆盖真实删除的选中集合。
  若两者各写一遍（`find -print` 一份、`find -delete` 另一份），门禁只证明了那份 print 是对的。
- **删除类脚本的门禁要双向断言**：只测「该删的没了」会漏掉**误删**（而误删才是破坏性的），
  只测「不该删的还在」会漏掉**没删干净**。fixture 必须同时放入两类。
  另配反空转：空树上不得报告删除项 —— 否则「该删的没了」可能只是因为它压根不存在。
- **控制组必须「旧实现 + 同一环境」**，而且**控制组自身要先被证明有效**。2026-09-12 两次栽在这：
  (a) 查 exit 137 时把改动前源码存成 `/tmp/daemon.c.bak`（**非 `.c` 结尾**），clang 报
      `ld: unknown file type` → 42 例全部「编译失败」。只看「有没有 FAIL」会得出**反向结论**。
      **控制组跑出异常结果时，先确认它真的执行了被测路径**（此处：文件名后缀决定 clang 当源码还是当目标文件）。
  (b) 换成 `/tmp/old_daemon.c` 后才得到有效对照。判据要**同位置**（同在第 40 个 ok 处停），
      而不是「都失败了」。
- **审计报告是快照不是现状**：`docs/` 的行号/结论会漂。用前必须验证
  `git log -S '<片段>' -- <文件>` 或 `git blame`。（曾把已修好的 S1(P0) 照抄成待办继续传播。）
- **代码里的「行号引用」必然漂移，且漂移后无信号 —— 一律改用符号锚点**。2026-09-12 逐条核对
  `scripts/` 与 `tests/` 里 13 处 `daemon.c:NNN`：只有 4 处仍指向所称内容，其余全部指向**无关代码**
  （一处称「setsid 自成进程组」，该行实际是 `} else {`；一处称「更新检查子进程」，该行实际是
  `int up = dsh_up();`）。根因：行号描述**位置**，位置随任何编辑改变。改用**函数名**锚点后，
  重命名会被编译/审查发现，而移动代码不会。已固化为门禁（`daemon.c references use symbol anchors`）。
  推论：**只核验「行号 ≤ 某行」是不够的** —— 当时正是据此判断「引用不会漂移」，而它们其实早就漂了；
  必须核验**内容**对得上。
- **「复刻验证」要连上下文复刻**（cwd、相对文件名、目录里还有什么）。只复刻命令 = 假验证。
- **`gh release create` 成功 ≠ 资产可下载**：同看 `gh api .../releases` 与 `.../releases/tags/<tag>`；
  `releases/tag/<tag>` 返回 200 只是 tag 页面。已在 `release.yml` 补「发布后下载资产三方比对哈希」。
- **失败路径保留现场** 比调日志级别值钱（暖机旧实现无条件 `rm -f` 日志 → 4 次超时无从诊断）。

# 五、CI 孤儿 daemon（两个来源，须按 job 分组归因）
- 来源一：`security-verification.sh` 的 EXIT trap 挂在第 7 节，而首次启动守护在前，且只 `rm -rf`
  从不停守护 → 「启动成功但随后失败」的路径不受保护。修法：`cleanup_all` 前移 + `daemon_stop_by_binary`。
- 来源二：`daemon.c` 每次守护启动都 `fork()`+`setsid()` 一个更新检查子进程，`sleep(10)` 后才 exec；
  那 10s 内它是**同名 `daemon` 且自成会话**，`kill $BPID` 杀不到，而基准只跑 ~3.5s。
  修法＝`DSH_RT_NO_AUTO_UPDATE=1`。
- 「某 job 恒 0」是排除共享组件的最强证据（Release 只跑 smoke → 恒 0）。
- `$!` 偏差**只出现在命令替换写法** `P="$(bin & echo $!)"`；`cmd & p=$!` 实测 3/3 命中。修前先分清形状。

# 六、install.sh / 更新链路
- `$RT_HOME/.install.lock` 同时是「安装互斥」与「守护更新期判定」的锁：守护见持锁者存活即拒 spawn dsh。
  install.sh 全程持锁 → **在 install.sh 内部启动守护去拉 dsh 必然 100% 失败**（暖机就这样踩死）。
  修法：给该守护实例**独立的无锁临时 RT_HOME**（复制 run.json + daemon，置 `DSH_RT_NO_AUTO_UPDATE=1`）；
  **`RT_STATE` 保持真实路径**（`NODE_COMPILE_CACHE` 按它算）。
- **绝不在 agent 沙箱里跑 `install.sh`**：
  (a) 它 `command -v node`，沙箱 PATH 里 WorkBuddy node 排在用户 fnm node 之前 → 把用户 PWA 绑到内部 node；
  (b) 非 Aqua 会话 `launchctl bootstrap` 必返 `5: Input/output error`，而 bootout 可能成功 →
      **注销掉用户本来可用的 LaunchAgent 且无法恢复**。判据：`TERM_SESSION_ID` / `XPC_SERVICE_NAME`
      为空即非 Aqua；**禁用沙箱也一样**。`DSH_INSTALL_NO_AGENT=1` 可跳过全部 launchctl。
- 沙箱还注入 `NODE_OPTIONS=--require=.../node-language-shim.cjs`；install.sh 现在「追加而非覆盖」
  NODE_OPTIONS，于是该 shim 被带进 pnpm → `ERR_PNPM_CODEBUDDY_BROKER_DENY`。本地跑 smoke 要
  `env -u NODE_OPTIONS` + PATH 收敛到用户 fnm node 与系统目录。

# 七、Homebrew 打包（阶段 4，就绪未发布）
- 位置：`packaging/homebrew/dsh-pwa.rb`（formula 单一真源）+ `scripts/bump-homebrew-formula.sh`；
  tap `3kaiu/homebrew-tap` **尚未创建**，故主 README 标注「尚未发布」而非写成可用方式。
- **Formula 刻意不自动安装运行时**：`install.sh` 会 `launchctl bootout/bootstrap`，而非 Aqua 会话
  bootstrap 必失败、bootout 却可能成功 → 自动执行会把用户本来可用的 LaunchAgent **注销且无法恢复**。
  故只落载荷 + 暴露 `dsh-pwa-install` 由用户显式执行。
- 两条实现约束：载荷**不能** symlink 进 `bin/`（`$0` 会变，install.sh 推导的 ROOT 就指错）；
  必须用 `bash` 调用（包内 install.sh 权限位是 **0644**，不可直接 exec）。
- `brew style` 要在 **tap 布局**下跑：非 tap 目录会多报 `Sorbet/*Sigil` 与 `FrozenStringLiteralComment`，
  用别的 tap 的 formula 做**对照**才能确认那是配置产物。`brew audit` 在 Homebrew 6 需要**已信任的 tap**
  （`brew trust`）→ 会改动本机信任状态，不做。
