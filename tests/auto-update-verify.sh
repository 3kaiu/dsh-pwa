#!/usr/bin/env bash
# 自动更新功能验证测试套件
# 把 tests/auto-update-checklist.md 中可自动化的验收点变成可持续回归的脚本:
#   1. updater plist 渲染  2. 无更新路径  3. 版本升级干跑  4. REMOTE 非法版本串
#   5. 并发互斥  6. 僵尸锁抢占  7. 失败回滚  8. dsh 运行中跳过  9. 日志轮转  10. 语法/门禁
# 破坏性项(需真实安装/断网/改真实 package.json 访问真实 registry)以 SKIP 标注,保持人工验收。
# 隔离: 所有用例运行在 mktemp 临时目录(DSH_RT_HOME/DSH_RT_STATE 指向临时目录),
#        npm/pnpm 全部使用假包装脚本(不触网),不触碰真实运行时,无需 root。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0; SKIP_COUNT=0

# 公共 helper(本套件仅用 pick_free_port 挑空闲端口;daemon 编译/启停用不到)
# shellcheck source=/dev/null
source "$ROOT/tests/lib/daemon-helpers.sh"

# 颜色输出
if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; RST=$'\033[0m'
else
  G=""; R=""; B=""; D=""; RST=""
fi

ok()   { echo "  ${G}✓${RST} $*"; ((PASS++)) || true; }
fail() { echo "  ${R}✗${RST} $*"; ((FAIL++)) || true; }
info() { echo "  ${D}$*${RST}"; }
skip() { echo "  ${D}SKIP:${RST} $*"; ((SKIP_COUNT++)) || true; }
h1()   { echo; echo "${B}$*${RST}"; }

UPDATER="$ROOT/scripts/update-dsh.sh"
cd "$ROOT"

# 全部用例的隔离根目录;退出时清理(含测试 8 的假 HTTP 服务)
TEST_ROOT="$(mktemp -d)"
SERVER_PID=""
trap 'rm -rf "$TEST_ROOT"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

# 空闲端口(默认 DSH_RT_PORT):每个用例独立端口,绝不撞真实 3080 守护
SAFE_PORT="$(pick_free_port)"

# make_env <name> <当前版本>
# 在 TEST_ROOT 下组装一个隔离的更新环境并 export 运行所需变量:
#   - run.json 的 node 指向本机真实 node 的符号链接(realpath 解析 fnm/volta shim);
#     该目录里同放假 npm/假 pnpm——脚本的 NPM_BIN=dirname(node)/npm 与 pnpm exec
#     全部落到假包装(PATH 前置),全程不触网
# 返回 1 表示本机无 node(update-dsh.sh 解析版本依赖真实 node),调用方应 skip
make_env() {
  local name="$1" cur="${2:-1.0.0}" node_path=""
  TEST_DIR="$TEST_ROOT/$name"
  TEST_RT="$TEST_DIR/rt"
  TEST_STATE="$TEST_DIR/state"
  TEST_FAKE="$TEST_DIR/bin"
  mkdir -p "$TEST_RT/app/node_modules/@deepseek-ai/dsh" "$TEST_STATE/logs" "$TEST_FAKE"

  if [ -z "${REAL_NODE:-}" ]; then
    node_path="$(command -v node 2>/dev/null || true)"
    if [ -z "$node_path" ]; then
      info "本机无 node(update-dsh.sh 解析版本需要真实 node),跳过该用例"
      return 1
    fi
    REAL_NODE="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$node_path" 2>/dev/null || echo "$node_path")"
  fi
  ln -s "$REAL_NODE" "$TEST_FAKE/node"

  # 假 npm:view → 输出 FAKE_NPM_VIEW_FILE 内容;exec → 转发给假 pnpm
  cat > "$TEST_FAKE/npm" <<'FAKE_NPM'
