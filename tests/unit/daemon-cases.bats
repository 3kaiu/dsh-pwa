#!/usr/bin/env bats
# daemon.c 核心逻辑黑盒单测:origin_ok / host_ok / extract_str / token 扫描行为。
# 不依赖真实 dsh:前台起 daemon(随机端口、隔离 RT_STATE、伪造 run.json)+ curl 断言。
# 复用 tests/lib/daemon-helpers.sh(与 smoke-test.sh / security-verification.sh 同一套 helper)。
# 注意:测试名仅 ASCII(bats 1.14 在 macOS 自带 bash 3.2 下对多字节测试名有缺陷,
#       中文描述会报 "unknown test name" 且 0 测试被执行,见 install-validation.bats 注释)。

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/tests/lib/daemon-helpers.sh"

# ---- 断言 helper(失败打印差异并返回非零,bats 判失败) ----
assert_status() {
  [ "$output" = "$1" ] || { echo "  expected HTTP [$1], got [$output]" >&2; return 1; }
}
assert_body_match() {
  if ! printf '%s' "$output" | grep -q "$1"; then
    echo "  body 未匹配 [$1]: ${output:0:200}" >&2
    return 1
  fi
}

# ---- 隔离环境:编译 daemon + 前台起 + 等 /health 就绪 ----
# 用法: start_daemon_env [run.json 内容(空=不写 run.json,即 runtime not installed 场景)]
# 结果写入测试内全局:TMP_ENV(环境根目录)/ PORT / DAEMON_PID
start_daemon_env() {
  local runjson="${1:-}"
  TMP_ENV="$(mktemp -d /tmp/dsh-unit.XXXXXX)"
  mkdir -p "$TMP_ENV/rt" "$TMP_ENV/state"
  export DSH_RT_HOME="$TMP_ENV/rt" DSH_RT_STATE="$TMP_ENV/state" DSH_HOME="$TMP_ENV/home"
  export DSH_RT_IDLE_STOP_SECS=2   # 兜底:即使忘杀,daemon 也会快速自停
  PORT=$(( (RANDOM % 20000) + 20000 ))
  export DSH_RT_PORT="$PORT"
  [ -z "$runjson" ] || printf '%s\n' "$runjson" > "$TMP_ENV/rt/run.json"
  if ! daemon_compile "$TMP_ENV/daemon"; then
    echo "  daemon 编译失败" >&2
    rm -rf "$TMP_ENV"
    TMP_ENV=""
    return 1
  fi
  DAEMON_PID="$(daemon_start_foreground "$TMP_ENV/daemon" "$TMP_ENV/daemon.log")"
  if ! daemon_wait_health "$PORT" any 5; then
    echo "  daemon 未就绪(日志见 $TMP_ENV/daemon.log)" >&2
    daemon_stop "$DAEMON_PID"
    rm -rf "$TMP_ENV"
    TMP_ENV=""
    DAEMON_PID=""
    return 1
  fi
}

stop_daemon_env() {
  if [ -n "${DAEMON_PID:-}" ]; then
    daemon_stop "$DAEMON_PID"
    DAEMON_PID=""
  fi
  if [ -n "${TMP_ENV:-}" ]; then
    rm -rf "$TMP_ENV"
    TMP_ENV=""
  fi
}

teardown() {
  if [ -n "${LOCK_PID:-}" ]; then
    kill "$LOCK_PID" 2>/dev/null || true
    LOCK_PID=""
  fi
  if [ -n "${FAKE_DSH_PID:-}" ]; then
    kill "$FAKE_DSH_PID" 2>/dev/null || true
    FAKE_DSH_PID=""
  fi
  stop_daemon_env
}

# ---- 用例 ----

@test "POST /wake without Origin returns 403" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/wake"
  assert_status "403"
}

@test "POST /wake with wrong Origin port returns 403" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$((PORT + 1))" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "403"
}

@test "POST /wake with matching Origin returns 200" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
}

@test "GET /health with evil Host header returns 403" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -H "Host: evil.com" \
    "http://127.0.0.1:$PORT/health"
  assert_status "403"
}

@test "GET /health with valid Host returns 200 and dsh:false" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ]
  assert_body_match '"dsh":false'
}

@test "GET /manifest.webmanifest serves daemon manifest without dsh" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s "http://127.0.0.1:$PORT/manifest.webmanifest"
  [ "$status" -eq 0 ]
  assert_body_match '"start_url":"/"'
  assert_body_match '"display":"standalone"'
}

