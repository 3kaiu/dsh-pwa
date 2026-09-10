#!/usr/bin/env bash
set -euo pipefail
# dsh 自动更新脚本:解析 registry dist-tag 的真实版本号,与本地实际版本比较后用 pnpm 增量更新
# 安装位置: $RT_HOME/scripts/update-dsh.sh(由 install.sh 部署;发行包解压在临时目录、装完即删,不可回溯源码路径)
# 被以下场景调用:
#   1. daemon 激活时后台触发(12h 节流,由 daemon 按 RT_STATE/last_update_check 判断)
#   2. LaunchAgent 定时任务每天凌晨 2:30(com.dshpwa.updater)
# 互斥: 与 install.sh 共用 $RT_HOME/.install.lock(mkdir 原子锁 + pid 存活检测),锁被占则记日志退出,绝不并发
# 版本策略: 跟随上游 latest 标签(与 install.sh 一致;DSH_VERSION 可覆盖为指定版本)
# 幂等: 已是最新版本则跳过;网络/pnpm 失败记日志后保持当前版本退出,绝不回退 npm

RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
RT_STATE="${DSH_RT_STATE:-$HOME/.local/state/dsh-runtime}"
APP_DIR="$RT_HOME/app"
NODE_DIR="$RT_HOME/node"
PNPM_STORE="$RT_HOME/.pnpm-store"
LOG_DIR="$RT_STATE/logs"
UPDATE_LOG="$LOG_DIR/update.log"

# 日志轮转:update.log 无限追加会持续膨胀;超 2MB 时滚动为 update.log.1(保留最近一份)
# (daemon.log 由 launchd 重定向且零常驻下只在活跃期增长,风险低,不轮转)
rotate_log() {
  [ -f "$UPDATE_LOG" ] || return 0
  local sz
  sz="$(stat -f%z "$UPDATE_LOG" 2>/dev/null || echo 0)"
  if [ "${sz:-0}" -gt 2097152 ]; then
    mv -f "$UPDATE_LOG" "$UPDATE_LOG.1" 2>/dev/null || true
  fi
}

log() { rotate_log; echo "$*" >> "$UPDATE_LOG" 2>/dev/null || true; }

read_version() {
  "$NODE_BIN" -e 'console.log(require(process.argv[1]).version)' \
    "$APP_DIR/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null || echo ""
}

# 未安装则无事可做(静默退出,不打日志)
[ -d "$APP_DIR/node_modules/@deepseek-ai/dsh" ] || exit 0

# node 解析:与 install.sh 一致(解析 fnm/volta 等 shim 符号链接到真实二进制;系统 node >=22 优先,其次自带 $RT_HOME/node)
NODE_BIN="$NODE_DIR/bin/node"
NPM_BIN="$NODE_DIR/bin/npm"
if command -v node >/dev/null 2>&1; then
  CAND="$(command -v node)"
  CAND="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$CAND" 2>/dev/null || echo "$CAND")"
  SYS_VER="$("$CAND" --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
  if [ "${SYS_VER:-0}" -ge 22 ]; then
    NODE_BIN="$CAND"
    CAND_NPM="$(dirname "$CAND")/npm"
    if [ -x "$CAND_NPM" ]; then
      NPM_BIN="$CAND_NPM"
    elif command -v npm >/dev/null 2>&1; then
      NPM_BIN="$(command -v npm)"
    fi
  fi
fi
[ -x "$NODE_BIN" ] || exit 0
[ -x "$NPM_BIN" ] || exit 0

CUR="$(read_version)"
[ -n "$CUR" ] || exit 0

# 安装锁:与 install.sh 共用同一路径($RT_HOME/.install.lock)
# mkdir 原子操作;持有进程已死视为僵尸锁可抢占,活着则记日志退出(防止更新与安装/其他更新并发破坏 node_modules)
LOCK="$RT_HOME/.install.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  LPID="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$LPID" ] && kill -0 "$LPID" 2>/dev/null; then
    mkdir -p "$LOG_DIR"
    log "! $(date '+%Y-%m-%d %H:%M:%S') 安装锁被占用(pid $LPID),跳过本次更新(当前 $CUR)"
    exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo "$$" > "$LOCK/pid"
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true' EXIT

mkdir -p "$LOG_DIR"

# 版本策略:跟随上游 latest 标签(与 install.sh 保持一致);DSH_VERSION 可覆盖(如 0.1.5-rc.1)
DSH_VERSION="${DSH_VERSION:-latest}"

# 先把 dist-tag 解析成真实版本号再比较(直接拿 "latest" 与本地如 "0.1.5" 比较永不相等,会恒判需更新)
REMOTE="$("$NPM_BIN" view "@deepseek-ai/dsh@$DSH_VERSION" version 2>/dev/null | tail -1 || true)"
if [ -z "$REMOTE" ]; then
  log "! $(date '+%Y-%m-%d %H:%M:%S') 无法获取远程版本(网络失败?),保持 $CUR"
  exit 0
