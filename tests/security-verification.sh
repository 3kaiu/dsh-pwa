#!/usr/bin/env bash
# 安全修复验证测试套件
# 验证所有已实施的安全控制是否按预期工作
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0

# 公共 helper:daemon_compile / daemon_start_foreground / daemon_wait_health / daemon_stop
# shellcheck source=/dev/null
source "$ROOT/tests/lib/daemon-helpers.sh"

# 回环请求约定:所有访问 127.0.0.1 的 curl 都带 --max-time + --noproxy '*'(理由同 smoke-test.sh):
#   --max-time:守护「已 bind 未 listen」时 macOS 丢弃 SYN,无超时的 curl 会挂到作业级 30min 超时;
#   --noproxy:curl 默认把 127.0.0.1 交给 http_proxy,「守护已死」会返回代理的 502 而非连接拒绝。
# 本节断言比对精确状态码,故失败时 HTTP_CODE 的取值必须可信:
#   000 = 连不上 / 挂满超时(真实失败); 502 = 请求被代理拦截(环境问题,非守护行为)。
# 另注:本脚本 set -e,`X=$(curl ...)` 未加 `|| true` 时 curl 失败会直接终止整个脚本
# (后面的用例不再执行、守护也不会被 daemon_stop 清理),故赋值一律带 `|| true`,由断言报错。

# 颜色输出
if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; RST=$'\033[0m'
else
  G=""; R=""; B=""; D=""; RST=""
fi

ok()   { echo "  ${G}✓${RST} $*"; ((PASS++)) || true; }
fail() { echo "  ${R}✗${RST} $*"; ((FAIL++)) || true; }
info() { echo "  ${D}$*${RST}"; }
h1()   { echo; echo "${B}$*${RST}"; }

cd "$ROOT"

h1 "1. 供应链完整性验证"

# 1.1 检查 release.yml 是否生成 SHA256
info "检查 CI 是否生成 SHA256 校验和..."
if grep -q "shasum -a 256 dsh-pwa.zip > dsh-pwa.zip.sha256" .github/workflows/release.yml; then
  ok "Release workflow 生成 SHA256 校验和"
else
  fail "Release workflow 缺少 SHA256 生成步骤"
fi

# 1.2 检查 release.yml 是否上传 SHA256
if grep "gh release" .github/workflows/release.yml | grep -q "dsh-pwa.zip.sha256"; then
  ok "Release workflow 上传 SHA256 文件"
else
  fail "Release workflow 未上传 SHA256 文件"
fi

# 1.3 检查 install.sh 是否验证 SHA256
# 断言必须锚定**实现**,不能锚定解释性注释。旧写法是
#   grep -q "shasum -a 256 -c pkg.zip.sha256" scripts/install.sh
# 而该字符串**只**出现在 install.sh 里那句「而不是 shasum -a 256 -c …」的说明性注释中
# (解释为什么不用 shasum -c);真实实现是 EXPECTED_SHA/ACTUAL_SHA 裸哈希比对。
# 双向都坏:删掉实现只留注释,本断言照样 ok(假绿);有人清理掉那句「不该做什么」的注释,
# 门禁反而变红(误报)。这里改为锚定实现标识符(重命名会被看见,像符号锚点一样)。
# **行为验证**(哈希相符必须放行、不符必须中止)在
# tests/unit/install-validation.bats 的
# "install.sh aborts the install when the release SHA-256 does not match"。
info "检查 install.sh 是否验证 SHA256..."
if grep -qF 'EXPECTED_SHA="$(awk' scripts/install.sh \
   && grep -qF 'ACTUAL_SHA="$(shasum -a 256' scripts/install.sh \
   && grep -qF '"$EXPECTED_SHA" != "$ACTUAL_SHA"' scripts/install.sh; then
  ok "install.sh 验证 SHA256 校验和(裸哈希比对)"
else
  fail "install.sh 缺少 SHA256 验证实现(仅有解释性注释不算)"
fi

