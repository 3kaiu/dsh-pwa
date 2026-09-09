#!/usr/bin/env bash
# dsh-pwa 守护进程性能分析工具
# 使用 macOS 内置工具进行零依赖性能分析
set -euo pipefail

DAEMON_PID=$(pgrep -f "daemon" | head -1 || echo "")
if [ -z "$DAEMON_PID" ]; then
  echo "❌ 守护进程未运行" >&2
  echo "提示: 运行 'launchctl kickstart -k gui/$(id -u)/com.dshpwa.daemon' 启动守护进程" >&2
  exit 1
fi

echo "==> 守护进程性能分析 (PID: $DAEMON_PID)"
echo ""

# 1. 内存占用
echo "1. 内存占用 (RSS/VSZ/进程信息):"
ps -p "$DAEMON_PID" -o pid,rss,vsz,%mem,%cpu,time,comm | head -2
echo ""

# 2. 堆分配详情
echo "2. 堆内存分配 (前 30 项):"
if command -v sudo >/dev/null 2>&1; then
  sudo heap "$DAEMON_PID" 2>/dev/null | head -30 || echo "  (需要 sudo 权限)"
else
  echo "  跳过 (无 sudo)"
fi
echo ""

# 3. 系统调用频率采样
echo "3. 系统调用频率 (10 秒采样):"
if command -v sudo >/dev/null 2>&1; then
  echo "  采样中..."
  timeout 10 sudo dtruss -p "$DAEMON_PID" -c 2>&1 | tail -20 || echo "  (采样超时或需要权限)"
else
  echo "  跳过 (无 sudo)"
fi
echo ""

# 4. 文件描述符
echo "4. 打开的文件描述符:"
lsof -p "$DAEMON_PID" 2>/dev/null | head -20 || echo "  (需要权限或 lsof 不可用)"
echo ""

# 5. 网络连接
echo "5. 网络连接:"
lsof -p "$DAEMON_PID" -i 2>/dev/null || echo "  (无活跃网络连接)"
echo ""

# 6. 虚拟内存统计
echo "6. 系统虚拟内存统计:"
vm_stat | head -10
echo ""

echo "==> 分析完成"
echo ""
echo "提示:"
echo "  - RSS 预期: ~1270KB (优化后)"
echo "  - 系统调用: ~2次/秒 (空闲时)"
echo "  - 文件描述符: <10 个"
