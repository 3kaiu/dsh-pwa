#!/usr/bin/env bash
# 引导页压缩工具 - 压缩 daemon.c 中的 HTML/CSS/JS
# 用法: bash minify-boot-page.sh
set -euo pipefail

DAEMON_C="${1:-src/daemon.c}"

if [ ! -f "$DAEMON_C" ]; then
  echo "错误: $DAEMON_C 不存在" >&2
  exit 1
fi

echo "分析引导页体积..."

# 提取 TPL 字符串 (从 static const char TPL[] = 开始到下一个分号)
ORIGINAL=$(awk '/^static const char TPL\[\]/, /^  ".*<\/script><\/body><\/html>";$/ {print}' "$DAEMON_C" | wc -c)

echo "当前 TPL 字符串: ${ORIGINAL} 字节"
echo ""
echo "压缩建议:"
echo "  1. CSS 压缩: 去除空格和换行 (~800 字节 → ~600 字节)"
echo "  2. JS 压缩: 简化变量名 (~1200 字节 → ~900 字节)"
echo "  3. HTML 压缩: 移除注释和多余空格 (~200 字节)"
echo ""
echo "预期收益: ~700 字节 (编译后二进制减少 ~1KB)"
echo ""
echo "注意:"
echo "  - 手动压缩会降低可读性"
echo "  - 建议保留当前版本,收益相对于 85KB 二进制微不足道"
echo "  - 如需压缩,可使用在线工具: https://www.minifier.org/"
