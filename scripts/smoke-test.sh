#!/usr/bin/env bash
set -euo pipefail
# 一键安装冒烟:隔离目录真实执行 install.sh(上游最新 node LTS + 官方 dsh),
# 完整走 install → 幂等重跑 → 守护(引导页/唤醒/透传/空闲自停)→ socket activation 端到端。
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
# 测试 helper:daemon_compile / daemon_start_foreground / daemon_wait_health / daemon_stop
# shellcheck source=/dev/null
source "$ROOT/tests/lib/daemon-helpers.sh"

step "1/5 install(真实安装:node 最新 LTS + dsh latest)"
bash "$INSTALL" || fail "install"
[ -x "$RT_HOME/daemon" ] || fail "daemon 未安装"
[ -f "$SMOKE_ROOT/rt/run.json" ] || fail "run.json 缺失"
grep -q '"node"' "$SMOKE_ROOT/rt/run.json" || fail "run.json 缺 node"
grep -q '"dsh"' "$SMOKE_ROOT/rt/run.json" || fail "run.json 缺 dsh"
# P1-3:含 token 的状态/日志目录运行时真实权限必须为 0700(install.sh 显式 chmod)
[ "$(stat -f %Lp "$RT_STATE")" = "700" ] || fail "RT_STATE 权限 $(stat -f %Lp "$RT_STATE"),应为 700"
[ "$(stat -f %Lp "$RT_STATE/logs")" = "700" ] || fail "logs 目录权限 $(stat -f %Lp "$RT_STATE/logs"),应为 700"

step "2/5 幂等重跑(已装同版应秒过)"
time bash "$INSTALL" || fail "重跑 install"

step "2b/5 端口被占时 install 应显式失败(而非静默失效)"
OCC_DIR="$SMOKE_ROOT/occ"; mkdir -p "$OCC_DIR"
python3 - "$OCC_DIR/port" <<'PY' &
import socket, sys
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
with open(sys.argv[1], "w") as f:
    f.write(str(s.getsockname()[1]))
s.accept()
PY
OCC_PID=$!
for _ in $(seq 1 20); do [ -s "$OCC_DIR/port" ] && break; sleep 0.1; done
[ -s "$OCC_DIR/port" ] || fail "占位监听器未启动"
OCC_PORT="$(cat "$OCC_DIR/port")"
if DSH_RT_PORT="$OCC_PORT" bash "$INSTALL" >"$OCC_DIR/install.log" 2>&1; then
  kill "$OCC_PID" 2>/dev/null || true
  fail "端口被占时 install 未报错(静默失效)"
fi
grep -q "已被占用" "$OCC_DIR/install.log" || fail "端口占用报错信息不清晰: $(tail -3 "$OCC_DIR/install.log")"
kill "$OCC_PID" 2>/dev/null || true
echo "OK: 端口被占时 install 显式报错退出"
# 清理占位后正常重跑,确认冲突场景不破坏后续安装
bash "$INSTALL" >/dev/null 2>&1 || fail "端口冲突测试后正常 install 失败"

step "3/5 守护:引导页/自动唤醒/就绪门控/透传"
export DSH_RT_IDLE_STOP_SECS=3
DAEMON_PID="$(daemon_start_foreground "$RT_HOME/daemon" "$SMOKE_ROOT/daemon.log")"
trap 'daemon_stop "$DAEMON_PID" 2>/dev/null || true' EXIT
# 梯度探测:前 10 次 500ms(快速启动),10-60 次 1s(正常),60+ 次 2s(慢启动)
daemon_wait_health "$SMOKE_PORT" any 5 || fail "daemon 未就绪"
# GET / 返回引导页,同时已自动拉起 dsh(无需引导页 JS 的 /wake 往返)
curl -fsS "http://127.0.0.1:$SMOKE_PORT/" | grep -q "DeepSeek Harness" || fail "引导页异常"
curl -fsS "http://127.0.0.1:$SMOKE_PORT/manifest.webmanifest" | grep -q '"display"' || fail "manifest 异常"
# /health 报"就绪"(能服务 HTTP)而非"进程活着":启动窗口内必须为 false,
# 引导页才不会过早切换(即 PWA 点开空白的根因)
h="$(curl -fsS "http://127.0.0.1:$SMOKE_PORT/health")"
echo "$h" | grep -q '"dsh":false' || fail "dsh 刚拉起时尚未就绪,health 不应为 true: $h"
# 梯度等待 dsh 就绪:前 10 次 500ms,后 50 次 1s,再后 2s(总计约 3 分钟)
daemon_wait_health "$SMOKE_PORT" true 300 1 || fail "自动唤醒后 dsh 未就绪"
# dsh 0.1.5+ 强制 token 鉴权:URL 带 token 换 cookie 后透传才 200(老版本无 token 则直接透传)
# 新行为:就绪判定只看 HTTP 探测(不再等 2s token 宽限),/health 可能先报 dsh:true、
# token 字段稍后才随响应出现 → 轮询等「日志 token」与「/health token」汇合(10s 上限;
# 未汇合且日志也无 token 则按旧版无 token 路径继续)
TOKEN=""
for _ in $(seq 1 20); do
  T="$(grep -o 'token=[A-Za-z0-9_-]*' "$RT_STATE/logs/dsh.log" 2>/dev/null | head -1 | cut -d= -f2 || true)"
  if [ -n "$T" ] && curl -fsS "http://127.0.0.1:$SMOKE_PORT/health" | grep -q "\"token\":\"$T\""; then
    TOKEN="$T"; break
  fi
  sleep 0.5
