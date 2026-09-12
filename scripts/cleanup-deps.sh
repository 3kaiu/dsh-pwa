#!/usr/bin/env bash
# dsh-pwa 依赖清理脚本 - 删除跨平台冗余文件
# 用法: bash cleanup-deps.sh [--dry-run] <node_modules 所在目录>
# 预期减少: ~34MB (16%)
#
# --dry-run(-n):只打印将被删除的路径,不做任何改动。
#   设计要点:选谁(谓词)只写一次,写在下面各段 find 里;执行由唯一的 del() 出口负责。
#   故 --dry-run 的输出与真实删除的**选中集合必然一致**,不会出现「dry-run 对、真删错」——
#   这正是 tests/unit/cleanup-deps.bats 能把它当门禁用(审计 C2)。
#
# 删除面分两类(审计 F6),dry-run 会逐行标注,好让 review 知道该看哪几条:
#   · 「确认安全」——平台白名单(node-pty 非 darwin 预编译)、精确包路径、白名单文档目录;
#   · 「按名字猜」——第 3 段(含 `*.md`)与第 4 段(`test/tests/examples/coverage` 等),
#     带 GUESS_LABEL。这一类是 S1 的同族风险:看起来像测试/文档 ≠ 是测试/文档
#     (yaml/doc/directives.js 是运行时代码,删掉后 dsh 直接起不来)。
#     require 探针只覆盖 sharp/node-pty 两个包,对「包在 test/ 里放运行时代码」是结构性盲区。
set -euo pipefail

DRY=0
case "${1:-}" in
  --dry-run|-n) DRY=1; shift ;;
esac

APP_DIR="${1:?错误: 需要提供 node_modules 路径作为参数}"
NM="$APP_DIR/node_modules"

if [ ! -d "$NM" ]; then
  echo "警告: $NM 不存在,跳过清理" >&2
  exit 0
fi

echo "开始清理跨平台冗余文件..."
# `|| true` 必须写在**命令替换内部**。脚本开头是 `set -euo pipefail`,而 `pipefail` 下
# `du` 失败会让整条赋值的退出码非零 → `set -e` 立即终止脚本,于是下一行的 `${BEFORE:-0}`
# **永不执行** —— 注释承诺的兜底其实是死代码(审计 F16,与 C1 同族:兜底写在了 `set -e`
# 够不着的地方)。判定「兜底是否有效」的唯一办法:问它所在的那条命令在失败时会不会先终止脚本。
BEFORE="$(du -sm "$NM" 2>/dev/null | awk '{print $1}' || true)"
BEFORE="${BEFORE:-0}"   # 真兜底:du 失败/目录瞬时消失时置 0,避免下方 $(( )) 空值语法报错退出

# 唯一的执行出口:从 stdin 读路径(每行一个),DRY=1 只打印,否则真删。
# 注意这里是**唯一**做删除的地方 —— 新增清理项时只加 find 谓词,不要另写 rm,
# 否则 dry-run 覆盖不到它(门禁会失效,而失效是静默的)。
#
# 可选参数 $1 = 风险标签。审计 F6:本脚本的删除面分两类 ——
#   · 「确认安全」:平台白名单(node-pty 非 darwin 预编译)、精确包路径、白名单文档目录;
#   · 「按名字猜」:第 3 段(含 `*.md`)与第 4 段(`test/tests/examples/coverage` 等)。
# 后一类是 S1 的同族风险:**看起来像测试/文档 ≠ 是测试/文档**(yaml/doc/directives.js 是
# 运行时代码,删掉后 dsh 直接起不来)。现有 require 探针只覆盖 sharp/node-pty 两个包,
# 对「某个包在 test/ 里放了运行时代码」是结构性盲区。
# 标签会打进 dry-run 的每一行,好让 review 的人**一眼知道该看哪几条**,而不是通读全部输出。
# (删掉实现只留注释仍会被门禁抓到:cleanup-deps.bats 断言的是选中集合,不是源码文本。)
del() {
  local label="${1:-}"
  if [ "$DRY" = 1 ]; then
    if [ -n "$label" ]; then
      sed "s|^|[dry-run] 将删除($label): |"
    else
      sed 's/^/[dry-run] 将删除: /'
    fi
  else
    while IFS= read -r p; do
      [ -n "$p" ] && rm -rf -- "$p"
    done
  fi
}

# 「按名字猜」的标签:同一份文案只用一处定义,免得两段漂移出不同说法。
GUESS_LABEL="按名字猜,可能是运行时代码,请复核"