#!/usr/bin/env bash
case "${1:-}" in
  view)
    cat "$FAKE_NPM_VIEW_FILE"
    ;;
  exec)
    shift
    cmd=""
    rest=()
    seen_sep=0
    for a in "$@"; do
      if [ "$seen_sep" = 1 ]; then
        if [ -z "$cmd" ]; then
          cmd="$a"
        else
          rest+=("$a")
        fi
      elif [ "$a" = "--" ]; then
        seen_sep=1
      fi
    done
    if [ -z "$cmd" ]; then
      echo "fake-npm: exec 后未找到命令" >&2
      exit 1
    fi
    exec "$(command -v "$cmd")" "${rest[@]}"
    ;;
  *)
    exit 0
    ;;
esac
FAKE_NPM

  # 假 pnpm:记录调用;FAKE_PNPM_FAIL=1 模拟失败;成功时把 node_modules 里
  # @deepseek-ai/dsh 版本改成 FAKE_REMOTE_VERSION 并生成 pnpm-lock.yaml
  cat > "$TEST_FAKE/pnpm" <<'FAKE_PNPM'
#!/usr/bin/env bash
printf '%s\n' "fake-pnpm: $*" >> "$FAKE_PNPM_LOG"
if [ "${FAKE_PNPM_FAIL:-0}" = "1" ]; then
  printf '%s\n' "fake-pnpm: FAKE_PNPM_FAIL=1 模拟失败" >> "$FAKE_PNPM_LOG"
  exit 1
fi
sleep "${FAKE_PNPM_SLEEP:-0}"
dir=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--dir" ]; then
    dir="$2"
    shift 2
  else
    shift
  fi
done
if [ -n "$dir" ] && [ -n "${FAKE_REMOTE_VERSION:-}" ] \
  && [ -f "$dir/node_modules/@deepseek-ai/dsh/package.json" ]; then
  python3 -c '
import json, sys
p, v = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["version"] = v
open(p, "w").write(json.dumps(d, indent=2) + "\n")
' "$dir/node_modules/@deepseek-ai/dsh/package.json" "$FAKE_REMOTE_VERSION"
  : > "$dir/pnpm-lock.yaml"
fi
exit 0
FAKE_PNPM
  chmod +x "$TEST_FAKE/npm" "$TEST_FAKE/pnpm"

  # 已安装 dsh 包 + 应用 manifest + run.json(单一事实源)
  printf '{"name":"dsh-runtime-app","private":true,"dependencies":{"@deepseek-ai/dsh":"%s"}}\n' "$cur" > "$TEST_RT/app/package.json"
  printf '{"name":"@deepseek-ai/dsh","version":"%s","bin":{"dsh":"./dsh-cli.js"}}\n' "$cur" > "$TEST_RT/app/node_modules/@deepseek-ai/dsh/package.json"
  printf '{"node":"%s","dsh":"%s"}\n' "$TEST_FAKE/node" "$TEST_RT/app/node_modules/@deepseek-ai/dsh/dsh-cli.js" > "$TEST_RT/run.json"

  TEST_VIEW_FILE="$TEST_FAKE/view.out"
  TEST_PNPM_LOG="$TEST_FAKE/pnpm.log"
  export DSH_RT_HOME="$TEST_RT"
  export DSH_RT_STATE="$TEST_STATE"
  export FAKE_NPM_VIEW_FILE="$TEST_VIEW_FILE"
  export FAKE_PNPM_LOG="$TEST_PNPM_LOG"
  export FAKE_PNPM_FAIL=0
  export FAKE_PNPM_SLEEP=0
  export FAKE_REMOTE_VERSION=""
}

# run_update [输出重定向文件] [DSH_RT_PORT];结束后 RUN_RC 携带 update-dsh.sh 退出码
run_update() {
  local out="${1:-$TEST_DIR/run.out}" port="${2:-$SAFE_PORT}"
  ( export DSH_RT_PORT="$port"; bash "$UPDATER" ) >"$out" 2>&1
  RUN_RC=$?
}

h1 "1. updater plist 渲染(参考 install.sh 的生成逻辑)"

