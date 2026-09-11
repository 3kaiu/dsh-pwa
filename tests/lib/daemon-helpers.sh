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
