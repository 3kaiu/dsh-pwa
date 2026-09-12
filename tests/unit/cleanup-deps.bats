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

@test "cleanup-deps dry-run labels the guess-based deletions and only those" {
  # 审计 F6:第 3、4 段是按**名字**猜(含 `*.md`、`test/` 等),而 S1 的教训是
  # 「看起来像文档 ≠ 是文档」。缓解办法是让 dry-run **逐行标注**风险,好让 review 有
  # 明确着力点。这里双向断言:猜出来的必须带标签,确认安全的必须不带 ——
  # 只测「带了标签」会漏掉「给所有条目都贴标签」(那就等于没标注)。
  local F="$BATS_TEST_TMPDIR/label"
  build_fixture "$F"
  run bash "$ROOT/scripts/cleanup-deps.sh" --dry-run "$F"
  [ "$status" -eq 0 ] || fail "dry-run 退出码 $status: $output"

  # 反空转:标签文案必须真实存在于输出里,否则下面两条会因「找不到」而双双通过。
  printf '%s' "$output" | grep -q '按名字猜' \
    || fail "dry-run 未标注任何『按名字猜』的风险条目(标签丢了?)"

  local line
  # 猜出来的(文件后缀 / 目录名)→ **每一行**都必须带标签。
  for p in "pkg/notes.md" "pkg/test" "pkg/examples" "pkg/coverage"; do
    line="$(printf '%s\n' "$output" | grep -F "$p")"
    [ -n "$line" ] || fail "dry-run 漏掉应删项: $p"
    if printf '%s\n' "$line" | grep -v '按名字猜' | grep -q .; then
      fail "按名字猜的条目未标注风险: $(printf '%s\n' "$line" | grep -v '按名字猜')"
    fi
  done
  # 确认安全的(平台白名单 / 精确包路径)→ 必须**存在**不带标签的行。
  # 注意不能用 `head -1` 抽单行:同一路径可能被多段同时选中(如 typescript/doc/d.md
  # 既被 `*.md` 规则命中、又被白名单文档目录命中),那时标签按段而异。
  for p in "node-pty/prebuilds/win32-x64" "@img/sharp-wasm32" "typescript/doc"; do
    line="$(printf '%s\n' "$output" | grep -F "$p")"
    [ -n "$line" ] || fail "dry-run 漏掉应删项: $p"
    if ! printf '%s\n' "$line" | grep -qv '按名字猜'; then
      fail "确认安全的条目被误标为『按名字猜』(标签失去区分力): $line"
    fi
  done
}