done
# 回归门:日志里已有 token 但 /health 迟迟不带 → 守护 token 扫描/下发链路坏了,必须报错
LOG_TOK="$(grep -o 'token=[A-Za-z0-9_-]*' "$RT_STATE/logs/dsh.log" 2>/dev/null | head -1 | cut -d= -f2 || true)"
[ -z "$LOG_TOK" ] || [ -n "$TOKEN" ] || fail "/health 未携带已捕获的 token(引导页无法完成鉴权握手)"
if [ -n "$TOKEN" ]; then
  # PWA 冷启动场景:就绪但无 dsh-auth cookie 的 GET / 必须得到引导页(而非 dsh 的 401)
  no_cookie="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/")"
  [ "$no_cookie" = "200" ] || fail "无 cookie 的 GET / 返回 $no_cookie(应为引导页 200,PWA 冷启动会 401)"
  curl -fsS "http://127.0.0.1:$SMOKE_PORT/" | grep -q "DeepSeek Harness" \
    || fail "无 cookie 的 GET / 应返回引导页(供 PWA 完成 token 握手)"
  # 就绪后 manifest 也必须是守护自己的(PWA 安装身份不得绑定 dsh 内部端口)
  curl -fsS "http://127.0.0.1:$SMOKE_PORT/manifest.webmanifest" | grep -q '"start_url":"/"' \
    || fail "就绪后 manifest 未由守护应答(PWA 会绑到 dsh 行为)"
  # 握手必须真的透传到 dsh 换取会话:只断言 200 测不出 F1 类死循环 bug(引导页也是 200),
  # 必须断言响应携带 Set-Cookie: dsh-auth(dsh 0.1.5+ 的持久会话 cookie)
  curl -fsS -o /dev/null -D "$SMOKE_ROOT/handshake.headers" -c "$SMOKE_ROOT/cookies.txt" \
    "http://127.0.0.1:$SMOKE_PORT/?token=$TOKEN" \
    || fail "token 握手失败(dsh 0.1.5+ 鉴权)"
  grep -qi '^set-cookie:.*dsh-auth' "$SMOKE_ROOT/handshake.headers" \
    || fail "token 握手响应未携带 Set-Cookie: dsh-auth(握手疑似被引导页拦截,引导页会无限 reload): $(tr -d '\r' < "$SMOKE_ROOT/handshake.headers" | head -5 | tr '\n' ' ')"
  code="$(curl -s -o /dev/null -w '%{http_code}' -b "$SMOKE_ROOT/cookies.txt" "http://127.0.0.1:$SMOKE_PORT/")"
else
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/")"
fi
[ "$code" = "200" ] || fail "透传 UI 返回 $code(token=${TOKEN:0:6}...)"
echo "OK: 引导页 + 自动唤醒 + 就绪门控 + 透传${TOKEN:+(token 鉴权)}通过"

step "3b/5 并发双 /wake 幂等(只允许 1 个 dsh 实例)"
curl -fsS -X POST -H "Origin: http://127.0.0.1:$SMOKE_PORT" "http://127.0.0.1:$SMOKE_PORT/stop" >/dev/null || fail "/stop"
daemon_wait_health "$SMOKE_PORT" false 60 || fail "stop 后 dsh 未停止"
( curl -fsS -X POST -H "Origin: http://127.0.0.1:$SMOKE_PORT" "http://127.0.0.1:$SMOKE_PORT/wake" >/dev/null &   curl -fsS -X POST -H "Origin: http://127.0.0.1:$SMOKE_PORT" "http://127.0.0.1:$SMOKE_PORT/wake" >/dev/null & wait )
# 梯度等待:前 10 次 500ms,后 50 次 1s,再后 2s
daemon_wait_health "$SMOKE_PORT" true 300 || fail "双唤醒后 dsh 未就绪"
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