# 1.4 检查 install.sh 是否 fail-closed
# 旧写法只要求「文件里出现过 exit 1」—— 全文件有十余处 exit 1,把整段校验逻辑删光也照样绿,
# 对「校验是否 fail-closed」毫无约束。改为锚定**两个**失败分支各自的告警文案:
# 清单缺失 与 哈希不符,两者必须同时存在。
missing_ok=0; mismatch_ok=0
if grep -qF 'warn "SHA256 校验文件缺失' scripts/install.sh; then missing_ok=1; fi
if grep -qF 'warn "发行包 SHA-256 校验失败' scripts/install.sh; then mismatch_ok=1; fi
if [ "$missing_ok" = "1" ] && [ "$mismatch_ok" = "1" ]; then
  ok "install.sh 使用 fail-closed 策略(清单缺失 + 哈希不符两分支)"
else
  fail "install.sh 未使用 fail-closed 策略(缺失分支=$missing_ok 不符分支=$mismatch_ok)"
fi

# 1.5 检查版本固定支持
if grep -q 'RELEASE_TAG="${DSH_RT_RELEASE_TAG:-latest}"' scripts/install.sh; then
  ok "install.sh 支持版本固定(DSH_RT_RELEASE_TAG)"
else
  fail "install.sh 不支持版本固定"
fi

# 1.6 检查 universal binary
if grep -q -- "-arch arm64 -arch x86_64" .github/workflows/release.yml; then
  ok "Release workflow 构建 universal binary"
else
  fail "Release workflow 仅构建单架构二进制"
fi

h1 "2. CSRF 防护验证"

# 2.1 运行时验证 - 启动临时 daemon 测试 CSRF
info "启动临时 daemon 进行运行时 CSRF 测试..."
# 测试期绝不触发后台更新子进程(与 tests/unit/daemon-cases.bats 同一约定)。
# 守护每次启动都会 fork 一个 setsid 的更新检查子进程,它先 sleep(10) 再 exec update-dsh.sh;
# 在那 10s 里它是**同名的 daemon 进程**且自成会话 —— 杀掉父守护不会杀掉它。套件跑得够久时
# 它会自己走到 exec(改名 bash)再退出,所以只是隐患;但短作业(见 ci-enhanced.yml 性能基准)
# 就会在 job 收尾时被抓成 orphan。另外它会在测试中途去动安装目录,与本套件互相干扰。
export DSH_RT_NO_AUTO_UPDATE=1
TMPD="$(mktemp -d)"
TEST_PORT=$((30000 + RANDOM % 10000))

# 收尾:停掉本脚本启动的守护 + 清掉全部临时目录。
# 必须注册在**第一个临时目录创建之后**,否则早期失败路径(daemon_compile 失败等)不受保护;
# 旧实现把 trap 挂在第 7 节(脚本末尾),前面 300 行全在保护之外,且只删了**当时那个** TMPD
# —— `TMPD_PERM` 从不清理,守护更是从不停。
# 停守护**同时按 pid 与按二进制路径**:实测 `$!` 未必就是最终在 listen 的进程(见
# daemon-helpers.sh 中 daemon_stop_by_binary 的注释),只按 pid 会漏,泄漏的守护要等到
# 空闲自停(默认 30s)才消失 —— 在 CI 里就表现为作业结束时 runner 报
# `Terminate orphan process: pid (…) (daemon)`。
cleanup_all() {
  daemon_stop "${DAEMON_PID:-}" 2>/dev/null || true
  daemon_stop "${PERM_PID:-}" 2>/dev/null || true
  [ -z "${TMPD:-}" ] || daemon_stop_by_binary "$TMPD/daemon"
  [ -z "${TMPD_PERM:-}" ] || daemon_stop_by_binary "$TMPD_PERM/daemon"
  [ -z "${TMPD_BUILD:-}" ] || daemon_stop_by_binary "$TMPD_BUILD/daemon"
  [ -z "${TMPD:-}" ] || rm -rf "$TMPD"
  [ -z "${TMPD_PERM:-}" ] || rm -rf "$TMPD_PERM"
  [ -z "${TMPD_BUILD:-}" ] || rm -rf "$TMPD_BUILD"
  return 0
}
trap cleanup_all EXIT