@test "GET / serves bootstrap page without dsh installed" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s "http://127.0.0.1:$PORT/"
  [ "$status" -eq 0 ]
  assert_body_match "DeepSeek Harness"
}

@test "POST /wake returns 500 when runtime not installed" {
  # 无 run.json:read_run 静默失败,NODE_BIN/DSH_BIN 为空 → /wake 报 runtime not installed
  start_daemon_env ""
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "500"
}

@test "daemon unescapes JSON escapes in run.json node path" {
  # extract_str 的 \\ 反转义:run.json 写 \\(JSON 转义反斜杠),伪造 node 文件名含单个 \。
  # 若 extract_str 未反转义,exec 会去找带两个 \ 的文件名而失败 → 伪造 node 不会被执行。
  cat > "$BATS_TEST_TMPDIR/fake\\node" <<'SH'
#!/bin/bash
touch "$FAKE_NODE_MARKER"
sleep 5
SH
  chmod +x "$BATS_TEST_TMPDIR/fake\\node"
  export FAKE_NODE_MARKER="$BATS_TEST_TMPDIR/marker"
  start_daemon_env "$(printf '{"node":"%s/fake\\\\node","dsh":"%s/fake\\\\node"}' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR")"
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  ok=0
  for _ in $(seq 1 50); do
    if [ -f "$FAKE_NODE_MARKER" ]; then ok=1; break; fi
    sleep 0.1
  done
  [ "$ok" = "1" ] || { echo "  extract_str 未把 \\\\ 反转义为 \:伪造 node 未被 exec" >&2; return 1; }
}

