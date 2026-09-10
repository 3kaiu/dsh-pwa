#!/usr/bin/env bash
set -euo pipefail
# dsh-pwa 一键安装:运行时(node 复用系统或装最新 LTS + 官方 dsh@latest)+ 守护 + LaunchAgent。
# 用法:  bash install.sh          (仓库根 / 发行包根;包内含预编译 daemon 则免 clang)
# 升级:  重跑本脚本即自动跟随上游最新(已安装版本不变则跳过)
# 环境:  DSH_RT_HOME DSH_RT_STATE DSH_HOME DSH_RT_PORT(默认 3080)
#        DSH_INSTALL_NO_AGENT(不注册守护,测试用) DSH_RT_NO_SYSTEM_NODE(强制装自带 node LTS)
#        DSH_RT_RELEASE_TAG(固定版本,如 v1.0.0;不设则用 latest)
START_TS="$(date +%s)"
RELEASE_TAG="${DSH_RT_RELEASE_TAG:-latest}"

# 进度输出:仅 TTY 时着色;管道/重定向退化为纯文本,curl 进度条同步切换
if [ -t 1 ]; then
  B=$'\033[1m'; C=$'\033[1;36m'; G=$'\033[32m'; D=$'\033[2m'; Y=$'\033[33m'; R=$'\033[0m'; PB='-#'
else
  B=""; C=""; G=""; D=""; Y=""; R=""; PB='-sS'
fi
h1()   { echo "${C}==>${R} ${B}$*${R}"; }
ok()   { echo "  ${G}✓${R} ${D}$*${R}"; }
warn() { echo "  ${Y}!${R} ${D}$*${R}" >&2; }
h1 "dsh-pwa 安装器"
echo "  ${D}github.com/3kaiu/dsh-pwa${R}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
# 仓库内运行(scripts/install.sh)时回溯到仓库根;发行包内运行时本身就是包根
[ -d "$ROOT/../scripts" ] && ROOT="$(cd "$ROOT/.." && pwd)"
# curl ... | bash 场景:无本地伴随文件 → 自动下载发行包到临时目录(无需手动下载)
if [ ! -f "$ROOT/src/daemon.c" ] && [ ! -f "$ROOT/daemon" ]; then
  h1 "自动下载发行包(releases/${RELEASE_TAG})"
  PKG_TMP="$(mktemp -d /tmp/dsh-pwa.XXXXXX)"
  DL_URL="https://github.com/3kaiu/dsh-pwa/releases/${RELEASE_TAG}/download/dsh-pwa.zip"
  SHA_URL="https://github.com/3kaiu/dsh-pwa/releases/${RELEASE_TAG}/download/dsh-pwa.zip.sha256"
  
  # 下载发行包 + SHA256
  curl -fsSL --max-time 300 -o "$PKG_TMP/pkg.zip" "$DL_URL" \
    || { echo "发行包下载失败(${DL_URL})" >&2; exit 1; }
  curl -fsSL --max-time 60 -o "$PKG_TMP/pkg.zip.sha256" "$SHA_URL" 2>/dev/null \
    || { warn "SHA256 校验文件缺失,发行包完整性无法验证"; rm -f "$PKG_TMP/pkg.zip"; exit 1; }
  
  # 校验 fail-closed:不通过则中止
  ( cd "$PKG_TMP" && shasum -a 256 -c pkg.zip.sha256 >/dev/null 2>&1 ) \
    || { warn "发行包 SHA-256 校验失败"; rm -rf "$PKG_TMP"; exit 1; }
  
  KB="$(awk -v n="$(stat -f%z "$PKG_TMP/pkg.zip")" 'BEGIN{printf "%.1f", n/1024}')"
  ( cd "$PKG_TMP" && unzip -q pkg.zip )
  rm -f "$PKG_TMP/pkg.zip" "$PKG_TMP/pkg.zip.sha256"
  ROOT="$PKG_TMP"
  ok "发行包 ${KB} KB 下载解压完成(SHA-256 校验通过)"
