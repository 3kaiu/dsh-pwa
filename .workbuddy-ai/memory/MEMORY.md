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
shellcheck -S warning scripts/*.sh
for f in scripts/*.sh; do bash -n "$f"; done
bats tests/unit/                                                   # 当前 39 项
```
再加一轮运行时 curl 回归（`/health`、`/stop`、`/wake`、Origin/Host 校验、cookie 校验）。

## 踩过的坑（通用 shell / CI 陷阱）
1. **`file -b` 对 universal/fat 二进制逐架构输出一行** → `grep -c arm64` 恒为 2，`= 1` 永不成立。判断架构要用子串匹配：`[[ "$(file -b "$BIN")" == *"$(uname -m)"* ]]`。
2. **`clang --analyze` 永远 exit 0**，静态分析默认不是门禁。必须补 `grep -Eq 'warning:|error:'` 才成为真实 gate。
3. **bats 1.14 + bash 3.2：测试名含非 ASCII 时会静默执行 0 个测试**（假绿）。已在 `install-validation.bats` 加 ASCII 守护。新增 `@test` 名务必全 ASCII。
4. **本仓库不跟踪 `pnpm-lock.yaml`** → 任何 lock-diff 类 CI 步骤都是空转。改为校验 lock 非空才是真门禁。
5. **shellcheck SC2034**：`for i in $(seq ...)` 中 `i` 未使用时改写作 `_`。

## daemon 安全模型（勿回退）
- CSRF：Origin / Host 头**精确匹配**，防跨站与 DNS rebinding。
- Cookie：必须精确匹配 `dsh-auth=` 名，不可用 `strncmp(ck, "dsh-auth", 8)`（会放行 `dsh-auth-evil`）。
- 请求头：必须循环 recv 至 `\r\n\r\n`，一次性 recv 遇分片会误判 403。
- token 嵌 JSON：先过 `token_json_safe()` 字符集校验。