T1="$TEST_ROOT/t01_plist"
mkdir -p "$T1/home" "$T1/rt" "$T1/state/logs"
TPL="$ROOT/launchd/com.dshpwa.updater.plist"
RENDERED="$T1/com.dshpwa.updater.plist"
# 与 scripts/install.sh(updater 注册段)完全一致的 sed 占位符替换
sed -e "s|__HOME__|$T1/home|g" \
    -e "s|__RT_HOME__|$T1/rt|g" \
    -e "s|__RT_STATE__|$T1/state|g" \
    -e "s|__LOG_DIR__|$T1/state/logs|g" \
    -e "s|__DSH_RT_PORT__|3080|g" "$TPL" > "$RENDERED"

if plutil -lint "$RENDERED" >/dev/null 2>&1; then
  ok "渲染后 plist 通过 plutil -lint"
else
  fail "渲染后 plist 未通过 plutil -lint"
fi

if grep -Eq '__HOME__|__RT_HOME__|__RT_STATE__|__LOG_DIR__|__DSH_RT_PORT__' "$RENDERED"; then
  fail "渲染后 plist 仍残留占位符"
else
  ok "渲染后无残留占位符(__HOME__/__RT_HOME__/__RT_STATE__/__LOG_DIR__)"
fi

if plutil -lint "$TPL" >/dev/null 2>&1; then
  ok "入库模板(launchd/com.dshpwa.updater.plist)XML 合法"
else
  fail "入库模板 XML 非法(plutil -lint 失败)"
fi

h1 "2. 无更新路径(已是最新 → 记日志 exit 0,不调用 pnpm)"

if make_env t02 1.0.0; then
  printf '1.0.0\n' > "$TEST_VIEW_FILE"
  run_update
  if [ "$RUN_RC" = 0 ] && grep -q "已是最新版本" "$TEST_STATE/logs/update.log"; then
    ok "exit 0 且日志记录「已是最新版本(1.0.0),无需更新」"
  else
    fail "无更新路径未按预期退出(rc=$RUN_RC)"
  fi
  if [ -f "$TEST_PNPM_LOG" ]; then
    fail "已是最新时不应调用 pnpm"
  else
    ok "未调用 pnpm"
  fi
else
  skip "无真实 node,跳过用例 2(无更新路径)"
fi

h1 "3. 版本升级路径(干跑:假 npm view 返回更高版本)"

if make_env t03 1.0.0; then
  printf '2.0.0\n' > "$TEST_VIEW_FILE"
  export FAKE_REMOTE_VERSION="2.0.0"
  run_update
  if [ "$RUN_RC" = 0 ] && grep -q "开始更新" "$TEST_STATE/logs/update.log"; then
    ok "日志记录「开始更新 dsh: 1.0.0 -> 2.0.0」"
  else
    fail "升级路径未记录「开始更新」(rc=$RUN_RC)"
  fi
  if [ -s "$TEST_PNPM_LOG" ]; then
    ok "pnpm 被调用($(head -1 "$TEST_PNPM_LOG"))"
  else
    fail "升级路径未调用 pnpm"
  fi
  if grep -q "更新完成" "$TEST_STATE/logs/update.log"; then
    ok "日志记录「更新完成」"
  else
    fail "未记录「更新完成」"
  fi
  if grep -q '"version": *"2.0.0"' "$TEST_RT/app/node_modules/@deepseek-ai/dsh/package.json"; then
    ok "node_modules 版本已更新到 2.0.0"
  else
    fail "node_modules 版本未更新"
  fi
  if grep -q 'dsh-cli.js' "$TEST_RT/run.json"; then
    ok "run.json 已刷新为新 dsh bin 路径"
  else
    fail "run.json 未刷新"
  fi
else
  skip "无真实 node,跳过用例 3(升级干跑)"
fi

h1 "4. REMOTE 非法版本串(假 npm view 返回垃圾串)"

