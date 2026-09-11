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
