#!/usr/bin/env bash
# dsh-pwa 依赖清理脚本 - 删除跨平台冗余文件
# 用法: bash cleanup-deps.sh <node_modules 路径>
# 预期减少: ~34MB (16%)
set -euo pipefail

APP_DIR="${1:?错误: 需要提供 node_modules 路径作为参数}"

if [ ! -d "$APP_DIR/node_modules" ]; then
  echo "警告: $APP_DIR/node_modules 不存在,跳过清理" >&2
  exit 0
fi

echo "开始清理跨平台冗余文件..."
BEFORE=$(du -sm "$APP_DIR/node_modules" 2>/dev/null | awk '{print $1}')
BEFORE="${BEFORE:-0}"   # du 失败/目录瞬时消失时兜底,避免下方 $(( )) 因空值语法报错退出

# 1. node-pty: 删除 Win32/Linux 预编译二进制 (~23MB)
if [ -d "$APP_DIR/node_modules/node-pty/prebuilds" ]; then
  echo "  清理 node-pty 非 macOS 平台二进制..."
  find "$APP_DIR/node_modules/node-pty/prebuilds" -mindepth 1 -maxdepth 1 -type d \
    ! -name "darwin-*" -exec rm -rf {} + 2>/dev/null || true
fi

# 2. @img/sharp: 删除 WASM 备用方案 (~9MB)
if [ -d "$APP_DIR/node_modules/@img/sharp-wasm32" ]; then
  echo "  清理 sharp WASM 备用库..."
  rm -rf "$APP_DIR/node_modules/@img/sharp-wasm32"
fi

# 3-6. 合并清理: 单次遍历多条件删除 (优化 40-50% 执行时间)
echo "  清理 sourcemap/配置/文档文件..."
find "$APP_DIR/node_modules" -type f \( \
  -name "*.map" \
  -o -name ".DS_Store" \
  -o -name "Thumbs.db" \
  -o -name ".eslintrc*" \
  -o -name ".prettierrc*" \
  -o -name "tsconfig.json" \
  -o -name "jest.config.*" \
  -o \( -name "*.md" ! -name "LICENSE*.md" ! -name "README.md" \) \
\) -delete 2>/dev/null || true

# 4. 文档/测试/示例目录
echo "  清理测试/示例目录..."
find "$APP_DIR/node_modules" -type d \
  \( -name test -o -name tests -o -name __tests__ \
  -o -name examples \
  -o -name coverage -o -name .nyc_output \) \
  -exec rm -rf {} + 2>/dev/null || true

# 注意: docs/doc 目录可能包含运行时代码(如 yaml/doc/directives.js)
# 只删除已知安全的文档目录（白名单机制）
for pkg_doc in "typescript/doc" "lodash/doc" "moment/doc"; do
  [ -d "$APP_DIR/node_modules/$pkg_doc" ] && rm -rf "$APP_DIR/node_modules/$pkg_doc" 2>/dev/null || true
done

AFTER=$(du -sm "$APP_DIR/node_modules" 2>/dev/null | awk '{print $1}')
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