step "4/5 空闲自停(PWA 关闭即停止 dsh,DSH_RT_IDLE_STOP_SECS=3)"
sleep 8
daemon_wait_health "$SMOKE_PORT" false 10 || fail "空闲后 dsh 未自动停止"
echo "OK: 空闲自停通过"
daemon_stop "$DAEMON_PID"

step "5/5 socket activation(launchd 持 socket → 连接激活 → 自退 → 再激活)"
SA_LABEL="com.dshpwa.smoke-test"
SA_DIR="$SMOKE_ROOT/sa"
SA_RT_HOME="$SA_DIR/rt"; SA_RT_STATE="$SA_DIR/state"; SA_LOG_DIR="$SA_RT_STATE/logs"
SA_PLIST="$HOME/Library/LaunchAgents/$SA_LABEL.plist"
SA_LISTENER_PID=""
sa_teardown() {
  launchctl bootout "gui/$(id -u)/$SA_LABEL" 2>/dev/null || true
  rm -f "$SA_PLIST"
  [ -n "$SA_LISTENER_PID" ] && kill "$SA_LISTENER_PID" 2>/dev/null || true
}
trap 'daemon_stop "$DAEMON_PID" 2>/dev/null || true; sa_teardown' EXIT
if [ -d "$HOME/Library/LaunchAgents" ] && [ -w "$HOME/Library/LaunchAgents" ] \
   && launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
  sa_teardown  # 清掉上次失败运行的残留 job
  mkdir -p "$SA_RT_HOME" "$SA_LOG_DIR"
  # 等前台守护(上一步)完全退出,避免干扰进程断言
  for _ in $(seq 1 10); do pgrep -f "$RT_HOME/daemon" >/dev/null || break; sleep 0.5; done

  # 伪 dsh:独立会话(setsid)的 TCP 监听器,只 accept 不回 HTTP
  # → dsh_up()=true(能 connect)而 dsh_ready()=false(探不出 HTTP 响应行)
  SA_PORT_FILE="$SA_DIR/dummy.port"
  python3 - "$SA_PORT_FILE" <<'PY' &
import os, socket, sys
os.setsid()  # 自成进程组:守护 stop_dsh 的 kill(-pid) 只会命中本监听器
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(16)
with open(sys.argv[1], "w") as f:
    f.write(str(s.getsockname()[1]))
while True:
    try:
        c, _ = s.accept()
    except OSError:
        break
    c.close()
