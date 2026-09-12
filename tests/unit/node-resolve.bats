#!/usr/bin/env bats
# node 路径解析门禁 —— 对应深审 F3。
#
# 背景:install.sh 与 update-dsh.sh 都用
#   CAND="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$CAND" 2>/dev/null || echo "$CAND")"
# 把 fnm/volta 的 shim 解析到真实 node。两个问题:
#   (1) 它**假定 python3 存在**,而 macOS 12.3+ 不再随系统附带 python3(需装 CLT)。
#       缺失时该行**静默**走 `|| echo "$CAND"` 分支,把未解析的路径原样返回 —— 没有任何信号。
#   (2) 未解析的路径若是 fnm 的 multishell 目录($XDG_STATE_HOME/fnm_multishells/<pid>_<ts>/),
#       它**随 shell 退出即失效**;而这条路径会被写进 $RT_HOME/run.json,守护此后 exec 一个
#       已死的 node —— 表现为「守护活着、dsh 永远起不来」,且没有任何用户可见的错误。
#       (与 NODE_OPTIONS 那条同族:配置类故障,零用户可见信号。)
# 修法:换成纯 bash 的 dsh_resolve_node(逐级 readlink),并**拒绝复用**解析后仍落在会话级
#       目录的路径(落回自带 node —— 那条装在 RT_HOME 下,是稳定的)。
#
# 两个脚本各内联一份实现(避免为一个 12 行算法引入新的部署/打包同步点),
# 本文件第 1 例用**逐字节一致**来消灭漂移 —— 与 install-validation.bats 里
# 「release.yml 与 install.sh 写出的 app manifest 必须逐字节一致」同一手法。
# 注意:测试名仅 ASCII(bats 1.14 + macOS bash 3.2 对多字节测试名有缺陷 → 静默 0 用例)。

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
# NODE_RESOLVE_SRC_DIR 可指向另一份 scripts/ 目录,用于 fail-before 复核
# (与 WARMUP_INSTALL_SRC / SHA_INSTALL_SRC / DSH_DAEMON_SRC 同约定)。
SRC_DIR="${NODE_RESOLVE_SRC_DIR:-$ROOT/scripts}"
INSTALL="$SRC_DIR/install.sh"
UPDATE="$SRC_DIR/update-dsh.sh"
BLOCK_BEGIN='>>> node-resolve-shared'
BLOCK_END='<<< node-resolve-shared'

extract_block() {
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    index($0, b) { f = 1; next }
    index($0, e) { f = 0 }
    f
  ' "$1"
}

# 「可移植路径解析」的两个反模式:依赖 python3、依赖 GNU 专有的 readlink -f。
# 必须**跳过注释行**:注释里写「不要用 python3 realpath」是文档,不是违规 ——
# 不跳的话,门禁会被它自己的说明文字触发(TRAPS §一.15「探针文本污染被测面」,
# 且注释同样在扫描面内)。只跳过「前导空白后以 # 开头」的整行注释;
# 行尾注释里的代码不在此列(那种写法本项目没有,且真出现时误报方向是安全的)。
detect_bad_resolution() {
  awk '
    { t = $0; sub(/^[ \t]+/, "", t) }
    substr(t, 1, 1) == "#" { next }
    /os\.path\.realpath/ || /readlink[[:space:]]+-f/ { printf "%s:%d: %s\n", FILENAME, FNR, $0 }
  ' "$1"
}

