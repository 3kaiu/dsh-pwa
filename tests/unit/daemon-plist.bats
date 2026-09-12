#!/usr/bin/env bats
# LaunchAgent(守护 plist)门禁 —— 对应深审 F1/F4。
#
# 为什么需要这个文件:launchd/com.dshpwa.daemon.plist 是「产品能不能用」的单点
#   (ProgramArguments / Sockets / EnvironmentVariables 任一写错,守护根本不会被激活,
#    而且**没有任何用户可见的错误**),但在 2026-09-12 深审之前它从未被渲染、lint 或断言过 ——
#    全仓库的 plutil -lint 只作用于 updater plist 与冒烟测试自建的 SA plist。
#    于是它里面写死的 NODE_OPTIONS=--use-system-ca 一直没被发现:该选项是 Node **22.15.0**
#    才引入的,而 install.sh 的 MIN_NODE=22 只比 major → 22.0–22.14 上每次 dsh spawn 都
#    立即 exit 9(实测:NODE_OPTIONS 含未识别选项时 node 拒绝启动,一行代码都不执行)。
#    它能一直保持绿色,靠的是三个条件叠加:CI 跑 macos-latest(node 较新)、冒烟与 dsh-probe
#    都**前台起守护且不带 NODE_OPTIONS**、以及没有任何门禁读这个文件。
#    同一个危害在 update-dsh.sh 里早已被能力探测防住 ——「一处防住了、另一处没防」。
#
# 本文件只做静态/渲染断言(不起守护),故可在任何环境稳定运行。
# 注意:测试名仅 ASCII(bats 1.14 + macOS 自带 bash 3.2 对多字节测试名有缺陷,
#       含中文的 @test 名会静默执行 0 个测试,见 install-validation.bats 注释)。

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TPL="$ROOT/launchd/com.dshpwa.daemon.plist"
UPDATER_TPL="$ROOT/launchd/com.dshpwa.updater.plist"
INSTALL="$ROOT/scripts/install.sh"
SMOKE="$ROOT/scripts/smoke-test.sh"

# 能力探测的字面形式(与 update-dsh.sh 同形)。放在变量里而不是直接写进断言,
# 是为了让「探针字面量」只有一处来源,避免本文件自己成为被测面的一部分。
PROBE="--use-system-ca -e ''"
ENTRY_BEGIN=">>> node-options-entry"
ENTRY_END="<<< node-options-entry <<<"

# 模板的**数据部分**(剥掉 XML 注释),因为占位符名在抬头注释里也会被列举,
# 若连注释一起扫,「只把占位符写进注释、正文里其实没有」也会通过 —— 那正是
# 「门禁被被测面自己的注释满足」这一类假绿(TRAPS §一.20)。
tpl_data() {
  awk '
    /<!--/ { inc = 1 }
    !inc  { print }
    /-->/  { inc = 0 }
  ' "$TPL"
}

# 模板数据部分出现的占位符名(去掉 __ 包裹),排序去重。
tpl_placeholders() {
  tpl_data | grep -oE '__[A-Z][A-Z0-9_]*__' \
    | sed -e 's/^__//' -e 's/__$//' | sort -u
}

# 某个渲染脚本里 sed 替换的占位符名,排序去重。
# 用字符类 [|] 而不是 \| ——BSD 与 BWK 工具对转义的 | 处理不一致,而 [|] 在两处都是字面量
# (本项目在 grep '\|' 上踩过「静默无输出」,见 TRAPS §一.1)。
renderer_placeholders() {
  grep -oE 's[|]__[A-Z][A-Z0-9_]*__[|]' "$1" \
    | sed -e 's/^s[|]__//' -e 's/__[|]$//' | sort -u
}

# 抽取 install.sh 里由标记包起来的能力探测段(供行为验证执行)。
extract_entry_block() {
  awk -v b="$ENTRY_BEGIN" -v e="$ENTRY_END" '
    index($0, b) { f = 1; next }
    index($0, e) { f = 0 }
    f
  ' "$1"
}

