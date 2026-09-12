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
  export DSH_RT_NO_AUTO_UPDATE=1   # 测试环境绝不触发后台更新子进程
  PORT="$(pick_free_port)"
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
  if [ -n "${STOP_CURL_PID:-}" ]; then
    kill "$STOP_CURL_PID" 2>/dev/null || true
    STOP_CURL_PID=""
  fi
  if [ -n "${LOCK_PID:-}" ]; then
    kill "$LOCK_PID" 2>/dev/null || true
    LOCK_PID=""
  fi
  if [ -n "${FAKE_DSH_PID:-}" ]; then
    kill "$FAKE_DSH_PID" 2>/dev/null || true
    FAKE_DSH_PID=""
  fi
  if [ -n "${VICTIM_PID:-}" ]; then
    kill "$VICTIM_PID" 2>/dev/null || true
    wait "$VICTIM_PID" 2>/dev/null || true
    VICTIM_PID=""
  fi
  # 兜底:按二进制路径收尾。A2/E3 用例会故意制造「上游只收不读」,若修复失效,连接子进程会
  # 卡在 write(2) 上 —— 只按 pid 杀守护本体是收不掉它的。必须在 stop_daemon_env 之前,
  # 因为那个函数会把 TMP_ENV 清空。
  [ -z "${TMP_ENV:-}" ] || daemon_stop_by_binary "$TMP_ENV/daemon"
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
  export DSH_RT_NO_AUTO_UPDATE=1
  PORT="$(pick_free_port)"
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