fi
RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
RT_STATE="${DSH_RT_STATE:-$HOME/.local/state/dsh-runtime}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PORT_RAW="${DSH_RT_PORT:-3080}"
# 端口校验:只接受 1024-65535,拒绝特权端口/无效值(防止配置注入)
if ! [[ "$PORT_RAW" =~ ^[0-9]+$ ]] || [ "$PORT_RAW" -lt 1024 ] || [ "$PORT_RAW" -gt 65535 ]; then
  echo "DSH_RT_PORT 无效(需 1024-65535 的整数):$PORT_RAW" >&2
  exit 1
fi
PORT="$PORT_RAW"
LOG_DIR="$RT_STATE/logs"
# daemon 编译统一参数(两处编译路径共用;universal binary 双架构,Intel Mac 也产出 arm64+x86_64)
DAEMON_CFLAGS=(-O2 -Wall -Wextra -arch arm64 -arch x86_64)
NODE_DIR="$RT_HOME/node"
APP_DIR="$RT_HOME/app"
NODE_BIN="$NODE_DIR/bin/node"
NPM_BIN="$NODE_DIR/bin/npm"
DSH_PKG="$APP_DIR/node_modules/@deepseek-ai/dsh/package.json"
ARCH="$(uname -m | sed 's/x86_64/x64/')"
mkdir -p "$RT_HOME" "$RT_STATE" "$LOG_DIR" "$NODE_DIR" "$APP_DIR" "$DSH_HOME"
# 含 token 的状态/日志目录必须 0700:umask 022 下 mkdir -p 建出 0755,且对已存在目录
# 不会收紧权限(daemon 的 mkdir(LOG_DIR,0700) 对已存在目录静默失败)→ 显式 chmod 兜底,
# 同时修复存量目录
chmod 0700 "$RT_STATE" "$LOG_DIR"

# 安装锁(并发互斥:双击连点/重复安装时后到者等待;仅属主进程已死才可抢占——
# 旧逻辑按 10 分钟锁龄抢占活锁,慢网首装实测 >12 分钟,会导致两个安装互相破坏)
LOCK="$RT_HOME/.install.lock"
LOCKED=0
for _ in $(seq 1 300); do
  if mkdir "$LOCK" 2>/dev/null; then
    echo "$$" > "$LOCK/pid"; LOCKED=1; break
  fi
  LPID="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -z "$LPID" ] || ! kill -0 "$LPID" 2>/dev/null; then
    rm -rf "$LOCK"; continue
  fi
  sleep 1
done
[ "$LOCKED" = "1" ] || { echo "等待安装锁超时(300s),请稍后重试" >&2; exit 1; }
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; [ -n "${PKG_TMP:-}" ] && rm -rf "$PKG_TMP"' EXIT

# ---------- 1) Node:优先复用系统已有 node(fnm/volta/nvm/PATH 均可,>=22 且带 npm);
#                否则安装 nodejs.org 最新 LTS(DSH_RT_NO_SYSTEM_NODE=1 强制走此路径) ----------
MIN_NODE=22
SYS_NODE=""; SYS_NPM=""
if [ "${DSH_RT_NO_SYSTEM_NODE:-}" != "1" ]; then
  CAND="$(command -v node 2>/dev/null || true)"
  if [ -n "$CAND" ]; then
    # 解析 fnm/volta 等 shim 符号链接到真实二进制(fnm 的 multishell 临时目录会随 shell 退出失效)
    CAND="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$CAND" 2>/dev/null || echo "$CAND")"
    V="$("$CAND" --version 2>/dev/null | sed 's/^v//' || true)"
    M="${V%%.*}"
    if [ -n "$M" ] && [ "$M" -ge "$MIN_NODE" ]; then
      CAND_NPM="$(dirname "$CAND")/npm"
      if [ -x "$CAND_NPM" ]; then
        SYS_NODE="$CAND"; SYS_NPM="$CAND_NPM"
      elif command -v npm >/dev/null 2>&1; then
        SYS_NODE="$CAND"; SYS_NPM="$(command -v npm)"
      fi
    fi
  fi
