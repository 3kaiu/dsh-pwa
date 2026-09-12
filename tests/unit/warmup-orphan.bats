#!/usr/bin/env bats
# 暖机收尾不得留下孤儿 dsh —— install.sh 4c 失败路径的回归门禁
#
# 背景:暖机的**成功**分支发 /stop 收掉 dsh;而**失败**分支旧实现只 kill 守护前台进程。
# 但 dsh 是守护经 setsid 自成的进程组(spawn_dsh() 里的 setsid()),不在守护的进程组里,于是守护被
# 硬杀后 dsh 会孤儿化 —— 继续 LISTEN、继续常驻内存。实测在真实机器上泄漏过 5 个
# (守护早已自退,dsh 仍在 127.0.0.1 上监听)。修法:两分支都发 /stop,并在 kill 守护后
# 按 dsh.pid 兜底「负 PID 打整组」(与守护自身的停止逻辑一致,stop_dsh())。
#
# 做法:按行锚点从 install.sh 切出 4c 的**真实代码**(不重写、不复制),用 stub daemon 驱动。
# stub 只做两件事:拉起一个自成进程组的子进程(模拟 dsh)、把它的 pid 写进
# $DSH_RT_STATE/dsh.pid(模拟守护的记账)。stub **不实现 HTTP**,于是 /health 永不返回
# dsh:true,天然走失败分支。断言:块跑完后那个子进程必须已经死了。
#
# 注意:测试描述必须全 ASCII —— bats 1.14 + macOS bash 3.2 下多字节描述会**静默清空用例**
# (假绿),install-validation.bats 里有同名守卫在盯着。

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # 允许指向另一份 install.sh,便于做 fail-before 复核(指向修复前的版本应当失败)
  INSTALL="${WARMUP_INSTALL_SRC:-$ROOT/scripts/install.sh}"
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/rt" "$FIX/state/logs" "$FIX/home"
}

fail() { echo "$*" >&2; return 1; }

# 切出 4c 暖机块:从 `# ---------- 4c)` 那行起,到 `# ---------- 5)` 前一行止。
# **必须从注释行起**而不是 `h1 "4c)"` 行 —— marker/预算等变量定义在 h1 之前。
extract_block() {
  awk '/^# -+ 4c\)/{f=1} f && /^# -+ 5\)/{exit} f' "$1"
}

@test "warmup block extracts to valid bash (anchor drift guard)" {
  extract_block "$INSTALL" > "$FIX/block.sh"
  grep -q 'WARM_READY' "$FIX/block.sh" || fail "extracted block lacks WARM_READY (anchor drifted?)"
  grep -q 'WARM_TIMEOUT=' "$FIX/block.sh" || fail "extracted block lacks WARM_TIMEOUT (anchor drifted?)"
  bash -n "$FIX/block.sh" || fail "extracted block is not valid bash (anchor drifted?)"
}

@test "failed warmup leaves no orphan dsh process" {
  extract_block "$INSTALL" > "$FIX/block.sh"
  bash -n "$FIX/block.sh" || fail "extracted block is not valid bash"

  # stub daemon:模拟守护拉起 dsh(setsid 自成进程组)并记账
  cat > "$FIX/rt/daemon" <<'STUB'
#!/usr/bin/env bash
python3 -c 'import os,time; os.setsid(); time.sleep(300)' &
child=$!
echo "$child" > "$DSH_RT_STATE/dsh.pid"
echo "$child" > "$FIX/child.pid"
wait
STUB
  chmod +x "$FIX/rt/daemon"

  # 只提供 4c 块依赖的外部变量与输出函数;块本身保持原样运行
  cat > "$FIX/harness.sh" <<'HARNESS'
set -uo pipefail
RT_HOME="$FIX/rt"
RT_STATE="$FIX/state"
DSH_HOME="$FIX/home"
LOG_DIR="$FIX/state/logs"
CUR_DSH="0.0.0-test"
NODE_BIN="/bin/true"
DSH_BIN="/bin/true"
DSH_RT_WARMUP_TIMEOUT_SECS=5
h1() { echo "== $* =="; }
ok() { echo "ok: $*"; }
warn() { echo "warn: $*" >&2; }
. "$FIX/block.sh"
HARNESS

  FIX="$FIX" bash "$FIX/harness.sh" > "$FIX/out.log" 2>&1 || true

  # 反空转:stub 必须真的拉起子进程并记了账,否则「没有孤儿」是假绿
  [ -s "$FIX/child.pid" ] || fail "stub never recorded a child pid (vacuous test); log: $(cat "$FIX/out.log")"
  child="$(cat "$FIX/child.pid")"

  if kill -0 "$child" 2>/dev/null; then
    kill -9 "$child" 2>/dev/null || true
    fail "orphan dsh survived the warmup cleanup (pid $child); log: $(cat "$FIX/out.log")"
  fi
}
