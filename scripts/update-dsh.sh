#!/usr/bin/env bash
set -euo pipefail
# dsh 自动更新脚本:解析 registry dist-tag 的真实版本号,与本地实际版本比较后用 pnpm 增量更新
# 安装位置: $RT_HOME/scripts/update-dsh.sh(由 install.sh 部署;发行包解压在临时目录、装完即删,不可回溯源码路径)
# 被以下场景调用:
#   1. daemon 激活时后台触发(12h 节流,由 daemon 按 RT_STATE/last_update_check 判断)
#   2. LaunchAgent 定时任务每天凌晨 2:30(com.dshpwa.updater)
# 互斥: 与 install.sh 共用 $RT_HOME/.install.lock(mkdir 原子锁 + pid 存活检测),锁被占则记日志退出,绝不并发
# 版本策略: 跟随上游 latest 标签(与 install.sh 一致;DSH_VERSION 可覆盖为指定版本)
# 幂等: 已是最新版本则跳过;网络/pnpm 失败则回滚到更新前的依赖树并记日志退出,绝不回退 npm

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

log() { mkdir -p "$LOG_DIR" 2>/dev/null || true; rotate_log; echo "$*" >> "$UPDATE_LOG" 2>/dev/null || true; }

read_version() {
  "$NODE_BIN" -e 'console.log(require(process.argv[1]).version)' \
    "$APP_DIR/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null || echo ""
}

# 未安装则无事可做(记日志,便于排查"定时任务在跑却从未更新"的情况)
if [ ! -d "$APP_DIR/node_modules/@deepseek-ai/dsh" ]; then
  log "! $(date '+%Y-%m-%d %H:%M:%S') 未检测到已安装的 dsh($APP_DIR),跳过更新"
  exit 0
fi

# node 解析:优先 $RT_HOME/run.json 的 "node" 字段(install.sh 写入的单一事实源,存的是真实
# node 绝对路径,不依赖 PATH)。launchd 定时/守护环境无用户 PATH 注入,command -v node 会失败;
# 复用系统 node 形态下 $RT_HOME/node 又被 install.sh 删除,不先查 run.json 会静默退出。
# run.json 缺失或不可用时回落原有顺序(与 install.sh 一致):command -v node(解析 fnm/volta
# 等 shim 符号链接到真实二进制,系统 node >=22 优先)→ 自带 $RT_HOME/node
NODE_BIN=""
RUN_NODE="$(grep -o '"node"[[:space:]]*:[[:space:]]*"[^"]*"' "$RT_HOME/run.json" 2>/dev/null | head -1 | sed -e 's/^"node"[[:space:]]*:[[:space:]]*"//' -e 's/"$//' || true)"
if [ -n "$RUN_NODE" ] && [ -x "$RUN_NODE" ]; then
  NODE_BIN="$RUN_NODE"
fi
if [ -z "$NODE_BIN" ] && command -v node >/dev/null 2>&1; then
  CAND="$(command -v node)"
  CAND="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$CAND" 2>/dev/null || echo "$CAND")"
  SYS_VER="$("$CAND" --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
  if [ "${SYS_VER:-0}" -ge 22 ]; then
    NODE_BIN="$CAND"
  fi
fi
[ -n "$NODE_BIN" ] || NODE_BIN="$NODE_DIR/bin/node"
NPM_BIN="$(dirname "$NODE_BIN")/npm"
if [ ! -x "$NODE_BIN" ]; then
  log "! $(date '+%Y-%m-%d %H:%M:%S') node 不存在(run.json 解析: ${RUN_NODE:-无}),跳过更新"
  exit 0
fi
if [ ! -x "$NPM_BIN" ]; then
  log "! $(date '+%Y-%m-%d %H:%M:%S') npm 不存在($NPM_BIN),跳过更新"
  exit 0
fi

# PATH 前置:npm/pnpm 的 shebang 都是 #!/usr/bin/env node,PATH 里没有 node 会恒失败;
# 统一注入 node 所在目录(幂等),此后所有 npm/pnpm 调用不再各自处理 PATH
NODE_BIN_DIR="$(dirname "$NODE_BIN")"
export PATH="$NODE_BIN_DIR:$PATH"

CUR="$(read_version)"
if [ -z "$CUR" ]; then
  log "! $(date '+%Y-%m-%d %H:%M:%S') 无法读取当前已装版本,跳过更新"
  exit 0