@test "daemon plist template does not bake in a version-gated NODE_OPTIONS" {
  # F1 的根因断言。模板是**数据**,这里断言的是数据的真实性质(不得写死版本相关的开关),
  # 不是「用文本去断言行为」——后者才是 TRAPS §一.20 的假绿。
  [ -s "$TPL" ] || { echo "  模板缺失或为空:$TPL" >&2; return 1; }
  # 反空转(面):模板必须真的可读且含 NODE_OPTIONS 占位符,否则下面的「不得含字面量」
  # 会因读不到文件而恒真。
  tpl_data | grep -q '__NODE_OPTIONS_ENTRY__' \
    || { echo "  模板数据部分缺 __NODE_OPTIONS_ENTRY__(改回写死了?注释里提到不算)" >&2; return 1; }
  if tpl_data | grep -q -- '--use-system-ca'; then
    echo "  模板写死了版本相关的 NODE_OPTIONS 选项(应由 install.sh 探测后注入):" >&2
    tpl_data | grep -n -- '--use-system-ca' | sed 's/^/    /' >&2
    return 1
  fi
}

@test "updater plist does not inject NODE_OPTIONS (its script probes at runtime)" {
  # updater 侧是**刻意**不注入的:update-dsh.sh 自己会探测(它跑在用户的 shell 环境里,
  # 拿得到当时真实的 node)。把这一条也钉住,免得将来有人「顺手统一」两个 plist。
  [ -s "$UPDATER_TPL" ] || { echo "  updater 模板缺失:$UPDATER_TPL" >&2; return 1; }
  if grep -q 'NODE_OPTIONS' "$UPDATER_TPL"; then
    echo "  updater plist 注入了 NODE_OPTIONS;update-dsh.sh 运行时自行探测,写死会让旧 node 拒绝启动" >&2
    grep -n 'NODE_OPTIONS' "$UPDATER_TPL" | sed 's/^/    /' >&2
    return 1
  fi
}

@test "every daemon plist placeholder is substituted by every renderer" {
  local tp rp missing p
  tp="$(tpl_placeholders)"
  # 反空转(面):抽取必须真的命中。锚点漂移时 tp 为空,集合比较会「空 ⊆ 空」恒真。
  # 用**必需成员**而不是裸计数当下界:模板将来合理地增删占位符时不会误报,
  # 而抽取失明 / 模板被改坏时必然命中(见 TRAPS §一.16)。
  for p in DAEMON_BIN HOME RT_HOME RT_STATE DSH_RT_PORT NODE_OPTIONS_ENTRY; do
    printf '%s\n' "$tp" | grep -qx "$p" \
      || { echo "  模板占位符集合缺少 $p(抽取失明或模板被改坏):[$tp]" >&2; return 1; }
  done

  # 单向(模板 ⊆ 渲染器)就够,而且不会误报:渲染器多出的占位符来自 updater 模板的替换,
  # 那些是合法的;但模板有而渲染器缺的,必然在产物里留下 __X__ → plist 非法 →
  # launchd **静默不加载**(用户看到「安装完成」却永远打不开)。拼写错误也走这条路径。
  for f in "$INSTALL" "$SMOKE"; do
    rp="$(renderer_placeholders "$f")"
    missing="$(comm -23 <(printf '%s\n' "$tp") <(printf '%s\n' "$rp"))"
    if [ -n "$missing" ]; then
      echo "  $(basename "$f") 未替换以下占位符(产物会留下 __X__ → plist 非法):" >&2
      printf '%s\n' "$missing" | sed 's/^/      /' >&2
      return 1
    fi
  done
}