fi
if [ -n "$SYS_NODE" ]; then
  NODE_BIN="$SYS_NODE"; NPM_BIN="$SYS_NPM"
  CUR_VER="$("$NODE_BIN" --version 2>/dev/null | sed 's/^v//' || true)"
  h1 "1) Node 运行时(复用系统 node v$CUR_VER)"
  ok "$NODE_BIN"
  # 此前安装过的自带 node 不再需要,腾出空间
  [ -x "$NODE_DIR/bin/node" ] && [ "$NODE_DIR/bin/node" != "$SYS_NODE" ] && rm -rf "$NODE_DIR"
else
  h1 "1) Node 运行时(nodejs.org 最新 LTS)"
  LTS_VER="$(curl -fsS --max-time 15 https://nodejs.org/dist/index.json 2>/dev/null \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((e["version"].lstrip("v") for e in d if e.get("lts") is not False),""))' 2>/dev/null || true)"
  [ -n "$LTS_VER" ] || LTS_VER="24.19.0"
  CUR_VER="$("$NODE_BIN" --version 2>/dev/null | sed 's/^v//' || true)"
  if [ "$CUR_VER" != "$LTS_VER" ]; then
    CACHE="$RT_HOME/.cache"; mkdir -p "$CACHE"
    TAR="$CACHE/node-v$LTS_VER-darwin-$ARCH.tar.gz"
    if [ ! -f "$TAR" ]; then
      echo "  ${D}下载 node-v$LTS_VER-darwin-$ARCH.tar.gz ...${R}"
      curl -fSL $PB --max-time 900 -o "$TAR" "https://nodejs.org/dist/v$LTS_VER/node-v$LTS_VER-darwin-$ARCH.tar.gz"
    fi
    # 校验 fail-closed:拿不到 SHASUMS 也中止,绝不安装未校验的二进制
    curl -fsS --max-time 60 -o "$CACHE/SHASUMS256.txt" "https://nodejs.org/dist/v$LTS_VER/SHASUMS256.txt" 2>/dev/null \
      || { warn "SHASUMS256.txt 下载失败,无法校验 node 安装包"; rm -f "$TAR"; exit 1; }
    ( cd "$CACHE" && grep "  node-v$LTS_VER-darwin-$ARCH.tar.gz$" SHASUMS256.txt | shasum -a 256 -c - >/dev/null ) \
      || { warn "SHA-256 校验失败"; rm -f "$TAR"; exit 1; }
    TMP="$(mktemp -d /tmp/dsh-install.XXXXXX)"
    tar -xzf "$TAR" -C "$TMP" --strip-components=1
    rm -rf "$NODE_DIR"
    mkdir -p "$NODE_DIR/bin" "$NODE_DIR/lib/node_modules"
    cp -P "$TMP/bin/node" "$NODE_DIR/bin/node"
    cp -P "$TMP/bin/npm" "$NODE_DIR/bin/npm"
    cp -R "$TMP/lib/node_modules/npm" "$NODE_DIR/lib/node_modules/"
    chmod +x "$NODE_DIR/bin/node" "$NODE_DIR/bin/npm"
    # strip 符号表再瘦 ~23MB;strip 使原签名失效,立即 ad-hoc 重签
    if ! strip -x "$NODE_DIR/bin/node" 2>/dev/null || ! codesign --force -s - "$NODE_DIR/bin/node" 2>/dev/null; then
      cp -P "$TMP/bin/node" "$NODE_DIR/bin/node"
    fi
    rm -rf "$TMP"
    ok "Node v$LTS_VER 安装完成"
  else
    ok "已是最新 v$CUR_VER,跳过"
  fi
