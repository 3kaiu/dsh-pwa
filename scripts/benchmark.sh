#!/usr/bin/env bash
# dsh-pwa 性能基准测试工具
# 依赖: hyperfine (brew install hyperfine)
set -euo pipefail

# 本脚本只压测本机守护,不做任何外网访问:直接清掉代理环境变量。
# curl 默认会把 127.0.0.1 的请求交给 http_proxy(实测 curl 8.7.1 打印
# "Uses proxy env variable http_proxy"),此时「守护已死」拿到的是代理的 502 而不是连接拒绝;
# 清掉代理同时也免去在 hyperfine 命令字符串里转义 --noproxy '*' 的麻烦(该字符串会再经
# sh -c 解析,未加引号的 * 有被 glob 展开的风险)。
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY

PORT="${DSH_RT_PORT:-3080}"
ENDPOINT="http://127.0.0.1:$PORT/health"

# 检查 hyperfine 是否安装
if ! command -v hyperfine >/dev/null 2>&1; then
  echo "❌ hyperfine 未安装" >&2
  echo "安装: brew install hyperfine" >&2
  exit 1
fi

# 检查守护进程是否运行(带超时:守护「已 bind 未 listen」时 macOS 丢弃 SYN,无超时会挂死)
if ! curl -fsS --max-time 5 "$ENDPOINT" >/dev/null 2>&1; then
  echo "❌ 守护进程未响应 ($ENDPOINT)" >&2
  echo "提示: 运行 'curl -fsS --max-time 5 http://127.0.0.1:$PORT/health' 触发 launchd socket activation" >&2
  exit 1
fi

echo "==> dsh-pwa 性能基准测试"
echo ""

# 1. /health 端点响应时间
echo "1. /health 端点响应延迟:"
hyperfine --warmup 5 --runs 20 \
  --export-markdown /tmp/benchmark-health.md \
  "curl -fsS --max-time 5 $ENDPOINT" 2>/dev/null
echo ""

# 2. 冷启动延迟 (停止 -> 唤醒)
echo "2. 冷启动延迟 (stop -> wake):"
echo "  (需真实 dsh 且会干扰在用会话，故仅给出手动步骤)"
echo "  手动测试:"
echo "    curl -X POST --max-time 5 -H 'Origin: http://127.0.0.1:$PORT' http://127.0.0.1:$PORT/stop"
echo "    time curl -fsS --max-time 10 http://127.0.0.1:$PORT/    # 触发自动唤醒,计时到引导页返回"
echo "    # dsh 就绪耗时: until curl -fsS --max-time 2 http://127.0.0.1:$PORT/health | grep -q '\"dsh\":true'; do sleep 0.2; done"
echo ""

# 3. 并发性能
echo "3. 并发连接测试 (10 并发):"
hyperfine --warmup 2 --runs 5 \
  --export-markdown /tmp/benchmark-concurrent.md \
  "seq 1 10 | xargs -P10 -I{} curl -fsS --max-time 5 $ENDPOINT >/dev/null" 2>/dev/null
echo ""

# 4. 基准报告
echo "==> 基准测试完成"
echo ""
echo "生成的报告:"
echo "  - /tmp/benchmark-health.md (健康检查延迟)"
echo "  - /tmp/benchmark-concurrent.md (并发性能)"
echo ""
echo "预期基准:"
echo "  - /health 响应: <10ms (中位数)"
echo "  - 冷启动: <100ms (优化后)"
echo "  - 并发 10 连接: <50ms"