if make_env t04 1.0.0; then
  printf '0.1.5;evil-injection\n' > "$TEST_VIEW_FILE"
  PKG_BEFORE="$(cat "$TEST_RT/app/package.json")"
  run_update
  if [ "$RUN_RC" = 0 ] && grep -q "远程版本串非法" "$TEST_STATE/logs/update.log"; then
    ok "exit 0 且日志记录「远程版本串非法」"
  else
    fail "非法版本串未按预期处理(rc=$RUN_RC)"
  fi
  PKG_AFTER="$(cat "$TEST_RT/app/package.json")"
  if [ "$PKG_BEFORE" = "$PKG_AFTER" ]; then
    ok "未改写 package.json"
  else
    fail "非法版本串下 package.json 被改写"
  fi
else
  skip "无真实 node,跳过用例 4(非法版本串)"
fi

h1 "5. 并发互斥(两个 update-dsh.sh 抢同一隔离锁目录)"

if make_env t05 1.0.0; then
  printf '2.0.0\n' > "$TEST_VIEW_FILE"
  export FAKE_REMOTE_VERSION="2.0.0"
  export FAKE_PNPM_SLEEP=1  # 持锁方放慢,确保后到者读到活锁(确定性跳过)
  RC1=0; RC2=0
  ( export DSH_RT_PORT="$SAFE_PORT"; bash "$UPDATER" ) >"$TEST_DIR/run1.out" 2>&1 &
  P1=$!
  ( export DSH_RT_PORT="$SAFE_PORT"; bash "$UPDATER" ) >"$TEST_DIR/run2.out" 2>&1 &
  P2=$!
  wait "$P1" || RC1=$?
  wait "$P2" || RC2=$?
  N_START="$(grep -c "开始更新" "$TEST_STATE/logs/update.log" 2>/dev/null || true)"
  N_SKIP="$(grep -c "跳过本次更新" "$TEST_STATE/logs/update.log" 2>/dev/null || true)"
  if [ "$N_START" = "1" ]; then
    ok "仅一个进程执行更新(「开始更新」×1)"
  else
    fail "「开始更新」出现 $N_START 次(应恰为 1)"
  fi
  if [ "$N_SKIP" = "1" ]; then
    ok "另一进程被锁挡住,记「跳过本次更新」退出"
  else
    fail "「跳过本次更新」出现 $N_SKIP 次(应恰为 1)"
  fi
  if [ "$RC1" = 0 ] && [ "$RC2" = 0 ]; then
    ok "两个进程均 exit 0"
  else
    fail "退出码异常(rc1=$RC1, rc2=$RC2)"
  fi
else
  skip "无真实 node,跳过用例 5(并发互斥)"
fi

h1 "6. 僵尸锁抢占(预置 .install.lock/pid=99999 死 pid)"

if make_env t06 1.0.0; then
  printf '2.0.0\n' > "$TEST_VIEW_FILE"
  export FAKE_REMOTE_VERSION="2.0.0"
  mkdir -p "$TEST_RT/.install.lock"
  printf '99999\n' > "$TEST_RT/.install.lock/pid"
  run_update
  if [ "$RUN_RC" = 0 ] && grep -q "开始更新" "$TEST_STATE/logs/update.log" && grep -q "更新完成" "$TEST_STATE/logs/update.log"; then
    ok "僵尸锁被抢占,更新正常执行(「开始更新」+「更新完成」)"
  else
    fail "僵尸锁未抢占(rc=$RUN_RC)"
  fi
  if [ ! -e "$TEST_RT/.install.lock" ]; then
    ok "锁目录在更新结束后已清理"
  else
    fail "锁目录残留"
  fi
else
  skip "无真实 node,跳过用例 6(僵尸锁抢占)"
fi

h1 "7. 失败回滚(假 pnpm 必败 → 恢复更新前依赖树)"