# 编译并启动 daemon
if daemon_compile "$TMPD/daemon" -arch arm64 -arch x86_64; then
  # 准备最小运行环境
  mkdir -p "$TMPD/rt" "$TMPD/state/logs" "$TMPD/home"
  echo '{"node":"/usr/bin/node","dsh":"/usr/bin/true"}' > "$TMPD/rt/run.json"
  
  # 后台启动 daemon
  export DSH_RT_HOME="$TMPD/rt" DSH_RT_STATE="$TMPD/state" DSH_HOME="$TMPD/home" DSH_RT_PORT="$TEST_PORT"
  DAEMON_PID="$(daemon_start_foreground "$TMPD/daemon" "$TMPD/daemon.log")"
  
  # 等待 daemon 就绪(梯度退避,6s 上限)
  if daemon_wait_health "$TEST_PORT" any 6; then
  # 测试1: 缺少 Origin 应返回 403
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' -X POST "http://127.0.0.1:$TEST_PORT/wake" 2>/dev/null || true)
  if [ "$HTTP_CODE" = "403" ]; then
    ok "CSRF 运行时：无 Origin 返回 403"
  else
    fail "CSRF 运行时：无 Origin 应返回 403，实际返回 $HTTP_CODE"
  fi
  
  # 测试2: 错误端口应返回 403（端口严格校验）
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' -X POST \
    -H "Origin: http://127.0.0.1:$((TEST_PORT + 1))" \
    "http://127.0.0.1:$TEST_PORT/wake" 2>/dev/null || true)
  if [ "$HTTP_CODE" = "403" ]; then
    ok "CSRF 运行时：错误端口返回 403（端口严格校验）"
  else
    fail "CSRF 运行时：错误端口应返回 403，实际返回 $HTTP_CODE"
  fi
  
  # 测试3: 正确 Origin 应返回 200
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' -X POST \
    -H "Origin: http://127.0.0.1:$TEST_PORT" \
    "http://127.0.0.1:$TEST_PORT/wake" 2>/dev/null || true)
  if [ "$HTTP_CODE" = "200" ]; then
    ok "CSRF 运行时：正确 Origin 返回 200"
  else
    fail "CSRF 运行时：正确 Origin 应返回 200，实际返回 $HTTP_CODE"
  fi

  # 测试4: 恶意 Host(DNS rebinding 模拟)应返回 403
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' \
    -H "Host: evil.com" \
    "http://127.0.0.1:$TEST_PORT/health" 2>/dev/null || true)
  if [ "$HTTP_CODE" = "403" ]; then
    ok "Host 校验：恶意 Host(evil.com)返回 403"
  else
    fail "Host 校验：恶意 Host 应返回 403，实际返回 $HTTP_CODE"
  fi

  # 测试5: 正常 Host(127.0.0.1:PORT)应返回 200
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' \
    "http://127.0.0.1:$TEST_PORT/health" 2>/dev/null || true)
  if [ "$HTTP_CODE" = "200" ]; then
    ok "Host 校验：正常 Host(127.0.0.1:$TEST_PORT)返回 200"
  else
    fail "Host 校验：正常 Host 应返回 200，实际返回 $HTTP_CODE"
  fi
  else
    fail "daemon 未就绪，跳过运行时 CSRF 测试"
  fi
  
  # 清理
  daemon_stop "$DAEMON_PID"
  rm -rf "$TMPD"
else
  fail "daemon 编译失败，跳过运行时 CSRF 测试"
  rm -rf "$TMPD"
fi

# 2.4 代码静态检查
info "检查 daemon.c CSRF 防护代码..."
if grep -q "CSRF 防护" src/daemon.c && grep -q 'find_header(buf, "Origin")' src/daemon.c; then
  ok "daemon.c 包含 CSRF 防护逻辑"
else
  fail "daemon.c 缺少 CSRF 防护"
fi

# 2.5 检查端口严格校验
if grep -q "origin_ok" src/daemon.c && grep -q "snprintf.*http://127.0.0.1:%d" src/daemon.c; then
  ok "daemon.c 实现端口严格校验"
