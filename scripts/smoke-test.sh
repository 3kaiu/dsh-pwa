#!/usr/bin/env bash
set -euo pipefail
# 一键安装冒烟:隔离目录真实执行 install.sh(上游最新 node LTS + 官方 dsh),
# 完整走 install → 幂等重跑 → 守护(引导页/唤醒/透传/空闲自停)→ socket activation 端到端。
# 用法: bash scripts/smoke-test.sh [install.sh 路径]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${1:-$ROOT/scripts/install.sh}"
[ -f "$INSTALL" ] || { echo "找不到 install.sh" >&2; exit 1; }
# 隔离根目录。**只清理由本脚本自己创建的**:调用方显式传入 SMOKE_ROOT 视为「我要留着看」
# (release.yml 就用 SMOKE_ROOT=/tmp/pkg-e2e-smoke 复用打包产物),那种情况一律不动。
SMOKE_ROOT_OWNED=0
if [ -z "${SMOKE_ROOT:-}" ]; then
  SMOKE_ROOT="$(mktemp -d /tmp/dsh-install-smoke.XXXXXX)"
  SMOKE_ROOT_OWNED=1
fi
SMOKE_PORT="${SMOKE_PORT:-13980}"
export DSH_RT_HOME="$SMOKE_ROOT/rt" DSH_RT_STATE="$SMOKE_ROOT/state"
export DSH_HOME="$SMOKE_ROOT/home" DSH_RT_PORT="$SMOKE_PORT" DSH_INSTALL_NO_AGENT=1
# 暖机预算(秒):本套件紧随其后的 3/5 步实测 dsh 数秒即就绪,25s 已是一个数量级余量。
# 而暖机自身出问题时,4 次 install × 默认 60s 会把 job 拖长 ~4m40s(实测 run 34631617230)。
# 真缺陷仍会超时并留下 warmup.failed,不会被这个更短的预算掩盖。
export DSH_RT_WARMUP_TIMEOUT_SECS="${DSH_RT_WARMUP_TIMEOUT_SECS:-25}"
RT_HOME="$DSH_RT_HOME"; RT_STATE="$DSH_RT_STATE"
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }
# 测试 helper:daemon_compile / daemon_start_foreground / daemon_wait_health / daemon_stop
# shellcheck source=/dev/null
source "$ROOT/tests/lib/daemon-helpers.sh"

# 回环请求约定:本脚本所有访问 127.0.0.1 的 curl 都必须同时带下面两个参数。
#   --max-time:守护「已 bind 未 listen」时 macOS 直接丢弃 SYN(不回 RST),无超时的 curl
#     会一直挂到作业级 timeout-minutes(30min),把真实缺陷掩盖成「卡住」——本次排查的起点
#     正是这种「只看到卡住、看不到原因」。实测该状态:挂满 --max-time 后 rc=28 且
#     http_code=000(而非空串),失败信息因此仍然准确。
#   --noproxy '*':curl 默认会把 127.0.0.1 的请求交给 http_proxy(实测 curl 8.7.1 打印
#     "Uses proxy env variable http_proxy"),此时「守护已死」拿到的是代理的 502 而不是
#     连接拒绝(000),断言与报错全部失真。代理存在与否不应改变本套件的结论。
# 注意:仅回环请求加 --noproxy;install.sh 子进程仍需走代理访问 nodejs.org/npm registry。
step "1/5 install(真实安装:node 最新 LTS + dsh latest)"
bash "$INSTALL" || fail "install"
[ -x "$RT_HOME/daemon" ] || fail "daemon 未安装"
[ -f "$SMOKE_ROOT/rt/run.json" ] || fail "run.json 缺失"
grep -q '"node"' "$SMOKE_ROOT/rt/run.json" || fail "run.json 缺 node"
grep -q '"dsh"' "$SMOKE_ROOT/rt/run.json" || fail "run.json 缺 dsh"
# P1-3:含 token 的状态/日志目录运行时真实权限必须为 0700(install.sh 显式 chmod)
[ "$(stat -f %Lp "$RT_STATE")" = "700" ] || fail "RT_STATE 权限 $(stat -f %Lp "$RT_STATE"),应为 700"
[ "$(stat -f %Lp "$RT_STATE/logs")" = "700" ] || fail "logs 目录权限 $(stat -f %Lp "$RT_STATE/logs"),应为 700"

