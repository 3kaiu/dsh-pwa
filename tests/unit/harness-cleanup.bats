#!/usr/bin/env bats
# 测试脚手架自身的收尾卫生:**任何会起守护的脚本,退出后都不得留下守护进程**。
#
# 背景(2026-09-12):CI 作业结束时 runner 稳定报 `Terminate orphan process: pid (…) (daemon)`
# (4 次 run 各 3 个)。对照 Release workflow(跑 smoke-test.sh 但**不跑**安全套件)为 **0 个**,
# 据此定位到 tests/security-verification.sh:它的 EXIT trap 只做了 `rm -rf "$TMPD"` ——
# 既不停守护,也不清 TMPD_PERM,而且 trap 挂在脚本末尾(前面 300 行全在保护之外)。
#
# 两个用例的分工:
#   用例 1(静态不变量,确定性):断言「EXIT trap 必须先于首次启动守护注册」且收尾真的按
#     二进制路径兜底。修复前的代码**必然违反**此不变量(它把 trap 放在第 7 节)。
#   用例 2(行为级):真跑一遍安全套件,断言退出后没有属于该套件临时目录的守护进程。
#     注意:本用例在**带进程插桩的沙箱**里可能空转 —— 实测把 TMPDIR 换成受控目录后泄漏
#     即消失(泄漏进程还持有沙箱日志 fd),故本地不可靠;但 CI(无沙箱)才是泄漏真正发生的
#     环境,在那里它是有意义的。真正的判据以 CI 的 orphan 报告为准。
#
# 注意:测试名仅 ASCII(bats 1.14 + macOS bash 3.2 对多字节测试名有缺陷,会 0 用例静默通过)。

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# 首次**真实调用**某模式的行号(空=未出现)。
# 必须排除注释行:本仓库注释里大量提及函数名(如「公共 helper:… daemon_start_foreground …」),
# 早期版本的门禁正是被第 10 行那条注释骗过,把「首次启动守护」误判成第 10 行 ——
# 于是它对真正的问题**恒报通过**。教训同 MEMORY 陷阱 21:探针必须锚定到被测对象本身。
first_call_line() {
  awk -v pat="$1" '
    /^[[:space:]]*#/ { next }          # 跳过整行注释
    $0 ~ pat { print NR; exit }
  ' "$2"
}

# 提取 shell 函数体(从 `name() {` 到行首 `}`)
func_body() {
  awk -v h="$1" 'index($0, h "()") == 1 {f=1} f {print} f && /^}/ {exit}' "$2"
}

# 提取「后台拉起守护」的那条命令语句(向前吸收 `\` 续行,得到完整命令)
daemon_launch_stmt() {
  awk -v n="$1" '
    { lines[NR]=$0 }
    END {
      s=n
      while (s>1 && lines[s-1] ~ /\\[[:space:]]*$/) s--
      for (i=s;i<=n;i++) print lines[i]
    }' "$2"
}

@test "daemon-starting scripts register EXIT trap before first daemon start" {
  # 路径可覆盖,供 fail-before 复验(指向修复前的副本)。本用例只**读**文件,不执行,
  # 故副本放在任意位置都成立。
  local f="" trap_line="" start_line="" handler="" name="" body=""
  for f in "${SEC_SCRIPT:-$ROOT/tests/security-verification.sh}" \
           "${SMOKE_SCRIPT:-$ROOT/scripts/smoke-test.sh}"; do
    name="$(basename "$f")"
    start_line="$(first_call_line 'daemon_start_foreground' "$f")"
    trap_line="$(first_call_line 'trap .*EXIT' "$f")"

    [ -n "$start_line" ] || { echo "$name: 未找到 daemon_start_foreground 调用" >&2; return 1; }
    [ -n "$trap_line" ] || { echo "$name: 未注册 EXIT trap" >&2; return 1; }
    [ "$trap_line" -lt "$start_line" ] || {
      echo "$name: EXIT trap 在第 $trap_line 行,晚于首次启动守护(第 $start_line 行)" >&2
      echo "  → 「守护已启动但随后失败」的路径不受保护,会留下孤儿守护" >&2
      return 1
    }

    # trap 的 handler 必须真的收守护:函数体里既有按 pid、也有按二进制路径
    handler="$(sed -n "${trap_line}p" "$f" | awk '{print $2}')"
    body="$(func_body "$handler" "$f")"
    [ -n "$body" ] || { echo "$name: trap 的 $handler 未定义" >&2; return 1; }
    printf '%s' "$body" | grep -q 'daemon_stop ' || {
      echo "$name: $handler 未按 pid 收守护" >&2; return 1; }
    printf '%s' "$body" | grep -q 'daemon_stop_by_binary' || {
      echo "$name: 未按二进制路径兜底 —— \`\$!\` 未必是在 listen 的那个进程" >&2
      echo "  (实测偏差 4~15 个 pid;见 tests/lib/daemon-helpers.sh)" >&2
      return 1
    }
  done
  return 0
}