else
  fail "daemon.c 缺少端口严格校验"
fi

# 2.6 检查 Host 校验(DNS rebinding 防护)
if grep -q "host_ok" src/daemon.c && grep -q "snprintf.*127.0.0.1:%d" src/daemon.c; then
  ok "daemon.c 实现 Host 校验(防 DNS rebinding)"
else
  fail "daemon.c 缺少 Host 校验"
fi

h1 "3. 文件权限安全"

# 3.1 检查日志文件权限
info "检查日志文件权限设置..."
if grep -q "open(LOG_FILE.*0600" src/daemon.c; then
  ok "dsh.log 使用 0600 权限"
else
  fail "dsh.log 未使用安全权限"
fi

# 3.2 检查日志目录权限
if grep -q "mkdir(LOG_DIR, 0700)" src/daemon.c; then
  ok "LOG_DIR 使用 0700 权限"
else
  fail "LOG_DIR 未使用安全权限"
fi

# 3.3 检查状态文件权限
if grep -q 'write_file_atomic(DSH_JSON' src/daemon.c && grep -q 'write_file_atomic(PID_FILE' src/daemon.c && grep -q "open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600)" src/daemon.c; then
  ok "状态文件(dsh.json, dsh.pid)使用 0600 权限"
else
  fail "状态文件未使用安全权限"
fi

# 3.4 install.sh 必须显式收紧 RT_STATE/LOG_DIR 权限
# (umask 022 下 mkdir -p 建出 0755,且对已存在目录不生效;daemon 的 mkdir(LOG_DIR,0700)
#  对已存在目录静默失败 → 仅靠源码里的 mkdir 调用会产生"假绿",install 侧需 chmod 兜底)
if grep -q 'chmod 0700 "$RT_STATE" "$LOG_DIR"' scripts/install.sh; then
  ok "install.sh 显式 chmod 0700 RT_STATE/LOG_DIR(含存量目录)"
else
  fail "install.sh 未显式收紧 RT_STATE/LOG_DIR 权限"
fi

# 3.5 运行时验证:daemon 自建 LOG_DIR 的真实权限必须为 0700(不再只 grep 源码)
info "运行时验证 LOG_DIR 真实权限(daemon 前台启动自建目录)..."
TMPD_PERM="$(mktemp -d)"
if daemon_compile "$TMPD_PERM/daemon"; then
  mkdir -p "$TMPD_PERM/rt" "$TMPD_PERM/state" "$TMPD_PERM/home"
  echo '{"node":"/usr/bin/true","dsh":"/usr/bin/true"}' > "$TMPD_PERM/rt/run.json"
  # 不预建 logs:让 daemon 自己 mkdir(LOG_DIR, 0700),验证真实落盘权限
  export DSH_RT_HOME="$TMPD_PERM/rt" DSH_RT_STATE="$TMPD_PERM/state" DSH_HOME="$TMPD_PERM/home"
  export DSH_RT_PORT="$((30000 + RANDOM % 10000))"
  PERM_PID="$(daemon_start_foreground "$TMPD_PERM/daemon" /dev/null)"
  for _ in $(seq 1 20); do [ -d "$TMPD_PERM/state/logs" ] && break; sleep 0.2; done
  PERM_MODE="$(stat -f %Lp "$TMPD_PERM/state/logs" 2>/dev/null || true)"
  if [ "$PERM_MODE" = "700" ]; then
    ok "运行时 LOG_DIR 真实权限为 0700"
  else
    fail "运行时 LOG_DIR 权限为 ${PERM_MODE:-缺失}(应为 700,含 token 的日志可被本机其他用户枚举)"
  fi
  daemon_stop "$PERM_PID"
  rm -rf "$TMPD_PERM"
else
  fail "daemon 编译失败,无法运行时验证 LOG_DIR 权限"
  rm -rf "$TMPD_PERM"
fi

