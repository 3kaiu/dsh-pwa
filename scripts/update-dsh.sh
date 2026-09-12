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

# 系统 CA(D4):企业 TLS 检查代理(Zscaler/Netskope 等)用自签 CA 重签证书,而 Node 默认
# 只信内置根证书 → registry 请求报 UNABLE_TO_VERIFY_LEAF_SIGNATURE,更新**静默永不发生**
# (只写一行日志,没人会看)。--use-system-ca 让 Node 改用系统钥匙串,与守护的
# com.dshpwa.daemon.plist 保持一致。放在脚本里而不是 updater.plist 里,是因为它必须
# **按当前 node 的能力决定**:
#   NODE_OPTIONS 中的非法选项会让 node 直接拒绝启动(实测 rc≠0、一行代码都不执行),
#   而该选项是 Node 22.15.0 才引入的,install.sh 只要求 major >= 22(MIN_NODE=22)。
#   无条件加 → 22.0~22.14 上 read_version 恒空、脚本每次都"跳过更新",把「证书失败」
#   换成更彻底的「同样永不更新,且连日志都说不清原因」。故先探测支持性,支持才加。
if "$NODE_BIN" --use-system-ca -e '' >/dev/null 2>&1; then
  NODE_OPTIONS="--use-system-ca${NODE_OPTIONS:+ $NODE_OPTIONS}"
  export NODE_OPTIONS