@test "daemon plist renders to a valid plist with no placeholder residue" {
  local out="$BATS_TEST_TMPDIR/daemon.plist" p
  local sedargs=()
  # 用**模板自己声明的**占位符集合来构造替换,而不是把 install.sh 的 sed 抄一遍 ——
  # 抄一遍就成了「另一套实现」,它的正确性不构成对 install.sh 的保证(TRAPS §四)。
  # 与上一条(模板 ⊆ 渲染器)合起来才闭环:模板可渲染 + 渲染器覆盖全部占位符。
  # __NODE_OPTIONS_ENTRY__ 是**整行**占位符(取值必须是合法 XML 条目或空),单独处理 ——
  # 塞一个 DUMMY_ 文本进去会让 plist 非法,那是本占位符的语义,不是模板的问题。
  while IFS= read -r p; do
    [ "$p" = "NODE_OPTIONS_ENTRY" ] && continue
    sedargs+=(-e "s|__${p}__|DUMMY_${p}|g")
  done <<< "$(tpl_placeholders)"
  [ "${#sedargs[@]}" -ge 5 ] || { echo "  替换参数只有 ${#sedargs[@]} 组,占位符抽取已失明" >&2; return 1; }

  # 分支 A:能力探测判定「不支持」→ 整行留空,plist 仍须合法,且该键必须不存在。
  sed "${sedargs[@]}" -e "s|__NODE_OPTIONS_ENTRY__||g" "$TPL" > "$out"
  plutil -lint "$out" >/dev/null || { echo "  渲染结果不是合法 plist(空条目分支):" >&2; plutil -lint "$out" >&2; return 1; }
  if grep -nE '__[A-Z][A-Z0-9_]*__' "$out" >/dev/null; then
    echo "  渲染后仍有未替换的占位符:" >&2
    grep -nE '__[A-Z][A-Z0-9_]*__' "$out" | sed 's/^/    /' >&2
    return 1
  fi
  # 反空转(反):留空**必须**真的没有该键 —— 留空字符串仍然等于设了 NODE_OPTIONS,语义不同。
  if plutil -extract EnvironmentVariables.NODE_OPTIONS raw -o - "$out" 2>/dev/null | grep -q .; then
    echo "  空条目渲染后 NODE_OPTIONS 仍然存在(应为整键省略)" >&2
    return 1
  fi

  # 分支 B:判定「支持」→ 条目注入后该键必须真的出现。否则上面那句「无残留」可能只是因为
  # 模板压根没有那个占位符(空提取恒真,见 TRAPS §一.16)。
  sed "${sedargs[@]}" \
      -e "s|__NODE_OPTIONS_ENTRY__|<key>NODE_OPTIONS</key><string>--use-system-ca</string>|g" \
      "$TPL" > "$out"
  plutil -lint "$out" >/dev/null || { echo "  渲染结果不是合法 plist(注入分支):" >&2; plutil -lint "$out" >&2; return 1; }
  plutil -extract EnvironmentVariables.NODE_OPTIONS raw -o - "$out" 2>/dev/null \
    | grep -q -- '--use-system-ca' \
    || { echo "  注入 NODE_OPTIONS 条目后该键未出现(渲染链失效)" >&2; return 1; }
}

@test "install.sh gates NODE_OPTIONS on a real node capability probe" {
  local block="$BATS_TEST_TMPDIR/node-options-entry.sh"
  extract_entry_block "$INSTALL" > "$block"
  # 反空转(面):抽取必须真的命中 —— 标记漂移时块为空,下面的行为断言会「测了个空文件」。
  [ -s "$block" ] || { echo "  未抽到 node-options-entry 段(标记漂移?)" >&2; return 1; }
  grep -qF -- "$PROBE" "$block" \
    || { echo "  段内没有能力探测(\"$PROBE\"),可能被改成无条件注入" >&2; return 1; }

  # 行为验证:用两个假 node 分别模拟「支持 / 不支持该选项」的真实 node。
  # 这是唯一能证明**门禁逻辑本身**正确的方式 —— 只断言「探测语句存在」是文本断言,
  # 把条件写反(或恒真)照样通过。
  local ok="$BATS_TEST_TMPDIR/node-ok" bad="$BATS_TEST_TMPDIR/node-bad"
  printf '#!/bin/sh\nexit 0\n' > "$ok"
  printf '#!/bin/sh\nexit 9\n' > "$bad"
  chmod +x "$ok" "$bad"

  local got_ok got_bad
  got_ok="$(env NODE_BIN="$ok" bash -c 'source "$1"; printf "%s" "$NODE_OPTIONS_ENTRY"' _ "$block")"
  got_bad="$(env NODE_BIN="$bad" bash -c 'source "$1"; printf "%s" "$NODE_OPTIONS_ENTRY"' _ "$block")"
  [ -n "$got_ok" ] \
    || { echo "  支持该选项的 node 未得到 NODE_OPTIONS 条目(能力探测写反了?)" >&2; return 1; }
  printf '%s' "$got_ok" | grep -qF -- '--use-system-ca' \
    || { echo "  条目内容异常:[$got_ok]" >&2; return 1; }
  [ -z "$got_bad" ] \
    || { echo "  不支持该选项的 node 仍被注入 NODE_OPTIONS(旧 node 会 rc=9 拒绝启动):[$got_bad]" >&2; return 1; }
}