# 暖机必须「跑过并表态」:warmup.ok / warmup.failed / warmup.skipped 恰有其一。
# 断言的是**存在性**(liveness)而非成功——暖机是尽力而为(失败不阻断安装),但
# **静默失败**不可接受:实测 run 34631617230 中暖机 4/4 次全部超时,而本套件照样打印
# SMOKE OK、CI 全绿,因为当时没有任何断言提到暖机(全仓库 grep 0 命中)。缺了这条,
# 「绿」会被读成「暖机可用」。真缺陷(永不就绪)仍会走 failed 分支并在收尾被点名。
warm_marks=0
for _m in warmup.ok warmup.failed warmup.skipped; do
  [ -f "$RT_STATE/$_m" ] && warm_marks=$((warm_marks + 1))
done
[ "$warm_marks" -eq 1 ] || fail "暖机未留下唯一状态标记(期望恰 1 个,实得 $warm_marks;查 $RT_STATE/warmup.*)"
# 立刻固化第 1 步的结论:后面的 install(2b、冲突后重装)会覆写 marker,
# 收尾汇总必须引用第 1 步的结果,否则「本次冒烟测的暖机」会被后来的重装顶替。
if [ -f "$RT_STATE/warmup.ok" ]; then
  WARM_STATUS="ok: $(cat "$RT_STATE/warmup.ok")"
elif [ -f "$RT_STATE/warmup.failed" ]; then
  WARM_STATUS="FAILED: $(cat "$RT_STATE/warmup.failed")"
  echo "  [WARN] 暖机未完成 —— 安装不受影响,但首次启动不会预热"
else
  WARM_STATUS="skipped: $(cat "$RT_STATE/warmup.skipped")"
fi

step "2/5 幂等重跑(已装同版,重入应成功且不破坏既有安装)"
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
# 持续监听:install.sh 的 stop_active_dsh() 会先 curl /health 探测,
# 若只 accept 一次就退出,端口会被提前释放,导致后续端口检测失效
while True:
    c, _ = s.accept()
    c.close()
PY
OCC_PID=$!
# 退出作业表:下面用 kill 收掉占位监听器,bash 收割时会打印
# 「Terminated: 15 python3 …」作业控制通知。该通知与日志交错出现在本步之后,
# 极易被读成失败(实测 run 34631617230 的日志里它正好插在 2b 的 OK 与 3/5 之间)。
# disown 后 kill 照常生效,只是不再产生这条噪声。
disown "$OCC_PID" 2>/dev/null || true
for _ in $(seq 1 20); do [ -s "$OCC_DIR/port" ] && break; sleep 0.1; done
[ -s "$OCC_DIR/port" ] || fail "占位监听器未启动"
OCC_PORT="$(cat "$OCC_DIR/port")"
# 本步验证的是「端口被占时 install 显式报错」,与暖机无关 → 显式关掉暖机,
# 免得每次都为它白等一轮预算(CI 上 4 次 install 各等一轮,合计约 4m40s)。
if DSH_RT_PORT="$OCC_PORT" DSH_INSTALL_NO_WARMUP=1 bash "$INSTALL" >"$OCC_DIR/install.log" 2>&1; then
  kill "$OCC_PID" 2>/dev/null || true
  fail "端口被占时 install 未报错(静默失效)"
fi
grep -q "已被占用" "$OCC_DIR/install.log" || fail "端口占用报错信息不清晰: $(tail -3 "$OCC_DIR/install.log")"
kill "$OCC_PID" 2>/dev/null || true
echo "OK: 端口被占时 install 显式报错退出"
# 清理占位后正常重跑,确认冲突场景不破坏后续安装(同样与暖机无关)
DSH_INSTALL_NO_WARMUP=1 bash "$INSTALL" >/dev/null 2>&1 || fail "端口冲突测试后正常 install 失败"

