#!/usr/bin/env bats
# dsh-pwa 安装脚本单元测试
# 依赖: bats-core (brew install bats-core)

setup() {
  # 测试环境准备
  export TEST_RT_HOME="/tmp/dsh-pwa-test-$$"
  export TEST_RT_STATE="$TEST_RT_HOME/state"
  mkdir -p "$TEST_RT_HOME" "$TEST_RT_STATE"
}

teardown() {
  # 清理测试环境
  rm -rf "$TEST_RT_HOME"
}

@test "install.sh 拒绝无效端口 (< 1024)" {
  run bash -c "DSH_RT_PORT=80 bash scripts/install.sh 2>&1 | head -5"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "端口无效" ]] || [[ "$output" =~ "1024-65535" ]]
}

@test "install.sh 拒绝无效端口 (> 65535)" {
  run bash -c "DSH_RT_PORT=70000 bash scripts/install.sh 2>&1 | head -5"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "端口无效" ]] || [[ "$output" =~ "1024-65535" ]]
}

@test "daemon.c 编译成功 (零警告)" {
  run clang -O2 -Wall -Wextra -Werror \
    -arch arm64 -arch x86_64 \
    -o /tmp/daemon-test src/daemon.c
  [ "$status" -eq 0 ]
}

@test "daemon 二进制是 universal binary" {
  clang -O2 -arch arm64 -arch x86_64 \
    -o /tmp/daemon-arch-test src/daemon.c
  run file /tmp/daemon-arch-test
  [[ "$output" =~ "universal binary" ]]
  [[ "$output" =~ "arm64" ]]
  [[ "$output" =~ "x86_64" ]]
  rm -f /tmp/daemon-arch-test
}

@test "daemon 二进制体积在合理范围 (<90KB)" {
  clang -O2 -arch arm64 -arch x86_64 \
    -o /tmp/daemon-size-test src/daemon.c
  SIZE=$(stat -f%z /tmp/daemon-size-test 2>/dev/null || stat -c%s /tmp/daemon-size-test)
  SIZE_KB=$((SIZE / 1024))
  rm -f /tmp/daemon-size-test
  [ "$SIZE_KB" -lt 90 ]
}

@test "cleanup-deps.sh 语法正确" {
  run bash -n scripts/cleanup-deps.sh
  [ "$status" -eq 0 ]
}

@test "update-dsh.sh 语法正确" {
  run bash -n scripts/update-dsh.sh
  [ "$status" -eq 0 ]
}

@test "smoke-test.sh 语法正确" {
  run bash -n scripts/smoke-test.sh
  [ "$status" -eq 0 ]
}
