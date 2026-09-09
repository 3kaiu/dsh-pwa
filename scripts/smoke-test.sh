#!/usr/bin/env bash
set -euo pipefail
# 一键安装冒烟:隔离目录真实执行 install.sh(上游最新 node LTS + 官方 dsh),
# 完整走 install → 幂等重跑 → 守护(引导页/唤醒/透传/空闲自停)。
# 用法: bash scripts/smoke-test.sh [install.sh 路径]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${1:-$ROOT/scripts/install.sh}"
[ -f "$INSTALL" ] || { echo "找不到 install.sh" >&2; exit 1; }
SMOKE_ROOT="${SMOKE_ROOT:-$(mktemp -d /tmp/dsh-install-smoke.XXXXXX)}"
SMOKE_PORT="${SMOKE_PORT:-13980}"
export DSH_RT_HOME="$SMOKE_ROOT/rt" DSH_RT_STATE="$SMOKE_ROOT/state"
export DSH_HOME="$SMOKE_ROOT/home" DSH_RT_PORT="$SMOKE_PORT" DSH_INSTALL_NO_AGENT=1
RT_HOME="$DSH_RT_HOME"; RT_STATE="$DSH_RT_STATE"
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

step "1/4 install(真实安装:node 最新 LTS + dsh latest)"
bash "$INSTALL" || fail "install"
[ -x "$RT_HOME/daemon" ] || fail "daemon 未安装"
[ -f "$SMOKE_ROOT/rt/run.json" ] || fail "run.json 缺失"
grep -q '"node"' "$SMOKE_ROOT/rt/run.json" || fail "run.json 缺 node"
grep -q '"dsh"' "$SMOKE_ROOT/rt/run.json" || fail "run.json 缺 dsh"

step "2/4 幂等重跑(已装同版应秒过)"
time bash "$INSTALL" || fail "重跑 install"

step "3/4 守护:引导页/自动唤醒/就绪门控/透传"
DSH_RT_IDLE_STOP_SECS=3 "$RT_HOME/daemon" >"$SMOKE_ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
trap 'kill "$DAEMON_PID" 2>/dev/null || true' EXIT
# 梯度探测:前 10 次 500ms(快速启动),10-60 次 1s(正常),60+ 次 2s(慢启动)
for i in $(seq 1 10); do
  curl -fsS -o /dev/null "http://127.0.0.1:$SMOKE_PORT/health" 2>/dev/null && break
  sleep 0.5
done
# GET / 返回引导页,同时已自动拉起 dsh(无需引导页 JS 的 /wake 往返)
curl -fsS "http://127.0.0.1:$SMOKE_PORT/" | grep -q "DeepSeek Harness" || fail "引导页异常"
curl -fsS "http://127.0.0.1:$SMOKE_PORT/manifest.webmanifest" | grep -q '"display"' || fail "manifest 异常"
# /health 报"就绪"(能服务 HTTP)而非"进程活着":启动窗口内必须为 false,
# 引导页才不会过早切换(即 PWA 点开空白的根因)
h="$(curl -fsS "http://127.0.0.1:$SMOKE_PORT/health")"
echo "$h" | grep -q '"dsh":false' || fail "dsh 刚拉起时尚未就绪,health 不应为 true: $h"
# 梯度等待 dsh 就绪:前 10 次 500ms,后 50 次 1s,再后 120 次 2s(总计 3 分钟)
for i in $(seq 1 10); do
  curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' && break
  sleep 0.5
done
curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' && { echo "  快速启动(${i}次探测,前10次500ms)"; } || {
  for i in $(seq 11 60); do
    curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' && break
    sleep 1
  done
  curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' && { echo "  正常启动(${i}次探测,11-60次1s)"; } || {
    for i in $(seq 61 180); do
      curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' && break
      sleep 2
    done
  }
}
curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' || fail "自动唤醒后 dsh 未就绪"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/")"
[ "$code" = "200" ] || fail "透传 UI 返回 $code"
echo "OK: 引导页 + 自动唤醒 + 就绪门控 + 透传通过"

step "3b/4 并发双 /wake 幂等(只允许 1 个 dsh 实例)"
curl -fsS -X POST -H "Origin: http://127.0.0.1:$SMOKE_PORT" "http://127.0.0.1:$SMOKE_PORT/stop" >/dev/null || fail "/stop"
for i in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":false' && break
  sleep 1
done
( curl -fsS -X POST -H "Origin: http://127.0.0.1:$SMOKE_PORT" "http://127.0.0.1:$SMOKE_PORT/wake" >/dev/null &   curl -fsS -X POST -H "Origin: http://127.0.0.1:$SMOKE_PORT" "http://127.0.0.1:$SMOKE_PORT/wake" >/dev/null & wait )
# 梯度等待:前 10 次 500ms,后 50 次 1s,再后 120 次 2s
for i in $(seq 1 10); do
  curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' && break
  sleep 0.5
done
curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' || {
  for i in $(seq 11 60); do
    curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' && break
    sleep 1
  done
  curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' || {
    for i in $(seq 61 180); do
      curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' && break
      sleep 2
    done
  }
}
curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":true' || fail "双唤醒后 dsh 未就绪"
if ps -ax -o command >/dev/null 2>&1; then
  n="$(ps -ax -o command | grep "[b]in\.js web" | grep -c "$SMOKE_ROOT" || true)"
  [ "$n" = "1" ] || fail "并发双 /wake 产生了 $n 个 dsh 实例(应为 1,孤儿泄漏)"
  echo "OK: 恰 1 个 dsh 实例(无孤儿)"
else
  echo "  (ps 不可用,跳过进程计数检查)"
fi

# P2-8: 验证 token 相关日志(未来 dsh 再改鉴权能早发现)
if grep -q "token" "$SMOKE_ROOT/daemon.log" 2>/dev/null; then
  echo "  (注意: daemon.log 中出现 'token' 字样,可能 dsh 已引入新鉴权机制)"
fi

step "4/4 空闲自停(PWA 关闭即停止 dsh,DSH_RT_IDLE_STOP_SECS=3)"
sleep 8
curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q '"dsh":false' || fail "空闲后 dsh 未自动停止"
echo "OK: 空闲自停通过"
kill "$DAEMON_PID" 2>/dev/null || true
echo; echo "SMOKE OK (root=$SMOKE_ROOT)"