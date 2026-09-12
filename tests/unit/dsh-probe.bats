#!/usr/bin/env bats
# dsh-probe.sh 的独立回归门禁:三态退出码 + 收尾不得留下孤儿守护/dsh。
#
# 三态必须分清:
#   0 = 就绪(真起过)
#   1 = 探测跑了但没就绪(真失败 → 调用方应回滚)
#   2 = 无法探测(缺件 → 调用方**不得**回滚)
#
# 收尾方式与 install.sh 4c 暖机同源(负 PID 整组、pgrep 按路径兜底),这里做独立断言。
# stub daemon 用 python3 实现迷你 HTTP,模拟「/health 先 false → /wake 后 true」;
# 不测真 dsh(本机未必有),只测探测流程本身的正确性。

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FIX="$BATS_TEST_TMPDIR"
  mkdir -p "$FIX/rt/scripts" "$FIX/state/logs" "$FIX/home"
}

stub_daemon() {
  # 参数 1: /health 返回 "dsh":true 前需要的 /wake 次数(默认 1)
  local need_wake="${1:-1}"
  cat > "$FIX/rt/daemon" <<PYSTUB
#!/usr/bin/env python3
import os, sys, socket, time, threading
PORT = int(os.environ.get('DSH_RT_PORT', 3080))
STATE = os.environ.get('DSH_RT_STATE', '')
CHILD_PID_FILE = os.environ.get('STUB_CHILD_PID_FILE', '')
wake_count = 0

def handler(conn, addr):
    global wake_count
    try:
        data = conn.recv(4096).decode('utf-8', errors='replace')
        req = data.splitlines()[0] if data else ''
        body = '{"starting":false,"dsh":false}'
        code = b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s'
        if 'GET /health' in req:
            if wake_count >= $need_wake:
                body = '{"starting":false,"dsh":true}'
            conn.sendall(code % (len(body), body.encode()))
        elif 'POST /wake' in req:
            wake_count += 1
            child = os.fork()
            if child == 0:
                os.setsid()
                with open(os.path.join(STATE, 'dsh.pid'), 'w') as f:
                    f.write(str(os.getpid()) + '\n')
                if CHILD_PID_FILE:
                    with open(CHILD_PID_FILE, 'w') as f:
                        f.write(str(os.getpid()) + '\n')
                time.sleep(300)
                sys.exit(0)
            conn.sendall(code % (len(body), body.encode()))
        elif 'POST /stop' in req:
            conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok')
            os._exit(0)
        else:
            conn.sendall(code % (len(body), body.encode()))
    except Exception as e:
        print("stub err:", e, file=sys.stderr)
    finally:
        conn.close()

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(('127.0.0.1', PORT))
sock.listen(5)
while True:
    try:
        c, a = sock.accept()
        t = threading.Thread(target=handler, args=(c, a))
        t.daemon = True
        t.start()
    except Exception:
        break
PYSTUB
  chmod +x "$FIX/rt/daemon"
}

@test "dsh-probe rc=2 when daemon binary is missing" {
  rm -f "$FIX/rt/daemon"
  cp "$ROOT/scripts/dsh-probe.sh" "$FIX/rt/scripts/dsh-probe.sh"
  printf '{"node":"/bin/true","dsh":"/bin/true"}\n' > "$FIX/rt/run.json"

  DSH_RT_HOME="$FIX/rt" DSH_RT_STATE="$FIX/state" DSH_HOME="$FIX/home" \
    run bash "$FIX/rt/scripts/dsh-probe.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"守护二进制不可执行"* ]] || {
    echo "unexpected output: $output"
    return 1
  }
}

@test "dsh-probe rc=0 when daemon reports dsh true and leaves no orphan" {
  stub_daemon 1
  cp "$ROOT/scripts/dsh-probe.sh" "$FIX/rt/scripts/dsh-probe.sh"
  printf '{"node":"/bin/true","dsh":"/bin/true"}\n' > "$FIX/rt/run.json"

  DSH_RT_HOME="$FIX/rt" DSH_RT_STATE="$FIX/state" DSH_HOME="$FIX/home" \
    DSH_RT_PROBE_TIMEOUT_SECS=15 \
    STUB_CHILD_PID_FILE="$FIX/stub-child.pid" \
    run bash "$FIX/rt/scripts/dsh-probe.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"就绪"* ]] || {
    echo "unexpected output: $output"
    return 1
  }

  # 反空转:stub 必须真的起了子进程并记了账,否则「没有孤儿」是假绿
  [ -s "$FIX/stub-child.pid" ] || {
    echo "stub never recorded a child pid (vacuous test)"
    return 1
  }
  child="$(cat "$FIX/stub-child.pid")"

  # 收尾后该子进程必须已死
  if kill -0 "$child" 2>/dev/null; then
    kill -9 "$child" 2>/dev/null || true
    echo "orphan dsh survived the probe cleanup (pid $child)"
    return 1
  fi
}

@test "dsh-probe rc=1 when daemon never reports dsh true and leaves no orphan" {
  stub_daemon 999
  cp "$ROOT/scripts/dsh-probe.sh" "$FIX/rt/scripts/dsh-probe.sh"
  printf '{"node":"/bin/true","dsh":"/bin/true"}\n' > "$FIX/rt/run.json"

  DSH_RT_HOME="$FIX/rt" DSH_RT_STATE="$FIX/state" DSH_HOME="$FIX/home" \
    DSH_RT_PROBE_TIMEOUT_SECS=3 \
    STUB_CHILD_PID_FILE="$FIX/stub-child.pid" \
    run bash "$FIX/rt/scripts/dsh-probe.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"未在 3s 内就绪"* ]] || {
    echo "unexpected output: $output"
    return 1
  }

  [ -s "$FIX/stub-child.pid" ] || {
    echo "stub never recorded a child pid (vacuous test)"
    return 1
  }
  child="$(cat "$FIX/stub-child.pid")"

  if kill -0 "$child" 2>/dev/null; then
    kill -9 "$child" 2>/dev/null || true
    echo "orphan dsh survived the probe cleanup (pid $child)"
    return 1
  fi
}