@test "both daemon plist renderers use the same node capability probe" {
  # 两个渲染点必须同形:只改一处是这类缺陷的经典成因(update-dsh.sh 防住了、plist 没防)。
  local a b
  a="$(grep -cF -- "$PROBE" "$INSTALL" || true)"
  b="$(grep -cF -- "$PROBE" "$SMOKE" || true)"
  [ "$a" -ge 1 ] || { echo "  install.sh 缺能力探测(\"$PROBE\")" >&2; return 1; }
  [ "$b" -ge 1 ] || { echo "  smoke-test.sh 缺能力探测(占位符会渲染成空,形状与 install.sh 不一致)" >&2; return 1; }
}

# —— F15:路径字符白名单(注入 plist 前的 fail-closed 校验)——
# 旧实现是 2 字符黑名单(`|` 与 `&`,理由是 sed 语义),但目标产物是 XML:
# `<` `>` `"` 与换行同样会产出**非法 plist** → launchd 静默不加载。
# 这里提取 install.sh 的 `>>> path-charset` 段**整段执行**(含 fail-closed 的 exit 1),
# 而不是 grep 源码文本 —— 后者删掉实现只留注释也照样绿(TRAPS §一.20)。
PATH_BEGIN=">>> path-charset"
PATH_END="<<< path-charset <<<"

extract_path_charset_block() {
  awk -v b="$PATH_BEGIN" -v e="$PATH_END" '
    index($0, b) { f = 1; next }
    index($0, e) { f = 0 }
    f
  ' "$1"
}

@test "install.sh rejects paths that cannot be written safely into the plist" {
  local blk
  blk="$(extract_path_charset_block "$INSTALL")"
  # 反空转(面):标记漂移时块为空 → 下面的行为断言会「测了个空脚本」而恒过。
  [ -n "$blk" ] || { echo "  未抽到 path-charset 段(标记漂移?)" >&2; return 1; }
  printf '%s' "$blk" | grep -q 'dsh_path_charset_bad' \
    || { echo "  段内没有校验函数,抽取锚点可能指错了地方" >&2; return 1; }

  local p
  # 正控:合法路径必须放行(rc=0)。含空格与非 ASCII 的路径也是合法的。
  for p in "/Users/seeu/dev/dsh-pwa" "/Users/John Doe/My App" "/Users/张 三/应用"; do
    if ! env HOME="$p" RT_HOME=/x RT_STATE=/y bash -c "$blk" >/dev/null 2>&1; then
      echo "  合法路径被误拒(白名单过严):[$p]" >&2
      return 1
    fi
  done

  # 负控:每个危险字符都必须被拒 —— 只测 `&` 会让 `<` 这一类继续漏网(正是 F15 的成因)。
  local ch
  for ch in '&' '|' '<' '>' '"' "'" ';' '$' '`' '\'; do
    if env HOME="/Users/a${ch}b" RT_HOME=/x RT_STATE=/y bash -c "$blk" >/dev/null 2>&1; then
      echo "  含 [$ch] 的路径被放行(会产出非法 plist,launchd 静默不加载)" >&2
      return 1
    fi
  done

  # 控制字符:换行/制表会直接截断 XML,且**不会**被「可见 ASCII 残留」那条判据命中,
  # 是最容易漏的一类,故单独覆盖。
  if env HOME="$(printf '/Users/a\nb')" RT_HOME=/x RT_STATE=/y bash -c "$blk" >/dev/null 2>&1; then
    echo "  含换行的路径被放行(会截断 plist)" >&2
    return 1
  fi
  if env HOME="$(printf '/Users/a\tb')" RT_HOME=/x RT_STATE=/y bash -c "$blk" >/dev/null 2>&1; then
    echo "  含制表的路径被放行" >&2
    return 1
  fi

  # 三个路径变量都要被检查,不能只查 HOME。
  if env HOME=/ok RT_HOME='/bad&path' RT_STATE=/y bash -c "$blk" >/dev/null 2>&1; then
    echo "  RT_HOME 未被校验(只查了 HOME?)" >&2
    return 1
  fi
  if env HOME=/ok RT_HOME=/x RT_STATE='/bad<path' bash -c "$blk" >/dev/null 2>&1; then
    echo "  RT_STATE 未被校验(只查了 HOME/RT_HOME?)" >&2
    return 1
  fi
}