PY
  SA_LISTENER_PID=$!
  for _ in $(seq 1 20); do [ -s "$SA_PORT_FILE" ] && break; sleep 0.1; done
  [ -s "$SA_PORT_FILE" ] || fail "伪 dsh 监听器未启动"
  DUMMY_PORT="$(cat "$SA_PORT_FILE")"
  # 残留状态(dsh.json 指向活端口 + dsh.pid):守护启动即认为 dsh 在跑,
  # /goodbye 后走快停 → stop_dsh(杀伪 dsh)→ activated 模式 exit(0) 自退
  printf '{"port":%s}\n' "$DUMMY_PORT" > "$SA_RT_STATE/dsh.json"
  printf '%s\n' "$SA_LISTENER_PID" > "$SA_RT_STATE/dsh.pid"

  # 随机高位端口(确保空闲)
  SA_PORT=$((RANDOM % 20000 + 21000))
  while (exec 3<>/dev/tcp/127.0.0.1/$SA_PORT) 2>/dev/null; do
    SA_PORT=$((RANDOM % 20000 + 21000))
  done

  TPL="$ROOT/launchd/com.dshpwa.daemon.plist"
  [ -f "$TPL" ] || TPL="$ROOT/com.dshpwa.daemon.plist"
  sed -e "s|__DAEMON_BIN__|$RT_HOME/daemon|g" \
      -e "s|__HOME__|$HOME|g" \
      -e "s|__RT_HOME__|$SA_RT_HOME|g" \
      -e "s|__RT_STATE__|$SA_RT_STATE|g" \
      -e "s|__LOG_DIR__|$SA_LOG_DIR|g" \
      -e "s|__DSH_RT_PORT__|$SA_PORT|g" "$TPL" > "$SA_PLIST"
  /usr/libexec/PlistBuddy \
    -c "Set :Label $SA_LABEL" \
    -c "Add :EnvironmentVariables:DSH_RT_IDLE_STOP_SECS string 3" \
    -c "Add :EnvironmentVariables:DSH_RT_GOODBYE_SECS string 1" \
    -c "Add :EnvironmentVariables:DSH_RT_NO_AUTO_UPDATE string 1" \
    "$SA_PLIST" >/dev/null
  plutil -lint "$SA_PLIST" >/dev/null || fail "测试 plist 无效"
  launchctl bootstrap "gui/$(id -u)" "$SA_PLIST" || fail "launchctl bootstrap 失败"

  # 激活前:job 已加载但守护不在跑(launchd 持有 socket,零常驻)
  sleep 0.5
  if pgrep -f "$RT_HOME/daemon" >/dev/null; then fail "bootstrap 后守护不应立即运行(无 RunAtLoad)"; fi
  # 首个 TCP 连接 → launchd 拉起守护(launch_activate_socket 接管 fd)
  h="$(curl -fsS --max-time 10 "http://127.0.0.1:$SA_PORT/health")" || fail "连接未触发守护激活"
  echo "$h" | grep -q '"dsh":false' || fail "激活后 health 异常: $h"
  pgrep -f "$RT_HOME/daemon" >/dev/null || fail "守护未被 launchd 拉起"
  grep -q "socket-activated" "$SA_LOG_DIR/daemon.log" 2>/dev/null \
    || fail "守护未走 launch_activate_socket 路径(日志缺 socket-activated)"
  # /goodbye → GOODBYE_GRACE=1s 快停 → stop_dsh → exit(0) 自退,launchd 重新接管 socket
  curl -fsS --max-time 10 -X POST -H "Origin: http://127.0.0.1:$SA_PORT" \
    "http://127.0.0.1:$SA_PORT/goodbye" >/dev/null || fail "/goodbye 请求失败"
  for _ in $(seq 1 30); do pgrep -f "$RT_HOME/daemon" >/dev/null || break; sleep 0.5; done
  if pgrep -f "$RT_HOME/daemon" >/dev/null; then fail "goodbye 后守护未自退(activated 模式应 exit(0))"; fi
  if [ -f "$SA_RT_STATE/dsh.json" ] || [ -f "$SA_RT_STATE/dsh.pid" ]; then
    fail "自退后残留状态未清理"
  fi
  # 再次连接 → 再次激活(ThrottleInterval=1 保证冷启动可循环)
  h="$(curl -fsS --max-time 10 "http://127.0.0.1:$SA_PORT/health")" || fail "二次激活请求失败"
  echo "$h" | grep -q '"dsh":false' || fail "二次激活 health 异常: $h"
  pgrep -f "$RT_HOME/daemon" >/dev/null || fail "守护未被再次拉起(ThrottleInterval 生效?)"
  # 零常驻兜底:此次激活后无任何连接且未运行 dsh(dsh.json 已清),IDLE_STOP(3s)后守护应自退。
  # 缺该分支时,任何不触发 /wake 的连接(如仅探测 /health)都会让守护永久驻留,违背零常驻。
  for _ in $(seq 1 30); do pgrep -f "$RT_HOME/daemon" >/dev/null || break; sleep 0.5; done
  pgrep -f "$RT_HOME/daemon" >/dev/null \
    && fail "空闲且未运行 dsh 时守护未自退(零常驻兜底失效)"
  echo "OK: socket activation 端到端通过(激活 → 自退 → 再激活 → 空闲自退)"
  sa_teardown
else
  # 无 GUI launchd 会话(如 CI runner):显式 SKIP + 状态文件,绝不静默假装通过。
  # 不返回非零:release 前置冒烟在无 GUI runner 上也应继续打包,靠 [SKIP] 与状态文件可见。
  echo "[SKIP] socket activation(无 GUI 会话:~/Library/LaunchAgents 不可写或无 launchd GUI 会话)"
  touch "$SMOKE_ROOT/socket-activation.skipped"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::notice title=socket activation::无 GUI 会话,SA 端到端测试已跳过(其余冒烟项真实执行);标记文件 $SMOKE_ROOT/socket-activation.skipped"
  fi
fi

echo; echo "SMOKE OK (root=$SMOKE_ROOT)"