@test "the two shared node-resolve blocks are byte-identical" {
  local a b
  a="$(extract_block "$INSTALL")"
  b="$(extract_block "$UPDATE")"
  # 反空转(面):抽取必须真的命中。标记漂移时两边都是空,`[ "" = "" ]` 恒真 ——
  # 门禁恒绿且看起来在管漂移(TRAPS §一.16 的「空提取满足上界」同族)。
  [ -n "$a" ] || { echo "  未能从 install.sh 抽到 node-resolve-shared 块(标记漂移?)" >&2; return 1; }
  [ -n "$b" ] || { echo "  未能从 update-dsh.sh 抽到 node-resolve-shared 块(标记漂移?)" >&2; return 1; }
  printf '%s' "$a" | grep -q 'dsh_resolve_node()' \
    || { echo "  install.sh 的块里没有 dsh_resolve_node()" >&2; return 1; }
  printf '%s' "$a" | grep -q 'dsh_node_path_is_session_scoped()' \
    || { echo "  install.sh 的块里没有 dsh_node_path_is_session_scoped()" >&2; return 1; }
  printf '%s' "$a" | grep -q 'dsh_resolve_node()' \
    && printf '%s' "$b" | grep -q 'dsh_node_path_is_session_scoped()' \
    || { echo "  update-dsh.sh 的块不完整" >&2; return 1; }
  local na nb
  na="$(printf '%s\n' "$a" | wc -l | tr -d ' ')"
  [ "$na" -ge 15 ] || { echo "  install.sh 的块只有 $na 行,抽取已失明" >&2; return 1; }

  if [ "$a" != "$b" ]; then
    echo "  两份 node-resolve-shared 块已漂移(必须逐字节一致):" >&2
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/    /' >&2
    return 1
  fi
}

@test "the shared block resolves shims without python3 and without readlink -f" {
  local block="$BATS_TEST_TMPDIR/block.sh"
  extract_block "$INSTALL" > "$block"
  [ -s "$block" ] || { echo "  抽取失败" >&2; return 1; }

  # 实现层面:块内不得出现 python3 依赖或 GNU 专有的 readlink -f。
  # 这是对**实现**的性质断言(不得依赖某能力),不是「用文本断言行为」——
  # 行为由下面两例真跑一遍来验。
  local bad
  bad="$(detect_bad_resolution "$block")"
  [ -z "$bad" ] || { echo "  块内仍有不可移植的解析方式:" >&2; printf '%s\n' "$bad" | sed 's/^/    /' >&2; return 1; }

  # 夹具:真实文件 <- 相对符号链接 <- 绝对符号链接(两级,覆盖相对/绝对两种跳法)
  local base="$BATS_TEST_TMPDIR/chain"
  mkdir -p "$base/real/bin" "$base/a/bin" "$base/b/bin"
  printf '#!/bin/sh\necho v22.0.0\n' > "$base/real/bin/node"
  chmod +x "$base/real/bin/node"
  ln -s ../../real/bin/node "$base/a/bin/node"
  ln -s "$base/a/bin/node" "$base/b/bin/node"
  # 期望值也要走 pwd -P:macOS 的 /var 是指向 /private/var 的符号链接,
  # mktemp -d 给出的路径与物理路径不同(直接比较会假失败)。
  local want
  want="$(cd "$base/real/bin" && pwd -P)/node"

  # (1) 常规 PATH 下解析
  local got
  got="$(bash -c 'source "$1"; dsh_resolve_node "$2"' _ "$block" "$base/b/bin/node")"
  [ "$got" = "$want" ] || { echo "  解析结果 [$got],期望 [$want]" >&2; return 1; }
  # 解析出来的路径必须真的可执行 —— 否则「解析成功」没有意义。
  [ -x "$got" ] || { echo "  解析结果不可执行:[$got]" >&2; return 1; }

  # (2) 行为验证「不依赖 python3」:把一个**必然失败**的 python3 桩放到 PATH 最前面,
  #     复刻 F3 的真实场景(macOS 12.3+ 不附带 python3)。若实现偷偷调用 python3,
  #     旧写法的 `|| echo "$CAND"` 会退回未解析路径 → 下面的断言必然失败。
  #     不用「收窄 PATH」的写法:那要求夹具自己挑出 readlink/dirname/basename 并 symlink,
  #     而这些命令在受限环境里可能本身就是代理 shim(实测本机 command -v readlink 指向
  #     一个需要完整环境的 broker),会让夹具自身失败 —— 测出的是夹具的问题而不是实现的。
  local stub="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 127\n' > "$stub/python3"
  chmod +x "$stub/python3"
  local got2
  got2="$(PATH="$stub:$PATH" bash -c 'source "$1"; dsh_resolve_node "$2"' _ "$block" "$base/b/bin/node")"
  [ "$got2" = "$want" ] \
    || { echo "  python3 不可用时解析结果 [$got2],期望 [$want](实现偷偷依赖了 python3?)" >&2; return 1; }

  # (3) 非符号链接路径必须原样解析(不得因为不是链接就失败)
  local got3
  got3="$(bash -c 'source "$1"; dsh_resolve_node "$2"' _ "$block" "$base/real/bin/node")"
  [ "$got3" = "$want" ] || { echo "  普通文件解析结果 [$got3],期望 [$want]" >&2; return 1; }
}