fi

# ---------- 2) dsh + daemon 并行安装(节省 3-5 秒) ----------
h1 "2) dsh(@deepseek-ai/dsh@latest)"
# pnpm:内容寻址存储 + 硬链接 → 升级只拉差异、node_modules 体积小、安装快。
# 用 npm exec 按需引导(复用上文确定的 NPM_BIN,不污染系统;pnpm@10 大版本固定)。
npx_pnpm() { "$NPM_BIN" exec --yes --package=pnpm@10 -- pnpm "$@"; }
PNPM_STORE="$RT_HOME/.pnpm-store"
# 自动跟随上游 latest 标签(稳定版本)
# 可通过 DSH_VERSION 环境变量覆盖到指定版本(如 DSH_VERSION=0.1.1-rc.2 bash install.sh)
DSH_VERSION="${DSH_VERSION:-latest}"
LATEST="$DSH_VERSION"
CUR_DSH="$("$NODE_BIN" -e 'console.log(require(process.argv[1]).version)' "$DSH_PKG" 2>/dev/null || true)"

# 检查是否需要编译 daemon (用于并行决策)
NEED_COMPILE_DAEMON=0
if [ -f "$ROOT/src/daemon.c" ] && command -v clang >/dev/null && [ ! -x "$ROOT/daemon" ]; then
  SRC_MD5="$(md5 -q "$ROOT/src/daemon.c" 2>/dev/null || true)"
  if [ ! -x "$RT_HOME/daemon" ] || [ "$SRC_MD5" != "$(cat "$RT_HOME/.daemon.md5" 2>/dev/null || true)" ]; then
    NEED_COMPILE_DAEMON=1
  fi
fi