step "3/5 守护:引导页/自动唤醒/就绪门控/透传"
export DSH_RT_IDLE_STOP_SECS=3
# 收尾:按 pid 与按**二进制路径**各收一遍。
# 只按 pid 不够:`$!` 未必就是最终在 listen 的那个进程(实测偏差 4~15 个 pid,见
# tests/lib/daemon-helpers.sh:daemon_stop_by_binary 的数据),漏掉的守护要等空闲自停
# (默认 30s)才消失 —— 在 CI 里就是作业结束时 runner 报 orphan daemon。
# RT_HOME / SA_RT_HOME 均由 SMOKE_ROOT 派生,路径唯一;sa_teardown 可能尚未定义(本函数在
# 其之前),故按 type 判定后再调用。
# **trap 必须先于首次启动守护注册**:否则「启动成功但随后失败」的路径不受保护。
smoke_teardown() {
  daemon_stop "${DAEMON_PID:-}" 2>/dev/null || true
  [ -z "${RT_HOME:-}" ] || daemon_stop_by_binary "$RT_HOME/daemon"
  [ -z "${SA_RT_HOME:-}" ] || daemon_stop_by_binary "$SA_RT_HOME/daemon"
  if [ "$(type -t sa_teardown 2>/dev/null || true)" = "function" ]; then
    sa_teardown
  fi
  return 0
}
trap smoke_teardown EXIT
DAEMON_PID="$(daemon_start_foreground "$RT_HOME/daemon" "$SMOKE_ROOT/daemon.log")"
# 梯度探测:前 10 次 500ms(快速启动),10-60 次 1s(正常),60+ 次 2s(慢启动)
daemon_wait_health "$SMOKE_PORT" any 5 || fail "daemon 未就绪"
# GET / 返回引导页,同时已自动拉起 dsh(无需引导页 JS 的 /wake 往返)
curl -fsS --max-time 5 --noproxy '*' "http://127.0.0.1:$SMOKE_PORT/" | grep -q "DeepSeek Harness" || fail "引导页异常"
curl -fsS --max-time 5 --noproxy '*' "http://127.0.0.1:$SMOKE_PORT/manifest.webmanifest" | grep -q '"display"' || fail "manifest 异常"
# /health 报"就绪"(能服务 HTTP)而非"进程活着":启动窗口内必须为 false,
# 引导页才不会过早切换(即 PWA 点开空白的根因)
# 断言取 body:curl 失败时 body 为空 → 下面 grep 失败并打印空值,报错依然可读
h="$(curl -fsS --max-time 5 --noproxy '*' "http://127.0.0.1:$SMOKE_PORT/health" || true)"
echo "$h" | grep -q '"dsh":false' || fail "dsh 刚拉起时尚未就绪,health 不应为 true: $h"
# 梯度等待 dsh 就绪:前 10 次 500ms,后 50 次 1s,再后 2s(总计约 3 分钟)
daemon_wait_health "$SMOKE_PORT" true 300 1 || fail "自动唤醒后 dsh 未就绪"
# dsh 0.1.5+ 强制 token 鉴权:URL 带 token 换 cookie 后透传才 200(老版本无 token 则直接透传)
# 新行为:就绪判定只看 HTTP 探测(不再等 2s token 宽限),/health 可能先报 dsh:true、
# token 字段稍后才随响应出现 → 轮询等「日志 token」与「/health token」汇合;
# 未汇合且日志也无 token 则按旧版无 token 路径继续。
# 窗口必须 ≥ 守护自身的扫描期限(maybe_scan_token() 的 120s),否则守护还在耐心等 token、
# 测试却已判失败。实测:同一发行产物用 10s 窗口会间歇性失败(重跑即过)——而 flaky gate
# 与坏 gate 无法区分,故取 120s 与守护对齐。真缺陷(永不捕获)仍会在 120s 后失败。
TOKEN=""
for _ in $(seq 1 240); do
  T="$(grep -o 'token=[A-Za-z0-9_-]*' "$RT_STATE/logs/dsh.log" 2>/dev/null | head -1 | cut -d= -f2 || true)"
  if [ -n "$T" ] && curl -fsS --max-time 5 --noproxy '*' "http://127.0.0.1:$SMOKE_PORT/health" | grep -q "\"token\":\"$T\""; then
    TOKEN="$T"; break
  fi
  sleep 0.5
