#!/usr/bin/env bats
# pwa-doctor.sh 的门禁:token 脱敏 + 判定逻辑
#
# 为什么要有它:该脚本的**用途就是被人贴出来**(「我该怎么给你提供判断依据」),而它会把
# /health 的原文打印出来 —— 而 /health 带 dsh 启动 token。脱敏一旦失效,就是把用户的 token
# 公开。这不是「顺手加的测试」,是这个脚本能存在的前提。
#
# 同时守住**判定逻辑**:症状分三类(旧版守护 / 新版但发非官方 manifest / 已透传),
# 判错的代价是把「旧版包装器」误导成「图标缓存」—— 本项目真实踩过一整轮(对着一台机器的
# 缓存查,真因在另一台机器的已装二进制里)。故用桩服务器喂两种 manifest,断言**结论随之翻转**,
# 而不是只看它打印了什么。
#
# 注意:测试描述必须全 ASCII —— bats 1.14 + macOS bash 3.2 下多字节描述会**静默清空用例**
# (假绿),install-validation.bats 里有同名守卫在盯着。

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # 允许指向另一份脚本,便于做 fail-before 复核
  DOCTOR="${PWA_DOCTOR_SRC:-$ROOT/scripts/pwa-doctor.sh}"
  FIX="$BATS_TEST_TMPDIR/fix"
  FAKE_HOME="$FIX/home"
  mkdir -p "$FIX" "$FAKE_HOME" "$FIX/rt" "$FIX/state"
  STUB_PID=""
  STUB_PORT=""
  # 必须存在的桩响应,默认给官方那份;单个用例可覆写
  printf '%s' '{"dsh":true,"port":1,"pid":2,"token":"SECRET-TOKEN-abcdef123456"}' > "$FIX/health.json"
  printf '%s' '{"id":"/","name":"DeepSeek Harness","short_name":"DSH","start_url":"/","scope":"/","display":"fullscreen","icons":[{"src":"/favicon.svg","sizes":"any","type":"image/svg+xml","purpose":"any"}]}' > "$FIX/manifest.json"
  printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50"></svg>' > "$FIX/favicon.svg"
  printf '%s' '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"></svg>' > "$FIX/icon.svg"
}

