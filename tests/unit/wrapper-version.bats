#!/usr/bin/env bats
# update-dsh.sh 的包装器版本检查(自我升级的可见性基础)回归门禁
#
# 背景:包装器此前完全没有版本标识 —— DSH_VERSION 是 dsh 的版本,自动更新也只更新 dsh。
# 装了旧包装器的用户永远不知道自己落后,而 v0.3.3 之前的安装是根本装不上的。
# 分工:update-dsh.sh 只负责把**远端最新 tag** 写进 $RT_STATE/wrapper.latest(它有 curl),
# 比较由守护做(它是 C、没有 TLS,但每次激活都要读,必须廉价)。
#
# 做法:按行锚点从 update-dsh.sh 切出**真实代码**(不重写、不复制),用本地桩服务器驱动 ——
# 否则这段逻辑只能靠「读代码觉得对」来验收,而本项目已经栽过好几次「看起来对」。
#
# 三个判据都是**反假绿**的:
#   1) 桩把 /latest 302 到 .../releases/tag/v0.3.9 → 必须落盘 v0.3.9
#   2) 302 到 .../releases(仓库无 release 时的真实行为,末段是字面量 "releases")
#      → 必须**不落盘**。不挡住就会把每个用户都标成落后,假阳性比不报更糟。
#   3) 时间戳新鲜 → 必须不发请求(节流)。用桩的请求计数证明,而不是只看文件没变。
#
# 注意:测试描述必须全 ASCII —— bats 1.14 + macOS bash 3.2 下多字节描述会**静默清空用例**
# (假绿),install-validation.bats 里有同名守卫在盯着。

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # 允许指向另一份 update-dsh.sh,便于做 fail-before 复核
  UPDATE_SRC="${WRAPPER_UPDATE_SRC:-$ROOT/scripts/update-dsh.sh}"
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/state"
  STUB_PID=""
  STUB_PORT=""
}

teardown() {
  if [ -n "${STUB_PID:-}" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
    STUB_PID=""
  fi
}

fail() { echo "$*" >&2; return 1; }

# 从 `# ---------- 包装器自身版本` 那行起,到 `CUR="$(read_version)"` 前一行止。
extract_block() {
  awk '/^# -+ 包装器自身版本/{f=1} f && /^CUR="\$\(read_version\)"/{exit} f' "$1"
}

# 桩:GET /latest → 302 到 $FIX/redirect 的内容;其余路径 → 200。
# 每次请求都重读 redirect 文件,所以可以先起服务、拿到端口、再写真实目标。
start_stub() {
  command -v python3 >/dev/null 2>&1 || return 1
  printf 'http://127.0.0.1:1/releases/tag/v0.0.0\n' > "$FIX/redirect"
  : > "$FIX/port"
  : > "$FIX/hits"
  python3 - "$FIX/port" "$FIX/redirect" "$FIX/hits" <<'PY' &
import http.server, socketserver, sys
port_file, target_file, hits_file = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(hits_file, "a") as f:
            f.write(self.path + "\n")
        if self.path == "/latest":
            target = open(target_file).read().strip()
            self.send_response(302)
            self.send_header("Location", target)
            self.end_headers()
        else:
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    def log_message(self, *a):
        pass
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
  STUB_PID=$!
  local i=0
  while [ ! -s "$FIX/port" ] && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$FIX/port" ] || return 1
  STUB_PORT="$(cat "$FIX/port")"
}

# 在隔离的 RT_STATE 里跑切出来的块;$1 = 覆盖的 DSH_RT_WRAPPER_LATEST_URL。
# **必须用 env 前缀**:块是作为**子进程**运行的,普通赋值不会传下去 —— 我第一版就写成
# `RT_STATE=... ; bash block.sh`,结果子进程里 RT_STATE 为空、写文件全部失败,而
# 「文件不存在」的断言恰好因此通过:三条用例全绿却什么都没测到。故本文件每处
# 「必须不写」的断言都配一条「证明块真的跑过」的断言(见各用例)。
run_block() {
  env RT_STATE="$FIX/state" DSH_RT_WRAPPER_LATEST_URL="$1" bash "$FIX/block.sh"
}

prepare_block() {
  extract_block "$UPDATE_SRC" > "$FIX/block.sh"
  bash -n "$FIX/block.sh" || fail "extracted block is not valid bash (anchor drifted?)"
  grep -q '^check_wrapper_version$' "$FIX/block.sh" || fail "extracted block never calls check_wrapper_version (anchor drifted?)"
}

@test "wrapper version check records the tag from the releases/latest redirect" {
  prepare_block
  start_stub || skip "python3 unavailable"
  printf 'http://127.0.0.1:%s/releases/tag/v0.3.9\n' "$STUB_PORT" > "$FIX/redirect"

  run_block "http://127.0.0.1:$STUB_PORT/latest"
  [ -f "$FIX/state/wrapper.latest" ] || fail "wrapper.latest was not written"
  [ "$(cat "$FIX/state/wrapper.latest")" = "v0.3.9" ] \
    || fail "expected v0.3.9, got [$(cat "$FIX/state/wrapper.latest")]"
  # 反空转:节流戳必须落盘,证明块真的执行到了网络那一步
  case "$(cat "$FIX/state/wrapper.latest.checked" 2>/dev/null || true)" in
    '' | *[!0-9]*) fail "throttle stamp missing or not numeric (did the block actually run?)" ;;
  esac
}

