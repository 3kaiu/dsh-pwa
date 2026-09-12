#!/usr/bin/env bats
# dsh-pwa 安装脚本单元测试
# 依赖: bats-core (brew install bats-core)
# 注意:测试描述用 ASCII(bats 1.14 在 macOS 自带 bash 3.2 下对多字节描述
#       的测试名编码有缺陷,中文描述会报 "unknown test name" 且 0 测试被执行)

setup() {
  # 测试环境准备
  export TEST_RT_HOME="/tmp/dsh-pwa-test-$$"
  export TEST_RT_STATE="$TEST_RT_HOME/state"
  mkdir -p "$TEST_RT_HOME" "$TEST_RT_STATE"
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

teardown() {
  # 清理测试环境
  rm -rf "$TEST_RT_HOME"
}

@test "install.sh rejects invalid port (< 1024)" {
  run env DSH_RT_PORT=80 bash "$ROOT/scripts/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "端口无效" ]] || [[ "$output" =~ "1024-65535" ]]
}

@test "install.sh rejects invalid port (> 65535)" {
  run env DSH_RT_PORT=70000 bash "$ROOT/scripts/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "端口无效" ]] || [[ "$output" =~ "1024-65535" ]]
}

@test "daemon.c compiles with zero warnings" {
  run clang -O2 -Wall -Wextra -Werror \
    -arch arm64 -arch x86_64 \
    -o /tmp/daemon-test "$ROOT/src/daemon.c"
  ST="$status"
  # 产物即刻清理:这里用**固定路径**(非 mktemp),不删就会永久留一个 ~120KB 的二进制在 /tmp。
  # 两个同类用例(universal / size)都已有 rm -f,唯独此处漏了。先存 $status 再删,
  # 保证断言失败时也清理(断言放在 rm 之后会因 bats 中止而跳过清理)。
  rm -f /tmp/daemon-test
  [ "$ST" -eq 0 ]
}

@test "daemon binary is universal (arm64 + x86_64)" {
  clang -O2 -arch arm64 -arch x86_64 \
    -o /tmp/daemon-arch-test "$ROOT/src/daemon.c"
  run file /tmp/daemon-arch-test
  [[ "$output" =~ "universal binary" ]]
  [[ "$output" =~ "arm64" ]]
  [[ "$output" =~ "x86_64" ]]
  rm -f /tmp/daemon-arch-test
}

@test "daemon binary size within limit (<150KB)" {
  # 阈值与 tests/security-verification.sh 的 150000 字节保持一致;
  # universal 双架构 + 内嵌引导页的当前体积约 117KB(旧 90KB 断言已过期)
  clang -O2 -arch arm64 -arch x86_64 \
    -o /tmp/daemon-size-test "$ROOT/src/daemon.c"
  SIZE=$(stat -f%z /tmp/daemon-size-test 2>/dev/null || stat -c%s /tmp/daemon-size-test)
  SIZE_KB=$((SIZE / 1024))
  rm -f /tmp/daemon-size-test
  [ "$SIZE_KB" -lt 150 ]
}

@test "cleanup-deps.sh passes bash -n" {
  run bash -n "$ROOT/scripts/cleanup-deps.sh"
  [ "$status" -eq 0 ]
}

@test "update-dsh.sh passes bash -n" {
  run bash -n "$ROOT/scripts/update-dsh.sh"
  [ "$status" -eq 0 ]
}

@test "smoke-test.sh passes bash -n" {
  run bash -n "$ROOT/scripts/smoke-test.sh"
  [ "$status" -eq 0 ]
}

@test "all bats test names are ASCII-only (guard)" {
  # 守护用例:bats 1.14 在 macOS 自带 bash 3.2 下对多字节测试名有缺陷——含中文的 @test 名会
  # 报 "unknown test name" 且整个文件 0 用例被执行(静默假绿,CI 仍"通过")。扫描所有 .bats
  # 的 @test 名,出现任何非 ASCII 字节立即失败,避免测试套件被无声清空。
  bad=0
  for f in "$ROOT"/tests/unit/*.bats; do
    while IFS= read -r line; do
      case "$line" in
        @test*)
          if printf '%s' "$line" | LC_ALL=C grep -q '[^ -~]'; then
            echo "  非 ASCII 测试名(会导致 bats 静默 0 用例): $f: $line" >&2
            bad=1
          fi
          ;;
      esac
    done < "$f"
  done
  [ "$bad" -eq 0 ]
}

@test "every curl carries a timeout, and every loopback curl bypasses the proxy" {
  # 两条约定,同一根因家族:门禁必须覆盖它**声称**覆盖的东西,不能只覆盖一半。
  #  (1) 超时:无超时的 curl 是一颗定时炸弹——服务「已 bind 未 listen」时 macOS 直接丢弃 SYN
  #      (不回 RST),curl 会一直挂到作业级 timeout-minutes(30min),把真实缺陷掩盖成「卡住」;
  #      本次 CI 排查正是被这种「只看到卡住、看不到原因」拖慢的。规则:每一处 curl 都必须带
  #      --max-time / -m。
  #  (2) 代理:curl **默认不豁免回环**,会把 127.0.0.1 交给 http_proxy(实测 curl 8.7.1 打印
  #      "Uses proxy env variable http_proxy")。此时「守护已死」拿到的是代理的 502 而不是
  #      连接拒绝(000),断言与报错全部失真。规则:回环 curl 必须带 --noproxy,或本文件已
  #      全局 `unset ...proxy`(benchmark.sh 取后者:它只压本机,且 hyperfine 的命令字符串会
  #      再经 sh -c 解析,未加引号的 * 有被 glob 展开的风险,故显式清代理更稳)。
  # 已知盲区(刻意保留,写清楚而不是假装覆盖):URL 写成变量时无法静态判定是否回环
  #   (如 benchmark.sh 的 "$ENDPOINT"),故不纳入代理检查。这与超时检查「不按 127.0.0.1
  #   过滤」是同一教训的两面:能静态判定的必须判,判不了的必须写明。
  # 扫描范围与形状处理(合并反斜杠续行、只认「像调用」的 curl)见下。
  offenders="$(
    for f in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh "$ROOT"/tests/lib/*.sh \
             "$ROOT"/.github/workflows/*.yml; do
      awk -v F="$f" '
        # 第一遍预扫描:本文件是否全局清掉代理环境变量(见上文 (2) 的 benchmark.sh 分支)。
        FNR == NR {
          if ($0 ~ /^[ \t]*unset[ \t]/ && $0 ~ /[Pp][Rr][Oo][Xx][Yy]/) unset_proxy = 1
          next
        }
        # 只认「像调用」的 curl(curl 后紧跟非字母数字字符,或裸 http URL),散文里提到 curl 不误报。
        function looks_like_call(t,   c) {
          if (!match(t, /curl[ \t]+/)) return 0
          # 刻意不用字符类 [^-A-Za-z0-9_]:BWK awk 会把 -A 解析成范围,使 "-" 落进否定类,
          # 于是所有 `curl -flag` 全被漏检(实测踩过)。改为取首字符逐个判断。
          c = substr(t, RSTART + RLENGTH, 1)
          if (c ~ /[A-Za-z0-9_]/ && c != "h") return 0
          return 1
        }
        # echo/printf 里的 curl 是给人看的提示文本,不是调用(benchmark.sh:26,44-46、
        # profile-daemon.sh:13 都是这种,含 127.0.0.1 字面量,不过滤就会误报);
        # 但 `echo "$(curl ...)"` 里的 curl 是真调用,不能一并放过。
        function is_prose(t) {
          return (t ~ /^(echo|printf)[ \t]/ && t !~ /\$\(curl/)
        }
        function check(l, ln,   t) {
          t = l
          sub(/^[ \t]+/, "", t)
          if (substr(t, 1, 1) == "#") return
          if (!looks_like_call(t)) return
          if (!(t ~ /--max-time[= ][0-9]/ || t ~ /-m [0-9]/))
            printf "%s:%d: [无超时] %s\n", F, ln, t
          if (!unset_proxy && !is_prose(t) \
              && t ~ /127\.0\.0\.1|localhost|\[::1\]/ && t !~ /--noproxy/)
            printf "%s:%d: [回环未绕代理] %s\n", F, ln, t
        }
        # awk 先合并反斜杠续行,否则「curl 在一行、URL 在下一行」会漏检(第一版就漏了)。
        { l = (buf == "" ? $0 : buf " " $0); buf = "" }
        l ~ /\\$/ { sub(/\\$/, "", l); buf = l; next }
        { check(l, FNR) }
        END { if (buf != "") check(buf, FNR) }
      ' "$f" "$f"
    done
  )"
  if [ -n "$offenders" ]; then
    printf '  curl 约定违规:\n%s\n' "$offenders" >&2
  fi
  [ -z "$offenders" ]
}

@test "every workflow job declares timeout-minutes" {
  # 不声明 timeout-minutes 的 job 会回落到 GitHub 默认 **360min**:任何一步卡住都会白烧
  # 6 小时 runner。本仓库既有约定是显式声明(build-and-test 30 / static-analysis 15 /
  # performance 20 / binary-analysis 10 / release 25),新增 job 必须跟上。
  # 只认 4 空格缩进的 job 级声明(step 级是 8 空格)——否则某个 step 上的 timeout
  # 会把「job 缺声明」蒙混过去。injobs 只在 jobs: 之后计数,避免把 on: 下的
  # push:/pull_request: 误当成 job。
  bad=0
  for f in "$ROOT"/.github/workflows/*.yml; do
    awk -v F="$f" '
      /^jobs:[ \t]*$/ { injobs = 1; next }
      /^[^ \t]/ { injobs = 0 }
      injobs {
        if ($0 ~ /^  [A-Za-z_][A-Za-z0-9_-]*:[ \t]*$/) { jobs++; names = names " " $1 }
        else if ($0 ~ /^    timeout-minutes:[ \t]*[0-9]+[ \t]*$/) tmo++
      }
      END {
        if (jobs != tmo) {
          printf "  %s: job 数=%d 但 job 级 timeout-minutes 数=%d(应覆盖:%s)\n", F, jobs, tmo, names
          exit 1
        }
      }
    ' "$f" || bad=1
  done
  [ "$bad" -eq 0 ]
}

# ---- A5:依赖树的完整性锚点 ----
# 背景:仓库不跟踪任何 lockfile,发行包内的 pnpm-lock.yaml 由 release.yml 现场生成。
# 旧实现只是「有就拷过来」却从不冻结,于是 lock 与 package.json 一旦不一致,pnpm 会
# **静默重新解析**整棵树 —— 锚点形同虚设;源码树安装更是每次都现场解析且毫无提示。

# 取 printf 的格式串(单引号内到 \n' 为止),只认含 dsh-runtime-app 的那一条。
extract_manifest_fmt() {
  awk '
    {
      i = index($0, "printf \047")
      if (i == 0) next
      s = substr($0, i + 8)
      if (index(s, "dsh-runtime-app") == 0) next
      j = index(s, "\\n\047")
      if (j == 0) next
      print substr(s, 1, j - 1)
      exit
    }
  ' "$1"
}

@test "install.sh freezes the shipped lockfile and warns when it is absent" {
  grep -q 'LOCK_ARG="--frozen-lockfile"' "$ROOT/scripts/install.sh" \
    || { echo "install.sh 未在锁存在时启用 --frozen-lockfile" >&2; return 1; }
  grep -q '未找到 pnpm-lock.yaml' "$ROOT/scripts/install.sh" \
    || { echo "install.sh 缺锁时未显式告警(静默现场解析)" >&2; return 1; }
  # 反空转:参数必须真的接到 pnpm 调用行上,不能只是定义完就没人用
  grep -q '\$NPM_EXTRA --prefer-offline' "$ROOT/scripts/install.sh" \
    || { echo "NPM_EXTRA/LOCK_ARG 未接到 pnpm 调用上(定义后无人使用)" >&2; return 1; }
}

@test "release.yml and install.sh write byte-identical app manifests" {
  # install.sh 现在带 --frozen-lockfile 安装,而那份 lock 是 release.yml 用**它自己的**
  # package.json 生成的。两者任何一个字段漂移,冻结校验就会在用户机器上失败 ——
  # 而「同一份字符串写两遍」正是本项目反复踩到的漂移源(README 计数、审计行号)。
  local a b
  a="$(extract_manifest_fmt "$ROOT/scripts/install.sh")"
  b="$(extract_manifest_fmt "$ROOT/.github/workflows/release.yml")"
  [ -n "$a" ] || { echo "未能从 install.sh 提取 app manifest(锚点漂移?)" >&2; return 1; }
  [ -n "$b" ] || { echo "未能从 release.yml 提取 app manifest(锚点漂移?)" >&2; return 1; }
  if [ "$a" != "$b" ]; then
    echo "app manifest 漂移:" >&2
    echo "  install.sh : $a" >&2
    echo "  release.yml: $b" >&2
    return 1
  fi
}

# —— 文档防漂移 ——
# 扫描范围刻意分成两类(写清楚,而不是假装全覆盖):
#  · 活文档(描述**当前**行为,数字会漂移):README.md、CHANGELOG.md、
#    docs/TOOLS_INTEGRATION.md、docs/AUTO_UPDATE_IMPLEMENTATION.md
#  · 历史快照(数字描述**当时**状态,改动等于篡改记录):docs/ADVERSARIAL_AUDIT_*.md 的
#    「29 项测试」、docs/DEEP_AUDIT_2026-09-11.md 的「6 个测试文件」、
#    docs/SMOKE_REVIEW_2026-09-12.md、docs/P0_P3_FIXES_IMPLEMENTATION.md(修复实施记录)。
#    将来若要合并这些快照(roadmap 项),合并稿应带明确日期并同样不写数字。
# 背景:README 曾手写「33 项断言 / 9+30=39 项」,而实测是 security 33、unit 68 ——
#   数字一旦手写就没人负责更新。数量必须以**运行器输出**为准:
#   `bats -c tests/unit/*.bats` 只统计不执行,且与 bats 实际执行口径一致;
#   静态 `grep -c '@test'` 会把注释里的 @test 也算进去(实测 16 vs 13),不可用。
detect_doc_counts() {
  # $1 = 待扫描文件;输出「数字+量词」的违规行(带行号)。
  # 规则是**一刀切**的:活文档里不出现「数字+项/个/条/款」,不要求同行出现测试关键词。
  #   原因:两段式(先筛数字+量词、再筛 bats/测试 等关键词)有盲区 —— 把数量单独写成一行
  #   (如「共 39 项测试」)就漏了,而「漏掉的漂移」正是本门禁要消灭的东西。
  #   实测四个活文档当前 0 处命中,故一刀切零误报;代价只是将来写数量时改用命令引用。
  # 用 -E 的多字节字面量交替而非方括号类 [项个条款]:后者在 C locale 下退化成逐字节匹配,
  #   会命中任何含相同字节的汉字(假阳性);交替是逐字节序列,与 locale 无关。
  # 已知盲区(刻意保留,写清楚而不是假装覆盖):只认阿拉伯数字,中文数字(如「三十九项」)
  #   不匹配。把 [一二三…十] 纳入会让「一个」「两个」这类日常表述大量误报,得不偿失;
  #   而测试数量在实践中总是写阿拉伯数字,故本门禁对**实际**漂移路径有效。
  grep -nE '[0-9]+ *(项|个|条|款)' "$1" 2>/dev/null || true
}

@test "living docs state no hand-written counts (drift guard)" {
  # 合成样本落在 bats 自己的临时目录里(BATS_TEST_TMPDIR 由 bats 回收),
  #   避免像本项目反复踩到的那样在 /tmp 留下孤儿文件。
  local probe="$BATS_TEST_TMPDIR/doc-probe.md"
  local f hits bad=0

  # 反空转(正):检测器必须命中合成违规样本。否则正则写错(本项目已多次踩到「门禁自身
  #   失明却恒绿」——如 BSD grep 的 \| 被当字面量、bracket 类漏掉 -)会让本门禁永远通过。
  printf '%s\n' 'bats tests/unit/   # 单元测试:安装校验(9 项)+ 守护黑盒用例(30 项),共 39 项' > "$probe"
  if [ -z "$(detect_doc_counts "$probe")" ]; then
    echo "门禁自检失败:检测器未命中合成违规样本(正则已失明)" >&2
    return 1
  fi
  # 反空转(正·盲区):数量单独成行时同样必须命中 —— 这条专门守住上面注释里说的两段式盲区。
  printf '%s\n' '当前单元测试共 39 项。' > "$probe"
  if [ -z "$(detect_doc_counts "$probe")" ]; then
    echo "门禁自检失败:单独成行的数量未被命中(两段式盲区复现)" >&2
    return 1
  fi
  # 反空转(反):合法内容不得误报 —— 否则门禁会被「绕过式重写」而不是被遵守。
  printf '%s\n' 'bash scripts/smoke-test.sh   # 端到端冒烟(无数字)' > "$probe"
  if [ -n "$(detect_doc_counts "$probe")" ]; then
    echo "门禁自检失败:合法行被误报" >&2
    return 1
  fi

  for f in "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/docs/TOOLS_INTEGRATION.md" \
           "$ROOT/docs/AUTO_UPDATE_IMPLEMENTATION.md"; do
    [ -f "$f" ] || { echo "活文档缺失(锚点漂移?): $f" >&2; return 1; }
    hits="$(detect_doc_counts "$f")"
    if [ -n "$hits" ]; then
      echo "活文档出现手写数量(必然漂移,请改为引用运行器输出):" >&2
      echo "  $f" >&2
      printf '%s\n' "$hits" | sed 's/^/    /' >&2
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}