fi

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
  # TOCTOU 防护(与 install.sh 同款):读到死 pid 到执行删除之间,锁可能被其他等待进程
  # 抢占重建(活锁)。O_EXCL 原子创建 claim 文件独占抢占权(claim 存在期间锁目录无法被
  # mkdir),claim 后复读 pid 仍是最初判死的值才清理;锁刚易主/他人正在抢占则本轮让位
  if ( set -C; echo "$$" > "$LOCK/claim" ) 2>/dev/null; then
    sleep 0.2
    if [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$LPID" ]; then
      rm -rf "$LOCK"
    else
      rm -f "$LOCK/claim" 2>/dev/null || true
      log "! $(date '+%Y-%m-%d %H:%M:%S') 安装锁刚被其他进程抢占,跳过本次更新(当前 $CUR)"
      exit 0
    fi
  else
    CPID="$(cat "$LOCK/claim" 2>/dev/null || true)"
    if [ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null; then
      log "! $(date '+%Y-%m-%d %H:%M:%S') 其他进程正在抢占安装锁,跳过本次更新(当前 $CUR)"
    else
      rm -f "$LOCK/claim" 2>/dev/null || true
      log "! $(date '+%Y-%m-%d %H:%M:%S') 清理残留 claim(抢占者已死),跳过本次更新(下轮再试)"
    fi
    exit 0
  fi
  if ! mkdir "$LOCK" 2>/dev/null; then
    log "! $(date '+%Y-%m-%d %H:%M:%S') 安装锁创建失败($LOCK),跳过本次更新"
    exit 0
  fi
fi
echo "$$" > "$LOCK/pid" 2>/dev/null || true
# 写后复核(与 install.sh 同款):mkdir→写 pid 微窗口内锁可能被并发抢占者删掉重建,
# pid 仍是自己才算真正持锁;否则本轮让位(下一轮定时任务再试)
if [ "$(cat "$LOCK/pid" 2>/dev/null || true)" != "$$" ]; then
  log "! $(date '+%Y-%m-%d %H:%M:%S') 安装锁竞争失败(被并发进程抢占),跳过本次更新"
  exit 0
fi
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true' EXIT

# 清理陈旧备份:全量重装前会把依赖树 mv 成 .bak.$$;若更新中途被 kill(断电/重启),
# 备份会残留。此刻已持有安装锁,不存在并发更新,任何 .bak 都是死备份,顺手清掉
rm -rf "$APP_DIR"/node_modules.bak.* "$APP_DIR"/pnpm-lock.yaml.bak.* 2>/dev/null || true

mkdir -p "$LOG_DIR"

# 版本策略:跟随上游 latest 标签(与 install.sh 保持一致);DSH_VERSION 可覆盖(如 0.1.5-rc.1)
DSH_VERSION="${DSH_VERSION:-latest}"

# 先把 dist-tag 解析成真实版本号再比较(直接拿 "latest" 与本地如 "0.1.5" 比较永不相等,会恒判需更新)
# 网络调用必须自带超时:本脚本在 npm view 之前就持 $RT_HOME/.install.lock,而守护 update_locked()
# 在持锁期间拒绝拉起 dsh —— npm 无超时参数时,registry 黑洞(丢包而非拒绝)会让锁被无限期持有,
# PWA 就一直停在引导页。实测(黑洞 registry 10.255.255.1:81):无参数 >40s 未返回;
# --fetch-timeout=20000 --fetch-retries=1 在 3.8s 内按预期中止。
# 20s × 2 次 ≈ 40s 上限:检查失败只是「保持当前版本」,下轮(每日 2:30 / 12h 节流)再试,代价可接受。
# 注意:只给「检查」加超时,不给下面的 pnpm update 加 —— 更新本身耗时长,外部打断会留下半更新树。
REMOTE="$("$NPM_BIN" view --fetch-timeout=20000 --fetch-retries=1 "@deepseek-ai/dsh@$DSH_VERSION" version 2>/dev/null | tail -1 || true)"
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
# --noproxy '*':守护恒在回环地址,而用户环境可能设了 http_proxy(代理不可达/不转发回环时
# curl 会一直挂到超时)→ 会误判「dsh 未运行」而在用户活跃时替换依赖树,故显式绕过代理。
RT_PORT="${DSH_RT_PORT:-3080}"
HEALTH="$(curl -s -m 2 --noproxy '*' "http://127.0.0.1:$RT_PORT/health" 2>/dev/null || true)"
if printf '%s' "$HEALTH" | grep -q '"dsh"[[:space:]]*:[[:space:]]*true'; then
  log "! $(date '+%Y-%m-%d %H:%M:%S') dsh 运行中(用户可能活跃),跳过本次更新(当前 $CUR)"
  exit 0
fi

# 更新期停机兜底:上方探测时 dsh 未运行,但探测到 pnpm 更新开始之间存在窄窗口——
# 用户恰好 /wake 会把 dsh 从即将半更新的 node_modules 拉起。经守护 /stop 优雅停掉
# 刚拉起的 dsh 兜住该窗口(守护自身继续服务引导页);连不上守护照常更新——curl 失败
# 绝不中止更新。更新完成后不主动重启:零常驻模式下下次 PWA 访问天然自动拉起新版。
if curl -fsS --max-time 5 --noproxy '*' -X POST -H "Origin: http://127.0.0.1:$RT_PORT" \
     "http://127.0.0.1:$RT_PORT/stop" >/dev/null 2>&1; then
  log "  更新前已停止运行中的 dsh(经守护 /stop),避免从半更新树启动"
fi

# pnpm 引导:与 install.sh 完全一致(npm exec 按需拉起 pnpm@10,内容寻址存储 + 硬链接)
# node_modules 由 pnpm 装出,pnpm 不可用则失败记日志,绝不回退 npm(npm 会损坏依赖树)
# PATH 已在 NODE_BIN 确定后统一前置,此处无需再处理
pnpm_run() {
  # NODE_OPTIONS 必须**追加**而非覆盖:覆盖会顺手抹掉上面按能力加上的 --use-system-ca,
  # 于是变成「npm view 过得去、pnpm install 过不去」——企业代理下最难查的半通状态。
  NODE_OPTIONS="--max-old-space-size=4096${NODE_OPTIONS:+ $NODE_OPTIONS}" \
    "$NPM_BIN" exec --yes --package=pnpm@10 -- pnpm "$@"
}

# 固定目标版本到 package.json(与 install.sh 同构),pnpm update 增量拉差异
write_app_manifest() {
  printf '{"name":"dsh-runtime-app","private":true,"dependencies":{"@deepseek-ai/dsh":"%s"},"pnpm":{"onlyBuiltDependencies":["node-pty","koffi","@deepseek-ai/dsh-subprocess-local"]}}\n' \
    "$1" > "$APP_DIR/package.json"
}

# 刷新 run.json:dsh bin 路径可能随版本变化(单一事实源,守护直启依赖它)
refresh_run_json() {
  local bin
  bin="$("$NODE_BIN" -e '
    const { join, dirname } = require("path");
    const pkg = require(process.argv[1]);
    const bin = typeof pkg.bin === "string" ? pkg.bin : (pkg.bin && pkg.bin.dsh) || "lib/bin.js";
    console.log(join(dirname(process.argv[1]), bin));
  ' "$APP_DIR/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null || true)"
  if [ -n "$bin" ]; then
    "$NODE_BIN" -e '
      const fs = require("fs");
      fs.writeFileSync(process.argv[1], JSON.stringify({ node: process.argv[2], dsh: process.argv[3] }) + "\n");
    ' "$RT_HOME/run.json" "$NODE_BIN" "$bin" 2>/dev/null || log "! run.json 刷新失败(守护将继续使用旧路径)"
  fi
}

# 把依赖树恢复到更新前版本(A4 探测失败时用)。两条路径:
#   1) 有 .bak(增量更新失败、走全量重装时 mv 出来的)→ 直接换回:零网络、近零成本
#   2) 无 .bak(增量更新就地改了树)→ 按**更新前版本号**重装。store 里刚用过这些包,
#      --prefer-offline 通常无需下载。这是真的回滚,而不是"保持现状"式的口头回滚。
rollback_deps() {
  if [ -d "$BAK_NM" ]; then
    rm -rf "$APP_DIR/node_modules"
    mv "$BAK_NM" "$APP_DIR/node_modules" 2>/dev/null || return 1
    if [ -f "$BAK_LOCK" ]; then
      rm -f "$APP_DIR/pnpm-lock.yaml"
      mv "$BAK_LOCK" "$APP_DIR/pnpm-lock.yaml" 2>/dev/null || true
    fi
    return 0
  fi
  [ -n "$CUR" ] || return 1
  write_app_manifest "$CUR"
  pnpm_run --dir "$APP_DIR" --store-dir "$PNPM_STORE" install --prefer-offline >> "$UPDATE_LOG" 2>&1 || return 1
  return 0
}

write_app_manifest "$REMOTE"

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

# 注意:备份**不在这里**清理。更新"成功"只代表 pnpm 把依赖树装出来了,还要过下面 A4 的
# 启动探测;探测失败要靠这份备份回滚。清理移到探测通过之后(旧实现此处就删,等于让
# "探测失败即回滚"永远无备份可用)。
NEW="$(read_version)"
if [ "$UPDATE_OK" = "1" ] && [ "$NEW" = "$REMOTE" ]; then
  # 清理跨平台冗余依赖(与 install.sh 保持一致;cleanup-deps.sh 需要传入 app 目录)
  if [ -f "$RT_HOME/scripts/cleanup-deps.sh" ]; then
    bash "$RT_HOME/scripts/cleanup-deps.sh" "$APP_DIR" >> "$UPDATE_LOG" 2>&1 || true
    # 原生依赖探针(与 install.sh 同源):cleanup 删了 sharp 的 WASM 回退与 node-pty 跨平台
    # 二进制,若某架构原生绑定缺失,dsh 图像/终端功能会运行时失败。从 dsh 包目录解析
    # (pnpm 隔离布局下 sharp/node-pty 是传递依赖)。更新本身已成功,故不回滚版本,但把问题
    # 显式记入日志并提示重装,而非静默留下半坏的依赖树。
    if ( cd "$APP_DIR/node_modules/@deepseek-ai/dsh" && "$NODE_BIN" -e "require('sharp'); require('node-pty')" ) >/dev/null 2>&1; then
      log "  $(date '+%Y-%m-%d %H:%M:%S') 关键原生依赖验证通过(sharp/node-pty)"
    else
      log "! $(date '+%Y-%m-%d %H:%M:%S') 清理后原生依赖验证失败(sharp/node-pty),建议重跑 install.sh 修复"
    fi
  fi
  refresh_run_json

  # ---- A4:更新后真实启动探测 ----
  # 上面的原生依赖探针只证明「sharp/node-pty 能被 require」;它不覆盖入口解析、ESM 依赖图、
  # 新版本对 node 版本的要求、cleanup-deps 删过头……那些只在真正启动时暴露。无人值守的
  # 凌晨更新必须自证可用,否则用户第二天面对的就是「服务消失」。故真起一次(见
  # scripts/dsh-probe.sh 头部:为什么必须在临时 RT_HOME 里探测)。
  #
  # 退出码三态,判错任何一态都有害:
  #   0 就绪     → 保留新版本
  #   1 未就绪   → **回滚**到更新前版本(这就是本次修复的目的)
  #   2 无法探测 → 保留新版本。缺件(没装守护/没 run.json/没有空闲端口)是环境问题,
  #                不是新版本的错;若也回滚,会变成"环境缺件 → 每次更新都回滚"的死循环,
  #                把本来好的版本也折腾坏。
  PROBE_RC=2
  PROBE_LOG="$LOG_DIR/probe.log"
  if [ -x "$RT_HOME/scripts/dsh-probe.sh" ]; then
    # `|| PROBE_RC=$?`:脚本 set -e,探测返回 1 时若直接调用会当场终止本脚本,
    # 后面判三态、回滚、写日志全部不执行(＝把"回滚"变成"静默退出")。
    bash "$RT_HOME/scripts/dsh-probe.sh" --timeout "${DSH_RT_PROBE_TIMEOUT_SECS:-60}" \
      --log "$PROBE_LOG" >> "$UPDATE_LOG" 2>&1 || PROBE_RC=$?
  else
    log "! 启动探测脚本缺失($RT_HOME/scripts/dsh-probe.sh),跳过探测(新版本可用性未验证)"
  fi

  case "$PROBE_RC" in
    1)
      if rollback_deps; then
        refresh_run_json
        ROLLBACK_CUR="$(read_version)"
        # 机器可判的痕迹:失败路径不能只写一行日志(见 install.sh 4c 的教训——"失败只 warn"
        # 曾让暖机 4/4 全挂而 CI 全绿)。冒烟/验收据此断言"探测真的跑过并表过态"。
        printf '%s\n' "$REMOTE" > "$RT_STATE/update.probe.failed" 2>/dev/null || true
        log "✗ $(date '+%Y-%m-%d %H:%M:%S') 新版本 $REMOTE 启动探测失败,已回滚到 ${ROLLBACK_CUR:-$CUR}(探测日志 $PROBE_LOG)"
      else
        printf '%s\n' "$REMOTE" > "$RT_STATE/update.probe.failed" 2>/dev/null || true
        log "✗ $(date '+%Y-%m-%d %H:%M:%S') 新版本 $REMOTE 启动探测失败,且回滚失败,依赖树可能损坏,请重跑 install.sh(探测日志 $PROBE_LOG)"
      fi
      ;;
    *)
      # 0(就绪)或 2(无法探测):保留新版本,备份已无用
      rm -rf "$BAK_NM" "$BAK_LOCK" 2>/dev/null || true
      rm -f "$RT_STATE/update.probe.failed" 2>/dev/null || true
      if [ "$PROBE_RC" = "0" ]; then
        log "✓ $(date '+%Y-%m-%d %H:%M:%S') 更新完成并已自证可用(启动探测通过): $CUR -> $NEW"
      else
        log "✓ $(date '+%Y-%m-%d %H:%M:%S') 更新完成(启动探测不可用,未验证): $CUR -> $NEW"
      fi
      ;;
  esac
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