fi
if [ "$CUR" = "$REMOTE" ]; then
  exit 0
fi

log "==> $(date '+%Y-%m-%d %H:%M:%S') 开始更新 dsh: $CUR -> $REMOTE($DSH_VERSION)"

# 更新期停机协调:pnpm 增量更新期间 node_modules 处于半更新状态,此时用户的 /wake 会把
# dsh 从半更新树里拉起来(崩溃/行为异常)。更新前先经守护的 /stop 端点优雅停掉运行中的
# dsh(守护自身继续服务引导页,只是 dsh 停了);连不上守护说明 dsh 没在跑(未激活/冒烟
# 测试 NO_AGENT 环境),跳过即可——curl 失败绝不中止更新。更新完成后不主动重启:
# 零常驻模式下下次 PWA 访问天然自动拉起新版。端口取 DSH_RT_PORT(installer 已注入
# updater plist),默认 3080 与守护一致。
RT_PORT="${DSH_RT_PORT:-3080}"
if curl -fsS --max-time 5 -X POST -H "Origin: http://127.0.0.1:$RT_PORT" \
     "http://127.0.0.1:$RT_PORT/stop" >/dev/null 2>&1; then
  log "  更新前已停止运行中的 dsh(经守护 /stop),避免从半更新树启动"
fi

# pnpm 引导:与 install.sh 完全一致(npm exec 按需拉起 pnpm@10,内容寻址存储 + 硬链接)
# node_modules 由 pnpm 装出,pnpm 不可用则失败记日志,绝不回退 npm(npm 会损坏依赖树)
pnpm_run() {
  PATH="$NODE_DIR/bin:$PATH" NODE_OPTIONS="--max-old-space-size=4096" \
    "$NPM_BIN" exec --yes --package=pnpm@10 -- pnpm "$@"
}

# 固定目标版本到 package.json(与 install.sh 同构),pnpm update 增量拉差异
printf '{"name":"dsh-runtime-app","private":true,"dependencies":{"@deepseek-ai/dsh":"%s"},"pnpm":{"onlyBuiltDependencies":["node-pty","koffi","@deepseek-ai/dsh-subprocess-local"]}}\n' \
  "$REMOTE" > "$APP_DIR/package.json"

UPDATE_OK=0
if pnpm_run --dir "$APP_DIR" --store-dir "$PNPM_STORE" update "@deepseek-ai/dsh" --prefer-offline >> "$UPDATE_LOG" 2>&1; then
  UPDATE_OK=1
else
  log "! 增量更新失败,尝试全量重装(pnpm install)"
  rm -rf "$APP_DIR/node_modules" "$APP_DIR/pnpm-lock.yaml"
  if pnpm_run --dir "$APP_DIR" --store-dir "$PNPM_STORE" install --prefer-offline >> "$UPDATE_LOG" 2>&1; then
    UPDATE_OK=1
  fi
fi

NEW="$(read_version)"
if [ "$UPDATE_OK" = "1" ] && [ "$NEW" = "$REMOTE" ]; then
  # 清理跨平台冗余依赖(与 install.sh 保持一致;cleanup-deps.sh 需要传入 app 目录)
  if [ -f "$RT_HOME/scripts/cleanup-deps.sh" ]; then
    bash "$RT_HOME/scripts/cleanup-deps.sh" "$APP_DIR" >> "$UPDATE_LOG" 2>&1 || true
  fi
  # 刷新 run.json:dsh bin 路径可能随版本变化(单一事实源,守护直启依赖它)
  DSH_BIN="$("$NODE_BIN" -e '
    const { join, dirname } = require("path");
    const pkg = require(process.argv[1]);
    const bin = typeof pkg.bin === "string" ? pkg.bin : (pkg.bin && pkg.bin.dsh) || "lib/bin.js";
    console.log(join(dirname(process.argv[1]), bin));
  ' "$APP_DIR/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null || true)"
  if [ -n "$DSH_BIN" ]; then
    "$NODE_BIN" -e '
      const fs = require("fs");
      fs.writeFileSync(process.argv[1], JSON.stringify({ node: process.argv[2], dsh: process.argv[3] }) + "\n");
    ' "$RT_HOME/run.json" "$NODE_BIN" "$DSH_BIN" 2>/dev/null || log "! run.json 刷新失败(守护将继续使用旧路径)"
  fi
  log "✓ $(date '+%Y-%m-%d %H:%M:%S') 更新完成: $CUR -> $NEW"
else
  log "✗ $(date '+%Y-%m-%d %H:%M:%S') 更新失败(当前 $NEW,目标 $REMOTE),保持当前版本"
fi