teardown() {
  if [ -n "${STUB_PID:-}" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
    STUB_PID=""
  fi
}

fail() { echo "$*" >&2; return 1; }

# 桩:按路径回 $FIX 下同名文件(health.json / manifest.json / favicon.svg / icon.svg),
# 缺失即 404;每次请求追加一行到 $FIX/hits,供反空转断言用。
start_stub() {
  command -v python3 >/dev/null 2>&1 || return 1
  : > "$FIX/port"
  : > "$FIX/hits"
  python3 - "$FIX/port" "$FIX" <<'PY' &
import http.server, os, socketserver, sys
port_file, fix = sys.argv[1], sys.argv[2]
MAP = {"/health": "health.json", "/manifest.webmanifest": "manifest.json",
       "/favicon.svg": "favicon.svg", "/icon.svg": "icon.svg"}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(os.path.join(fix, "hits"), "a") as f:
            f.write(self.path + "\n")
        name = MAP.get(self.path)
        path = os.path.join(fix, name) if name else None
        if path and os.path.exists(path):
            body = open(path, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type",
                             "application/json" if name.endswith(".json") else "image/svg+xml")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
    def log_message(self, *a):
        pass
with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
    with open(port_file, "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()
PY
  STUB_PID=$!
  local i=0
  while [ ! -s "$FIX/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$FIX/port" ] || return 1
  STUB_PORT="$(cat "$FIX/port")"
}

# HOME 指向假目录:让守护二进制/RT_HOME/Web App 三段的输出确定化,只留桩驱动的部分可变。
run_doctor() {
  HOME="$FAKE_HOME" DSH_RT_HOME="$FIX/rt" DSH_RT_STATE="$FIX/state" \
    bash "$DOCTOR" "$STUB_PORT" 2>&1 || true
}

@test "doctor redacts the dsh token from /health" {
  start_stub || skip "python3 unavailable"
  out="$(run_doctor)"

  # 反空转(正):先证明桩真的被访问过 —— 否则「输出里没有 token」可能只是因为脚本没跑到那步。
  [ -s "$FIX/hits" ] || fail "stub was never hit (did the script actually run?)"
  printf '%s' "$out" | grep -q '^  {"dsh":true' || fail "health section did not print: $out"

  # 断言一律用 `if …; then fail; fi` 而不是 `… && fail`:bats 用 `set -e` + 检查末条退出码,
  # 而 `cmd && fail` 在**断言通过**(cmd 失败)时整体退出码为 1 —— 只要它恰好是最后一条语句,
  # 用例就会因为「断言成立」而变红。`if` 形式在任何位置都成立(见 TRAPS)。
  if printf '%s' "$out" | grep -q 'SECRET-TOKEN-abcdef123456'; then
    fail "token leaked into the report -- this script is meant to be pasted publicly"
  fi
  printf '%s' "$out" | grep -q '"token":"<redacted>"' \
    || fail "redaction marker missing; token field was dropped instead of masked: $out"
  # 反向:脱敏不得把整行吃掉(只换掉 token 值,其余字段仍要在)
  printf '%s' "$out" | grep -q '"port":1' || fail "redaction swallowed neighbouring fields: $out"
}

@test "doctor reports pass-through when the served manifest is the official one" {
  start_stub || skip "python3 unavailable"
  out="$(run_doctor)"
  [ -s "$FIX/hits" ] || fail "stub was never hit"
  printf '%s' "$out" | grep -q 'official(官方那份' \
    || fail "official manifest was not recognised as pass-through: $out"
  if printf '%s' "$out" | grep -q 'self-authored'; then
    fail "official manifest was misjudged as self-authored: $out"
  fi
  true
}

@test "doctor flags the old daemon when the served manifest is self-authored" {
  start_stub || skip "python3 unavailable"
  # 旧版守护发的那份:display=standalone、icons 指向 /icon.svg
  printf '%s' '{"name":"DeepSeek Harness","short_name":"DSH","id":"/","scope":"/","start_url":"/","display":"standalone","background_color":"#0B0E14","theme_color":"#0B0E14","icons":[{"src":"/icon.svg","sizes":"any","type":"image/svg+xml"}]}' > "$FIX/manifest.json"
  out="$(run_doctor)"
  [ -s "$FIX/hits" ] || fail "stub was never hit"
  printf '%s' "$out" | grep -q 'self-authored(自造那份' \
    || fail "self-authored manifest was not flagged: $out"
  # 结论必须把**顺序**说清楚(先升级、再重加):顺序反了会把旧图标再烘一遍
  printf '%s' "$out" | grep -q '升级包装器' || fail "verdict omits the upgrade step: $out"
  printf '%s' "$out" | grep -q '删掉该 Web App 重新添加' || fail "verdict omits the re-add step: $out"
}

@test "doctor reads the wrapper build from binary strings, not from file size" {
  # 不给桩:本用例只验第一段(已装守护)。两份假二进制的**大小相同**,只有内容不同 ——
  # 这正是判据的意义:ad-hoc 签名会让同源码的产物相差约 50KB,按大小比会得出错误结论。
  mkdir -p "$FIX/rt"
  head -c 4096 /dev/zero | tr '\0' 'A' > "$FIX/rt/daemon"
  printf '%s' '/manifest.webmanifest /icon.svg /icon.svg' >> "$FIX/rt/daemon"
  chmod +x "$FIX/rt/daemon"
  dirty="$(run_doctor)"
  printf '%s' "$dirty" | grep -qE '自造图标路由数: [1-9]' \
    || fail "old build (contains /icon.svg) was not detected: $dirty"

  # 反向:同一份文件把旧字符串抹掉、**大小不变**后,必须判为 0 —— 否则该字段只是「非空即报」
  head -c 4096 /dev/zero | tr '\0' 'A' > "$FIX/rt/daemon"
  chmod +x "$FIX/rt/daemon"
  clean="$(run_doctor)"
  printf '%s' "$clean" | grep -qE '自造图标路由数: 0' \
    || fail "clean build was misreported as self-authoring: $clean"
}