# 3.6 端口被占时 install.sh 必须显式失败(而非 launchd bind 失败后静默失效)
if grep -q 'exec 3<>"/dev/tcp/127.0.0.1/$PORT"' scripts/install.sh && \
   grep -q "DSH_RT_PORT=<空闲端口>" scripts/install.sh; then
  ok "install.sh 检测端口占用并显式报错(bootout 之后、bootstrap 之前)"
else
  fail "install.sh 未检测端口占用"
fi

h1 "4. 端口分配安全"

# 4.1 检查端口验证
info "检查端口验证逻辑..."
if grep -q "1024.*65535" scripts/install.sh; then
  ok "install.sh 验证端口范围(1024-65535)"
else
  fail "install.sh 未验证端口范围"
fi

# 4.2 检查 daemon.c 端口验证
if grep -q "parsed >= 1024 && parsed <= 65535" src/daemon.c; then
  ok "daemon.c 验证端口范围"
else
  fail "daemon.c 未验证端口范围"
fi

# 4.3 检查端口预留机制(断言**机制与时序**,不是函数名存在)
# 旧写法 `grep -q "pick_port_fd"` 只证明「函数名出现过」,删掉函数体只留名字照样绿;
# 文案还停在**已撤回的结论**上 —— E5(5503968)已把 pick_port_fd 的头注释按实现改写为
# 「保持 bind 但未 listen 的 fd:只缩小窗口,非互斥,审计 E5」,断言却说「消除 TOCTOU」。
# 改为断言两条真实机制:
#   (a) 预留 = bind 后**不** listen 的占位 socket —— 若加了 listen,dsh 自己 bind 同端口必失败;
#   (b) 释放(close(reserve_fd))必须**早于** execl —— 即窗口收窄而非互斥。
# 抽取按**符号名 + 花括号配平**定位(helper `extract_fn`,见 tests/lib/daemon-helpers.sh);
# 旧写法 `sed -n '/^static int pick_port_fd/,/^}/p'` 的终点是「第一行列 0 的 }」,函数体内
# 一旦出现列 0 的 } 就被静默截断(审计 F10)。三层判据依次是:
#   「抽到没有」→「长度够不够(下界,兜住截断)」→「机制对不对」,
# 三种失败给出**不同**的文案,便于一眼归因。
pick_fn="$(extract_fn pick_port_fd)"
spawn_fn="$(extract_fn spawn_dsh)"
if [ -z "$pick_fn" ] || [ -z "$spawn_fn" ]; then
  fail "未能定位端口预留相关函数(源码抽取为空,断言失效)"
elif [ "$(printf '%s\n' "$pick_fn" | wc -l)" -lt 6 ] || [ "$(printf '%s\n' "$spawn_fn" | wc -l)" -lt 20 ]; then
  fail "端口预留函数抽取过短(疑似被截断,断言不可信)"
elif printf '%s\n' "$pick_fn" | grep -q 'listen('; then
  fail "pick_port_fd 对预留 socket 调用了 listen(dsh 将无法 bind 同一端口)"
elif ! printf '%s\n' "$pick_fn" | grep -q 'bind(s'; then
  fail "pick_port_fd 未先 bind 占位,端口预留机制缺失"