@test "wake refused by install lock is retried after lock clears without a new wake" {
  # 回归:引导页只在首次进入时 POST 一次 /wake(BOOT_PAGE 的 fired 守卫),之后仅轮询 /health,
  # 而 /health 不触发 spawn(只有 /wake 与页面请求会)。若那唯一一次唤醒撞上 update-dsh.sh 持
  # .install.lock,旧实现直接丢弃且无人重试 → 页面永久停在「正在唤醒…」。
  # 来源:CI 冒烟 3b(并发双 /wake)被拒后仅轮询 /health,卡满 300s 超时;同一提交重跑即绿,
  # 说明是依赖 npm view 时长的时序型缺陷。故本用例刻意不再发第二次 /wake,只轮询 /health。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  export FAKE_DSH_MARKER="$BATS_TEST_TMPDIR/dsh-started.marker"
  cat > "$BATS_TEST_TMPDIR/fake-dsh-pending.py" <<'PY'
#!/usr/bin/env python3
import os, socket, sys
args = sys.argv
port = 0
for i in range(len(args) - 1):
    if args[i] == "--port":
        port = int(args[i + 1])
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=pendingTok\n" % port)
sys.stdout.flush()
marker = os.environ.get("FAKE_DSH_MARKER", "")
if marker:
    open(marker, "w").close()
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
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    except OSError:
        pass
    c.close()
PY
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh-pending.py\"}"
  # 伪锁:活进程 pid 写入 $RT_HOME/.install.lock/pid
  sleep 60 &
  LOCK_PID=$!
  mkdir -p "$DSH_RT_HOME/.install.lock"
  printf '%s\n' "$LOCK_PID" > "$DSH_RT_HOME/.install.lock/pid"
  # 唯一一次 /wake:被锁拒绝(200 但不拉起)
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  sleep 0.5
  [ ! -f "$FAKE_DSH_MARKER" ] || { echo "  持锁期间 dsh 被拉起(marker 已出现)" >&2; return 1; }
  grep -q "更新进行中" "$TMP_ENV/daemon.log" \
    || { echo "  守护未走 install.lock 拒绝路径(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  # 释放锁:此后不再发任何 /wake,只轮询 /health(与引导页 tick 行为一致)
  kill "$LOCK_PID" 2>/dev/null || true
  wait "$LOCK_PID" 2>/dev/null || true
  rm -rf "$DSH_RT_HOME/.install.lock"
  ok=""
  for _ in $(seq 1 60); do
    h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    if printf '%s' "$h" | grep -q '"dsh":true'; then ok=1; break; fi
    sleep 0.2
  done
  [ "$ok" = "1" ] \
    || { echo "  锁释放后仅轮询 /health,12s 内被丢弃的唤醒未被自愈重试(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  [ -f "$FAKE_DSH_MARKER" ] || { echo "  /health 报 dsh:true 但伪 dsh 未真正执行(marker 缺失)" >&2; return 1; }
}

@test "boot page re-fires /wake until dsh becomes ready" {
  # 回归:引导页旧实现用 fired 守卫只 POST 一次 /wake —— 单次丢包,或服务端在更新期丢弃唤醒
  # (spawn_dsh 的 install.lock 分支),页面就永久卡在「正在唤醒…」。新实现最多每 2s 重发一次。
  # 这里真跑页面 JS:从 GET / 抽出 <script>,在 node 里用桩(fetch/document/Date.now/setTimeout)
  # 驱动 tick() 若干轮并统计 /wake 次数 —— 断言行为而非对源码做字符串匹配
  # (字符串门禁抓不住「守卫又加回来」这类回归)。
  NODE="$(command -v node || true)"
  [ -n "$NODE" ] || { echo "  node 不可用,无法驱动页面 JS" >&2; return 1; }
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  curl -s "http://127.0.0.1:$PORT/" > "$BATS_TEST_TMPDIR/boot.html"
  grep -q "DeepSeek Harness" "$BATS_TEST_TMPDIR/boot.html" \
    || { echo "  GET / 未返回引导页(见 $BATS_TEST_TMPDIR/boot.html)" >&2; return 1; }
  cat > "$BATS_TEST_TMPDIR/boot-harness.js" <<'JS'
const fs = require('fs'), vm = require('vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { console.error('no <script> block'); process.exit(2); }
let wakes = 0, healths = 0, domReady = null;
const els = {};
const mkEl = () => ({ style: {}, className: '', textContent: '', onclick: null });
global.document = {
  getElementById: (id) => (els[id] || (els[id] = mkEl())),
  addEventListener: (ev, fn) => { if (ev === 'DOMContentLoaded') domReady = fn; },
};
global.window = { addEventListener: () => {} };
global.navigator = {};
global.location = { reload: () => {} };
global.setTimeout = () => 0;   // 桩掉自调度,改由 harness 显式驱动 tick,避免无限循环
global.setInterval = () => 0;
global.fetch = (u) => {
  const s = String(u);
  if (s.indexOf('/health') === 0) { healths++; return Promise.resolve({ json: () => Promise.resolve({ dsh: false }) }); }
  if (s === '/wake') { wakes++; return Promise.resolve({}); }
  return Promise.resolve({});
};
let now = 1000000;
Date.now = () => now;          // 假时钟:每轮前进 3s,跨过 2s 重发节流窗口
vm.runInThisContext(m[1]);
const flush = () => new Promise((r) => setImmediate(r));
(async () => {
  if (!domReady) { console.error('no DOMContentLoaded handler'); process.exit(3); }
  domReady();                                    // 首次 tick 由页面自己发起
  for (let i = 0; i < 6; i++) {
    await flush();
    now += 3000;
    if (typeof globalThis.tick === 'function') globalThis.tick();
  }
  await flush();
  console.log('wakes=' + wakes + ' healths=' + healths);
})();
JS
  run "$NODE" "$BATS_TEST_TMPDIR/boot-harness.js" "$BATS_TEST_TMPDIR/boot.html"
  [ "$status" -eq 0 ] || { echo "  页面 JS 驱动失败: $output" >&2; return 1; }
  healths="$(printf '%s' "$output" | sed -n 's/.*healths=\([0-9]*\).*/\1/p')"
  wakes="$(printf '%s' "$output" | sed -n 's/.*wakes=\([0-9]*\).*/\1/p')"
  [ "${healths:-0}" -ge 3 ] \
    || { echo "  轮询未推进(healths=$healths),harness 可能失效" >&2; return 1; }
  [ "${wakes:-0}" -ge 3 ] \
    || { echo "  7 轮 tick(每轮间隔 3s)只发出 ${wakes:-0} 次 /wake,引导页未重发唤醒" >&2; return 1; }
}

@test "lowercase origin header with correct value is accepted" {
  # 头字段名应大小写不敏感(RFC 7230):小写 origin: + 正确值不得被误拒为 CSRF(应 200 而非 403)
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
}

@test "lowercase host header with valid value returns 200 on health" {
  # curl -H 'host:' 会被规范化回 Host:,用原始 socket 发真正的小写 host: 头
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  code="$("$PY" - "$PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=3)
s.sendall(("GET /health HTTP/1.1\r\nhost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n" % port).encode())
data = b""
while True:
    try:
        chunk = s.recv(4096)
    except OSError:
        break
    if not chunk:
        break
    data += chunk
s.close()
print(data.split(b" ", 2)[1].decode() if b" " in data else "000")
PY
)"
  [ "$code" = "200" ] || { echo "  小写 host: 头 /health 应 200,得到 [$code]" >&2; return 1; }
}

@test "stop then immediate wake keeps new dsh state files" {
  # P2 竞态回归:伪 dsh 收 SIGTERM 后优雅退出耗时 1s(拉宽 stop 等待窗口)。
  # 旧实现:/stop 在连接子进程直连执行,等待期间主进程因 /wake spawn 新 dsh 并写新
  # dsh.json/dsh.pid;旧 stop 结束时无条件 unlink 两个文件,误删新实例状态。
  # 新实现:/stop 只投递命令字节,主进程串行结算 stop→wake,新实例状态不被误删。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  cat > "$BATS_TEST_TMPDIR/fake-dsh-slowstop.py" <<'PY'
#!/usr/bin/env python3
import os, signal, socket, sys, time
args = sys.argv
port = 0
for i in range(len(args) - 1):
    if args[i] == "--port":
        port = int(args[i + 1])
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=stopRaceTok\n" % port)
sys.stdout.flush()
ppid = os.getppid()
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(16)
s.settimeout(1.0)
def onterm(sig, frm):
    # 立刻关监听 socket:dsh_up() 探测即刻变 false(新实例可被 /wake 拉起),
    # 但进程本身再存活 1s——stop_dsh 的等待循环必须真等一轮,竞态窗口拉满全程
    try:
        s.close()
    except OSError:
        pass
    time.sleep(1.0)
    os._exit(0)
signal.signal(signal.SIGTERM, onterm)
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
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh-slowstop.py\"}"
  # 实例 1:拉起并等就绪
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  daemon_wait_health "$PORT" true 5 || { echo "  实例 1 未就绪(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  old_pid="$(cat "$DSH_RT_STATE/dsh.pid" 2>/dev/null || true)"
  # /stop 后台发出(旧实现会在连接子进程里同步阻塞最长 6s),同时立即反复 /wake
  # 覆盖 stop 等待窗口,直到拉起新实例(started 响应)
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/stop" > "$BATS_TEST_TMPDIR/stop.code" &
  STOP_CURL_PID=$!
  started=""
  for _ in $(seq 1 60); do
    r="$(curl -s --max-time 2 -X POST -H "Origin: http://127.0.0.1:$PORT" \
      "http://127.0.0.1:$PORT/wake" 2>/dev/null || true)"
    if printf '%s' "$r" | grep -q 'started'; then started=1; break; fi
    sleep 0.1
  done
  wait "$STOP_CURL_PID" 2>/dev/null || true
  [ "$(cat "$BATS_TEST_TMPDIR/stop.code")" = "200" ] \
    || { echo "  /stop 响应非 200: $(cat "$BATS_TEST_TMPDIR/stop.code")" >&2; return 1; }
  [ "$started" = "1" ] || { echo "  6s 内 /wake 未拉起新实例(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  # 等新实例就绪:pid 必须与实例 1 不同(确认是重启而非旧实例存活)
  new_ok=""
  for _ in $(seq 1 60); do
    h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    if printf '%s' "$h" | grep -q '"dsh":true'; then
      p="$(printf '%s' "$h" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')"
      if [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "$old_pid" ]; then new_ok=1; break; fi
    fi
    sleep 0.2
  done
  [ "$new_ok" = "1" ] || { echo "  12s 内新实例未就绪(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  # 核心断言:连续 ~5s(跨过旧实现 stop 子进程的误删时刻)新实例状态文件健在且一致。
  # 轮询本身也是在场证据,避免 IDLE_STOP 误停。
  for _ in $(seq 1 10); do
    h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    printf '%s' "$h" | grep -q '"dsh":true' || { echo "  新实例未持续就绪: $h" >&2; return 1; }
    port="$(printf '%s' "$h" | sed -n 's/.*"port":\([0-9]*\).*/\1/p')"
    [ -f "$DSH_RT_STATE/dsh.json" ] || { echo "  dsh.json 被误删(stop/wake 竞态)" >&2; return 1; }
    grep -q "\"port\":$port" "$DSH_RT_STATE/dsh.json" \
      || { echo "  dsh.json 端口与新实例不一致: $(cat "$DSH_RT_STATE/dsh.json")" >&2; return 1; }
    [ -f "$DSH_RT_STATE/dsh.pid" ] || { echo "  dsh.pid 被误删(stop/wake 竞态)" >&2; return 1; }
    fpid="$(cat "$DSH_RT_STATE/dsh.pid")"
    kill -0 "$fpid" 2>/dev/null \
      || { echo "  dsh.pid 指向已死进程($fpid)" >&2; return 1; }
    sleep 0.5
  done
}

# ---- CSRF 矩阵(origin_ok):四个状态变更端点全覆盖 + localhost 分支 + 前缀绕过 + 透传路径 ----

@test "POST /stop without Origin returns 403" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/stop"
  assert_status "403"
}

@test "POST /ping without Origin returns 403" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/ping"
  assert_status "403"
}

@test "POST /goodbye without Origin returns 403" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/goodbye"
  assert_status "403"
}

@test "POST /stop with matching Origin returns 200 async" {
  # /stop 语义是异步投递命令字节即回 200(不阻塞等待 dsh 死透),无 dsh 时同样 200
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -w '\n%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/stop"
  [ "${lines[1]}" = "200" ] || { echo "  expected 200, got ${lines[1]}" >&2; return 1; }
  assert_body_match '"stopped":true'
}

@test "POST /stop with prefix-bypass Origin suffix returns 403" {
  # http://127.0.0.1:PORT.evil.com 以期望值开头但整体是 evil 域名,必须 403
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT.evil.com" \
    "http://127.0.0.1:$PORT/stop"
  assert_status "403"
}

@test "POST /wake with localhost Origin returns 200" {
  # origin_ok 的 localhost 分支:http://localhost:PORT 同样放行
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://localhost:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
}

