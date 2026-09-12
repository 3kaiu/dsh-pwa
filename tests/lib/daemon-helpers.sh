#!/usr/bin/env bash
# tests/lib/daemon-helpers.sh —— 守护进程测试公共 helper
#
# 供以下脚本 source,消除「编译 daemon + 前台起 daemon + 轮询 health + 杀 daemon」的重复:
#   - scripts/smoke-test.sh
#   - tests/security-verification.sh
#   - tests/unit/daemon-cases.bats
#   - tests/auto-update-verify.sh(仅用 pick_free_port)
#
# 约定(与 daemon 读取一致的环境变量,由调用方 export):
#   DSH_RT_HOME / DSH_RT_STATE / DSH_HOME / DSH_RT_PORT
# 兼容 bash 3.2(macOS 自带)+ bats 1.14;函数内部自防御 set -u,不依赖调用方选项。

DSH_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DSH_DAEMON_SRC="${DSH_DAEMON_SRC:-$DSH_TEST_ROOT/src/daemon.c}"

# pick_free_port
# 挑一个当前空闲的回环端口(bind port 0 由内核分配,随即释放):降低与残留监听进程冲突的概率。
# 窗口期内仍可能被抢占(探测与使用之间非原子),但显著优于纯随机;python3 不可用时回退随机。
pick_free_port() {
  local py=""
  py="$(command -v python3 || true)"
  if [ -n "$py" ]; then
    "$py" -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()' && return 0
  fi
  echo $(( (RANDOM % 20000) + 20000 ))
}

# daemon_compile <输出路径> [clang 额外参数...]
# 编译 src/daemon.c(-O2 -Wall -Wextra -Werror);成功静默,失败打印编译日志并返回非零。
daemon_compile() {
  local out="${1:-}" log=""
  if [ -z "$out" ]; then
    echo "daemon_compile: 缺少输出路径" >&2
    return 1
  fi
  shift
  log="${out}.compile.log"
  if clang -O2 -Wall -Wextra -Werror "$@" -o "$out" "$DSH_DAEMON_SRC" 2>"$log"; then
    rm -f "$log"
    return 0
  fi
  cat "$log" >&2 || true
  rm -f "$log"
  return 1
}

# daemon_start_foreground <daemon 二进制> [日志路径,默认 /dev/null]
# 前台(后台 job)起 daemon,stdout/stderr 重定向到日志,echo 进程 PID。
daemon_start_foreground() {
  local bin="${1:-}" log="${2:-/dev/null}"
  if [ -z "$bin" ]; then
    echo "daemon_start_foreground: 缺少二进制路径" >&2
    return 1
  fi
  "$bin" >"$log" 2>&1 &
  echo $!
}

# daemon_wait_health <端口> [期望: any|true|false,默认 any] [超时秒,默认 5] [打印梯度档位 0|1,默认 0]
# 梯度退避:前 10 次 0.5s → 50 次 1s → 其余 2s;条件满足返回 0,超时返回 1。
#   any   = /health 返回 200(daemon 能服务 HTTP)
#   true  = 响应体含 "dsh":true(dsh 已就绪)
#   false = 响应体含 "dsh":false(dsh 未运行)
daemon_wait_health() {
  local port="${1:-}" want="${2:-any}" tmo="${3:-5}" tier="${4:-0}"
  local h="" n=0 start="" dead=""
  if [ -z "$port" ]; then
    echo "daemon_wait_health: 缺少端口" >&2
    return 1
  fi
  start="$(date +%s)"
  dead=$((start + tmo))
  while :; do
    n=$((n + 1))
    # 回环请求必须绕过代理:curl 默认把 127.0.0.1 交给 http_proxy。带 -f 时代理的 502
    # 会让 curl 非零退出且不输出 body → h 恒为空 → 本函数会一直重试到超时,把「守护已就绪」
    # 误报成「未就绪」(在设了 http_proxy 的机器上就是稳定的假失败)。与 smoke-test.sh 同约定。
    h="$(curl -fsS --max-time 2 --noproxy '*' "http://127.0.0.1:$port/health" 2>/dev/null || true)"
    if [ -n "$h" ]; then
      case "$want" in
        any)
          return 0
          ;;
        true)
          if printf '%s' "$h" | grep -q '"dsh":true'; then
            if [ "$tier" = "1" ]; then
              if [ "$n" -le 10 ]; then
                echo "  快速启动(${n}次探测,前10次500ms)"
              elif [ "$n" -le 60 ]; then
                echo "  正常启动(${n}次探测,11-60次1s)"
              fi
            fi
            return 0
          fi
          ;;
        false)
          if printf '%s' "$h" | grep -q '"dsh":false'; then
            return 0
          fi
          ;;
      esac
    fi
    [ "$(date +%s)" -ge "$dead" ] && return 1
    if [ "$n" -le 10 ]; then
      sleep 0.5
    elif [ "$n" -le 60 ]; then
      sleep 1
    else
      sleep 2
    fi
  done
}

# daemon_stop <PID>
# 杀 daemon(SIGTERM → 最多 2s → SIGKILL)+ wait 收割 + 清 dsh.json/dsh.pid 残留。
daemon_stop() {
  local pid="${1:-}"
  if [ -z "$pid" ]; then
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [ -n "${DSH_RT_STATE:-}" ]; then
    rm -f "$DSH_RT_STATE/dsh.json" "$DSH_RT_STATE/dsh.pid"
  fi
}

