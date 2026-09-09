#!/usr/bin/env bash
set -euo pipefail
# dsh 自动更新脚本:检查 npm registry 最新版本并增量更新
# 被以下场景调用:
#   1. daemon 启动后延迟 10 秒后台触发
#   2. LaunchAgent 定时任务每天凌晨 2:30
# 幂等:已是最新版本则跳过;网络失败静默退出(不阻塞 daemon)

LOCK_DIR="${DSH_RT_STATE:-$HOME/.local/state/dsh-runtime}/update.lock.d"

# 目录原子锁:防止并发更新(daemon 后台 + 定时任务可能重叠)
# mkdir 在 macOS/Linux 都是原子操作
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # 检查锁是否过期(超过 1 小时视为僵尸锁)
  if [ -d "$LOCK_DIR" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -f%m "$LOCK_DIR" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -gt 3600 ]; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    else
      exit 0
    fi
  else
    exit 0
  fi
fi
trap "rmdir '$LOCK_DIR' 2>/dev/null || true" EXIT

RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
APP_DIR="$RT_HOME/app"
NODE_BIN="$RT_HOME/node/bin/node"
NPM_BIN="$RT_HOME/node/bin/npm"

# 优先使用系统 node(与 install.sh 保持一致)
if command -v node >/dev/null 2>&1; then
  SYS_VER="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
  if [ "${SYS_VER:-0}" -ge 20 ]; then
    NODE_BIN="$(command -v node)"
    NPM_BIN="$(command -v npm)"
  fi
fi

[ ! -x "$NODE_BIN" ] && exit 0
[ ! -x "$NPM_BIN" ] && exit 0
[ ! -d "$APP_DIR/node_modules/@deepseek-ai/dsh" ] && exit 0

# 自动跟随上游 next 标签(dsh 官方开发分支)
# 可通过 DSH_VERSION 环境变量覆盖回退(如 DSH_VERSION=0.1.1-rc.2)
DSH_VERSION="${DSH_VERSION:-next}"
LATEST="$DSH_VERSION"

# 读取当前安装版本
CUR="$("$NODE_BIN" -e 'console.log(require(process.argv[1]).version)' \
  "$APP_DIR/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null || echo "")"

if [ "$CUR" = "$LATEST" ]; then
  exit 0
fi

# 增量更新(npm update 只下载变化的包,比 npm install 快 70-85%)
LOG_DIR="${DSH_RT_STATE:-$HOME/.local/state/dsh-runtime}/logs"
mkdir -p "$LOG_DIR"
UPDATE_LOG="$LOG_DIR/update.log"

{
  echo "==> $(date '+%Y-%m-%d %H:%M:%S') 开始更新 dsh: $CUR -> $LATEST"
  if PATH="$RT_HOME/node/bin:$PATH" NODE_OPTIONS="--max-old-space-size=2048" \
     "$NPM_BIN" update --prefix "$APP_DIR" --prefer-offline --no-audit --no-fund 2>&1; then
    UPDATED="$("$NODE_BIN" -e 'console.log(require(process.argv[1]).version)' \
      "$APP_DIR/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null || echo "")"
    echo "✓ 更新完成: $UPDATED"
    
    # 清理跨平台冗余依赖(与 install.sh 保持一致)
    CLEANUP="$RT_HOME/../scripts/cleanup-deps.sh"
    if [ -f "$CLEANUP" ]; then
      bash "$CLEANUP" >/dev/null 2>&1 || true
    fi
  else
    echo "✗ 更新失败(非零退出),保持当前版本 $CUR"
  fi
  echo "提示: pnpm store 累积历史版本可能占用磁盘空间,运行以下命令清理:"
  echo "  pnpm store prune"
} >> "$UPDATE_LOG" 2>&1