if make_env t07 1.0.0; then
  printf '2.0.0\n' > "$TEST_VIEW_FILE"
  export FAKE_PNPM_FAIL=1
  touch "$TEST_RT/app/node_modules/MARKER"
  printf 'lockfile-v1\n' > "$TEST_RT/app/pnpm-lock.yaml"
  run_update
  if [ "$RUN_RC" = 0 ] && grep -q "已回滚" "$TEST_STATE/logs/update.log"; then
    ok "日志记录「已回滚」(保持当前版本承诺)"
  else
    fail "未记录「已回滚」(rc=$RUN_RC)"
  fi
  if [ -f "$TEST_RT/app/node_modules/MARKER" ]; then
    ok "node_modules/MARKER 已恢复"
  else
    fail "MARKER 未恢复,依赖树损坏"
  fi
  if grep -q '"version": *"1.0.0"' "$TEST_RT/app/node_modules/@deepseek-ai/dsh/package.json"; then
    ok "版本读回原值 1.0.0"
  else
    fail "回滚后版本异常"
  fi
else
  skip "无真实 node,跳过用例 7(失败回滚)"
fi

h1 "8. dsh 运行中跳过(假 /health 服务返回 {\"dsh\":true})"

if make_env t08 1.0.0; then
  printf '2.0.0\n' > "$TEST_VIEW_FILE"
  PORT=""
  for _ in 1 2 3; do
    CAND="$(pick_free_port)"
    # 裸 socket 假服务:bind 与 listen 之间不夹任何解析动作。
    # 不要换回 http.server.HTTPServer —— 它在 server_bind() 里调用 socket.getfqdn(host)
    # 做反向解析,而该调用恰好夹在 bind() 与 listen() 之间:解析慢时 socket 会长时间停在
    # 「已绑定、未监听」状态,而 macOS 对此时到达的 SYN 是直接丢弃(实测 curl 挂满超时,
    # 不返回 ECONNREFUSED)。CI(GitHub macOS runner)上反向解析可达数秒 → update-dsh.sh 的
    # /health 探测(-m 2)与 /stop 探测(--max-time 5)双双超时 → 健康检查读不到 dsh:true →
    # 误判「dsh 未运行」→ 照常更新,本用例假失败(实测 CI 用例耗时 ~7.9s ≈ 2s+5s 双超时)。
    # 同 job 内 smoke-test.sh 的占位监听器同样是裸 socket,在 CI 稳定通过,可反证网络无碍。
    python3 -c '
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(16)
body = b"{\"dsh\":true,\"port\":0,\"pid\":0}"
while True:
    try:
        c, _ = s.accept()
    except OSError:
        break
    try:
        c.recv(4096)
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                  + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
    except OSError:
        pass
    finally:
        c.close()
' "$CAND" >/dev/null 2>&1 &
    CAND_PID=$!
    # 就绪判定必须真连一次:kill -0 只证明进程活着,不证明端口已在 listen(见上方注释)。
    # 保留 curl 退出码:失败时据此区分「连不上(7)」与「挂到超时(28)」,否则 2>/dev/null
    # 会把失败原因一并吞掉,让下一次同类故障无从定位。
    PROBE=""; PROBE_RC=0
    for _ in $(seq 1 50); do
      PROBE_RC=0
      PROBE="$(curl -s -m 1 --noproxy '*' "http://127.0.0.1:$CAND/health" 2>/dev/null)" || PROBE_RC=$?
      if printf '%s' "$PROBE" | grep -q '"dsh":true'; then break; fi
      sleep 0.1
    done
    if printf '%s' "$PROBE" | grep -q '"dsh":true'; then
      PORT="$CAND"
      SERVER_PID="$CAND_PID"
      break
    fi
    kill "$CAND_PID" 2>/dev/null || true
    wait "$CAND_PID" 2>/dev/null || true
  done
  if [ -z "$PORT" ]; then
    fail "无法启动假 HTTP 服务(健康探测需要)"
    info "最后一次探测: curl rc=$PROBE_RC 响应=${PROBE:-<空>}(rc=7 连不上 / rc=28 挂到超时)"
  else
    run_update "$TEST_DIR/run.out" "$PORT"
    if [ "$RUN_RC" = 0 ] && grep -q "dsh 运行中" "$TEST_STATE/logs/update.log" && grep -q "跳过本次更新" "$TEST_STATE/logs/update.log"; then
      ok "日志记录「dsh 运行中…跳过本次更新」并 exit 0"
    else
      fail "dsh 运行中未跳过(rc=$RUN_RC)"
      info "假服务在 127.0.0.1:$PORT 已就绪(探测响应 $PROBE),但 updater 未识别;update.log 尾部:"
      tail -3 "$TEST_STATE/logs/update.log" 2>/dev/null | while IFS= read -r l; do info "    $l"; done
    fi
    if grep -q '"version": *"1.0.0"' "$TEST_RT/app/node_modules/@deepseek-ai/dsh/package.json" && [ ! -f "$TEST_PNPM_LOG" ]; then
      ok "node_modules 未动且未调用 pnpm"
    else
      fail "dsh 运行中仍修改了依赖树"
    fi
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
else
  skip "无真实 node,跳过用例 8(dsh 运行中跳过)"