done
# 回归门:日志里已有 token 但 /health 迟迟不带 → 守护 token 扫描/下发链路坏了,必须报错
LOG_TOK="$(grep -o 'token=[A-Za-z0-9_-]*' "$RT_STATE/logs/dsh.log" 2>/dev/null | head -1 | cut -d= -f2 || true)"
[ -z "$LOG_TOK" ] || [ -n "$TOKEN" ] || fail "/health 未携带已捕获的 token(引导页无法完成鉴权握手)"
if [ -n "$TOKEN" ]; then
  # PWA 冷启动场景:就绪但无 dsh-auth cookie 的 GET / 必须得到引导页(而非 dsh 的 401)
  no_cookie="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' "http://127.0.0.1:$SMOKE_PORT/" || true)"
  [ "$no_cookie" = "200" ] || fail "无 cookie 的 GET / 返回 $no_cookie(应为引导页 200,PWA 冷启动会 401)"
  curl -fsS --max-time 5 --noproxy '*' "http://127.0.0.1:$SMOKE_PORT/" | grep -q "DeepSeek Harness" \
    || fail "无 cookie 的 GET / 应返回引导页(供 PWA 完成 token 握手)"
  # 就绪后 manifest 也必须是守护自己的(PWA 安装身份不得绑定 dsh 内部端口)
  curl -fsS --max-time 5 --noproxy '*' "http://127.0.0.1:$SMOKE_PORT/manifest.webmanifest" | grep -q '"start_url":"/"' \
    || fail "就绪后 manifest 未由守护应答(PWA 会绑到 dsh 行为)"
  # 握手必须真的透传到 dsh 换取会话:只断言 200 测不出 F1 类死循环 bug(引导页也是 200),
  # 必须断言响应携带 Set-Cookie: dsh-auth(dsh 0.1.5+ 的持久会话 cookie)
  curl -fsS --max-time 5 --noproxy '*' -o /dev/null -D "$SMOKE_ROOT/handshake.headers" -c "$SMOKE_ROOT/cookies.txt" \
    "http://127.0.0.1:$SMOKE_PORT/?token=$TOKEN" \
    || fail "token 握手失败(dsh 0.1.5+ 鉴权)"
  grep -qi '^set-cookie:.*dsh-auth' "$SMOKE_ROOT/handshake.headers" \
    || fail "token 握手响应未携带 Set-Cookie: dsh-auth(握手疑似被引导页拦截,引导页会无限 reload): $(tr -d '\r' < "$SMOKE_ROOT/handshake.headers" | head -5 | tr '\n' ' ')"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' -b "$SMOKE_ROOT/cookies.txt" "http://127.0.0.1:$SMOKE_PORT/" || true)"
else
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' "http://127.0.0.1:$SMOKE_PORT/" || true)"
fi
[ "$code" = "200" ] || fail "透传 UI 返回 $code(token=${TOKEN:0:6}...)"
echo "OK: 引导页 + 自动唤醒 + 就绪门控 + 透传${TOKEN:+(token 鉴权)}通过"