@test "daemon captures dsh launch token into /health" {
  # 伪 dsh(python):打印 `dsh web: .../?token=xxx` 到 stdout(→ dsh.log)+ 起 HTTP 监听。
  # 覆盖 token 扫描链路:spawn → 日志捕获 → http_probe 就绪 → /health 携带 token。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  export FAKE_DSH_TOKEN="uT3st_Tok-en9"
  cat > "$BATS_TEST_TMPDIR/fake-dsh.py" <<'PY'
#!/usr/bin/env python3
import os, socket, sys
args = sys.argv
port = 0
for i in range(len(args) - 1):
    if args[i] == "--port":
        port = int(args[i + 1])
token = os.environ.get("FAKE_DSH_TOKEN", "unitTESTtoken123")
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=%s\n" % (port, token))
sys.stdout.flush()
ppid = os.getppid()  # 守护杀了我父进程 → PPID 变化 → 自行退出,不留孤儿
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(16)
s.settimeout(1.0)
while True:
    if os.getppid() != ppid:
        break
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    except OSError:
        break
    try:
        c.recv(1024)
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nok")
    except OSError:
        pass
    c.close()
PY
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh.py\"}"
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  got=""
  for _ in $(seq 1 40); do
    h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    if printf '%s' "$h" | grep -q '"token":"uT3st_Tok-en9"'; then got=1; break; fi
    sleep 0.2
  done
  [ "$got" = "1" ] || { echo "  8s 内 /health 未携带捕获的 token(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
}

@test "token handshake GET /?token= relays upstream while bare GET / without cookie returns bootstrap page" {
  # F1 回归:引导页的握手 fetch('/?token=…') 是无 cookie 的 GET /,曾被「无 cookie GET /
  # 回引导页」拦截挡死 → Set-Cookie 永远拿不到 → 引导页无限 reload。
  # 伪 dsh 模拟 dsh 0.1.5+ 鉴权:?token= → 200+Set-Cookie dsh-auth;带 cookie → 200;裸 / → 401。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  export FAKE_DSH_TOKEN="h4ndSh4ke-Tok9"
  cat > "$BATS_TEST_TMPDIR/fake-dsh-auth.py" <<'PY'
#!/usr/bin/env python3
import os, socket, sys
args = sys.argv
port = 0
for i in range(len(args) - 1):
    if args[i] == "--port":
        port = int(args[i + 1])
token = os.environ.get("FAKE_DSH_TOKEN", "unitTESTtoken123")
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=%s\n" % (port, token))
sys.stdout.flush()
ppid = os.getppid()  # 守护杀了我父进程 → PPID 变化 → 自行退出,不留孤儿
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(16)
s.settimeout(1.0)
while True:
    if os.getppid() != ppid:
        break
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    except OSError:
        break
    try:
        req = c.recv(4096).decode("latin-1")
        line = req.split("\r\n", 1)[0]
        if "?token=" in line:
            body = b"handshake-ok"
            c.sendall(("HTTP/1.1 200 OK\r\nSet-Cookie: dsh-auth=fakesess; Path=/\r\n"
                       "Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body)).encode() + body)
        elif "Cookie: dsh-auth" in req:
            body = b"app-ok"
            c.sendall(("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                       % len(body)).encode() + body)
        else:
            body = b"unauthorized"
            c.sendall(("HTTP/1.1 401 Unauthorized\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                       % len(body)).encode() + body)
    except OSError:
        pass
    c.close()
PY
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh-auth.py\"}"
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  # 等就绪 + token 捕获(与上一用例同一链路)
  ok=""
  for _ in $(seq 1 40); do
    h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    if printf '%s' "$h" | grep -q '"token":"h4ndSh4ke-Tok9"'; then ok=1; break; fi
    sleep 0.2
  done
  [ "$ok" = "1" ] || { echo "  8s 内 /health 未携带 token(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  # 1) 无 cookie 的 GET /?token= → 必须透传到上游,响应携带 Set-Cookie: dsh-auth
  run curl -s -D - -o "$BATS_TEST_TMPDIR/hs.body" "http://127.0.0.1:$PORT/?token=$FAKE_DSH_TOKEN"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | tr -d '\r' | grep -qi '^set-cookie:.*dsh-auth' \
    || { echo "  握手响应未携带 Set-Cookie: dsh-auth(疑似被引导页拦截): ${output:0:200}" >&2; return 1; }
  grep -q 'handshake-ok' "$BATS_TEST_TMPDIR/hs.body" \
    || { echo "  握手响应体非上游应答(疑似引导页 HTML): $(head -c 200 "$BATS_TEST_TMPDIR/hs.body")" >&2; return 1; }
  # 2) 无 cookie 无 token 的 GET / → 回引导页(而非透传吃 dsh 的 401)
  run curl -s "http://127.0.0.1:$PORT/"
  [ "$status" -eq 0 ]
  assert_body_match "DeepSeek Harness"
  # 3) 带 dsh-auth cookie 的 GET / → 正常透传(拿上游应答而非引导页)
  run curl -s -H "Cookie: dsh-auth=fakesess" "http://127.0.0.1:$PORT/"
  [ "$status" -eq 0 ]
  assert_body_match "app-ok"
}

@test "daemon restart adopts running dsh and still captures launch token" {
  # F5 回归:守护重启收养运行中的 dsh(spawn_pid=0)时也必须扫日志捕获 token,
  # 否则 /health 永远不带 token,引导页等 token 失败后裸 reload 吃 401。
  # 场景:伪 dsh 先起(stdout 重定向到 dsh.log,模拟上实例遗留日志),dsh.json 指向其端口,
  # 守护后启动走 adopt 路径(spawn_pid=0)。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  export FAKE_DSH_TOKEN="ad0pt_Tok-en42"
  export FAKE_DSH_PORT_FILE="$BATS_TEST_TMPDIR/adopt.port"
  cat > "$BATS_TEST_TMPDIR/fake-dsh-adopt.py" <<'PY'
#!/usr/bin/env python3
import os, socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(16)
port = s.getsockname()[1]
pf = os.environ.get("FAKE_DSH_PORT_FILE", "")
if pf:
    with open(pf, "w") as f:
        f.write(str(port))
token = os.environ.get("FAKE_DSH_TOKEN", "unitTESTtoken123")
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=%s\n" % (port, token))
sys.stdout.flush()
s.settimeout(1.0)
deadline = time.time() + 120  # 自限时,bats teardown 再兜底 kill
while time.time() < deadline:
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    except OSError:
        break
    try:
        c.recv(1024)
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    except OSError:
        pass
    c.close()
PY
  TMP_ENV="$(mktemp -d /tmp/dsh-unit.XXXXXX)"
  mkdir -p "$TMP_ENV/rt" "$TMP_ENV/state/logs"
  export DSH_RT_HOME="$TMP_ENV/rt" DSH_RT_STATE="$TMP_ENV/state" DSH_HOME="$TMP_ENV/home"
  export DSH_RT_IDLE_STOP_SECS=60  # 收养场景验证期不空闲停机
  PORT=$(( (RANDOM % 20000) + 20000 ))
  export DSH_RT_PORT="$PORT"
  FAKE_DSH_PID=""
  "$PY" "$BATS_TEST_TMPDIR/fake-dsh-adopt.py" >"$DSH_RT_STATE/logs/dsh.log" 2>&1 &
  FAKE_DSH_PID=$!
  for _ in $(seq 1 20); do [ -s "$FAKE_DSH_PORT_FILE" ] && break; sleep 0.1; done
  [ -s "$FAKE_DSH_PORT_FILE" ] || { echo "  伪 dsh 未启动" >&2; return 1; }
  printf '{"port":%s}\n' "$(cat "$FAKE_DSH_PORT_FILE")" > "$DSH_RT_STATE/dsh.json"
  if ! daemon_compile "$TMP_ENV/daemon"; then
    echo "  daemon 编译失败" >&2
    return 1
  fi
  DAEMON_PID="$(daemon_start_foreground "$TMP_ENV/daemon" "$TMP_ENV/daemon.log")"
  daemon_wait_health "$PORT" any 5 || { echo "  daemon 未就绪(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  got=""
  for _ in $(seq 1 40); do
    h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    if printf '%s' "$h" | grep -q '"token":"ad0pt_Tok-en42"'; then got=1; break; fi
    sleep 0.2
  done
  [ "$got" = "1" ] || { echo "  收养场景 8s 内 /health 未携带 token(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
}

@test "spawn_dsh refuses while install lock held by live pid, spawns after lock clears" {
  # 更新协调回归:update-dsh.sh 持 $RT_HOME/.install.lock/pid(存活 pid)期间,/wake 不得
  # 从半更新的 node_modules 拉起 dsh;锁清除后同一 /wake 路径应能正常拉起。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  export FAKE_DSH_MARKER="$BATS_TEST_TMPDIR/dsh-started.marker"
  cat > "$BATS_TEST_TMPDIR/fake-dsh-lock.py" <<'PY'
#!/usr/bin/env python3
import os, socket, sys
args = sys.argv
port = 0
for i in range(len(args) - 1):
    if args[i] == "--port":
        port = int(args[i + 1])
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=lockT0ken\n" % port)
sys.stdout.flush()
marker = os.environ.get("FAKE_DSH_MARKER", "")
if marker:
    open(marker, "w").close()
ppid = os.getppid()
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(16)
s.settimeout(1.0)
while True:
    if os.getppid() != ppid:
        break
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    except OSError:
        break
    try:
        c.recv(1024)
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    except OSError:
        pass
    c.close()
PY
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh-lock.py\"}"
  # 伪锁:活进程 pid 写入 $RT_HOME/.install.lock/pid
  sleep 60 &
  LOCK_PID=$!
  mkdir -p "$DSH_RT_HOME/.install.lock"
  printf '%s\n' "$LOCK_PID" > "$DSH_RT_HOME/.install.lock/pid"
  # /wake 应 200 但不拉起 dsh:marker 不出现、/health 持续 dsh:false
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  locked_false=""
  for _ in $(seq 1 10); do
    h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    printf '%s' "$h" | grep -q '"dsh":true' && break
    sleep 0.3
  done
  [ ! -f "$FAKE_DSH_MARKER" ] || { kill "$LOCK_PID" 2>/dev/null || true; echo "  持锁期间 dsh 被拉起(marker 已出现)" >&2; return 1; }
  h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
  printf '%s' "$h" | grep -q '"dsh":false' \
    || { kill "$LOCK_PID" 2>/dev/null || true; echo "  持锁期间 /health 应报 dsh:false: $h" >&2; return 1; }
  # 锁清除(pid 死 + 目录移除)后,同一路径 /wake 能正常拉起
  kill "$LOCK_PID" 2>/dev/null || true
  wait "$LOCK_PID" 2>/dev/null || true
  rm -rf "$DSH_RT_HOME/.install.lock"
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  ok=""
  for _ in $(seq 1 40); do
    h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    if printf '%s' "$h" | grep -q '"dsh":true'; then ok=1; break; fi
    sleep 0.2
  done
  [ "$ok" = "1" ] || { echo "  锁清除后 8s 内 dsh 未被拉起(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  [ -f "$FAKE_DSH_MARKER" ] || { echo "  dsh 就绪但 marker 未出现(伪 dsh 未真正执行?)" >&2; return 1; }
}