@test "session-scoped detection accepts fnm multishell and rejects stable shims" {
  local block="$BATS_TEST_TMPDIR/block2.sh"
  extract_block "$INSTALL" > "$block"
  [ -s "$block" ] || { echo "  抽取失败" >&2; return 1; }

  is_scoped() {
    bash -c 'source "$1"; if dsh_node_path_is_session_scoped "$2"; then echo yes; else echo no; fi' \
      _ "$block" "$1"
  }

  # 正控:fnm 的 multishell 目录**每个会话一份**,shell 退出即删 —— 必须识别出来。
  [ "$(is_scoped "/Users/x/.local/state/fnm_multishells/1197_1789215933663/bin/node")" = "yes" ] \
    || { echo "  未识别 fnm_multishells 会话级路径(这正是本门禁要防的缺陷)" >&2; return 1; }

  # 负控:这些 shim 的路径是**稳定**的,一并拒绝会误伤正常安装(误报同样是门禁缺陷)。
  local stable
  for stable in \
    "/Users/x/.volta/bin/node" \
    "/Users/x/.nvm/versions/node/v22.14.0/bin/node" \
    "/Users/x/.local/share/mise/shims/node" \
    "/opt/homebrew/bin/node" \
    "/usr/local/bin/node" \
    "/Users/x/.local/share/dsh-runtime/node/bin/node"
  do
    [ "$(is_scoped "$stable")" = "no" ] \
      || { echo "  稳定路径被误判为会话级:[$stable]" >&2; return 1; }
  done
}

@test "no product script resolves paths via python3 or readlink -f" {
  local probe="$BATS_TEST_TMPDIR/bad-probe.sh"
  # 反空转(正):检测器必须命中合成违规样本,否则正则写错会让本门禁永远通过。
  printf '%s\n' 'CAND="$(python3 -c '"'"'import os;print(os.path.realpath(x))'"'"')"' > "$probe"
  [ -n "$(detect_bad_resolution "$probe")" ] \
    || { echo "  门禁自检失败:未命中 python3 realpath 样本(正则已失明)" >&2; return 1; }
  printf '%s\n' 'p="$(readlink -f "$p")"' > "$probe"
  [ -n "$(detect_bad_resolution "$probe")" ] \
    || { echo "  门禁自检失败:未命中 readlink -f 样本" >&2; return 1; }
  # 反空转(反):合法写法不得误报,否则门禁会被「绕过式重写」而不是被遵守。
  printf '%s\n' 'n="$(readlink "$p")"' > "$probe"
  [ -z "$(detect_bad_resolution "$probe")" ] \
    || { echo "  门禁自检失败:普通 readlink 被误报" >&2; return 1; }

  # 扫描面限定在 scripts/*.sh(产品代码)。tests/auto-update-verify.sh 里还有一处同款
  # python3 realpath,那是**测试夹具构造**,缺 python3 时表现为测试报错(响亮),
  # 不会像产品路径那样静默产出一个坏配置 —— 刻意不纳入,写清楚而不是假装全覆盖。
  local f hits bad=0 scanned=0
  for f in "$SRC_DIR"/*.sh; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    hits="$(detect_bad_resolution "$f")"
    if [ -n "$hits" ]; then
      echo "  仍用不可移植方式解析路径: $f" >&2
      printf '%s\n' "$hits" | sed 's/^/    /' >&2
      bad=1
    fi
  done
  [ "$scanned" -ge 8 ] || { echo "  扫描面异常(只扫到 $scanned 个脚本,glob 漂移?)" >&2; return 1; }
  [ "$bad" -eq 0 ]
}
