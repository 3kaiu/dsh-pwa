#!/usr/bin/env bash
set -uo pipefail
# dsh 启动探测:在**隔离的临时 RT_HOME** 里真实拉起一次守护 → /wake → 等 dsh 就绪 → 收尾。
#
# 为什么需要它:更新/安装成功后「require('sharp'/'node-pty') 通过」≠「dsh 能起来」。
# 入口解析、ESM 依赖图、新版本对 node 版本的要求、cleanup-deps 删过头……都只在真正
# 启动时暴露。无人值守的凌晨更新若留下一个起不来的 dsh,用户第二天看到的就是「服务消失」。
#
# 为什么不能直接在真实 RT_HOME 里探测:update-dsh.sh 整个运行期持 $RT_HOME/.install.lock,
# 而守护的 update_locked() 据此判定「更新进行中」并**拒绝 spawn dsh**(spawn_dsh() 里的
# update_locked() 分支),于是「持锁者自己启动守护去拉起 dsh」是构造性死结——install.sh 暖机
# 正是这样 100% 失败的(见其 4c 注释)。故用临时 RT_HOME:守护从 RT_HOME 只读三处
# (read_run() / update_locked() / trigger_background_update()),复制前两者即可,临时目录里
# 没有锁,也就没有死结;再置 DSH_RT_NO_AUTO_UPDATE=1,免得它去找临时目录里并不存在的更新脚本。
#
# RT_STATE 必须保持**真实路径**:NODE_COMPILE_CACHE 由 spawn_dsh() 按 RT_STATE 计算,
# 指错地方这次启动就白起了(探测顺带把编译缓存填充好,用户下次真实启动更快)。
# 代价是探测实例会把 dsh.json/dsh.pid 写进真实 RT_STATE,若此刻真实守护还活着就会覆盖它
# 正在用的状态 —— 故这两个文件先快照、探测后原样恢复(见 snapshot_state/restore_state)。
#
# 退出码(**三态必须分清**,调用方据此决定是否回滚):
#   0 = dsh 就绪(真起过一次)
#   1 = 探测确实跑了,但 dsh 未在预算内就绪(真失败 → 调用方应回滚)
#   2 = 无法探测(缺守护二进制/run.json/空闲端口,或守护根本没 bind)→ 未获知任何信息,
#       调用方**不得**回滚(否则环境缺件会被误判成「新版本坏了」而无限回滚)
#
# 用法: dsh-probe.sh [--timeout SECS] [--log FILE]
#   --timeout  就绪等待预算,默认 $DSH_RT_PROBE_TIMEOUT_SECS 或 60(秒)
#   --log      守护/dsh 的输出落点,默认 /tmp/dsh-probe.log(失败时**保留**,便于定位)
# 环境: DSH_RT_HOME DSH_RT_STATE DSH_HOME(可选,与守护一致)

RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
RT_STATE="${DSH_RT_STATE:-$HOME/.local/state/dsh-runtime}"
LOG="${DSH_RT_PROBE_LOG:-/tmp/dsh-probe.log}"
TIMEOUT="${DSH_RT_PROBE_TIMEOUT_SECS:-60}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="${2:-}" ; shift 2 ;;
    --log)     LOG="${2:-}"     ; shift 2 ;;
    -h|--help) echo "用法: dsh-probe.sh [--timeout SECS] [--log FILE]"; exit 0 ;;
    *) echo "dsh-probe: 未知参数 $1" >&2; exit 2 ;;
  esac
done
# 预算校验:非数字/越界一律回退默认(与 install.sh 暖机同款守卫)
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=60 ;; esac
{ [ "$TIMEOUT" -ge 1 ] && [ "$TIMEOUT" -le 600 ]; } || TIMEOUT=60

DAEMON="$RT_HOME/daemon"
RUN_JSON="$RT_HOME/run.json"
[ -x "$DAEMON" ]  || { echo "dsh-probe: 守护二进制不可执行($DAEMON),无法探测" >&2; exit 2; }
[ -f "$RUN_JSON" ] || { echo "dsh-probe: run.json 缺失($RUN_JSON),无法探测" >&2; exit 2; }

# 空闲端口:优先 python3(与 install.sh 同款);无 python3(精简系统/无 CLT)时用 bash
# /dev/tcp 试随机高位端口兜底 —— 探测不该因为少个解释器就整条失效。
PORT=""
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || true)"
if [ -z "$PORT" ]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    CAND=$(( 20000 + RANDOM % 20000 ))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$CAND") 2>/dev/null; then PORT="$CAND"; break; fi
  done
fi
case "$PORT" in ''|*[!0-9]*) echo "dsh-probe: 无法分配空闲端口,无法探测" >&2; exit 2 ;; esac

ORIGIN="http://127.0.0.1:$PORT"
TMP_RT="$(mktemp -d /tmp/dsh-probe.XXXXXX 2>/dev/null || true)"
[ -n "$TMP_RT" ] || { echo "dsh-probe: 无法创建临时目录,无法探测" >&2; exit 2; }

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: > "$LOG" 2>/dev/null || true

# 真实 RT_STATE 里 dsh.json/dsh.pid 的快照(探测实例会覆盖它们)
SNAP="$TMP_RT/.state-snap"
mkdir -p "$SNAP"
snapshot_state() {
  local f
  for f in dsh.json dsh.pid; do
    [ -f "$RT_STATE/$f" ] && cp "$RT_STATE/$f" "$SNAP/$f" 2>/dev/null || true
  done
}
restore_state() {
  local f
  for f in dsh.json dsh.pid; do
    if [ -f "$SNAP/$f" ]; then
      cp "$SNAP/$f" "$RT_STATE/$f" 2>/dev/null || true
    else
      rm -f "$RT_STATE/$f" 2>/dev/null || true
    fi
  done
}
snapshot_state