fi

# 安装锁:与 install.sh 共用同一路径($RT_HOME/.install.lock)
# mkdir 原子操作;持有进程已死视为僵尸锁可抢占,活着则记日志退出(防止更新与安装/其他更新并发破坏 node_modules)
LOCK="$RT_HOME/.install.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  LPID="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$LPID" ] && kill -0 "$LPID" 2>/dev/null; then
    log "! $(date '+%Y-%m-%d %H:%M:%S') 安装锁被占用(pid $LPID),跳过本次更新(当前 $CUR)"
    exit 0
  fi
  rm -rf "$LOCK"
  if ! mkdir "$LOCK" 2>/dev/null; then
    log "! $(date '+%Y-%m-%d %H:%M:%S') 安装锁创建失败($LOCK),跳过本次更新"
    exit 0
  fi
fi
echo "$$" > "$LOCK/pid"
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true' EXIT

# 清理陈旧备份:全量重装前会把依赖树 mv 成 .bak.$$;若更新中途被 kill(断电/重启),
# 备份会残留。此刻已持有安装锁,不存在并发更新,任何 .bak 都是死备份,顺手清掉
rm -rf "$APP_DIR"/node_modules.bak.* "$APP_DIR"/pnpm-lock.yaml.bak.* 2>/dev/null || true

mkdir -p "$LOG_DIR"

# 版本策略:跟随上游 latest 标签(与 install.sh 保持一致);DSH_VERSION 可覆盖(如 0.1.5-rc.1)
DSH_VERSION="${DSH_VERSION:-latest}"

# 先把 dist-tag 解析成真实版本号再比较(直接拿 "latest" 与本地如 "0.1.5" 比较永不相等,会恒判需更新)
REMOTE="$("$NPM_BIN" view "@deepseek-ai/dsh@$DSH_VERSION" version 2>/dev/null | tail -1 || true)"
if [ -z "$REMOTE" ]; then
  log "! $(date '+%Y-%m-%d %H:%M:%S') 无法获取远程版本(网络失败?),保持 $CUR"
  exit 0
fi
if [[ ! "$REMOTE" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z._+]+)?$ ]]; then
  log "! $(date '+%Y-%m-%d %H:%M:%S') 远程版本串非法: $REMOTE,保持 $CUR"
  exit 0
fi
if [ "$CUR" = "$REMOTE" ]; then
  log "  $(date '+%Y-%m-%d %H:%M:%S') 已是最新版本($CUR),无需更新"
  exit 0
fi

log "==> $(date '+%Y-%m-%d %H:%M:%S') 开始更新 dsh: $CUR -> $REMOTE($DSH_VERSION)"

# 活跃会话协调:定时/后台更新与用户使用零协调曾导致"正在用的 dsh 被杀 + 引导页立刻
# /wake 拉起半更新的 node_modules"。规则:dsh 在跑(守护 /health 报 dsh:true,大概率有
# 活跃会话)→ 推迟本次更新,等下一轮(每天 2:30 / 守护激活 12h 节流)用户不在场时再做;
# /health 不可达(守护未激活,典型凌晨场景)→ dsh 必然没在跑,照常更新。
RT_PORT="${DSH_RT_PORT:-3080}"
HEALTH="$(curl -s -m 2 "http://127.0.0.1:$RT_PORT/health" 2>/dev/null || true)"
if printf '%s' "$HEALTH" | grep -q '"dsh"[[:space:]]*:[[:space:]]*true'; then
  log "! $(date '+%Y-%m-%d %H:%M:%S') dsh 运行中(用户可能活跃),跳过本次更新(当前 $CUR)"
  exit 0
fi

# 更新期停机兜底:上方探测时 dsh 未运行,但探测到 pnpm 更新开始之间存在窄窗口——
# 用户恰好 /wake 会把 dsh 从即将半更新的 node_modules 拉起。经守护 /stop 优雅停掉
# 刚拉起的 dsh 兜住该窗口(守护自身继续服务引导页);连不上守护照常更新——curl 失败
# 绝不中止更新。更新完成后不主动重启:零常驻模式下下次 PWA 访问天然自动拉起新版。
if curl -fsS --max-time 5 -X POST -H "Origin: http://127.0.0.1:$RT_PORT" \
     "http://127.0.0.1:$RT_PORT/stop" >/dev/null 2>&1; then
  log "  更新前已停止运行中的 dsh(经守护 /stop),避免从半更新树启动"