@test "relay POST /api/x without Origin returns 403, with Origin passes through" {
  # 透传路径同样有 CSRF 防护:dsh 就绪后,POST 无 Origin → 403;正确 Origin → 透传拿到上游应答
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  cat > "$BATS_TEST_TMPDIR/fake-dsh-api.py" <<'PY'
#!/usr/bin/env python3
import os, socket, sys
args = sys.argv
port = 0
for i in range(len(args) - 1):
    if args[i] == "--port":
        port = int(args[i + 1])
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=apiT0ken\n" % port)
sys.stdout.flush()
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
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\napibod")
    except OSError:
        pass
    c.close()
PY
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh-api.py\"}"
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  daemon_wait_health "$PORT" true 5 || { echo "  伪 dsh 未就绪(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  run curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST \
    "http://127.0.0.1:$PORT/api/x"
  assert_status "403"
  run curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST \
    -H "Origin: http://127.0.0.1:$PORT.evil.com" \
    "http://127.0.0.1:$PORT/api/x"
  assert_status "403"
  run curl -s -w '\n%{http_code}' --max-time 3 -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/api/x"
  [ "${lines[1]}" = "200" ] || { echo "  正确 Origin 的透传应 200,得到 ${lines[1]}" >&2; return 1; }
  assert_body_match '^apibod'
}

# ---- Host 矩阵(host_ok):localhost 放行 / 无 Host 拒绝 / 前缀绕过拒绝 ----

@test "GET /health with Host localhost:PORT returns 200" {
  # curl 默认发 Host: 127.0.0.1:PORT,显式 -H 覆盖为 localhost:PORT 应同样放行
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -H "Host: localhost:$PORT" \
    "http://127.0.0.1:$PORT/health"
  assert_status "200"
}

@test "GET /health without Host header (raw HTTP/1.0) returns 403" {
  # HTTP/1.0 原始请求无 Host 头(host_ok 找不到 Host 即拒绝),防非浏览器客户端绕过
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  code="$("$PY" - "$PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=3)
s.sendall(b"GET /health HTTP/1.0\r\n\r\n")
data = b""
while True:
    try:
        chunk = s.recv(4096)
    except OSError:
        break
    if not chunk:
        break
    data += chunk
s.close()
print(data.split(b" ", 2)[1].decode() if b" " in data else "000")
PY
)"
  [ "$code" = "403" ] || { echo "  无 Host 头应 403,得到 [$code]" >&2; return 1; }
}

@test "GET /health with Host 127.0.0.1:PORT.evil.com returns 403" {
  # Host 值以期望值开头但整体是 evil 域名,必须 403(前缀绕过变体)
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s -o /dev/null -w '%{http_code}' -H "Host: 127.0.0.1:$PORT.evil.com" \
    "http://127.0.0.1:$PORT/health"
  assert_status "403"
}

# ---- 故障注入组:崩溃风暴冷却 / SIGTERM 拒死走 SIGKILL 兜底 / 崩溃自愈 ----

