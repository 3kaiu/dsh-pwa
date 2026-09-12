#!/usr/bin/env bats
# cleanup-deps.sh 的「删除面」门禁(审计 C2)
#
# 背景:该脚本在 install.sh 与 update-dsh.sh 两条路径上**真删文件**,而此前唯一的把关是
# `bash -n`(只查语法)—— 没有任何用例覆盖「它到底删了什么」。审计 C2 指出删除面远大于探针
# 覆盖。这里用合成 fixture 把删除面**钉死**:该删的必须消失,不该删的必须存活。
#
# 为什么 dry-run 与真跑各测一遍:两者共用同一段 find 谓词(见脚本里的 del),故 dry-run 的
# 选中集合能代表真实删除;但「选中」与「真的删掉了」仍是两件事,故真跑单独断言一次。

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

fail() { echo "$*" >&2; return 1; }

# 构造 fixture:同时放入「该删」与「必须存活」两类,避免只测单向导致误删无感。
build_fixture() {
  local nm="$1/node_modules"
  mkdir -p "$nm/pkg/test" "$nm/pkg/coverage" "$nm/pkg/examples" \
           "$nm/node-pty/prebuilds/darwin-arm64" "$nm/node-pty/prebuilds/win32-x64" \
           "$nm/@img/sharp-wasm32" "$nm/@img/sharp-darwin-arm64" "$nm/typescript/doc"
  # —— 该删 ——
  printf 'x' > "$nm/pkg/a.js.map"
  printf 'x' > "$nm/.DS_Store"
  printf 'x' > "$nm/pkg/tsconfig.json"
  printf 'x' > "$nm/pkg/notes.md"
  printf 'x' > "$nm/pkg/test/t.js"
  printf 'x' > "$nm/pkg/coverage/c.json"
  printf 'x' > "$nm/pkg/examples/e.js"
  printf 'x' > "$nm/node-pty/prebuilds/win32-x64/pty.node"
  printf 'x' > "$nm/@img/sharp-wasm32/index.js"
  printf 'x' > "$nm/typescript/doc/d.md"
  # —— 必须存活 ——
  printf 'x' > "$nm/pkg/index.js"
  printf 'x' > "$nm/pkg/package.json"
  printf 'x' > "$nm/pkg/README.md"
  printf 'x' > "$nm/pkg/LICENSE.md"
  printf 'x' > "$nm/node-pty/prebuilds/darwin-arm64/pty.node"
  printf 'x' > "$nm/@img/sharp-darwin-arm64/index.js"
}

# 被脚本**直接选中**的路径(应出现在 dry-run 输出里)。注意目录被选中 ≠ 其中的文件被单独选中。
SELECTED=(
  "pkg/a.js.map"
  ".DS_Store"
  "pkg/tsconfig.json"
  "pkg/notes.md"
  "pkg/test"
  "pkg/coverage"
  "pkg/examples"
  "node-pty/prebuilds/win32-x64"
  "@img/sharp-wasm32"
  "typescript/doc"
)
# 必须**存活**的路径:既不能被选中,也不能在真跑后消失。
KEPT=(
  "pkg/index.js"
  "pkg/package.json"
  "pkg/README.md"
  "pkg/LICENSE.md"
  "node-pty/prebuilds/darwin-arm64/pty.node"
  "@img/sharp-darwin-arm64/index.js"
)
# 真跑之后必须**不存在**的路径(含被删目录内部的文件)。
GONE=(
  "pkg/a.js.map"
  ".DS_Store"
  "pkg/tsconfig.json"
  "pkg/notes.md"
  "pkg/test/t.js"
  "pkg/coverage/c.json"
  "pkg/examples/e.js"
  "node-pty/prebuilds/win32-x64/pty.node"
  "@img/sharp-wasm32/index.js"
  "typescript/doc/d.md"
)

@test "cleanup-deps dry-run selects exactly the intended surface" {
  local F="$BATS_TEST_TMPDIR/dry" p
  build_fixture "$F"
  run bash "$ROOT/scripts/cleanup-deps.sh" --dry-run "$F"
  [ "$status" -eq 0 ] || fail "dry-run 退出码 $status: $output"

  # 反空转(正):必须真的选中了东西。谓词若整段写错,输出为空,下面的「该删」断言会全绿。
  printf '%s' "$output" | grep -q '将删除' || fail "dry-run 未选中任何路径(谓词或 fixture 有问题)"

  for p in "${SELECTED[@]}"; do
    printf '%s' "$output" | grep -qF "$p" || fail "dry-run 漏掉了应删项: $p"
  done
  for p in "${KEPT[@]}"; do
    printf '%s' "$output" | grep -qF "$p" && fail "dry-run 选中了不该删的: $p"
  done
  # dry-run 不得触碰文件系统
  [ -e "$F/node_modules/pkg/a.js.map" ] || fail "dry-run 竟然删了文件"
}

@test "cleanup-deps real run deletes the doomed set and spares the rest" {
  local F="$BATS_TEST_TMPDIR/real" p
  build_fixture "$F"
  run bash "$ROOT/scripts/cleanup-deps.sh" "$F"
  [ "$status" -eq 0 ] || fail "退出码 $status: $output"

  for p in "${GONE[@]}"; do
    [ -e "$F/node_modules/$p" ] && fail "应删未删: $p"
  done
  for p in "${KEPT[@]}"; do
    [ -e "$F/node_modules/$p" ] || fail "误删(必须存活): $p"
  done
}

@test "cleanup-deps is a no-op on a tree with nothing to clean" {
  # 反空转(反):无可删项时不得报告删除了任何东西 —— 否则上一条「该删的没了」可能只是
  # 因为它压根不存在,而不是谓词正确。
  local F="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$F/node_modules/pkg"
  printf 'x' > "$F/node_modules/pkg/index.js"
  run bash "$ROOT/scripts/cleanup-deps.sh" --dry-run "$F"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '将删除' && fail "空树上 dry-run 报告了删除项"
  [ -e "$F/node_modules/pkg/index.js" ] || fail "空树上的 dry-run 动了文件"
  true
}

@test "cleanup-deps exits 0 when node_modules is absent" {
  local F="$BATS_TEST_TMPDIR/nonm"
  mkdir -p "$F"
  run bash "$ROOT/scripts/cleanup-deps.sh" "$F"
  [ "$status" -eq 0 ] || fail "缺 node_modules 时应静默跳过,实际退出码 $status"
  [[ "$output" == *"不存在"* ]] || fail "缺 node_modules 时未给出提示: $output"
}