if [ -n "$LATEST" ] && [ "$CUR_DSH" != "$LATEST" ] || [ -z "$CUR_DSH" ]; then
  printf '{"name":"dsh-runtime-app","private":true,"dependencies":{"@deepseek-ai/dsh":"%s"},"pnpm":{"onlyBuiltDependencies":["node-pty","koffi","@deepseek-ai/dsh-subprocess-local"]}}\n' "${LATEST:-latest}" > "$APP_DIR/package.json"
  [ -f "$ROOT/pnpm-lock.yaml" ] && cp "$ROOT/pnpm-lock.yaml" "$APP_DIR/"
  
  NPM_START="$SECONDS"
  if [ -z "$CUR_DSH" ] || [ -n "${DSH_RT_FORCE_REINSTALL:-}" ]; then
    # 首次安装或强制重装
    echo "  ${D}pnpm install dsh@${LATEST:-latest}(首次约 1~5 分钟视网络)${R}"
    NPM_CMD="install"; NPM_TARGET=""
  else
    # 增量升级 (仅下载变化的包)
    echo "  ${D}增量升级 dsh: $CUR_DSH → ${LATEST} (pnpm 仅拉差异包)${R}"
    NPM_CMD="update"; NPM_TARGET="@deepseek-ai/dsh"
  fi
  
  # 并行启动 npm 操作和 daemon 编译
  if [ "$NEED_COMPILE_DAEMON" = "1" ]; then
    echo "  ${D}同时编译 daemon (并行优化)...${R}"
    (
      clang "${DAEMON_CFLAGS[@]}" -o "$RT_HOME/daemon.tmp" "$ROOT/src/daemon.c" 2>"$RT_HOME/.daemon.build.log" \
        && mv "$RT_HOME/daemon.tmp" "$RT_HOME/daemon" \
        && echo "$SRC_MD5" > "$RT_HOME/.daemon.md5"
    ) &
    DAEMON_PID=$!
  fi
  
  # npm install/update (主进程等待)
  if ! PATH="$NODE_DIR/bin:$PATH" NODE_OPTIONS="--max-old-space-size=4096" npx_pnpm \
       --dir "$APP_DIR" --store-dir "$PNPM_STORE" $NPM_CMD $NPM_TARGET --prefer-offline; then
    # 如果是 update 失败,尝试回退到全量 install
    if [ "$NPM_CMD" = "update" ]; then
      warn "增量升级失败,回退到全量重装..."
      rm -rf "$APP_DIR/node_modules" "$APP_DIR/pnpm-lock.yaml"
      if ! PATH="$NODE_DIR/bin:$PATH" NODE_OPTIONS="--max-old-space-size=4096" npx_pnpm \
           --dir "$APP_DIR" --store-dir "$PNPM_STORE" install --prefer-offline; then
        [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
        warn "dsh 安装失败"
        exit 1
      fi
    else
      [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
      warn "dsh 安装失败"
      exit 1
    fi
  fi
  ok "完成($(( SECONDS - NPM_START ))s)"
  
  # 等待 daemon 编译完成
  if [ -n "${DAEMON_PID:-}" ]; then
    if wait "$DAEMON_PID" 2>/dev/null; then
      ok "daemon 编译完成(并行)"
    else
      warn "daemon 并行编译失败,稍后将重试"
      rm -f "$RT_HOME/daemon" "$RT_HOME/.daemon.md5"
    fi
  fi
  
  # 深度清理 node_modules
  if [ -f "$ROOT/scripts/cleanup-deps.sh" ]; then
    echo "  ${D}清理跨平台冗余文件...${R}"
    bash "$ROOT/scripts/cleanup-deps.sh" "$APP_DIR" 2>/dev/null || true
    
    # 验证探针：确保清理未破坏运行时原生依赖(从 dsh 包目录解析——pnpm 隔离布局下
    # sharp/node-pty 是传递依赖,顶层 node_modules/ 只有 @deepseek-ai,从 APP_DIR 解析必失败)
    echo "  ${D}验证关键依赖完整性...${R}"
    if ! ( cd "$APP_DIR/node_modules/@deepseek-ai/dsh" && "$NODE_BIN" -e "require('sharp'); require('node-pty')" >/dev/null 2>&1 ); then
      warn "依赖验证失败（sharp/node-pty），回退重装"
      rm -rf "$APP_DIR/node_modules"
      if ! PATH="$NODE_DIR/bin:$PATH" NODE_OPTIONS="--max-old-space-size=4096" npx_pnpm \
           --dir "$APP_DIR" --store-dir "$PNPM_STORE" install --prefer-offline; then
        warn "回退重装失败"; exit 1
      fi
    else
      ok "关键原生依赖验证通过 (sharp/node-pty)"
    fi
  else
    find "$APP_DIR/node_modules" \( -name "*.map" -o -name "*.md" -o -name ".DS_Store" \) -delete 2>/dev/null || true
    find "$APP_DIR/node_modules" -type d \( -name test -o -name tests -o -name __tests__ \) -exec rm -rf {} + 2>/dev/null || true
  fi
  
  CUR_DSH="$("$NODE_BIN" -e 'console.log(require(process.argv[1]).version)' "$DSH_PKG")"
  ok "dsh $CUR_DSH 安装完成"
else
  ok "已是最新 $CUR_DSH,跳过"
fi

# ---------- 3) run.json:守护直启 dsh 的运行时位置(单一事实源) ----------
h1 "3) 运行时配置(run.json)"
DSH_BIN="$("$NODE_BIN" -e '
  const { join, dirname } = require("path");
  const p = process.argv[1];
  const pkg = require(p);
  const bin = typeof pkg.bin === "string" ? pkg.bin : (pkg.bin && pkg.bin.dsh) || "lib/bin.js";
  console.log(join(dirname(p), bin));
' "$DSH_PKG")"
"$NODE_BIN" -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({ node: process.argv[2], dsh: process.argv[3] }) + "\n");
' "$RT_HOME/run.json" "$NODE_BIN" "$DSH_BIN"
ok "node=$NODE_BIN"
ok "dsh=$DSH_BIN"

# ---------- 4) 守护二进制(发行包预编译优先;否则本地 clang 编译;均 ad-hoc 签名) ----------
h1 "4) 守护(按需唤醒,~1.3MB RSS)"
install_daemon() { chmod +x "$RT_HOME/daemon"; codesign --force -s - "$RT_HOME/daemon" 2>/dev/null || true; }
if [ -x "$ROOT/daemon" ] && [ "$(file -b "$ROOT/daemon" | grep -c "$(uname -m)")" = "1" ]; then
  cp "$ROOT/daemon" "$RT_HOME/daemon"; install_daemon
  ok "发行包预编译($(uname -m))"
elif [ -f "$ROOT/src/daemon.c" ] && command -v clang >/dev/null; then
  SRC_MD5="$(md5 -q "$ROOT/src/daemon.c" 2>/dev/null || true)"
  if [ -x "$RT_HOME/daemon" ] && [ "$SRC_MD5" != "" ] && [ "$SRC_MD5" = "$(cat "$RT_HOME/.daemon.md5" 2>/dev/null || true)" ]; then
    install_daemon
    ok "守护已是最新(daemon.c 未变,免编译)"
  else
    echo "  ${D}clang 编译中 ...${R}"
    clang "${DAEMON_CFLAGS[@]}" -o "$RT_HOME/daemon" "$ROOT/src/daemon.c" || { warn "守护编译失败"; exit 1; }
    [ -n "$SRC_MD5" ] && printf '%s\n' "$SRC_MD5" > "$RT_HOME/.daemon.md5"
    install_daemon
    ok "本地 clang 编译完成"
  fi
elif [ -x "$RT_HOME/daemon" ]; then
  ok "沿用已安装"
else
  warn "未找到可用守护(需预编译 daemon 或 clang),PWA 自动拉起不可用"
fi

# ---------- 4b) 更新脚本部署(daemon/updater 通过 $RT_HOME/scripts/ 调用;发行包临时目录装完即删,不可回溯) ----------
if [ -d "$ROOT/scripts" ]; then
  mkdir -p "$RT_HOME/scripts"
  for s in update-dsh.sh cleanup-deps.sh; do
    if [ -f "$ROOT/scripts/$s" ]; then
      cp "$ROOT/scripts/$s" "$RT_HOME/scripts/$s"
      chmod 700 "$RT_HOME/scripts/$s"
    fi
  done
fi

# ---------- 5) LaunchAgent 注册(零常驻 socket activation:launchd 持有 socket,连接到达才拉起守护) ----------
h1 "5) LaunchAgent(零常驻,首次访问自动唤醒)"
AGENT_OK=0
if [ "${DSH_INSTALL_NO_AGENT:-}" != "1" ]; then
  TPL="$ROOT/launchd/com.dshpwa.daemon.plist"
  [ -f "$TPL" ] || TPL="$ROOT/com.dshpwa.daemon.plist"
  if [ -f "$TPL" ]; then
    AGENT_DIR="$HOME/Library/LaunchAgents"
    AGENT="$AGENT_DIR/com.dshpwa.daemon.plist"
    mkdir -p "$AGENT_DIR"
    sed -e "s|__DAEMON_BIN__|$RT_HOME/daemon|g" \
        -e "s|__HOME__|$HOME|g" \
        -e "s|__RT_HOME__|$RT_HOME|g" \
        -e "s|__RT_STATE__|$RT_STATE|g" \
        -e "s|__LOG_DIR__|$LOG_DIR|g" \
        -e "s|__DSH_RT_PORT__|$PORT|g" "$TPL" > "$AGENT"
    # plist 含路径拓扑(非密钥),但仍收 0600 最小暴露(默认 umask 022 会生成 0644)
    chmod 600 "$AGENT"
    # 清理旧名残留(改名前的 com.dshlauncher.daemon),避免旧守护占住端口
    launchctl bootout "gui/$(id -u)/com.dshlauncher.daemon" 2>/dev/null || true
    rm -f "$AGENT_DIR/com.dshlauncher.daemon.plist"
    # 升级重载:先 bootout 旧 job(终止在跑守护并释放其 socket)再 bootstrap 新 plist,
    # 确保重载后由新 job 的 launchd 持有监听 socket。
    # 零常驻:无 RunAtLoad/KeepAlive,绝不 kickstart——kick 会立即拉起守护,违背零常驻设计;
    # 登录后首个 TCP 连接(PWA 点图标)才触发激活。
    launchctl bootout "gui/$(id -u)/com.dshpwa.daemon" 2>/dev/null || true
    # 端口占用检测:bootout 已释放旧 job 的 socket,此刻仍被占 → 是其他进程占着端口。
    # 若不拦截,launchd bind 失败会导致守护永不激活(静默失效),install 还会 open 占用者的页面。
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
      sleep 1  # bootout 后 socket 释放可能有短暂延迟,复查一次
      if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
        echo "端口 $PORT 已被其他进程占用,LaunchAgent 无法监听,守护将无法激活。" >&2
        echo "请释放占用进程(查看:lsof -iTCP:$PORT -sTCP:LISTEN),或用 DSH_RT_PORT=<空闲端口> 重新安装。" >&2
        exit 1
      fi
    fi
    launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null \
      || launchctl enable "gui/$(id -u)/com.dshpwa.daemon" 2>/dev/null || true
    AGENT_OK=1
    ok "com.dshpwa.daemon 已注册(launchd 持有 socket,零常驻;首次访问 http://127.0.0.1:$PORT/ 自动唤醒)"
  else
    warn "缺少 plist 模板,未注册守护"
  fi
  
  # 注册自动更新器(定时任务,每天凌晨 2:30)
  UPDATER_TPL="$ROOT/launchd/com.dshpwa.updater.plist"
  if [ -f "$UPDATER_TPL" ] && [ "${DSH_RT_NO_AUTO_UPDATE:-}" != "1" ]; then
    UPDATER="$AGENT_DIR/com.dshpwa.updater.plist"
    sed -e "s|__HOME__|$HOME|g" \
        -e "s|__RT_HOME__|$RT_HOME|g" \
        -e "s|__RT_STATE__|$RT_STATE|g" \
        -e "s|__LOG_DIR__|$LOG_DIR|g" \
        -e "s|__DSH_RT_PORT__|$PORT|g" "$UPDATER_TPL" > "$UPDATER"
    chmod 600 "$UPDATER"
    launchctl bootstrap "gui/$(id -u)" "$UPDATER" 2>/dev/null \
      || launchctl enable "gui/$(id -u)/com.dshpwa.updater" 2>/dev/null || true
    ok "com.dshpwa.updater 已注册(每天凌晨 2:30 自动检查更新)"
  fi
else
  # 测试模式(不注册 agent)同样校验端口,让占用端口配置尽早暴露而非静默通过
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
    echo "端口 $PORT 已被占用,请用 DSH_RT_PORT=<空闲端口> 重新安装。" >&2
    exit 1
  fi
  ok "跳过(DSH_INSTALL_NO_AGENT)"
fi

# ---------- 6) 完成:自动打开 dsh 页面 ----------
SECS=$(( $(date +%s) - START_TS ))
echo
echo "${G}✓${R} ${B}安装完成${R}(${D}${SECS}s${R})"
echo "  ${D}node v$("$NODE_BIN" --version 2>/dev/null | sed 's/^v//' || echo -) · dsh $CUR_DSH · 运行时 $RT_HOME${R}"
if [ "$AGENT_OK" = "1" ]; then
  open "http://127.0.0.1:$PORT/" 2>/dev/null || true
  echo "  ${D}已自动打开 http://127.0.0.1:$PORT/${R}"
fi