# daemon_stop_by_binary <daemon 二进制路径>
# 按「可执行文件路径」收尾,作为 daemon_stop <PID> 的**兜底**。
#
# 为什么需要兜底:`daemon_start_foreground` 用 `$( ... )` 取 `$!`,而 `$!` 未必就是最终
# 在 listen 的那个进程。实测(2026-09-12,本机 3/3 次复现):`$!`=11765 而实际 LISTEN 的是
# 11780、`$!`=12510 而实际 12516、`$!`=13253 而实际 13259 —— 偏差 4~15 个 pid,
# 于是 `daemon_stop "$!"` 杀掉了**另一个**进程,真正的守护存活到空闲自停(默认 30s)。
# 在 CI 里表现为作业结束时 runner 报 `Terminate orphan process: pid (…) (daemon)`。
#
# 路径来自 `mktemp -d`,每次唯一;`^` 锚定到命令行开头(守护以 "$bin" 直接启动,argv[0]
# 即该路径),故不会误伤测试脚本自身或同机其他进程。
daemon_stop_by_binary() {
  local bin="${1:-}" p="" pat=""
  if [ -z "$bin" ]; then
    return 0
  fi
  pat="^${bin}(\$| )"
  for p in $(pgrep -f "$pat" 2>/dev/null || true); do
    kill "$p" 2>/dev/null || true
  done
  for _ in $(seq 1 20); do
    pgrep -f "$pat" >/dev/null 2>&1 || break
    sleep 0.1
  done
  for p in $(pgrep -f "$pat" 2>/dev/null || true); do
    kill -9 "$p" 2>/dev/null || true
  done
  return 0
}

# extract_fn <函数名> [源文件,默认 $DSH_DAEMON_SRC] [clean|raw,默认 clean]
# 按「符号名 + 花括号配平」抽取一个函数定义,取代 `sed -n '/^static X/,/^}/p'` 行范围抽取。
#
# 为什么不能用行范围(审计 F10):
#   行范围的终点是「第一行以 } 开头的行」。函数体内一旦出现列 0 的 },抽取就被**静默截断**;
#   而起点正则若写得宽(如 `/^static void stop_dsh/`),还会**同时匹配** `stop_dsh_wait` ——
#   于是「通过」是因为测到了**另一个函数**。两种情况下 ok/fail 都与真实结构无关。
#   这与已整治的 `daemon.c:NNN` 行号引用是同一家族:位置描述随编辑漂移且无信号。
#
# **默认输出净代码(clean)**:剥掉 // 行注释、/* */ 块注释与 "…"/'…' 字面量之后的行。
#   理由 —— 断言不得被注释或字符串满足(TRAPS §一.20/§一.24「探针污染」)。若默认给原文,
#   每个调用方都得自己记得再剥一遍,而「忘了剥」正是已经复发过三次的那个 bug。
#   需要看原文(例如失败信息里要打印源码)时显式传 `raw`。
#
# 实现要点:
#   · 花括号只在**净代码**上计数(同上,否则字符串/注释里的 { } 会让配平跑偏);
#   · 定义行判据 = 行首(允许缩进)以 `static` 开头,且含 `<名>( … ) {`
#     —— 要求**开括号与 `{` 同行**。这同时满足三件事:
#       排除调用点(调用形如 `x();`,右括号后不是 `{`);
#       排除声明(以 `;` 结尾,同样没有 `{`);
#       精确匹配名字(`stop_dsh` 因 `[ \t]*(` 紧邻而不会命中 `stop_dsh_wait`),
#       且**单行函数**(`static void stop_dsh(void) { stop_dsh_wait(…); }`)也能抽到
#       —— 早先「该行不含 `;`」的判据会把单行函数整个漏掉。
#     已知限制(写清楚而非假装覆盖):函数签名**跨行**换行时匹配不到 —— 本仓库无此写法。
#   · 未找到函数 → **无输出**。调用方必须先判空:抽取失败必须与「结构合规」可区分
#     (TRAPS §一.16 的下界要求),再叠加一个**刻意宽松**的行数下界兜住截断。
extract_fn() {
  local fn="${1:-}" src="${2:-${DSH_DAEMON_SRC:-}}" mode="${3:-clean}"
  if [ -z "$fn" ] || [ -z "$src" ] || [ ! -f "$src" ]; then
    return 0
  fi
  awk -v fn="$fn" -v mode="$mode" '
    BEGIN { SQ = sprintf("%c", 39) }   # 单引号:awk 程序在 bash 单引号里,不能直接写
    function sanitize(line,   i, c, out) {
      out = ""; i = 1
      while (i <= length(line)) {
        c = substr(line, i, 1)
        if (blk) {                                             # 块注释中
          if (c == "*" && substr(line, i + 1, 1) == "/") { blk = 0; i += 2; continue }
          i++; continue
        }
        if (inq) {                                             # 字面量中
          if (c == "\\") { i += 2; continue }
          if (c == q) { inq = 0 }
          i++; continue
        }
        if (c == "/" && substr(line, i + 1, 1) == "*") { blk = 1; i += 2; continue }
        if (c == "/" && substr(line, i + 1, 1) == "/") { break }   # 行注释到行尾
        if (c == "\"" || c == SQ) { inq = 1; q = c; i++; continue }
        out = out c
        i++
      }
      return out
    }
    {
      clean = sanitize($0)
      if (!started) {
        if (clean ~ ("^[ \t]*static[ \t].*[ \t*]" fn "[ \t]*\\([^;]*\\)[ \t]*\\{")) {
          started = 1
        } else {
          next
        }
      }
      if (mode == "raw") print; else print clean
      o = gsub(/\{/, "", clean)
      c = gsub(/\}/, "", clean)
      depth += o - c
      if (o > 0) opened = 1
      if (opened && depth <= 0) exit
    }
  ' "$src"
}