# 1. node-pty: 删除 Win32/Linux 预编译二进制 (~23MB)
if [ -d "$NM/node-pty/prebuilds" ]; then
  echo "  清理 node-pty 非 macOS 平台二进制..."
  find "$NM/node-pty/prebuilds" -mindepth 1 -maxdepth 1 -type d \
    ! -name "darwin-*" -print 2>/dev/null | del || true
fi

# 2. @img/sharp: 删除 WASM 备用方案 (~9MB)
if [ -d "$NM/@img/sharp-wasm32" ]; then
  echo "  清理 sharp WASM 备用库..."
  printf '%s\n' "$NM/@img/sharp-wasm32" | del || true
fi

# 3-6. 合并清理: 单次遍历多条件删除 (优化 40-50% 执行时间)
echo "  清理 sourcemap/配置/文档文件..."
# 风险提示(审计 F6):本段与下一段是**按名字猜**,不是按「确认无用」判断。
#   · `*.md` 是「除 LICENSE*/README 之外全删」—— 若某包把运行时代码或必须的配置写成 .md,
#     会被静默删掉(没有报错,只有运行期才炸);
#   · 判定「这文件是文档」靠的是后缀,而 S1 的教训正是「看起来像文档 ≠ 是文档」。
# 已做的缓解:dry-run 给每一行打上 GUESS_LABEL,让 review 有明确着力点。
# 未做(留给后续):改成白名单包 + 逐包 require 冒烟 —— 那是把「猜」换成「测」,
# 但会引入「对哪些包跑 require」的新判断,不在本次审计范围内。
find "$NM" -type f \( \
  -name "*.map" \
  -o -name ".DS_Store" \
  -o -name "Thumbs.db" \
  -o -name ".eslintrc*" \
  -o -name ".prettierrc*" \
  -o -name "tsconfig.json" \
  -o -name "jest.config.*" \
  -o \( -name "*.md" ! -name "LICENSE*.md" ! -name "README.md" \) \
\) -print 2>/dev/null | del "$GUESS_LABEL" || true

# 4. 文档/测试/示例目录
echo "  清理测试/示例目录..."
# 同属「按名字猜」(审计 F6):`test`/`examples` 这些目录名在绝大多数包里确实是测试,
# 但只要有一个包在里面放了运行时代码,这里就会把它整棵删掉。dry-run 同样打标签。
find "$NM" -type d \
  \( -name test -o -name tests -o -name __tests__ \
  -o -name examples \
  -o -name coverage -o -name .nyc_output \) -print 2>/dev/null | del "$GUESS_LABEL" || true

# 注意: docs/doc 目录可能包含运行时代码(如 yaml/doc/directives.js)
# 只删除已知安全的文档目录（白名单机制）
for pkg_doc in "typescript/doc" "lodash/doc" "moment/doc"; do
  if [ -d "$NM/$pkg_doc" ]; then
    printf '%s\n' "$NM/$pkg_doc" | del || true
  fi
done

if [ "$DRY" = 1 ]; then
  echo "[dry-run] 结束:未做任何改动(去掉 --dry-run 才会真正删除)"
  exit 0
fi

AFTER="$(du -sm "$NM" 2>/dev/null | awk '{print $1}' || true)"
AFTER="${AFTER:-0}"
SAVED=$((BEFORE - AFTER))

echo "清理完成:"
echo "  清理前: ${BEFORE}MB"
echo "  清理后: ${AFTER}MB"
if [ "$BEFORE" -gt 0 ]; then
  # 百分比必须先算进变量,再拼进 echo。写成「双引号串内嵌 $( ) 、$( ) 内再用转义双引号」
  # 在 macOS 自带的 bash 3.2 下会解析错乱:内层 \" 破坏外层引号,echo 收到 2 个参数
  # (整行被打印两遍),awk 被调用 2 次且程序被截断(两次 syntax error),$( ) 结果为空。
  # 实测 CI 输出「节省空间: 62MB (%)   节省空间: 62MB (%)」;shellcheck 不报此形状,
  # 命令替换的非零退出也不会影响 echo 的退出码,故 set -e 同样拦不住(静默)。
  SAVED_PCT="$(awk "BEGIN {printf \"%.1f\", $SAVED*100/$BEFORE}")"
  echo "  节省空间: ${SAVED}MB (${SAVED_PCT}%)"
else
  echo "  节省空间: ${SAVED}MB"   # BEFORE=0 时不做百分比(除零)
fi
