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
