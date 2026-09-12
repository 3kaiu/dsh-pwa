#!/usr/bin/env bats
# extract_fn 的回归门禁 —— 审计 F10「sed 行范围抽函数体的静默失配面」。
#
# 被测对象是 tests/lib/daemon-helpers.sh 里的 extract_fn(符号锚点 + 花括号配平)。
# 为什么值得单独设门禁:它是 security-verification.sh 里 4.3 / 5.3 / 6.1 三条断言的
# **共同地基** —— 抽取器错了,那三条断言的结论就与真实结构无关(F10 原文:
# 「ok 或 fail 都会给出与真实结构无关的结论」)。

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$ROOT/tests/lib/daemon-helpers.sh"
  FX="$BATS_TEST_TMPDIR/fixture.c"
  SRC="$ROOT/src/daemon.c"
}

# 反空转:所有用例都断言**具体行数或具体内容**,不看退出码。

@test "extract_fn returns the whole body even when a brace sits at column 0" {
  # 函数体内一行列 0 的 } 会让「第一行列 0 的 }」式行范围抽取**静默截断**。
  cat > "$FX" <<'EOF'
static int before(void) { return 1; }

static int target(int n) {
  int s = 0;
  if (n > 0) {
    s = 1;
}
  s += 2;
  return s;
}

static int after(void) { return 2; }
EOF
  local new_n old_n
  new_n="$(extract_fn target "$FX" | wc -l | tr -d ' ')"
  old_n="$(sed -n '/^static int target/,/^}/p' "$FX" | wc -l | tr -d ' ')"
  # 新抽取器拿到完整 8 行;旧写法在第 5 行(列 0 的 } )被截断。
  [ "$new_n" = "8" ] || { echo "extract_fn 行数=$new_n(应为 8)" >&2; return 1; }
  [ "$old_n" = "5" ] || { echo "对照:旧 sed 行数=$old_n(应为 5,用于证明差异真实存在)" >&2; return 1; }
  # 截断后丢失的尾部代码必须在新结果里 —— 否则「行数对」可能只是巧合。
  extract_fn target "$FX" | grep -q 's += 2;' || { echo "尾部代码丢失" >&2; return 1; }
  # 且不得越过函数边界把 after() 也吞进来。
  if extract_fn target "$FX" | grep -q 'return 2;'; then
    echo "抽取越界:吞掉了下一个函数" >&2
    return 1
  fi
}

@test "clean mode strips comments so a comment cannot satisfy a textual judgement" {
  # 探针污染(TRAPS §一.20):注释里出现被扫的字面量不得算命中。
  cat > "$FX" <<'EOF'
static int probe(int *o) {
  // 这里绝不 listen( 任何东西
  if (bind(s, 0, 0) < 0) return -1;
  return s;
}
EOF
  if extract_fn probe "$FX" | grep -q 'listen('; then
    echo "clean 模式被注释满足(探针污染)" >&2
    return 1
  fi
  # 正控:同一文件 raw 模式必须能看到那句注释,否则上一条可能是「抽取整体失效」的假绿。
  extract_fn probe "$FX" raw | grep -q 'listen(' || {
    echo "raw 模式看不到注释,说明抽取本身失效" >&2
    return 1
  }
  # 反控:代码里的 bind( 必须仍然可见,证明 clean 不是把代码也剥了。
  extract_fn probe "$FX" | grep -q 'bind(s' || { echo "clean 模式把代码也剥掉了" >&2; return 1; }
}

@test "extract_fn matches the symbol exactly, not a longer sibling name" {
  # 旧写法 `/^static void stop_dsh/` 会**同时匹配** stop_dsh_wait —— 于是断言
  # 「stop_dsh 在发信号前验证 PID」实际测的是 stop_dsh_wait 的函数体。
  local short_n long_n
  short_n="$(extract_fn stop_dsh "$SRC" | wc -l | tr -d ' ')"
  long_n="$(extract_fn stop_dsh_wait "$SRC" | wc -l | tr -d ' ')"
  [ "$short_n" = "1" ] || { echo "stop_dsh 应只抽到 1 行委托体,实得 $short_n" >&2; return 1; }
  [ "$long_n" -ge 20 ] || { echo "stop_dsh_wait 应抽到完整函数体(≥20 行),实得 $long_n" >&2; return 1; }
  # PID 验证逻辑在 stop_dsh_wait 里,不在 stop_dsh 里 —— 这正是 6.1 必须换锚点的原因。
  extract_fn stop_dsh_wait "$SRC" | grep -q 'kill(pid, 0)' || {
    echo "stop_dsh_wait 里未找到 PID 验证" >&2
    return 1
  }
  if extract_fn stop_dsh "$SRC" | grep -q 'kill(pid, 0)'; then
    echo "stop_dsh 一行委托体里不该有 kill 调用" >&2
    return 1
  fi
}

@test "extract_fn yields empty output for an unknown symbol" {
  # 调用方靠「空输出」把「抽取失败」与「结构合规」区分开(TRAPS §一.16 的下界要求)。
  local out
  out="$(extract_fn no_such_function_anywhere "$SRC")"
  [ -z "$out" ] || { echo "未知符号应输出空,实得 $out" >&2; return 1; }
  # 正控:同一文件里真实存在的符号必须非空,否则上一条可能只是「抽取器整体坏了」。
  [ -n "$(extract_fn http_probe "$SRC")" ] || { echo "已知符号也抽不到,抽取器整体失效" >&2; return 1; }
}

@test "extract_fn is brace-balanced on the real daemon source" {
  # 对真实源码的四个函数做「首行是签名、末行是 }」的结构校验 —— 配平若跑偏,末行就不是 }。
  local f first last
  for f in pick_port_fd spawn_dsh http_probe stop_dsh_wait; do
    first="$(extract_fn "$f" "$SRC" | head -1)"
    last="$(extract_fn "$f" "$SRC" | tail -1)"
    case "$first" in
      *"$f("*) ;;
      *) echo "$f 首行不是函数签名: $first" >&2; return 1 ;;
    esac
    [ "$last" = "}" ] || { echo "$f 末行不是 }: $last" >&2; return 1; }
  done
}