step "3b/5 并发双 /wake 幂等(只允许 1 个 dsh 实例)"
curl -fsS --max-time 5 --noproxy '*' -X POST -H "Origin: http://127.0.0.1:$SMOKE_PORT" "http://127.0.0.1:$SMOKE_PORT/stop" >/dev/null || fail "/stop"
daemon_wait_health "$SMOKE_PORT" false 60 || fail "stop 后 dsh 未停止"
# 两个 /wake 并发:守护在连接子进程里只写 1 字节命令即返回,响应本身是毫秒级;
# 失败不在此处断言(wait 无参恒返回 0),由下面的就绪等待给出可读结论。
( curl -fsS --max-time 5 --noproxy '*' -X POST -H "Origin: http://127.0.0.1:$SMOKE_PORT" "http://127.0.0.1:$SMOKE_PORT/wake" >/dev/null &   curl -fsS --max-time 5 --noproxy '*' -X POST -H "Origin: http://127.0.0.1:$SMOKE_PORT" "http://127.0.0.1:$SMOKE_PORT/wake" >/dev/null & wait )
# 梯度等待:前 10 次 500ms,后 50 次 1s,再后 2s
daemon_wait_health "$SMOKE_PORT" true 300 || fail "双唤醒后 dsh 未就绪"
if ps -ax -o command >/dev/null 2>&1; then
  n="$(ps -ax -o command | grep "[b]in\.js web" | grep -c "$SMOKE_ROOT" || true)"
  [ "$n" = "1" ] || fail "并发双 /wake 产生了 $n 个 dsh 实例(应为 1,孤儿泄漏)"
  echo "OK: 恰 1 个 dsh 实例(无孤儿)"
else
  # ps 不可用(受限/沙箱会话:实测 rc=126 "Operation not permitted" 且无输出)→ 孤儿断言
  # 无法执行。绝不静默假装通过:与第 5 步同约定,显式 [SKIP] + 状态文件。否则本步只留一行
  # 括号提示,而结尾照样打印 SMOKE OK,读者会把它读成「全部断言都跑过」——
  # 这正是「委托外部 helper 的门禁退化成 no-op」那一类。
  echo "[SKIP] 并发孤儿检查(ps 不可用:无法统计 dsh 实例数)"
  touch "$SMOKE_ROOT/orphan-count.skipped"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::notice title=orphan count::ps 不可用,并发孤儿检查已跳过(其余冒烟项真实执行);标记文件 $SMOKE_ROOT/orphan-count.skipped"
  fi
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
# trap 已在第 121 行注册(smoke_teardown 会按 type 判定后调用 sa_teardown),此处不重复注册。
# launchd GUI 会话可用性必须实测「能否注册 job」,只探「能否读 GUI 域」不够。
# 实测(受限/沙箱会话):`launchctl print gui/UID` 返回 0,但 bootstrap 被拒——
#   Bootstrap failed: 5: Input/output error   (rc=5)
# 此时若径直进入 SA 分支,第 5 步会把「环境限制」报成产品 FAIL(实测 exit 1),
# 与下方「无 GUI 会话应显式 SKIP、不返回非零」的约定相悖,也让本地 gauntlet 失真。
# 探针用唯一 label 注册一个 no-op job 再立即 bootout,不残留任何状态。
launchd_gui_usable() {
  [ -d "$HOME/Library/LaunchAgents" ] && [ -w "$HOME/Library/LaunchAgents" ] || return 1
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 || return 1
  local d plist label="com.dshpwa.probe.$$"
  d="$(mktemp -d)" || return 1
  plist="$d/probe.plist"
  {
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict>'
    printf '<key>Label</key><string>%s</string>\n' "$label"
    printf '%s\n' '<key>ProgramArguments</key><array><string>/usr/bin/true</string></array>' '</dict></plist>'
  } > "$plist"
  if launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    rm -rf "$d"
    return 0
  fi
  rm -rf "$d"
  return 1
}
if launchd_gui_usable; then
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
  h="$(curl -fsS --max-time 10 --noproxy '*' "http://127.0.0.1:$SA_PORT/health")" || fail "连接未触发守护激活"
  echo "$h" | grep -q '"dsh":false' || fail "激活后 health 异常: $h"
  pgrep -f "$RT_HOME/daemon" >/dev/null || fail "守护未被 launchd 拉起"
  grep -q "socket-activated" "$SA_LOG_DIR/daemon.log" 2>/dev/null \
    || fail "守护未走 launch_activate_socket 路径(日志缺 socket-activated)"
  # /goodbye → GOODBYE_GRACE=1s 快停 → stop_dsh → exit(0) 自退,launchd 重新接管 socket
  curl -fsS --max-time 10 --noproxy '*' -X POST -H "Origin: http://127.0.0.1:$SA_PORT" \
    "http://127.0.0.1:$SA_PORT/goodbye" >/dev/null || fail "/goodbye 请求失败"
  for _ in $(seq 1 30); do pgrep -f "$RT_HOME/daemon" >/dev/null || break; sleep 0.5; done
  if pgrep -f "$RT_HOME/daemon" >/dev/null; then fail "goodbye 后守护未自退(activated 模式应 exit(0))"; fi
  if [ -f "$SA_RT_STATE/dsh.json" ] || [ -f "$SA_RT_STATE/dsh.pid" ]; then
    fail "自退后残留状态未清理"
  fi
  # 再次连接 → 再次激活(ThrottleInterval=1 保证冷启动可循环)
  h="$(curl -fsS --max-time 10 --noproxy '*' "http://127.0.0.1:$SA_PORT/health")" || fail "二次激活请求失败"
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
  # 无可用 GUI launchd 会话(CI runner,或受限/沙箱会话拒绝 bootstrap):显式 SKIP + 状态文件,
  # 绝不静默假装通过。不返回非零:release 前置冒烟在无 GUI runner 上也应继续打包,
  # 靠 [SKIP] 与状态文件可见。
  echo "[SKIP] socket activation(无可用 GUI 会话:~/Library/LaunchAgents 不可写、无 launchd GUI 会话,或 bootstrap 被会话限制拒绝)"
  touch "$SMOKE_ROOT/socket-activation.skipped"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::notice title=socket activation::无 GUI 会话,SA 端到端测试已跳过(其余冒烟项真实执行);标记文件 $SMOKE_ROOT/socket-activation.skipped"
  fi
