#!/usr/bin/env bash
# dsh-pwa 二进制体积分析工具
# 使用 macOS 内置工具分析二进制结构
set -euo pipefail

DAEMON="${1:-$HOME/.local/share/dsh-runtime/daemon}"

if [ ! -f "$DAEMON" ]; then
  echo "❌ 二进制文件不存在: $DAEMON" >&2
  echo "提示: 指定路径如 'bash $0 /path/to/daemon'" >&2
  exit 1
fi

echo "==> 二进制分析: $DAEMON"
echo ""

# 1. 基本信息
echo "1. 文件信息:"
ls -lh "$DAEMON" | awk '{print "  大小: " $5 "\n  修改时间: " $6 " " $7 " " $8}'
file "$DAEMON" | sed 's/^/  /'
echo ""

# 2. 段大小分析
echo "2. 段大小分析 (Mach-O segments):"
size -m "$DAEMON" | head -10
echo ""

# 3. 架构验证
echo "3. 架构信息:"
lipo -info "$DAEMON" 2>/dev/null || echo "  (单一架构或 lipo 不可用)"
echo ""

# 4. 依赖库
echo "4. 链接的动态库:"
otool -L "$DAEMON" | sed 's/^/  /'
echo ""

# 5. 导出符号数量
echo "5. 导出符号统计:"
SYMBOLS=$(nm -g "$DAEMON" 2>/dev/null | wc -l | tr -d ' ')
echo "  导出符号数量: $SYMBOLS"
if [ "$SYMBOLS" -gt 100 ]; then
  echo "  ⚠️  警告: 符号数量较多，考虑使用 strip -x 优化"
fi
echo ""

# 6. 代码签名验证
echo "6. 代码签名状态:"
codesign -dv "$DAEMON" 2>&1 | grep -E "(Identifier|Authority|Signature)" | sed 's/^/  /' || echo "  未签名"
echo ""

# 7. 体积对比基准
echo "7. 体积基准对比:"
SIZE_BYTES=$(stat -f%z "$DAEMON" 2>/dev/null || stat -c%s "$DAEMON" 2>/dev/null)
SIZE_KB=$((SIZE_BYTES / 1024))
echo "  当前: ${SIZE_KB} KB"
echo "  预期: 100-150 KB (universal 双架构,含内嵌引导页)"
if [ "$SIZE_KB" -gt 150 ]; then
  echo "  ⚠️  警告: 二进制膨胀 (>150KB)，检查是否引入了新依赖"
else
  echo "  ✓ 正常范围"
fi
echo ""

echo "==> 分析完成"