fi

# pnpm 引导:与 install.sh 完全一致(npm exec 按需拉起 pnpm@10,内容寻址存储 + 硬链接)
# node_modules 由 pnpm 装出,pnpm 不可用则失败记日志,绝不回退 npm(npm 会损坏依赖树)
# PATH 已在 NODE_BIN 确定后统一前置,此处无需再处理
pnpm_run() {
  NODE_OPTIONS="--max-old-space-size=4096" \
    "$NPM_BIN" exec --yes --package=pnpm@10 -- pnpm "$@"
}

# 固定目标版本到 package.json(与 install.sh 同构),pnpm update 增量拉差异
printf '{"name":"dsh-runtime-app","private":true,"dependencies":{"@deepseek-ai/dsh":"%s"},"pnpm":{"onlyBuiltDependencies":["node-pty","koffi","@deepseek-ai/dsh-subprocess-local"]}}\n' \
  "$REMOTE" > "$APP_DIR/package.json"

UPDATE_OK=0
BAK_NM="$APP_DIR/node_modules.bak.$$"
BAK_LOCK="$APP_DIR/pnpm-lock.yaml.bak.$$"
if pnpm_run --dir "$APP_DIR" --store-dir "$PNPM_STORE" update "@deepseek-ai/dsh" --prefer-offline >> "$UPDATE_LOG" 2>&1; then
  UPDATE_OK=1
else
  log "! 增量更新失败,尝试全量重装(pnpm install)"
  # 删除前先把现有依赖树 mv 成同目录备份(rename,近零成本)。全量重装也失败(如断网)时
  # 回滚恢复,避免 node_modules 被删导致 dsh 彻底不可用(凌晨无人值守的"过夜服务消失")
  mv "$APP_DIR/node_modules" "$BAK_NM" 2>/dev/null || true
  mv "$APP_DIR/pnpm-lock.yaml" "$BAK_LOCK" 2>/dev/null || true
  if pnpm_run --dir "$APP_DIR" --store-dir "$PNPM_STORE" install --prefer-offline >> "$UPDATE_LOG" 2>&1; then
    UPDATE_OK=1
  fi
fi

# 重装成功(或增量直接成功)则备份已无用,清理掉;失败则留给下方回滚
if [ "$UPDATE_OK" = "1" ]; then
  rm -rf "$BAK_NM" "$BAK_LOCK" 2>/dev/null || true
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
  if [ "$UPDATE_OK" = "0" ]; then
    # 更新彻底失败(增量与全量均败):先清掉失败残留的半新树,再把备份 mv 回原位,
    # 恢复更新前可用的依赖树——"保持当前版本"必须是真的保持,而不是删空后的保持
    rm -rf "$APP_DIR/node_modules" "$APP_DIR/pnpm-lock.yaml"
    if [ -d "$BAK_NM" ] || [ -f "$BAK_LOCK" ]; then
      [ -d "$BAK_NM" ] && mv "$BAK_NM" "$APP_DIR/node_modules" 2>/dev/null || true
      [ -f "$BAK_LOCK" ] && mv "$BAK_LOCK" "$APP_DIR/pnpm-lock.yaml" 2>/dev/null || true
      ROLLBACK_CUR="$(read_version)"
      if [ -n "$ROLLBACK_CUR" ]; then
        log "✗ $(date '+%Y-%m-%d %H:%M:%S') 更新失败(目标 $REMOTE),已回滚到更新前版本($ROLLBACK_CUR)"
      else
        log "✗ $(date '+%Y-%m-%d %H:%M:%S') 更新失败且回滚后版本不可读,依赖树可能损坏,请重跑 install.sh"
      fi
    else
      log "✗ $(date '+%Y-%m-%d %H:%M:%S') 更新失败(目标 $REMOTE),且无备份可回滚,依赖树可能损坏,请重跑 install.sh"
    fi
  else
    # pnpm 声称成功但版本不符:树是刚装出的完整树,只是没落到目标版本,保持现状即可
    log "✗ $(date '+%Y-%m-%d %H:%M:%S') 更新后版本异常(当前 $NEW,目标 $REMOTE),保持当前版本"
  fi
fi