fi

h1 "9. 日志轮转(update.log 超 2MB → 轮转为 update.log.1)"

if make_env t09 1.0.0; then
  printf '1.0.0\n' > "$TEST_VIEW_FILE"
  dd if=/dev/zero of="$TEST_STATE/logs/update.log" bs=1048576 count=3 2>/dev/null
  BIG_SIZE="$(stat -f%z "$TEST_STATE/logs/update.log")"
  run_update
  if [ -f "$TEST_STATE/logs/update.log.1" ]; then
    ok "update.log 已轮转为 update.log.1(阈值 >2MB)"
  else
    fail "未生成 update.log.1"
  fi
  SZ1="$(stat -f%z "$TEST_STATE/logs/update.log.1" 2>/dev/null || echo 0)"
  if [ "$SZ1" = "$BIG_SIZE" ]; then
    ok "旧日志完整保留($SZ1 字节)"
  else
    fail "轮转后大小不符($SZ1 ≠ $BIG_SIZE)"
  fi
  if grep -q "已是最新版本" "$TEST_STATE/logs/update.log"; then
    ok "轮转后新日志正常写入 update.log"
  else
    fail "轮转后新日志未写入"
  fi
else
  skip "无真实 node,跳过用例 9(日志轮转)"
fi

h1 "10. update-dsh.sh 语法与可执行性(与 CI 门禁一致)"

if bash -n "$UPDATER"; then
  ok "bash -n 语法检查通过"
else
  fail "bash -n 语法检查失败"
fi
if [ -x "$UPDATER" ]; then
  ok "update-dsh.sh 具备可执行位"
else
  fail "update-dsh.sh 缺少可执行位"
fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$UPDATER" "$0"; then
    ok "shellcheck -S warning 零告警(update-dsh.sh + 本套件)"
  else
    fail "shellcheck -S warning 存在告警"
  fi
else
  skip "shellcheck 未安装,跳过 shellcheck 检查"
fi

h1 "未自动化项(SKIP —— 破坏性/需真实环境,保留人工验收)"

skip "测试 1 后台异步更新:需真实安装 + launchd + 激活触发(自动化会触碰真实运行时)"
skip "测试 2 定时更新器:需真实 launchctl 注册 com.dshpwa.updater"
skip "测试 4 禁用自动更新:需真实安装 + launchctl 验证"
skip "测试 6 网络故障降级:需真实断网/屏蔽 registry"
skip "测试 7 版本验证(真实版):需改真实 package.json 并访问真实 registry(干跑升级路径已由测试 3 覆盖)"
skip "卸载测试:需真实安装后 bootout/删文件"
skip "性能测试:需真实运行环境(启动延迟/内存占用)"
skip "文件权限 stat:需真实安装后的日志文件(0600)"
skip "路径注入防护:DSH_RT_HOME 注入会在真实文件系统落地脏目录,保留人工验证"

h1 "测试总结"
echo
if [ "$FAIL" = "0" ]; then
  echo "${G}${B}✓ 全部通过${RST} ($PASS 项通过, $SKIP_COUNT 项 SKIP)"
  exit 0
else
  echo "${R}${B}✗ 发现问题${RST} (${G}$PASS 通过${RST}, ${R}$FAIL 失败${RST}, $SKIP_COUNT 项 SKIP)"
  exit 1
fi