elif printf '%s\n' "$spawn_fn" | awk '
      # 取「最后一次 close(reserve_fd)」与「第一次 execl」比:任何一次释放晚于 exec
      # 都会让预留 fd 泄漏进 dsh —— dsh 自己 bind 同端口会 EADDRINUSE,唤醒直接失败。
      /execl\(/            { if (!e) e = NR }
      /close\(reserve_fd\)/ { c = NR }
      END {
        if (!e || !c) exit 1   # 抽取失效(没找到 exec 或没找到释放)
        exit (c < e) ? 0 : 1
      }'; then
  ok "端口预留:先 bind 占位、spawn 前释放(窗口收窄,非互斥)"
else
  fail "预留 socket 的释放未早于 execl(时序退化,窗口被放大)"
fi

# 4.4 检查 reserve_fd 使用
if grep -q "int reserve_fd = pick_port_fd" src/daemon.c && grep -q "close(reserve_fd)" src/daemon.c; then
  ok "daemon.c 正确管理端口预留 socket"
else
  fail "daemon.c 端口预留实现不完整"
fi

h1 "5. HTTP 就绪探测强化"

# 5.1 检查探测超时
info "检查 HTTP 探测超时配置..."
if grep -q "struct timeval tv = { 3, 0 }" src/daemon.c; then
  ok "HTTP 探测超时增至 3 秒"
else
  fail "HTTP 探测超时仍为 1 秒"
fi

# 5.2 检查协议版本验证
if grep -q 'strncmp(b, "HTTP/1.", 7)' src/daemon.c; then
  ok "HTTP 探测验证协议版本(HTTP/1.x)"
else
  fail "HTTP 探测未验证协议版本"
fi

# 5.3 检查缓冲区大小
# 旧写法 else 走 info:该断言在**任何情况下**都不会让套件变红,却仍占着「33 项测试」的名额
# (TRAPS §一.5「失败只 warn 不阻断 = 空转门禁」)。探测缓冲过小会让响应头被静默截断,
# 与「截断必须可观测」相悖,是真实安全属性 → 改 fail。
# 抽取改用符号锚点 + 花括号配平(旧 `sed` 行范围会被函数体内列 0 的 `}` 静默截断,审计 F10);
# 三层判据「抽到没有 → 长度够不够 → 容量对不对」各给不同文案。
probe_fn="$(extract_fn http_probe)"
if [ -z "$probe_fn" ]; then
  fail "未能定位 http_probe 函数(源码抽取为空,断言失效)"
elif [ "$(printf '%s\n' "$probe_fn" | wc -l)" -lt 10 ]; then
  fail "http_probe 抽取过短(疑似被截断,断言不可信)"
elif printf '%s\n' "$probe_fn" | grep -q 'char b\[512\]'; then
  ok "HTTP 探测使用足够大的缓冲区(512 字节)"
else
  fail "HTTP 探测缓冲区不足 512 字节(响应头可能被静默截断)"
fi

h1 "6. 低风险问题修复"

# 6.1 检查 PID 验证
# 旧写法 `sed -n '/^static void stop_dsh/,/^}/p'` 的起点正则**同时匹配** `stop_dsh_wait`,
# 于是实际抽到的是 stop_dsh_wait 的函数体 —— 断言「通过」是因为它测的是**另一个函数**;
# 而 F5 把 stop_dsh 改成一行委托后,stop_dsh 自身已不含任何 kill 调用。这是 F10 所说的
# 「结论与真实结构无关」的活样本。改为按符号精确抽取**真正承载该逻辑的函数**。
info "检查停机路径是否验证 PID..."
stop_fn="$(extract_fn stop_dsh_wait)"
if [ -z "$stop_fn" ]; then
  fail "未能定位 stop_dsh_wait(源码抽取为空,断言失效)"
elif [ "$(printf '%s\n' "$stop_fn" | wc -l)" -lt 20 ]; then
  fail "stop_dsh_wait 抽取过短(疑似被截断,断言不可信)"
elif printf '%s\n' "$stop_fn" | grep -q 'kill(pid, 0)'; then
  ok "停机路径在发信号前用 kill(pid,0) 验证 PID 存在"
else
  fail "停机路径未在发信号前验证 PID 存在性"
fi

# 6.2 检查 HTML 转义
# 旧写法 `grep -q "HTML 转义" || grep -q "&lt;"`:第一个分支命中的是**解释性注释**
# (daemon.c 里「HTML 转义(防路径注入…)」那行),删掉实现只留注释照样绿(TRAPS §一.20 探针污染);
# 第二个分支只证明「文件某处出现过 &lt;」,与 LOG_DIR 是否被转义无关。else 又走 info 永不失败。
# 改为锚定实现:build_boot 必须**实际调用** html_escape 处理 LOG_DIR,且三个映射齐全。
if grep -qF 'html_escape(LOG_DIR, esc, sizeof esc)' src/daemon.c \
   && grep -qF '"&lt;"' src/daemon.c \
   && grep -qF '"&amp;"' src/daemon.c \
   && grep -qF '"&quot;"' src/daemon.c; then
  ok "build_boot 对 LOG_DIR 调用 html_escape 且 < & \" 映射齐全"
else
  fail "build_boot 未对 LOG_DIR 做完整 HTML 转义(路径注入防御缺失)"
fi

# 6.3 检查 JSON 转义处理
# 旧写法 `grep -q "反转义" || grep -q '\\\\'`:第一个分支命中的同样是注释
# (「简单的反转义:只处理 \\ 和 \"」),第二个分支过宽。else 又走 info 永不失败。
# 改为锚定 extract_str 里真实的反转义分支:\\\\ 与 \" 成对还原。
if grep -qF "q[i] == '\\\\' && i + 1 < l" src/daemon.c \
   && grep -qF "(q[i+1] == '\\\\' || q[i+1] == '\"')" src/daemon.c; then
  ok "extract_str 对 \\\\ 与 \" 成对反转义"
else
  fail "extract_str 未处理 JSON 转义(含转义的路径会被错误解析)"
fi

h1 "7. 编译测试"

# 7.1 编译 daemon.c
info "编译 daemon.c(universal binary)..."
# 用独立变量,不复用 TMPD:复用会让 cleanup_all 只记得最后一个目录,前面那个被覆盖后
# 再无引用(旧实现正是如此)。两个目录都由 cleanup_all 统一清。
TMPD_BUILD="$(mktemp -d)"

if daemon_compile "$TMPD_BUILD/daemon" -arch arm64 -arch x86_64; then
  ok "daemon.c 编译成功(无警告)"
else
  fail "daemon.c 编译失败"
fi

# 7.2 检查二进制架构
if [ -f "$TMPD_BUILD/daemon" ]; then
  FILE_OUT=$(file "$TMPD_BUILD/daemon")
  if echo "$FILE_OUT" | grep -q "universal binary" && \
     echo "$FILE_OUT" | grep -q "x86_64" && \
     echo "$FILE_OUT" | grep -q "arm64"; then
    ok "daemon 包含 2 个架构(arm64 + x86_64)"
  else
    fail "daemon 不是 universal binary: $FILE_OUT"
  fi
fi

# 7.3 检查符号表清理
# 旧写法 else 走 info:体积暴涨(误带调试符号 / 误嵌资产)永远不会让套件变红 → 改 fail。
# 阈值 150000 是「双架构 + 内嵌引导页」的合理上界(实测约 120KB);真的合理增长时应当
# **显式上调阈值**并说明原因,而不是靠 info 静默放过。
if [ -f "$TMPD_BUILD/daemon" ]; then
  SIZE=$(stat -f%z "$TMPD_BUILD/daemon")
  if [ "$SIZE" -lt 150000 ]; then
    ok "daemon 二进制大小合理($SIZE 字节)"
  else
    fail "daemon 二进制过大($SIZE 字节 ≥ 150000,疑似误带调试符号)"
  fi
fi

h1 "测试总结"
echo
# 反空转(TRAPS §一.16):只断言 `FAIL=0` 会被「一条都没跑到」满足 —— 脚本若在早期被
# `set -e` 掐断,或某个 if 分支整段没进,PASS 会**静默变小**而仍然 exit 0(且最后一行
# 照样打印「全部通过」)。故给 PASS 设下界,并在失败信息里打印实际值。
# 下界随用例增减**人工上调**(新增断言后忘了调大只是少一层保护,不会误报)。
PASS_MIN=33
if [ "$FAIL" != "0" ]; then
  echo "${R}${B}✗ 发现问题${RST} (${G}$PASS 通过${RST}, ${R}$FAIL 失败${RST})"
  exit 1
fi
if [ "$PASS" -lt "$PASS_MIN" ]; then
  echo "${R}${B}✗ 断言数不足${RST} (${G}$PASS 通过${RST} < 下界 $PASS_MIN —— 有断言被静默跳过?)"
  exit 1
fi
echo "${G}${B}✓ 全部通过${RST} ($PASS 项测试)"
exit 0
