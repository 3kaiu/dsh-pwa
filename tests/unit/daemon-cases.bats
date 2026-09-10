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