cp "$DAEMON" "$TMP_RT/daemon" 2>/dev/null || { rm -rf "$TMP_RT"; echo "dsh-probe: 复制守护失败" >&2; exit 2; }
cp "$RUN_JSON" "$TMP_RT/run.json" 2>/dev/null || { rm -rf "$TMP_RT"; echo "dsh-probe: 复制 run.json 失败" >&2; exit 2; }

DPID=""
DSH_PID=""
CLEANED=0
# 收尾:幂等,所有退出路径(含信号/中断)都走这里。
# 顺序与 install.sh 暖机一致(那边踩过「失败分支只 kill 守护 → dsh 孤儿化继续 LISTEN」):
# 先 /stop,再 kill 守护,再按**路径**兜底收守护,最后对 dsh 打**负 PID 整组**
# (dsh 由守护 setsid 自成进程组,不在守护组里,不整组打就会残留)。
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  [ -n "$DSH_PID" ] || DSH_PID="$(cat "$RT_STATE/dsh.pid" 2>/dev/null || true)"
  case "$DSH_PID" in ''|*[!0-9]*) DSH_PID="" ;; esac
  curl -fsS --max-time 3 --noproxy '*' -X POST -H "Origin: $ORIGIN" "$ORIGIN/stop" >/dev/null 2>&1 || true
  [ -n "$DPID" ] && kill "$DPID" 2>/dev/null || true
  [ -n "$DPID" ] && wait "$DPID" 2>/dev/null || true
  # 兜底:按路径再收一遍。$! 未必是最终在 listen 的那个进程(实测偏差 4~15 个 pid,
  # 见 tests/lib/daemon-helpers.sh:daemon_stop_by_binary)。TMP_RT 来自 mktemp(路径唯一),
  # 用 ^ 锚定命令行开头,不会误伤探测脚本自身或同机其他进程。
  for _p in $(pgrep -f "^${TMP_RT}/daemon(\$| )" 2>/dev/null || true); do
    kill -TERM "$_p" 2>/dev/null || true
  done
  if [ -n "$DSH_PID" ] && [ "$DSH_PID" -gt 1 ] && [ "$DSH_PID" != "$$" ] \
     && kill -0 "$DSH_PID" 2>/dev/null; then
    kill -TERM -- "-$DSH_PID" 2>/dev/null || kill -TERM "$DSH_PID" 2>/dev/null || true
    sleep 1
    if kill -0 "$DSH_PID" 2>/dev/null; then
      kill -9 -- "-$DSH_PID" 2>/dev/null || kill -9 "$DSH_PID" 2>/dev/null || true
    fi
  fi
  restore_state
  rm -rf "$TMP_RT"
}
trap cleanup EXIT INT TERM

# 启动探测实例。DSH_RT_IDLE_STOP_SECS 给短值:收尾时守护自己也会尽快退出。
# NO_AUTO_UPDATE=1:临时 RT_HOME 里没有 update-dsh.sh,别让它去找(且避免再 fork 一个更新子进程)。
DSH_RT_HOME="$TMP_RT" DSH_RT_STATE="$RT_STATE" DSH_RT_PORT="$PORT" \
  DSH_RT_IDLE_STOP_SECS=3 DSH_RT_NO_AUTO_UPDATE=1 \
  "$TMP_RT/daemon" >> "$LOG" 2>&1 &
DPID=$!

# 等守护 bind(最长 2s)。等不到 = 探测环境本身有问题(端口竞态/守护起不来),按 2 处理。
BOUND=0
for _ in $(seq 1 20); do
  if curl -fsS --max-time 1 --noproxy '*' "$ORIGIN/health" >/dev/null 2>&1; then BOUND=1; break; fi
  sleep 0.1
done
if [ "$BOUND" != "1" ]; then
  echo "dsh-probe: 探测实例未在 2s 内 bind($ORIGIN),无法探测(日志 $LOG)" >&2
  exit 2
fi

curl -fsS --max-time 3 --noproxy '*' -X POST -H "Origin: $ORIGIN" "$ORIGIN/wake" >/dev/null 2>&1 || true

READY=0
DIED=0
for _ in $(seq 1 $(( TIMEOUT * 2 ))); do
  H="$(curl -fsS --max-time 2 --noproxy '*' "$ORIGIN/health" 2>/dev/null || true)"
  if printf '%s' "$H" | grep -q '"dsh":true'; then READY=1; break; fi
  # 启动即崩:pid 已记账但进程没了 → 立刻失败,不必跑满预算(真实报错在 $LOG 里)
  P="$(cat "$RT_STATE/dsh.pid" 2>/dev/null || true)"
  case "$P" in
    ''|*[!0-9]*) : ;;
    *) if ! kill -0 "$P" 2>/dev/null; then DIED=1; DSH_PID="$P"; break; fi ;;
  esac
  sleep 0.5
done
# 收尾前先记 pid:守护停止 dsh 后会 unlink dsh.pid,那时就读不到了
DSH_PID="$(cat "$RT_STATE/dsh.pid" 2>/dev/null || true)"

if [ "$READY" = "1" ]; then
  echo "dsh-probe: dsh 就绪(端口 $PORT,预算 ${TIMEOUT}s)"
  exit 0
fi
if [ "$DIED" = "1" ]; then
  echo "dsh-probe: dsh 启动后立即退出(pid $DSH_PID),详见日志 $LOG" >&2
else
  echo "dsh-probe: dsh 未在 ${TIMEOUT}s 内就绪,详见日志 $LOG" >&2
fi
exit 1