fi

# 收尾:集中列出本环境跳过的检查与暖机结论。SMOKE OK 只代表「已执行的断言全过」,
# 既不等于「全部断言都执行过」,也不等于「暖机成功」;不列出来,这几件事在输出里
# 无法区分(实测:暖机 4/4 次全失败时,除了 install 阶段的一行 warn 什么都看不到)。
echo
case "${WARM_STATUS:-}" in
  ok:*)      echo "暖机:成功(${WARM_STATUS#ok: })" ;;
  FAILED:*)  echo "暖机:失败 —— ${WARM_STATUS#FAILED: }(安装不受影响,但首次启动未预热)" ;;
  skipped:*) echo "暖机:跳过(${WARM_STATUS#skipped: })" ;;
  *)         echo "暖机:状态未知(第 1 步未记录)" ;;
esac

skipped_any=0
for m in "$SMOKE_ROOT"/*.skipped; do
  [ -e "$m" ] || continue
  if [ "$skipped_any" = 0 ]; then
    echo
    echo "跳过项(本环境未执行,不在 SMOKE OK 的断言范围内):"
    skipped_any=1
  fi
  echo "  - $(basename "$m" .skipped)"
done

# 成功即清理:整个 root 实测约 485MB(内含上游 node + dsh 的完整安装)。失败路径**故意保留**
# ——`fail()` 直接 exit 1,根本走不到这里,于是现场(daemon.log / *.skipped / 安装产物)原样留
# 给诊断;这与 install.sh 暖机失败保留 warmup.log 是同一条原则。
if [ "$SMOKE_ROOT_OWNED" = "1" ]; then
  echo; echo "SMOKE OK"
  rm -rf "$SMOKE_ROOT"
else
  echo; echo "SMOKE OK (root=$SMOKE_ROOT)"
fi
