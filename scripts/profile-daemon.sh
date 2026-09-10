#!/usr/bin/env bash
# dsh-pwa 守护进程性能分析工具
# 使用 macOS 内置工具进行零依赖性能分析
set -euo pipefail

# 精确匹配守护二进制路径,而非裸 "daemon"(裸词会误命中 docker daemon、mDNSResponder 等
# 任意含 daemon 的进程,拿到错误 PID 后所有 ps/heap/lsof 分析都指向无关进程)。
# 与 smoke-test.sh 同一模式:RT_HOME 默认 ~/.local/share/dsh-runtime。
RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
DAEMON_PID="$(pgrep -f "$RT_HOME/daemon" | head -1 || true)"
if [ -z "$DAEMON_PID" ]; then
  echo "❌ 守护进程未运行" >&2
  echo "提示: 运行 'curl -fsS http://127.0.0.1:3080/health' 触发 launchd socket activation 拉起守护进程" >&2
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