@test "wrapper version check refuses a redirect target that is not a version tag" {
  prepare_block
  start_stub || skip "python3 unavailable"
  # 仓库还没有任何 release 时,releases/latest 会落到 .../releases,末段是字面量 "releases"。
  # 放它过去 ⇒ 每个用户都被标成落后。假阳性比不报更糟,必须挡住。
  printf 'http://127.0.0.1:%s/releases\n' "$STUB_PORT" > "$FIX/redirect"

  run_block "http://127.0.0.1:$STUB_PORT/latest"
  [ ! -f "$FIX/state/wrapper.latest" ] \
    || fail "wrapper.latest must not be written for a non-tag target (got [$(cat "$FIX/state/wrapper.latest")])"
  # 反空转:节流戳落盘 ⇒ 块确实跑过、确实发过请求,「没写 wrapper.latest」是真结论
  [ -s "$FIX/state/wrapper.latest.checked" ] || fail "throttle stamp missing (did the block actually run?)"
  [ -s "$FIX/hits" ] || fail "stub was never hit (did the block actually run?)"
}

@test "wrapper version check throttles and makes no request while the stamp is fresh" {
  prepare_block
  start_stub || skip "python3 unavailable"
  printf 'http://127.0.0.1:%s/releases/tag/v0.3.9\n' "$STUB_PORT" > "$FIX/redirect"
  date +%s > "$FIX/state/wrapper.latest.checked"

  run_block "http://127.0.0.1:$STUB_PORT/latest"
  [ ! -f "$FIX/state/wrapper.latest" ] || fail "throttled run must not refresh wrapper.latest"
  # 反假绿:必须证明「没发请求」,而不是只看文件没变(文件没变也可能因为桩没被访问过)
  [ ! -s "$FIX/hits" ] || fail "throttled run still hit the network: $(tr '\n' ' ' < "$FIX/hits")"
}

@test "wrapper version check is fully disabled by DSH_RT_NO_WRAPPER_CHECK" {
  prepare_block
  start_stub || skip "python3 unavailable"
  printf 'http://127.0.0.1:%s/releases/tag/v0.3.9\n' "$STUB_PORT" > "$FIX/redirect"

  env RT_STATE="$FIX/state" DSH_RT_NO_WRAPPER_CHECK=1 \
      DSH_RT_WRAPPER_LATEST_URL="http://127.0.0.1:$STUB_PORT/latest" \
      bash "$FIX/block.sh"
  [ ! -f "$FIX/state/wrapper.latest" ] || fail "disabled check must not write wrapper.latest"
  [ ! -f "$FIX/state/wrapper.latest.checked" ] || fail "disabled check must not even write the throttle stamp"
  # 反空转:开关确实是被 env 传进去的(否则上面的「不写」可能只是因为块根本没跑)
  env RT_STATE="$FIX/state" DSH_RT_NO_WRAPPER_CHECK=1 \
      DSH_RT_WRAPPER_LATEST_URL="http://127.0.0.1:$STUB_PORT/latest" \
      bash -c 'bash "$0" && echo ran' "$FIX/block.sh" | grep -q ran \
    || fail "block did not run to completion under the disable switch"
}