@test "crash storm enters cooldown and boot page stays responsive" {
  # run.json 指向立即退出(exit 0)的假 dsh:连发 3 次 /wake 都被拉起;
  # 第 4 次 /wake 触发 60s 冷却不再拉起;冷却期间 GET / 秒回引导页(非阻塞)。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  export FAKE_DSH_CRASH_LOG="$BATS_TEST_TMPDIR/crash-spawns.log"
  cat > "$BATS_TEST_TMPDIR/fake-dsh-crash.py" <<'PY'
#!/usr/bin/env python3
import os, sys
log = os.environ.get("FAKE_DSH_CRASH_LOG", "")
if log:
    with open(log, "a") as f:
        f.write("%d\n" % os.getpid())
sys.exit(0)
PY
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh-crash.py\"}"
  nspawn() { [ -f "$FAKE_DSH_CRASH_LOG" ] && wc -l < "$FAKE_DSH_CRASH_LOG" | tr -d ' ' || echo 0; }
  for i in 1 2 3; do
    run curl -s -o /dev/null -w '%{http_code}' -X POST \
      -H "Origin: http://127.0.0.1:$PORT" \
      "http://127.0.0.1:$PORT/wake"
    assert_status "200"
    ok=""
    for _ in $(seq 1 30); do
      [ "$(nspawn)" -ge "$i" ] && { ok=1; break; }
      sleep 0.1
    done
    [ "$ok" = "1" ] || { echo "  第 $i 次 /wake 后假 dsh 未被拉起(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  done
  # 第 4 次 /wake:进入冷却,不再拉起(等待一个足够窗口确认无第 4 个 spawn)
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  sleep 1
  [ "$(nspawn)" = "3" ] \
    || { echo "  第 4 次 /wake 后仍拉起了 dsh(冷却未生效,spawn 数 $(nspawn))" >&2; return 1; }
  # 冷却期间主循环不被阻塞:GET / 秒回引导页
  t0=$(python3 -c 'import time; print(time.time())')
  run curl -s -w '\n%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/"
  t1=$(python3 -c 'import time; print(time.time())')
  [ "${lines[1]}" = "200" ] || { echo "  冷却期间 GET / 应 200,得到 ${lines[1]}" >&2; return 1; }
  assert_body_match "DeepSeek Harness"
  el="$(python3 -c "print(round($t1 - $t0, 1))")"
  [ "$(python3 -c "print(1 if $el < 2.0 else 0)")" = "1" ] \
    || { echo "  冷却期间 GET / 耗时 ${el}s(疑似阻塞主循环)" >&2; return 1; }
}

@test "stop escalates to SIGKILL when dsh ignores SIGTERM" {
  # 伪 dsh trap SIGTERM 后拒死:POST /stop(异步 200)后,SIGTERM 宽限(~6s)耗尽
  # 必须升级 SIGKILL 把进程组打死的兜底路径。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  cat > "$BATS_TEST_TMPDIR/fake-dsh-stubborn.py" <<'PY'
#!/usr/bin/env python3
import os, signal, socket, sys
args = sys.argv
port = 0
for i in range(len(args) - 1):
    if args[i] == "--port":
        port = int(args[i + 1])
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=stubbornTok\n" % port)
sys.stdout.flush()
signal.signal(signal.SIGTERM, signal.SIG_IGN)  # 拒绝优雅退出,逼出 SIGKILL 兜底
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
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh-stubborn.py\"}"
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  daemon_wait_health "$PORT" true 5 || { echo "  伪 dsh 未就绪(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  dsh_pid="$(cat "$DSH_RT_STATE/dsh.pid" 2>/dev/null || true)"
  [ -n "$dsh_pid" ] || { echo "  dsh.pid 缺失" >&2; return 1; }
  kill -0 "$dsh_pid" 2>/dev/null || { echo "  伪 dsh 未存活" >&2; return 1; }
  run curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/stop"
  assert_status "200"  # 异步语义:立即 200,不等待 dsh 死透
  dead=""
  for _ in $(seq 1 90); do
    kill -0 "$dsh_pid" 2>/dev/null || { dead=1; break; }
    sleep 0.1
  done
  [ "$dead" = "1" ] \
    || { kill -9 "$dsh_pid" 2>/dev/null || true; echo "  /stop 后 9s 内拒死 dsh 未被 SIGKILL(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
}

@test "dsh crash self-heals on next wake" {
  # 伪 dsh 就绪后收到 GET /die 自杀(SIGKILL self):主循环 waitpid 收割(spawn_pid 清零
  # → 状态清理 → /health 翻 dsh:false),随后 /wake 必须能重新拉起新实例。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  cat > "$BATS_TEST_TMPDIR/fake-dsh-suicidal.py" <<'PY'
#!/usr/bin/env python3
import os, signal, socket, sys
args = sys.argv
port = 0
for i in range(len(args) - 1):
    if args[i] == "--port":
        port = int(args[i + 1])
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=suicideTok\n" % port)
sys.stdout.flush()
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
        req = c.recv(1024).decode("latin-1")
        if req.startswith("GET /die"):
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndied")
            c.close()
            os.kill(os.getpid(), signal.SIGKILL)  # 模拟 dsh 崩溃
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    except OSError:
        pass
    c.close()
PY
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh-suicidal.py\"}"
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  daemon_wait_health "$PORT" true 5 || { echo "  伪 dsh 未就绪(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  old_pid="$(cat "$DSH_RT_STATE/dsh.pid" 2>/dev/null || true)"
  # 触发自杀(curl 可能收到连接重置,忽略)
  curl -s --max-time 3 "http://127.0.0.1:$PORT/die" >/dev/null 2>&1 || true
  fell=""
  for _ in $(seq 1 30); do
    h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    printf '%s' "$h" | grep -q '"dsh":false' && { fell=1; break; }
    sleep 0.2
  done
  [ "$fell" = "1" ] || { echo "  dsh 自杀后 6s 内 /health 未翻 dsh:false(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  # 再 /wake:必须能重新拉起(waitpid 清理链完整),且是新 pid
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  revived=""
  for _ in $(seq 1 40); do
    h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    if printf '%s' "$h" | grep -q '"dsh":true'; then
      p="$(printf '%s' "$h" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')"
      if [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "$old_pid" ]; then revived=1; break; fi
    fi
    sleep 0.2
  done
  [ "$revived" = "1" ] || { echo "  /wake 未重新拉起 dsh(或 pid 未变化)(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
}

@test "dsh exiting 9 on an unusable NODE_OPTIONS self-heals on the next wake" {
  # F1 的服务端兜底。plist 里的 NODE_OPTIONS 已由 install.sh 按能力探测注入,但手工编辑 plist、
  # 或安装后把 node 换到更旧版本,都会让 NODE_OPTIONS 含当前 node 不认识的选项 —— node 会
  # **拒绝启动**并返回 9(实测:一行代码都不执行)。表现是「守护在跑、dsh 永远起不来」,
  # 且没有任何用户可见的错误。守护观察到退出码 9 后剥掉该变量;客户端只轮询 /health、
  # 不会自己重试,所以自愈责任必须在服务端。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  # 伪 dsh:只要 NODE_OPTIONS 含 --use-system-ca 就 exit 9(忠实复刻旧 node 的行为),
  # 否则正常打印 launch token 并服务。
  cat > "$BATS_TEST_TMPDIR/fake-dsh-nodeopts.py" <<'PY'
#!/usr/bin/env python3
import os, socket, sys
if "--use-system-ca" in os.environ.get("NODE_OPTIONS", ""):
    sys.exit(9)  # 旧 node 拒绝 NODE_OPTIONS 里的未知选项:一行代码都不执行
args = sys.argv
port = 0
for i in range(len(args) - 1):
    if args[i] == "--port":
        port = int(args[i + 1])
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=nodeoptsTok\n" % port)
sys.stdout.flush()
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
  # 模拟「plist 注入了旧 node 不接受的选项」:守护继承该环境变量并透传给 dsh。
  export NODE_OPTIONS="--use-system-ca"
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh-nodeopts.py\"}"
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  # 守护必须**识别**出退出码 9 的成因(而不是只在日志里留一行普通退出记录)。
  detected=""
  for _ in $(seq 1 30); do
    if grep -q '不被当前 node 接受' "$TMP_ENV/daemon.log" 2>/dev/null; then detected=1; break; fi
    sleep 0.2
  done
  [ "$detected" = "1" ] || { echo "  守护未识别退出码 9(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  # 再唤醒:必须已剥掉 NODE_OPTIONS 并成功拉起 dsh。这一条同时是「上一条不是空转」的正控 ——
  # 没有它,「日志里出现了那句话」可能只是打了一行日志而行为没变。
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  daemon_wait_health "$PORT" true 10 \
    || { echo "  剥离 NODE_OPTIONS 后仍未拉起 dsh(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  unset NODE_OPTIONS
}

@test "SIGTERM stops dsh and cleans state instead of orphaning it" {
  # F5。plist 里 AbandonProcessGroup=true,而 dsh 又经 setsid 自成会话 —— 两者叠加使
  # launchd **不会**连带清理 dsh。守护若不处理 SIGTERM(launchctl bootout / kickstart -k
  # 都发它),dsh 就成了孤儿:继续常驻、继续占端口,而守护已经退出、再没有任何东西会提到它。
  # 这是**唯一**没有用户可见信号的泄漏路径(零常驻承诺被破坏),且只在卸载/重装/升级时发生,
  # 日常使用完全看不到。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  cat > "$BATS_TEST_TMPDIR/fake-dsh-long.py" <<'PY'
#!/usr/bin/env python3
# 忠实复刻真实 dsh 的两点:1) 经 setsid 自成会话,**父进程死掉也不会跟着退**;
# 2) 收到 SIGTERM 才退出(python 默认动作)。故这里**不能**加 ppid 看门狗 ——
# 那会让伪 dsh 在守护被杀后自己退出,「孤儿」这条断言就永远测不到东西。
import os, socket, sys
args = sys.argv
port = 0
for i in range(len(args) - 1):
    if args[i] == "--port":
        port = int(args[i + 1])
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=sigtermTok\n" % port)
sys.stdout.flush()
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(16)
s.settimeout(1.0)
while True:
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
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh-long.py\"}"
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  daemon_wait_health "$PORT" true 5 || { echo "  伪 dsh 未就绪(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  dsh_pid="$(cat "$DSH_RT_STATE/dsh.pid" 2>/dev/null || true)"
  [ -n "$dsh_pid" ] || { echo "  dsh.pid 缺失,夹具无效" >&2; return 1; }
  FAKE_DSH_PID="$dsh_pid"   # 交给 teardown 兜底:任何提前失败都不许把它留成真孤儿
  # 反空转:伪 dsh 必须**真的在跑**,否则「没有孤儿」是假绿(它可能压根没起来)。
  kill -0 "$dsh_pid" 2>/dev/null || { echo "  伪 dsh 未在运行,夹具无效" >&2; return 1; }

  # 发 SIGTERM(与 launchctl bootout 同信号),并给收尾计时。
  # 判退出用 kill -0:守护是 $( ) 子 shell 的后台作业,不是本 shell 的子进程,故 wait 不可用;
  # 被 init 收养后退出即被收割,不会有僵尸让 kill -0 恒成功。
  t0="$(date +%s)"
  kill -TERM "$DAEMON_PID" 2>/dev/null || true
  exited=""
  for _ in $(seq 1 60); do
    kill -0 "$DAEMON_PID" 2>/dev/null || { exited=1; break; }
    sleep 0.1
  done
  t1="$(date +%s)"
  DAEMON_PID=""   # 无论结果如何都不再重复杀;下面按断言归因
  [ "$exited" = "1" ] || { echo "  守护收到 SIGTERM 后 6s 未退出(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  # 收尾预算:必须明显快于 stop_dsh 的 6s 优雅期 —— 否则会拖慢 launchd 卸载与测试 teardown。
  [ "$((t1 - t0))" -le 4 ] \
    || { echo "  守护收尾耗时 $((t1 - t0))s(应 <=4s)" >&2; return 1; }

  # 核心断言:伪 dsh 必须已被停掉。不修的话它照样活着(默认 SIGTERM 动作只是杀掉守护自己)。
  gone=""
  for _ in $(seq 1 30); do
    kill -0 "$dsh_pid" 2>/dev/null || { gone=1; break; }
    sleep 0.1
  done
  if [ "$gone" != "1" ]; then
    kill -9 "$dsh_pid" 2>/dev/null || true
    FAKE_DSH_PID=""
    echo "  SIGTERM 后 dsh(pid $dsh_pid)仍在运行 —— 孤儿(日志见 $TMP_ENV/daemon.log)" >&2
    return 1
  fi
  FAKE_DSH_PID=""   # 已被守护停掉,teardown 无需再收
  # 状态文件也必须清干净:留着会让下次守护启动收养一个已死的 pid。
  if [ -f "$DSH_RT_STATE/dsh.json" ] || [ -f "$DSH_RT_STATE/dsh.pid" ]; then
    echo "  SIGTERM 后状态文件未清理(dsh.json/dsh.pid)" >&2
    return 1
  fi
}

@test "stop skips signaling when dsh.pid points at non-node process (PID reuse guard)" {
  # stop_dsh 发信号前必须核对可执行路径(proc_pidpath)。黑盒近似「PID 被回收给无关进程」的
  # 最坏场景:dsh 就绪后把 dsh.pid 覆写为另一个活进程(sleep)的 pid——kill(pid,0) 恒通过,
  # 旧实现会误发 SIGTERM/SIGKILL 打死无辜进程。新实现发现其可执行文件非 node 后应跳过信号、
  # 只清状态文件并记日志:受害 sleep 必须存活,状态文件被清,日志出现复用判定。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  cat > "$BATS_TEST_TMPDIR/fake-dsh-reuse.py" <<'PY'
#!/usr/bin/env python3
import os, socket, sys
args = sys.argv
port = 0
for i in range(len(args) - 1):
    if args[i] == "--port":
        port = int(args[i + 1])
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=reuseTok9\n" % port)
sys.stdout.flush()
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
  start_daemon_env "{\"node\":\"$PY\",\"dsh\":\"$BATS_TEST_TMPDIR/fake-dsh-reuse.py\"}"
  run curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/wake"
  assert_status "200"
  daemon_wait_health "$PORT" true 5 || { echo "  伪 dsh 未就绪(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
  # 受害进程:sleep 模拟「PID 被回收后的无关进程」(kill -0 恒通过但可执行文件非 node);
  # 注意后续操作需在 IDLE_STOP(2s) 窗口内完成,避免空闲停机路径先以真实 dsh pid 抢先执行
  sleep 60 &
  VICTIM_PID=$!
  # 覆写 dsh.pid 模拟 PID 复用(真实场景:dsh 已死、其 PID 被分配给 sleep)
  printf '%s\n' "$VICTIM_PID" > "$DSH_RT_STATE/dsh.pid"
  run curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    "http://127.0.0.1:$PORT/stop"
  assert_status "200"
  ok=""
  for _ in $(seq 1 30); do
    # 受害进程必须存活(未被误杀);状态文件被清;日志出现 PID 复用判定
    if kill -0 "$VICTIM_PID" 2>/dev/null \
       && [ ! -f "$DSH_RT_STATE/dsh.pid" ] \
       && [ ! -f "$DSH_RT_STATE/dsh.json" ] \
       && grep -q '疑似被复用' "$TMP_ENV/daemon.log" 2>/dev/null; then
      ok=1
      break
    fi
    sleep 0.2
  done
  [ "$ok" = "1" ] || { echo "  stop_dsh 对非 node pid 未跳过信号(受害进程被误杀或状态未清,日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
}

@test "stuck upstream does not pin the relay child" {
  # A2 + E3 回归。上游(伪 dsh)「只收不读」时,relay 里的 write_all(u,…) 会在写满 socket
  # 缓冲后阻塞在 write(2)。修复前:连接子进程永不退出 → 主循环 waitpid 收不到 → active 恒 >0
  # → 空闲停机判定(dsh_port>0 && active==0)永不成立 → dsh 不停、守护不自退,零常驻承诺失效。
  # 修复后:上游 socket 有 SO_SNDTIMEO → write 返回 EAGAIN → write_all 改为等可写且**有上限**
  # → 放弃本次写入 → relay 收尾整条连接 → 子进程退出。
  # 判据(可观测):发一个足以填满上游缓冲的 POST 之后,连接子进程必须在有限时间内消失,
  # 只剩守护本体。用小子超时(1s / 300ms)把等待压到秒级,避免用例本身跑很久。
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  export FAKE_DSH_PORT_FILE="$BATS_TEST_TMPDIR/stuck.port"
  cat > "$BATS_TEST_TMPDIR/fake-dsh-stuck.py" <<'PY'
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
sys.stdout.write("dsh web: http://127.0.0.1:%d/?token=stuckT0ken\n" % port)
sys.stdout.flush()
s.settimeout(1.0)
deadline = time.time() + 120
held = []
while time.time() < deadline:
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    except OSError:
        break
    try:
        c.settimeout(1.0)
        first = c.recv(1024)
    except OSError:
        first = b""
    if first.startswith(b"GET "):
        try:
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        except OSError:
            pass
        c.close()
    else:
        held.append(c)
PY
  TMP_ENV="$(mktemp -d /tmp/dsh-unit.XXXXXX)"
  mkdir -p "$TMP_ENV/rt" "$TMP_ENV/state/logs"
  export DSH_RT_HOME="$TMP_ENV/rt" DSH_RT_STATE="$TMP_ENV/state" DSH_HOME="$TMP_ENV/home"
  export DSH_RT_IDLE_STOP_SECS=60   # 本用例验证期内不要空闲停机
  export DSH_RT_NO_AUTO_UPDATE=1
  export DSH_RT_IO_TIMEOUT_SECS=1   # 上游写超时
  export DSH_RT_WRITE_WAIT_MS=300   # 等可写的上限
  PORT="$(pick_free_port)"
  export DSH_RT_PORT="$PORT"
  FAKE_DSH_PID=""
  "$PY" "$BATS_TEST_TMPDIR/fake-dsh-stuck.py" >"$DSH_RT_STATE/logs/dsh.log" 2>&1 &
  FAKE_DSH_PID=$!
  for _ in $(seq 1 20); do [ -s "$FAKE_DSH_PORT_FILE" ] && break; sleep 0.1; done
  [ -s "$FAKE_DSH_PORT_FILE" ] || { echo "  伪 dsh 未启动" >&2; return 1; }
  printf '{"port":%s}\n' "$(cat "$FAKE_DSH_PORT_FILE")" > "$DSH_RT_STATE/dsh.json"
  daemon_compile "$TMP_ENV/daemon" || { echo "  daemon 编译失败" >&2; return 1; }
  DAEMON_PID="$(daemon_start_foreground "$TMP_ENV/daemon" "$TMP_ENV/daemon.log")"
  # 等 dsh:true —— 即 dsh_ready() 成立,请求才会被透传而不是拿到引导页
  daemon_wait_health "$PORT" true 8 || { echo "  守护未就绪(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }

  # 基线:此刻只有守护本体(每个请求的连接子进程都是短命的)
  base="$(pgrep -f "^${TMP_ENV}/daemon( |\$)" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$base" = "1" ] || { echo "  基线进程数异常:$base(应为 1)" >&2; return 1; }

  # 4MB 请求体:远超回环 socket 缓冲,必然把「只收不读」的上游写满
  head -c 4194304 /dev/zero | tr '\0' 'x' > "$BATS_TEST_TMPDIR/big.bin"
  curl -s -o /dev/null --max-time 30 -X POST \
    -H "Origin: http://127.0.0.1:$PORT" \
    --data-binary "@$BATS_TEST_TMPDIR/big.bin" \
    "http://127.0.0.1:$PORT/api/x" >/dev/null 2>&1 || true

  ok=""
  for _ in $(seq 1 100); do
    n="$(pgrep -f "^${TMP_ENV}/daemon( |\$)" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$n" = "1" ]; then ok=1; break; fi
    sleep 0.2
  done
  if [ "$ok" != "1" ]; then
    echo "  连接子进程未在 20s 内退出(残留 $n 个)—— 卡在上游写,active 永不归零(A2/E3)" >&2
    return 1
  fi
}

# ---- token 采集(E1)辅助:伪 dsh + dsh.json + 预置 dsh.log,走「收养运行中 dsh」路径 ----
# 用法: start_token_env <token>;结果:TMP_ENV / PORT / DAEMON_PID
start_token_env() {
  local tok="$1" py="" fp=""
  py="$(command -v python3 || true)"
  [ -n "$py" ] || { echo "  python3 不可用" >&2; return 1; }
  export FAKE_DSH_PORT_FILE="$BATS_TEST_TMPDIR/tok.port"
  rm -f "$FAKE_DSH_PORT_FILE"
  cat > "$BATS_TEST_TMPDIR/fake-dsh-tok.py" <<'PY'
#!/usr/bin/env python3
import os, socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(16)
pf = os.environ.get("FAKE_DSH_PORT_FILE", "")
if pf:
    with open(pf, "w") as f:
        f.write(str(s.getsockname()[1]))
s.settimeout(1.0)
deadline = time.time() + 90
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
  export DSH_RT_IDLE_STOP_SECS=60
  export DSH_RT_NO_AUTO_UPDATE=1
  PORT="$(pick_free_port)"
  export DSH_RT_PORT="$PORT"
  FAKE_DSH_PID=""
  "$py" "$BATS_TEST_TMPDIR/fake-dsh-tok.py" >/dev/null 2>&1 &
  FAKE_DSH_PID=$!
  for _ in $(seq 1 20); do [ -s "$FAKE_DSH_PORT_FILE" ] && break; sleep 0.1; done
  [ -s "$FAKE_DSH_PORT_FILE" ] || { echo "  伪 dsh 未启动" >&2; return 1; }
  fp="$(cat "$FAKE_DSH_PORT_FILE")"
  printf '{"port":%s}\n' "$fp" > "$DSH_RT_STATE/dsh.json"
  # 预置 dsh.log:守护走「收养运行中 dsh」路径,启动时即扫此文件抓 token
  printf 'dsh web: http://127.0.0.1:%s/?token=%s\n' "$fp" "$tok" > "$DSH_RT_STATE/logs/dsh.log"
  daemon_compile "$TMP_ENV/daemon" || { echo "  daemon 编译失败" >&2; return 1; }
  DAEMON_PID="$(daemon_start_foreground "$TMP_ENV/daemon" "$TMP_ENV/daemon.log")"
  daemon_wait_health "$PORT" any 5 || { echo "  守护未就绪(日志见 $TMP_ENV/daemon.log)" >&2; return 1; }
}

@test "token longer than the old 64-byte buffer is captured in full" {
  # E1 前半。旧实现 dsh_token[64] + 「循环撞上上限即当作值已完整结束」→ 缓存 63 字符**前缀**;
  # 而 scan_token 开头 `if (dsh_token[0]) return;` 使其**永不重扫** → 引导页永远拿错 token,
  # 握手吃 401 → 无限 reload。当前 dsh token 长 43,故这是潜伏缺陷(dsh 一加长就命中)。
  # 判据:100 字符 token 必须**完整**出现在 /health。
  tok="$(printf 'T%.0s' $(seq 1 100))"
  start_token_env "$tok"
  got=""
  h=""
  for _ in $(seq 1 40); do
    h="$(curl -s --max-time 2 --noproxy '*' "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    if printf '%s' "$h" | grep -q "\"token\":\"$tok\""; then got=1; break; fi
    sleep 0.2
  done
  if [ "$got" != "1" ]; then
    echo "  /health 未携带完整 100 字符 token(被截断,见 $TMP_ENV/daemon.log)" >&2
    printf '  health=%s\n' "$h" >&2
    return 1
  fi
}

@test "token beyond the buffer limit is refused, not truncated" {
  # E1 后半:超过缓冲上限时必须**拒绝缓存**而不是缓存前缀 —— 错值会让引导页无限 reload 吃 401,
  # 无值则引导页按「等 token」路径处理,是可恢复的。
  # 判据:300 字符 token → /health 不带 token 字段,且守护日志出现截断判定。
  tok="$(printf 'T%.0s' $(seq 1 300))"
  start_token_env "$tok"
  sleep 1
  h="$(curl -s --max-time 2 --noproxy '*' "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
  if printf '%s' "$h" | grep -q '"token"'; then
    echo "  超长 token 被缓存(应拒绝):$h" >&2
    return 1
  fi
  grep -q '判为截断' "$TMP_ENV/daemon.log" 2>/dev/null || {
    echo "  守护日志未出现截断判定(见 $TMP_ENV/daemon.log)" >&2
    return 1
  }
}

@test "incomplete request head is rejected with 400" {
  # E2 回归:read_request_head 此前只判 `>0`,于是「缓冲区读满」与「SO_RCVTIMEO 读超时」
  # 都被当成完整请求,守护会基于**被截断的数据**做 Host/Origin/路径判定并继续透传 ——
  # 与「relay 不解析后续请求」组合即构成安全判定绕过链。
  # 判据:发一个**没有结束空行**的请求头,必须得到 400(而不是被当作完整请求继续处理)。
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  python3 不可用" >&2; return 1; }
  out="$(PORT="$PORT" "$PY" -c '
import os, socket
p = int(os.environ["PORT"])
s = socket.create_connection(("127.0.0.1", p), timeout=10)
s.sendall(("GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n" % p).encode())  # 故意不发结束空行
s.settimeout(10)
data = b""
try:
    while True:
        b = s.recv(4096)
        if not b:
            break
        data += b
except OSError:
    pass
s.close()
print(data.decode("latin1").split("\r\n")[0])
' 2>/dev/null || true)"
  case "$out" in
    *"400"*) ;;
    *) echo "  截断请求头未返回 400,实际:[$out]" >&2; return 1 ;;
  esac
}

# ---- 包装器自我版本(/health 的 wrapper_* 字段)与引导页完整性 ----
# 背景:包装器此前完全没有版本标识 —— DSH_VERSION 是 dsh 的版本,自动更新也只更新 dsh,
# 于是装了旧包装器的用户永远不知道自己落后(v0.3.3 之前的安装更是根本装不上)。
# 这里只验证**比较**逻辑:本机版本来自 $RT_HOME/.wrapper-version(install.sh 写入),
# 远端最新 tag 来自 $RT_STATE/wrapper.latest(update-dsh.sh 写入)。守护不做网络。
# 判据刻意区分「落后」与「未知」:任一文件缺失都必须**不报**该字段 —— 未知 ≠ 落后。

@test "health omits wrapper fields when no wrapper version is recorded" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  run curl -s --max-time 2 "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ]
  assert_body_match '"dsh":false'
  case "$output" in
    *wrapper_version*)
      echo "  未安装包装器版本时不应报 wrapper_version: $output" >&2
      return 1 ;;
  esac
}

@test "health reports wrapper_outdated when local and remote versions differ" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  printf 'v0.3.1\n' > "$TMP_ENV/rt/.wrapper-version"
  printf 'v0.3.9\n' > "$TMP_ENV/state/wrapper.latest"
  run curl -s --max-time 2 "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ]
  assert_body_match '"wrapper_version":"0.3.1"'
  assert_body_match '"wrapper_latest":"0.3.9"'
  assert_body_match '"wrapper_outdated":true'
}

@test "health normalizes the v prefix and does not flag an up-to-date wrapper" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  # 两侧写法不同(v 前缀只在一侧)但语义同版 → 必须判为不落后。
  # 若归一化失效,这里会恒报 outdated,而「永远提示升级」和「从不提示」一样是坏掉的信号。
  printf '0.3.3\n' > "$TMP_ENV/rt/.wrapper-version"
  printf 'v0.3.3\n' > "$TMP_ENV/state/wrapper.latest"
  run curl -s --max-time 2 "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ]
  assert_body_match '"wrapper_outdated":false'
}

@test "health reports wrapper_version without latest when the remote tag is unknown" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  printf 'v0.3.3\n' > "$TMP_ENV/rt/.wrapper-version"
  run curl -s --max-time 2 "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ]
  assert_body_match '"wrapper_version":"0.3.3"'
  case "$output" in
    *wrapper_outdated*)
      echo "  远端 tag 未知时不应报 wrapper_outdated(未知 ≠ 落后): $output" >&2
      return 1 ;;
  esac
}

@test "health never emits a version string outside the whitelist charset" {
  start_daemon_env '{"node":"/nonexistent/dsh-unit-node","dsh":"/nonexistent/dsh-unit-dsh"}'
  # 该值会被原样嵌进 JSON。被污染的文件不能把 JSON 拆掉(引号/反斜杠必须被拒)。
  printf 'v1.0";"injected":"yes\n' > "$TMP_ENV/rt/.wrapper-version"
  run curl -s --max-time 2 "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ]
  case "$output" in
    *injected*)
      echo "  非法字符集被放进了 JSON: $output" >&2
      return 1 ;;
  esac
  assert_body_match '"dsh":false'
  # 正控:同一路径换成合法值后字段必须出现 —— 证明上一步的「没有」是字符集过滤的结果,
  # 而不是这条链路压根没生效(否则本用例在修复前也会通过,属空转)。
  printf 'v0.3.3\n' > "$TMP_ENV/rt/.wrapper-version"
  run curl -s --max-time 2 "http://127.0.0.1:$PORT/health"
  assert_body_match '"wrapper_version":"0.3.3"'
}

@test "boot page survives a long LOG_DIR instead of being silently truncated" {
  # E4 回归。TPL_HEAD+TPL_TAIL 实测 3431 字节,旧缓冲 4096 只留 665 字节给 LOG_DIR ——
  # 一旦 LOG_DIR 变长(用户自定义 DSH_RT_STATE、或模板再长一点),snprintf 就静默截断成
  # 半截 HTML / 半截 <script>,引导页白屏且**没有任何信号**。
  # 用一条约 700 字符的 RT_STATE 把这个边界真实推过 4096:修复前必然丢掉 </html>,
  # 修复后(8192)完整。判据取收尾标签 —— 截断必然丢掉它,而它不可能被别的东西补齐。
  # 单个路径分量不能超过 NAME_MAX(255),故拆成多段拼出约 790 字符的 RT_STATE。
  local LONG="$BATS_TEST_TMPDIR" seg i
  seg="$(printf 'p%.0s' $(seq 1 180))"
  for i in 1 2 3 4; do LONG="$LONG/$seg"; done
  mkdir -p "$LONG/rt" "$LONG/state/logs"
  export DSH_RT_HOME="$LONG/rt" DSH_RT_STATE="$LONG/state" DSH_HOME="$LONG/home"
  export DSH_RT_IDLE_STOP_SECS=2
  export DSH_RT_NO_AUTO_UPDATE=1
  TMP_ENV="$LONG"
  PORT="$(pick_free_port)"
  export DSH_RT_PORT="$PORT"
  if ! daemon_compile "$LONG/daemon"; then
    echo "  daemon 编译失败" >&2
    return 1
  fi
  DAEMON_PID="$(daemon_start_foreground "$LONG/daemon" "$LONG/daemon.log")"
  if ! daemon_wait_health "$PORT" any 5; then
    echo "  daemon 未就绪(日志见 $LONG/daemon.log)" >&2
    return 1
  fi
  run curl -s --max-time 2 "http://127.0.0.1:$PORT/"
  [ "$status" -eq 0 ]
  # 反空转:先确认拿到的确实是一份引导页(否则「有 </html>」可能来自别的响应)
  assert_body_match 'DeepSeek Harness'
  assert_body_match '</html>'
}

# ---------- E6 安全响应头 / 并发上限 ----------

# boot_template <源文件> —— 抽出引导页模板区域(TPL_HEAD 起到 html_escape 前)。
# 锚点用**符号名**而非行号:行号会随任何编辑静默漂移(见 install-validation.bats 的
# 「daemon.c references use symbol anchors」门禁)。
boot_template() {
  awk '/^static const char TPL_HEAD\[\] =/,/^static void html_escape/' "$1"
}

# tpl_needs <含模板文本的文件> —— 从模板**推导** CSP 必须满足的约束。
# 刻意不把指令名硬编码一遍:硬编码等于把「模板需要什么」抄第二遍,模板一改两边一起错,
# 正是这条门禁要防的失败。参数化到文件是为了负控能用合成样本驱动它。
# 输出 `<指令>+<源>`:只断言「指令存在」是不够的 —— 外链脚本需要 script-src 含 'self',
# 而只有 'unsafe-inline' 时页面照样被拦死(白屏),门禁却全绿。故必须连源列表一起要求。
tpl_needs() {
  local t n=""
  t="$(cat "$1")"
  [ -n "$t" ] || { echo "模板为空" >&2; return 1; }
  printf '%s' "$t" | grep -q '<script>'              && n="$n script-src+unsafe-inline"
  printf '%s' "$t" | grep -q '<style>'               && n="$n style-src+unsafe-inline"
  printf '%s' "$t" | grep -qE '<script[^>]*src='     && n="$n script-src+self"
  printf '%s' "$t" | grep -qE 'rel=.stylesheet.'     && n="$n style-src+self"
  printf '%s' "$t" | grep -qE 'fetch\(|sendBeacon'   && n="$n connect-src+self"
  printf '%s' "$t" | grep -q 'icon\.svg'             && n="$n img-src+self"
  printf '%s' "$t" | grep -q 'manifest\.webmanifest' && n="$n manifest-src+self"
  printf '%s' "$n"
}

@test "security headers are sent on every response (nosniff + CSP)" {
  start_daemon_env '{"node":"/nonexistent/node","dsh":"/nonexistent/dsh"}'
  run curl -s -D - -o /dev/null --max-time 2 --noproxy '*' "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ] || { echo "  curl 失败 rc=$status" >&2; return 1; }
  printf '%s' "$output" | grep -qi '^X-Content-Type-Options: nosniff' \
    || { echo "  缺少 nosniff:" >&2; printf '%s\n' "$output" | head -12 >&2; return 1; }
  printf '%s' "$output" | grep -qi '^Content-Security-Policy: ' \
    || { echo "  缺少 CSP:" >&2; printf '%s\n' "$output" | head -12 >&2; return 1; }
  # CSP 必须**在响应里**且非空 —— 只断言「有这个头名」会被 `Content-Security-Policy: `(空值)
  # 满足,那等于没设。
  local csp
  csp="$(printf '%s' "$output" | grep -i '^Content-Security-Policy: ' | head -1)"
  printf '%s' "$csp" | grep -q "default-src 'none'" \
    || { echo "  CSP 未收敛到 default-src 'none': $csp" >&2; return 1; }
}

@test "CSP covers every resource the boot page actually needs" {
  # 为什么需要这条:引导页一旦被 CSP 打断就是**白屏**,而白屏没有任何信号 ——
  # 与 E4(引导页静默截断)同一类失效。门禁从模板**推导**需求,再核对真实响应头,
  # 于是「模板加了新资源类型但忘了改 CSP」会在 CI 变红,而不是在用户浏览器里变白屏。
  start_daemon_env '{"node":"/nonexistent/node","dsh":"/nonexistent/dsh"}'
  run curl -s -D - -o /dev/null --max-time 2 --noproxy '*' "http://127.0.0.1:$PORT/"
  [ "$status" -eq 0 ] || { echo "  curl 失败 rc=$status" >&2; return 1; }
  local csp
  csp="$(printf '%s' "$output" | grep -i '^Content-Security-Policy: ' | head -1)"
  [ -n "$csp" ] || { echo "  响应里没有 CSP" >&2; return 1; }

  local tpl="$BATS_TEST_TMPDIR/tpl.txt"
  # 必须读**构建守护所用的那份源码**($DSH_DAEMON_SRC),而不是写死 src/daemon.c ——
  # 否则「模板」与「实际响应头」可能来自两个不同文件,门禁就成了跨文件比对,既会误报
  # 也失去了被变异驱动的能力(本项目用 DSH_DAEMON_SRC 复验旧实现,是既有接缝)。
  boot_template "$DSH_DAEMON_SRC" > "$tpl"
  # 反空转(正):锚点必须真的抓到模板。抓不到时 needs 会是空集,而「空集里每条都在 CSP 里」
  # 恒真 —— 门禁全绿却什么都没测(TRAPS §一 第 16 条:只设上界的门禁会被空提取满足)。
  grep -q '<script' "$tpl" || { echo "模板抽取失败(锚点漂移?),见 $tpl" >&2; return 1; }

  local need needs miss=""
  needs="$(tpl_needs "$tpl")"
  # 反空转(面):推导出的需求条数必须有下界,否则同上是空集恒真。
  set -- $needs
  [ "$#" -ge 4 ] || { echo "只推导出 $# 条 CSP 需求(下界 4),推导逻辑失明?[$needs]" >&2; return 1; }

  for need in $needs; do
    local d="${need%%+*}" src="${need##*+}"
    if ! printf '%s' "$csp" | grep -q -- "$d"; then miss="$miss $need"; continue; fi
    # 指令存在还不够:必须确认**该指令的源列表里**真的放行了所需来源。
    printf '%s' "$csp" | grep -qE "$d[^;]*'$src'" || miss="$miss $need"
  done
  [ -z "$miss" ] || {
    echo "  CSP 缺少引导页需要的指令:$miss" >&2
    echo "  实际 CSP: $csp" >&2
    return 1
  }
}

@test "CSP gate self-check detects a newly introduced resource type" {
  # 负控:门禁必须抓得住「模板新增资源类型」这一真实场景。若推导函数只会输出固定集合,
  # 上一条用例在模板变化时不会变红 —— 那就只是把指令名抄了一遍。
  local probe="$BATS_TEST_TMPDIR/probe.html" needs

  # (a) 外链样式表:必须推出 style-src+self(内联那条挡不住外链)
  printf '%s\n' '<style>x{}</style><link rel="stylesheet" href="/x.css">' > "$probe"
  needs="$(tpl_needs "$probe")"
  printf '%s' "$needs" | grep -q 'style-src+self' \
    || { echo "  未推出 style-src+self:[$needs]" >&2; return 1; }

  # (b) 外链脚本:同理必须要求 script-src 含 'self'。这正是「只查指令是否存在」会漏掉的场景 ——
  #     CSP 里 script-src 只有 'unsafe-inline' 时 <script src> 会被浏览器拦死(白屏),
  #     而只查指令名的门禁全绿。所以推导必须细到**源列表**。
  printf '%s\n' '<script src="/a.js"></script>' > "$probe"
  needs="$(tpl_needs "$probe")"
  printf '%s' "$needs" | grep -q 'script-src+self' \
    || { echo "  未推出 script-src+self:[$needs]" >&2; return 1; }

  # (c) 内联脚本 + 内联样式:两条都要推出,且必须是内联形态
  printf '%s\n' '<script>1</script><style>x{}</style>' > "$probe"
  needs="$(tpl_needs "$probe")"
  printf '%s' "$needs" | grep -q 'script-src+unsafe-inline' \
    || { echo "  未推出 script-src+unsafe-inline:[$needs]" >&2; return 1; }
  printf '%s' "$needs" | grep -q 'style-src+unsafe-inline' \
    || { echo "  未推出 style-src+unsafe-inline:[$needs]" >&2; return 1; }
  # 反向:模板里没有 manifest / icon / fetch 时不得凭空要求对应指令,否则门禁会误报
  # (误报和漏报同样是缺陷 —— 它会逼人放宽门禁,见技能里「false positive 与 miss 同类」)。
  printf '%s' "$needs" | grep -qE 'manifest-src|img-src|connect-src' \
    && { echo "  误报未出现的资源类型:[$needs]" >&2; return 1; }
  return 0
}

@test "concurrency cap refuses the N+1th connection with 503 and recovers" {
  # E6d 回归。旧实现每连接 fork 且**无上限**,只有 fd 耗尽(EMFILE)才退避 —— 即「已经太晚」
  # 之后才降速。这里把上限压到 1,用一条「只连不写」的连接占住唯一的额度。
  export DSH_RT_MAX_CONN=1
  start_daemon_env '{"node":"/nonexistent/node","dsh":"/nonexistent/dsh"}'
  unset DSH_RT_MAX_CONN

  local PY; PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "  [SKIP] 无 python3,无法驱动持连接样本" >&2; return 0; }

  # 每 0.4s 滴一个字节:守护对客户端 socket 的读超时是 2s,**每收到数据即重置**,
  # 故子进程会被一直吊住(不像「发一次就睡」那样 2s 后自退)。这样断言窗口足够宽。
  "$PY" -c '
import socket,sys,time
s=socket.socket(); s.connect(("127.0.0.1",int(sys.argv[1])))
s.sendall(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n")   # 刻意不发结束空行:请求头不完整
for _ in range(25):
    try: s.sendall(b"X")
    except OSError: break
    time.sleep(0.4)
' "$PORT" >/dev/null 2>&1 &
  local HOLD_PID=$!

  # 正控:额度被占满时 /health 必须 503(它自己也走同一条 accept 路径)
  local got=""
  for _ in $(seq 1 25); do
    got="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 --noproxy '*' \
      "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    [ "$got" = "503" ] && break
    sleep 0.2
  done
  kill "$HOLD_PID" 2>/dev/null || true
  wait "$HOLD_PID" 2>/dev/null || true

  [ "$got" = "503" ] || { echo "  并发上限未生效:期望 503,实际 [$got]" >&2; return 1; }

  # 反控(同样重要):额度释放后必须恢复 200。这一半同时证明上限**没有过度生效** ——
  # 若把 MAX_CONN 误做成 0(`active >= 0` 恒真),上面那半照样通过,而这里会一直 503。
  got=""
  for _ in $(seq 1 25); do
    got="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 --noproxy '*' \
      "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    [ "$got" = "200" ] && break
    sleep 0.2
  done
  [ "$got" = "200" ] || { echo "  额度释放后未恢复:期望 200,实际 [$got]" >&2; return 1; }
}
