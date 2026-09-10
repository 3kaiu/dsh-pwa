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
  [ "$status" -eq 0 ]
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

@test "every loopback curl in CI-executed shell scripts carries a timeout" {
  # 回环 curl 必须带 --max-time / -m:守护「已 bind 未 listen」时 macOS 直接丢弃 SYN(不回 RST),
  # 无超时的 curl 会一直挂到作业级 timeout-minutes(30min),把真实缺陷掩盖成「卡住」——
  # 本次 CI 排查正是被这种「只看到卡住、看不到原因」拖慢的。
  # awk 先合并反斜杠续行,避免「curl 在一行、URL 在下一行」时漏检。
  # 命中 127.0.0.1 与 localhost(daemon 的 host_ok/origin_ok 两者都放行,将来可能有人写 localhost)。
  # 范围仅 shell 脚本;bats 用例不纳入:其 curl 都在 daemon_wait_health(自带 --max-time 2)
  # 确认守护已监听之后,且守护已死时是连接拒绝(快速失败)而非挂起。
  offenders="$(
    for f in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh "$ROOT"/tests/lib/*.sh; do
      awk -v F="$f" '
        function bad(l,   t) {
          t = l; sub(/^[ \t]+/, "", t)
          if (substr(t, 1, 1) == "#") return 0
          if (t !~ /curl/) return 0
          if (t !~ /127\.0\.0\.1/ && t !~ /localhost/) return 0
          if (t ~ /--max-time[= ][0-9]/ || t ~ /-m [0-9]/) return 0
          return 1
        }
        { l = (buf == "" ? $0 : buf " " $0); buf = "" }
        l ~ /\\$/ { sub(/\\$/, "", l); buf = l; next }
        bad(l) { printf "%s:%d: %s\n", F, FNR, l }
        END { if (buf != "" && bad(buf)) printf "%s: %s\n", F, buf }
      ' "$f"
    done
  )"
  if [ -n "$offenders" ]; then
    printf '  无超时的回环 curl(请补 --max-time):\n%s\n' "$offenders" >&2
  fi
  [ -z "$offenders" ]
}