@test "security-verification.sh leaves no daemon behind" {
  # 用受控 TMPDIR,这样残留守护的 argv[0] 前缀可知,判据精确到本用例创建的目录
  local iso="$BATS_TEST_TMPDIR/iso"
  mkdir -p "$iso"

  # SECURITY_SRC 可覆盖,供 fail-before 复验(指向修复前的副本)
  local src="${SECURITY_SRC:-$ROOT/tests/security-verification.sh}"

  run env TMPDIR="$iso" bash "$src"
  [ "$status" -eq 0 ] || { echo "套件自身未通过(exit=$status)" >&2; return 1; }

  # 反空转:必须真的执行到「启动守护」的两处分支,否则本用例什么也没验
  printf '%s' "$output" | grep -q '启动临时 daemon' \
    || { echo "未执行到启动守护的分支,用例空转" >&2; return 1; }
  printf '%s' "$output" | grep -q '运行时验证 LOG_DIR 真实权限' \
    || { echo "未执行到第二个守护的分支,用例空转" >&2; return 1; }

  # 给 SIGTERM 一点生效时间(守护无 SIGTERM 处理器,默认动作即退出,1s 足够)
  sleep 1

  local left=""
  left="$(pgrep -f "^${iso}/[^ ]*/daemon( |\$)" 2>/dev/null || true)"
  if [ -n "$left" ]; then
    echo "残留守护进程(应被收尾):" >&2
    pgrep -fl "^${iso}/[^ ]*/daemon( |\$)" >&2 || true
    for _p in $left; do kill -9 "$_p" 2>/dev/null || true; done
    return 1
  fi
  return 0
}

@test "workflow steps that background the daemon disable auto-update" {
  # 守护**每次启动**都会 fork 一个 setsid 的更新检查子进程(见 src/daemon.c:1057 的注释),
  # 它先 sleep(10) 再 exec update-dsh.sh。在那 10s 里它是一个**同名的 daemon 进程**且自成会话
  # (setsid),因此「杀掉守护」根本杀不到它 —— 实测:父守护 95539 被杀后,子进程 95541 存活。
  # 短作业(job 收尾早于那 10s)就会在收尾时被 runner 抓成 orphan:ci-enhanced.yml 的性能基准
  # 步骤实测约 3.5s,run 34647776445 / 34651085008 各稳定报 1 个 orphan daemon。
  # 故凡在 workflow 里**后台**拉起守护的命令,必须在同一条命令里置 DSH_RT_NO_AUTO_UPDATE=1。
  # 约定出处:tests/unit/daemon-cases.bats:32「测试环境绝不触发后台更新子进程」。
  local dir="${WORKFLOWS_DIR:-$ROOT/.github/workflows}"
  local f="" ln="" stmt="" bad=0
  for f in "$dir"/*.yml; do
    [ -f "$f" ] || continue
    for ln in $(awk '/daemon/ && /&[[:space:]]*$/ {print NR}' "$f"); do
      stmt="$(daemon_launch_stmt "$ln" "$f")"
      if ! printf '%s' "$stmt" | grep -q 'DSH_RT_NO_AUTO_UPDATE'; then
        echo "$(basename "$f"):$ln 后台拉起守护,但同一条命令里没有 DSH_RT_NO_AUTO_UPDATE" >&2
        echo "  → 更新检查子进程会在守护被杀后继续存活(sleep 10s 内同名),短作业收尾即报 orphan daemon" >&2
        printf '%s\n' "$stmt" | sed 's/^/    /' >&2
        bad=1
      fi
    done
  done
  [ "$bad" = "0" ]
}
