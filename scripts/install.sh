#!/usr/bin/env bash
set -euo pipefail
# 安装产物默认仅属主可读(状态/日志目录另有显式 chmod 0700 兜底,见下)
umask 077
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
if [ ! -f "$ROOT/src/daemon.c" ] && [ ! -f "$ROOT/daemon.c" ] && [ ! -f "$ROOT/daemon" ]; then
  h1 "自动下载发行包(releases/${RELEASE_TAG})"
  PKG_TMP="$(mktemp -d /tmp/dsh-pwa.XXXXXX)"
  # 立即注册清理:下载/解压/校验任一步失败都不泄漏临时目录
  # (拿到安装锁后会被下方含锁清理的完整 trap 覆盖,其已含 PKG_TMP 清理)
  trap '[ -n "${PKG_TMP:-}" ] && rm -rf "$PKG_TMP" 2>/dev/null || true' EXIT
  DL_URL="https://github.com/3kaiu/dsh-pwa/releases/${RELEASE_TAG}/download/dsh-pwa.zip"
  SHA_URL="https://github.com/3kaiu/dsh-pwa/releases/${RELEASE_TAG}/download/dsh-pwa.zip.sha256"
  
  # 下载发行包 + SHA256
  curl -fsSL --max-time 300 -o "$PKG_TMP/pkg.zip" "$DL_URL" \
    || { echo "发行包下载失败(${DL_URL})" >&2; exit 1; }
  curl -fsSL --max-time 60 -o "$PKG_TMP/pkg.zip.sha256" "$SHA_URL" 2>/dev/null \
    || { warn "SHA256 校验文件缺失,发行包完整性无法验证"; rm -f "$PKG_TMP/pkg.zip"; exit 1; }
  
  # 校验 fail-closed:不通过则中止。
  # 直接比对哈希,而不是 `shasum -a 256 -c pkg.zip.sha256`:后者按清单里记录的**文件名**
  # 找文件,而生成端(.github/workflows/release.yml:74)记录的资产名是 dsh-pwa.zip、
  # 校验端下载名是 pkg.zip → shasum 报 "dsh-pwa.zip: No such file or directory" 并 rc=1,
  # 恒落入本分支,curl|bash 安装 100% 中断(已按 release.yml 生成端忠实复现实测)。
  # 比对哈希可永久消除「两侧文件名必须一致」这一隐式契约,且对清单格式(裸哈希/带文件名/
  # 二进制模式 *name)与本地命名都不敏感。
  EXPECTED_SHA="$(awk 'NF {print $1; exit}' "$PKG_TMP/pkg.zip.sha256" 2>/dev/null || true)"
  ACTUAL_SHA="$(shasum -a 256 "$PKG_TMP/pkg.zip" 2>/dev/null | awk '{print $1}' || true)"
  if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    warn "发行包 SHA-256 校验失败(清单期望 ${EXPECTED_SHA:-<空>},实际下载 ${ACTUAL_SHA:-<空>})"
    rm -rf "$PKG_TMP"; exit 1
  fi
  
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
# plist 模板经 sed(分隔符 |、替换串中 & 有特殊含义)注入路径:路径含这两个字符
# 会产出损坏的 plist,替换前校验、fail-closed 拒绝(LOG_DIR 由 RT_STATE 派生,已覆盖)
for _P in "$HOME" "$RT_HOME" "$RT_STATE"; do
  case "$_P" in
    *'|'*|*'&'*)
      echo "路径含 | 或 &,无法生成 LaunchAgent 配置:$_P" >&2
      exit 1
      ;;
  esac
done
# daemon 编译统一参数(两处编译路径共用;universal binary 双架构,Intel Mac 也产出 arm64+x86_64)
DAEMON_CFLAGS=(-O2 -Wall -Wextra -arch arm64 -arch x86_64)
# daemon 源码路径兼容:仓库内为 src/daemon.c;发行包内为包根 daemon.c(两种布局都识别)
DAEMON_SRC=""
for _c in "$ROOT/src/daemon.c" "$ROOT/daemon.c"; do
  [ -f "$_c" ] && { DAEMON_SRC="$_c"; break; }
done
NODE_DIR="$RT_HOME/node"
APP_DIR="$RT_HOME/app"
NODE_BIN="$NODE_DIR/bin/node"
NPM_BIN="$NODE_DIR/bin/npm"
DSH_PKG="$APP_DIR/node_modules/@deepseek-ai/dsh/package.json"
ARCH="$(uname -m | sed 's/x86_64/x64/')"
mkdir -p "$RT_HOME" "$RT_STATE" "$LOG_DIR" "$NODE_DIR" "$APP_DIR" "$DSH_HOME"
# 含 token 的状态/日志目录必须 0700:mkdir -p 对已存在目录不会收紧权限(daemon 的
# mkdir(LOG_DIR,0700) 对已存在目录静默失败),脚本顶部 umask 077 只保护新建 → 显式 chmod
# 兜底并修复存量目录
chmod 0700 "$RT_STATE" "$LOG_DIR"

# 安装锁(并发互斥:双击连点/重复安装时后到者等待;仅属主进程已死才可抢占——
# 旧逻辑按 10 分钟锁龄抢占活锁,慢网首装实测 >12 分钟,会导致两个安装互相破坏)
LOCK="$RT_HOME/.install.lock"
LOCKED=0
for _ in $(seq 1 300); do
  if mkdir "$LOCK" 2>/dev/null; then
    echo "$$" > "$LOCK/pid" 2>/dev/null || true
    # 写后复核:mkdir→写 pid 的微窗口内锁可能被抢占者删掉重建(空 pid 会被误判陈旧)。
    # pid 仍是自己才真正持锁——活 pid 的锁绝不会被抢占,复核通过即安全;
    # 不一致说明实际未拿到,继续循环重试
    if [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$$" ]; then
      LOCKED=1; break
    fi
    continue
  fi
  LPID="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -z "$LPID" ] || ! kill -0 "$LPID" 2>/dev/null; then
    # TOCTOU 防护:读到死 pid 到执行删除之间,锁可能被其他等待进程抢占重建(活锁)。
    # 1) O_EXCL 原子创建 claim 文件独占抢占权:claim 存在期间锁目录无法被 mkdir,
    #    多个等待者只有一个能走到删除,新持有者也不可能中途出现
    if ( set -C; echo "$$" > "$LOCK/claim" ) 2>/dev/null; then
      sleep 0.2  # 等待可能正处于 mkdir→写 pid 微窗口的新持有者完成落笔
      # 2) 复读 pid 仍是最初判死的值才删(陈旧锁连同 claim 一并删除);不一致说明
      #    锁刚易主(活锁),只归还 claim,不动锁
      if [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$LPID" ]; then
        rm -rf "$LOCK"
      else
        rm -f "$LOCK/claim" 2>/dev/null || true
      fi
    else
      # 已有等待者在抢占:活着的等它完成;死了的清残留 claim(否则会永远挡住后来者)
      CPID="$(cat "$LOCK/claim" 2>/dev/null || true)"
      if [ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null; then
        sleep 0.2
      else
        rm -f "$LOCK/claim" 2>/dev/null || true
      fi
    fi
    continue
  fi
  sleep 1
done
[ "$LOCKED" = "1" ] || { echo "等待安装锁超时(300s),请稍后重试" >&2; exit 1; }
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; [ -n "${PKG_TMP:-}" ] && rm -rf "$PKG_TMP"' EXIT

# 活动会话协调:升级/重装会替换 node_modules,正在运行的 dsh 从半更新的依赖树读代码会崩溃或
# 行为异常。与 update-dsh.sh 同源策略:先探测守护 /health,若 dsh 在跑则经 /stop 优雅停掉,
# 并等它真正退出后再动依赖树。本脚本此刻已持有 .install.lock,守护 update_locked() 会拒绝
# 重新拉起 dsh,因此停下后不会被引导页立刻唤醒(等本次装完自然恢复)。
# /health 不可达(未安装/守护未激活)→ dsh 必然没在跑,直接返回。
# --noproxy '*':守护恒在回环地址,而用户环境可能设了 http_proxy(代理不可达/不转发回环时
# curl 会一直挂到超时)→ 会误判「dsh 未运行」而在用户活跃时替换依赖树,故显式绕过代理。
stop_active_dsh() {
  local port="${1:-3080}" health=""
  health="$(curl -s -m 2 --noproxy '*' "http://127.0.0.1:$port/health" 2>/dev/null || true)"
  printf '%s' "$health" | grep -q '"dsh"[[:space:]]*:[[:space:]]*true' || return 0
  echo "  ${D}检测到 dsh 正在运行,先优雅停止(避免从半更新的依赖树启动)...${R}"
  curl -fsS --max-time 5 --noproxy '*' -X POST -H "Origin: http://127.0.0.1:$port" \
    "http://127.0.0.1:$port/stop" >/dev/null 2>&1 || true
  # 等待停止完成(daemon 侧 stop_dsh 最长 6s;给 7s 余量后不再阻塞)
  for _ in $(seq 1 14); do
    health="$(curl -s -m 2 --noproxy '*' "http://127.0.0.1:$port/health" 2>/dev/null || true)"
    printf '%s' "$health" | grep -q '"dsh"[[:space:]]*:[[:space:]]*true' || return 0
    sleep 0.5
  done
  warn "dsh 仍在运行(停止超时),继续安装;守护持锁期间不会重新拉起"
  return 0
}

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
if [ -n "$DAEMON_SRC" ] && command -v clang >/dev/null && [ ! -x "$ROOT/daemon" ]; then
  SRC_MD5="$(md5 -q "$DAEMON_SRC" 2>/dev/null || true)"
  if [ ! -x "$RT_HOME/daemon" ] || [ "$SRC_MD5" != "$(cat "$RT_HOME/.daemon.md5" 2>/dev/null || true)" ]; then
    NEED_COMPILE_DAEMON=1
  fi
fi

if [ -n "$LATEST" ] && [ "$CUR_DSH" != "$LATEST" ] || [ -z "$CUR_DSH" ]; then
  printf '{"name":"dsh-runtime-app","private":true,"dependencies":{"@deepseek-ai/dsh":"%s"},"pnpm":{"onlyBuiltDependencies":["node-pty","koffi","@deepseek-ai/dsh-subprocess-local"]}}\n' "${LATEST:-latest}" > "$APP_DIR/package.json"
  # A5:依赖树的完整性锚点。发行包携带 release.yml 现场生成、并经该 workflow 的端到端冒烟
  # 真实验证过的 pnpm-lock.yaml。旧实现只是「有就拷过来」,从不冻结 —— 于是 lock 与
  # package.json 一旦不一致,pnpm 会**静默重新解析**整棵树,integrity 锚点形同虚设;
  # 源码树安装($ROOT 无 lock)更是每次都现场解析,连一句提示都没有。
  # 现在:拷进 APP_DIR 并在**首次安装**路径上冻结;缺失时显式告警而非静默降级。
  # 只冻 install 不冻 update —— `pnpm update` 的目的就是移动版本,冻结会自相矛盾。
  LOCK_ARG=""
  if [ -f "$ROOT/pnpm-lock.yaml" ]; then
    cp "$ROOT/pnpm-lock.yaml" "$APP_DIR/"
    if [ "$DSH_VERSION" != "latest" ]; then
      # 锁是按 latest 解析的:指定具体版本时装它必然对不上,--frozen-lockfile 会直接报错退出
      warn "DSH_VERSION=$DSH_VERSION 与发行包锁定的依赖树不一致,本次不冻结 lockfile"
    elif [ -n "${DSH_RT_NO_FROZEN_LOCK:-}" ]; then
      warn "DSH_RT_NO_FROZEN_LOCK 已置位:跳过 --frozen-lockfile(依赖树将现场解析)"
    else
      LOCK_ARG="--frozen-lockfile"
    fi
  else
    warn "未找到 pnpm-lock.yaml:本次将现场解析依赖树(无 integrity 锚点;发行包内应携带该文件)"
  fi
  stop_active_dsh "$PORT"   # 依赖树即将被替换:先停掉正在运行的 dsh
  
  NPM_START="$SECONDS"
  if [ -z "$CUR_DSH" ] || [ -n "${DSH_RT_FORCE_REINSTALL:-}" ]; then
    # 首次安装或强制重装
    echo "  ${D}pnpm install dsh@${LATEST:-latest}(首次约 1~5 分钟视网络)${R}"
    NPM_CMD="install"; NPM_TARGET=""; NPM_EXTRA="$LOCK_ARG"
  else
    # 增量升级 (仅下载变化的包)
    echo "  ${D}增量升级 dsh: $CUR_DSH → ${LATEST} (pnpm 仅拉差异包)${R}"
    NPM_CMD="update"; NPM_TARGET="@deepseek-ai/dsh"; NPM_EXTRA=""
  fi
  
  # 并行启动 npm 操作和 daemon 编译
  if [ "$NEED_COMPILE_DAEMON" = "1" ]; then
    echo "  ${D}同时编译 daemon (并行优化)...${R}"
    (
      clang "${DAEMON_CFLAGS[@]}" -o "$RT_HOME/daemon.tmp" "$DAEMON_SRC" 2>"$RT_HOME/.daemon.build.log" \
        && mv "$RT_HOME/daemon.tmp" "$RT_HOME/daemon" \
        && echo "$SRC_MD5" > "$RT_HOME/.daemon.md5"
    ) &
    DAEMON_PID=$!
  fi
  
  # npm install/update (主进程等待)
  # 追加而非覆盖:用户可能已设 NODE_OPTIONS(如企业代理需 --use-system-ca),覆盖会静默丢弃。
  if ! PATH="$NODE_DIR/bin:$PATH" NODE_OPTIONS="--max-old-space-size=4096${NODE_OPTIONS:+ $NODE_OPTIONS}" npx_pnpm \
       --dir "$APP_DIR" --store-dir "$PNPM_STORE" $NPM_CMD $NPM_TARGET $NPM_EXTRA --prefer-offline; then
    # 如果是 update 失败,尝试回退到全量 install
    if [ "$NPM_CMD" = "update" ]; then
      warn "增量升级失败,回退到全量重装..."
      rm -rf "$APP_DIR/node_modules" "$APP_DIR/pnpm-lock.yaml"
      # 追加而非覆盖:用户可能已设 NODE_OPTIONS(如企业代理需 --use-system-ca),覆盖会静默丢弃。
      if ! PATH="$NODE_DIR/bin:$PATH" NODE_OPTIONS="--max-old-space-size=4096${NODE_OPTIONS:+ $NODE_OPTIONS}" npx_pnpm \
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
      # 追加而非覆盖:用户可能已设 NODE_OPTIONS(如企业代理需 --use-system-ca),覆盖会静默丢弃。
      if ! PATH="$NODE_DIR/bin:$PATH" NODE_OPTIONS="--max-old-space-size=4096${NODE_OPTIONS:+ $NODE_OPTIONS}" npx_pnpm \
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
# 架构兼容判定:macOS `file` 对 universal 二进制逐架构各输出一行("arm64" 出现多次),
# 故不能用 `grep -c "$(uname -m)" = 1`——恒为 2,预编译分支永不命中,发行包被迫本地重编译
# (违背"免本地编译"承诺,且无 clang 的机器直接退化)。改用子串匹配:含本机架构即可用。
if [ -x "$ROOT/daemon" ] && [[ "$(file -b "$ROOT/daemon" 2>/dev/null)" == *"$(uname -m)"* ]]; then
  cp "$ROOT/daemon" "$RT_HOME/daemon"; install_daemon
  # 一致性记录:优先用发行包随附的 .daemon.md5(release.yml 依打包源码生成);缺失则就地
  # 计算源码指纹。使后续源码安装能据此判断免编译,而非因缺记录反复重编译。
  if [ -f "$ROOT/.daemon.md5" ]; then
    cp "$ROOT/.daemon.md5" "$RT_HOME/.daemon.md5"
  elif [ -n "$DAEMON_SRC" ]; then
    SRC_MD5="$(md5 -q "$DAEMON_SRC" 2>/dev/null || true)"
    [ -n "$SRC_MD5" ] && printf '%s\n' "$SRC_MD5" > "$RT_HOME/.daemon.md5"
  fi
  ok "发行包预编译($(uname -m))"
elif [ -n "$DAEMON_SRC" ] && command -v clang >/dev/null; then
  SRC_MD5="$(md5 -q "$DAEMON_SRC" 2>/dev/null || true)"
  if [ -x "$RT_HOME/daemon" ] && [ "$SRC_MD5" != "" ] && [ "$SRC_MD5" = "$(cat "$RT_HOME/.daemon.md5" 2>/dev/null || true)" ]; then
    install_daemon
    ok "守护已是最新(daemon.c 未变,免编译)"
  else
    echo "  ${D}clang 编译中 ...${R}"
    clang "${DAEMON_CFLAGS[@]}" -o "$RT_HOME/daemon" "$DAEMON_SRC" || { warn "守护编译失败"; exit 1; }
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
  for s in update-dsh.sh cleanup-deps.sh dsh-probe.sh; do
    if [ -f "$ROOT/scripts/$s" ]; then
      cp "$ROOT/scripts/$s" "$RT_HOME/scripts/$s"
      chmod 700 "$RT_HOME/scripts/$s"
    fi
  done
fi

# ---------- 4b2) 包装器**自身**版本(自我升级的可见性基础) ----------
# DSH_VERSION 是 dsh 的版本;包装器此前**完全没有版本标识**,于是自动更新只更新 dsh,
# 装了旧包装器的用户永远不知道自己落后(v0.3.3 之前的安装更是根本装不上)。
# 来源优先级:发行包内 VERSION(release.yml 写入 tag)> git describe(从源码树运行)
#            > DSH_RT_RELEASE_TAG > unknown。
# **不写死常量**:可验证的数字靠手写正是本项目两次踩到的漂移根因。
WRAPPER_VERSION=""
if [ -f "$ROOT/VERSION" ]; then
  WRAPPER_VERSION="$(head -n 1 "$ROOT/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
elif [ -d "$ROOT/.git" ] && command -v git >/dev/null 2>&1; then
  WRAPPER_VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || true)"
fi
[ -n "$WRAPPER_VERSION" ] || WRAPPER_VERSION="$RELEASE_TAG"
[ -n "$WRAPPER_VERSION" ] || WRAPPER_VERSION="unknown"
printf '%s\n' "$WRAPPER_VERSION" > "$RT_HOME/.wrapper-version"
chmod 600 "$RT_HOME/.wrapper-version" 2>/dev/null || true

# ---------- 4c) 暖机:安装后预热 NODE_COMPILE_CACHE 与文件系统缓存 ----------
# 零常驻不改:暖机是「安装时一次性」行为,不是登录常驻。启动守护前台模式,
# 触发 /wake → 等 dsh 就绪 → /stop → kill 守护。失败只 warn,不阻断安装。
#
# 可观测性(勿回退):暖机允许失败,但**静默失败**不可接受。实测 run 34631617230:
# 暖机 4/4 次全部超时(每次跑满 60s),CI 却全绿、job 白涨 ~4m40s——因为失败只 warn,
# 且 tests/ 与 .github/ 下没有任何断言提到暖机(全仓库 grep 0 命中)。
# 故每次暖机都必须留下机器可判的痕迹:三个 marker 互斥(warmup.ok / warmup.failed /
# warmup.skipped),冒烟测试断言「三者恰有其一」——即暖机真的跑过并表过态,
# 而不是悄悄消失。「绿」从此不再等于「暖机可用」。
WARM_MARK="$RT_STATE"
rm -f "$WARM_MARK/warmup.ok" "$WARM_MARK/warmup.failed" "$WARM_MARK/warmup.skipped"
warmup_mark() { printf '%s\n' "$2" > "$WARM_MARK/warmup.$1" 2>/dev/null || true; }
WARM_CACHE_DIR="$RT_STATE/node-cache"
WARM_VER_FILE="$RT_STATE/.warmup.dsh-version"
# 暖机预算可调:冒烟测试用更短预算(其紧随其后的 3/5 步实测 dsh 数秒即就绪),
# 避免 CI 在暖机自身出问题时被「4 次 install × 60s」拖垮。非法值回退默认 60s。
WARM_TIMEOUT="${DSH_RT_WARMUP_TIMEOUT_SECS:-60}"
case "$WARM_TIMEOUT" in ''|*[!0-9]*) WARM_TIMEOUT=60 ;; esac
{ [ "$WARM_TIMEOUT" -ge 5 ] && [ "$WARM_TIMEOUT" -le 600 ]; } || WARM_TIMEOUT=60
WARM_CACHE_FILES=0
if [ -d "$WARM_CACHE_DIR" ]; then
  WARM_CACHE_FILES="$(find "$WARM_CACHE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ' || true)"
fi
WARM_CACHE_FILES="${WARM_CACHE_FILES:-0}"
h1 "4c) 暖机(填充编译缓存,加速首次启动)"
if [ "${DSH_INSTALL_NO_WARMUP:-}" = "1" ]; then
  ok "跳过(DSH_INSTALL_NO_WARMUP=1)"
  warmup_mark skipped "DSH_INSTALL_NO_WARMUP=1"
elif [ "$WARM_CACHE_FILES" -gt 0 ] && [ "$(cat "$WARM_VER_FILE" 2>/dev/null || true)" = "$CUR_DSH" ]; then
  # 幂等重跑/同版重装免做:缓存已填充且 dsh 版本未变 → 收益为零而固定耗时数十秒。
  # 版本一变缓存即失效(daemon.c 的 NODE_COMPILE_CACHE 语义),故必须按版本判定,
  # 只看「目录非空」会在升级后错误地跳过真正需要的暖机。
  ok "缓存已热(${WARM_CACHE_FILES} 个文件,dsh $CUR_DSH 未变),免做"
  warmup_mark skipped "缓存已热(${WARM_CACHE_FILES} 个文件,dsh $CUR_DSH)"
elif [ -x "$RT_HOME/daemon" ] && [ -n "$NODE_BIN" ] && [ -n "$DSH_BIN" ]; then
  # 找一个空闲端口(避免与正式端口冲突)
  WARM_PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || true)"
  WARM_RT_HOME="$(mktemp -d /tmp/dsh-warmup.XXXXXX 2>/dev/null || true)"
  if [ -z "$WARM_PORT" ] || [ -z "$WARM_RT_HOME" ]; then
    warn "无法分配临时端口或临时目录,跳过暖机"
    warmup_mark skipped "无法分配临时端口或临时目录"
    [ -n "$WARM_RT_HOME" ] && rm -rf "$WARM_RT_HOME"
  else
    WARM_ORIGIN="http://127.0.0.1:$WARM_PORT"
    # 暖机实例必须用**独立的 RT_HOME**。install.sh 整个运行期都持
    # $RT_HOME/.install.lock(内含自身存活 pid),而守护的 update_locked() 据此判定
    # 「更新进行中」并直接放弃 spawn(daemon.c:296)。同一把锁既做安装互斥、又被守护
    # 读作「node_modules 处于半更新状态」,于是暖机成了构造性死结:实测 100% 必失败
    # (CI 4/4 次超时、本地同样),与机器快慢无关。
    # 暖机是安装期的一次性进程,不该被安装器自己的锁挡住,故给它一个无锁临时 RT_HOME。
    # 守护从 RT_HOME 只读三处:run.json、.install.lock、scripts/update-dsh.sh
    # (daemon.c:119/257/539),故复制 run.json + daemon 即可;再置 NO_AUTO_UPDATE=1,
    # 免得它去找这个临时目录里并不存在的更新脚本。
    # RT_STATE 仍指向真实目录:预热目标正是 $RT_STATE/node-cache——NODE_COMPILE_CACHE
    # 由守护按 RT_STATE 计算(daemon.c:348),指错地方就白暖了。
    cp "$RT_HOME/daemon" "$WARM_RT_HOME/daemon" 2>/dev/null || true
    cp "$RT_HOME/run.json" "$WARM_RT_HOME/run.json" 2>/dev/null || true
    # 短空闲超时:stop 后守护 3s 内自停(前台模式不会真 exit,但 dsh 会停)
    DSH_RT_HOME="$WARM_RT_HOME" DSH_RT_STATE="$RT_STATE" DSH_HOME="$DSH_HOME" \
      DSH_RT_PORT="$WARM_PORT" DSH_RT_IDLE_STOP_SECS=3 DSH_RT_NO_AUTO_UPDATE=1 \
      "$WARM_RT_HOME/daemon" >/tmp/dsh-warmup.log 2>&1 &
    WDPID=$!
    # 等守护 bind 完成(最长 2s)
    for _ in $(seq 1 20); do
      curl -fsS --max-time 1 --noproxy '*' "$WARM_ORIGIN/health" >/dev/null 2>&1 && break
      sleep 0.1
    done
    # 触发唤醒
    curl -fsS --max-time 3 --noproxy '*' -X POST -H "Origin: $WARM_ORIGIN" "$WARM_ORIGIN/wake" >/dev/null 2>&1 || true
    # 等 dsh 就绪(真实系统通常 2-5s;全新安装/慢机可能更长,故预算可调,见上)
    WARM_READY=0
    for _ in $(seq 1 $(( WARM_TIMEOUT * 2 ))); do
      WARM_H="$(curl -fsS --max-time 2 --noproxy '*' "$WARM_ORIGIN/health" 2>/dev/null || true)"
      if printf '%s' "$WARM_H" | grep -q '"dsh":true'; then
        WARM_READY=1
        break
      fi
      sleep 0.5
    done
    # 收尾:无论就绪与否都先优雅停止 dsh。
    # 旧实现只在成功分支发 /stop;失败分支直接 kill 守护,而 dsh 是守护经 setsid 自成的
    # 进程组(daemon.c:339),父进程被硬杀后它会**孤儿化**并继续监听端口、常驻内存
    # (实测泄漏过 5 个:守护早已自退,dsh 仍在 127.0.0.1 上 LISTEN)。故两分支都发。
    # 先记 pid 再 /stop —— 守护停止 dsh 后会 unlink dsh.pid,那时就读不到了。
    WARM_DSH_PID="$(cat "$RT_STATE/dsh.pid" 2>/dev/null || true)"
    case "$WARM_DSH_PID" in ''|*[!0-9]*) WARM_DSH_PID="" ;; esac
    curl -fsS --max-time 3 --noproxy '*' -X POST -H "Origin: $WARM_ORIGIN" "$WARM_ORIGIN/stop" >/dev/null 2>&1 || true
    sleep 1
    if [ "$WARM_READY" = "1" ]; then
      WARM_CACHE_FILES=0
      if [ -d "$WARM_CACHE_DIR" ]; then
        WARM_CACHE_FILES="$(find "$WARM_CACHE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ' || true)"
      fi
      WARM_CACHE_FILES="${WARM_CACHE_FILES:-0}"
      if [ "$WARM_CACHE_FILES" -gt 0 ]; then
        ok "暖机完成(编译缓存已填充:${WARM_CACHE_FILES} 个文件)"
        # 记版本:下次同版重装据此免做。**仅在缓存真的落盘时记录**——否则会把
        # 「没产出缓存」误记成「已热」,导致后续永久跳过暖机。
        printf '%s\n' "$CUR_DSH" > "$WARM_VER_FILE" 2>/dev/null || true
        warmup_mark ok "${WARM_CACHE_FILES} 个缓存文件,dsh $CUR_DSH"
      else
        ok "暖机完成(缓存将在首次真实启动时生成)"
        warmup_mark ok "dsh 已就绪但未落盘缓存(旧 node 不支持 NODE_COMPILE_CACHE?)"
      fi
    else
      warn "暖机超时(dsh 未在 ${WARM_TIMEOUT}s 内就绪),不影响使用"
      # 保留现场:失败时绝不删日志。旧实现无条件 rm,使 CI 里的「超时」彻底无从诊断。
      cp /tmp/dsh-warmup.log "$LOG_DIR/warmup.log" 2>/dev/null || true
      warmup_mark failed "dsh 未在 ${WARM_TIMEOUT}s 内就绪(日志:$LOG_DIR/warmup.log)"
      if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning title=warmup::暖机超时,本次未预热(安装不受影响,首次启动较慢);日志 $LOG_DIR/warmup.log"
      fi
    fi
    # 清理:无论暖机是否成功,都 kill 守护前台进程
    kill "$WDPID" 2>/dev/null || true
    wait "$WDPID" 2>/dev/null || true
    # 兜底:按**路径**再收一遍暖机守护。
    # 理由:`$!` 未必就是最终在 listen 的那个进程 —— 实测偏差 4~15 个 pid
    # (tests/lib/daemon-helpers.sh:daemon_stop_by_binary 有完整数据),只按 pid kill 会
    # 漏掉真正的守护,而它要等空闲自停(默认 30s)才消失:在 CI 里就是作业结束时 runner 报
    # `Terminate orphan process: pid (…) (daemon)`;在用户机器上则是装完还留个监听进程。
    # WARM_RT_HOME 来自 mktemp -d(路径唯一);`^` 锚定命令行开头(守护以该路径直接启动,
    # argv[0] 即它),不会误伤 install.sh 自身或同机其他进程。
    for _WP in $(pgrep -f "^${WARM_RT_HOME}/daemon(\$| )" 2>/dev/null || true); do
      kill -TERM "$_WP" 2>/dev/null || true
    done
    # 兜底:守护被硬杀时 dsh 可能还活着 —— 失败分支的 /stop 未必生效(dsh 根本没起来时
    # 无人应答),而 dsh 因 setsid 不在守护的进程组里,不会随守护一起死。
    # 用**负 PID 打整组**,与守护自身的停止逻辑一致(daemon.c:469:负 PID 整组发信号,
    # 防 node + pty 子进程残留)。仅在 pid 仍存活时才动手;此处距 spawn 仅 1~2s,
    # pid 复用概率可忽略。
    if [ -n "$WARM_DSH_PID" ] && [ "$WARM_DSH_PID" -gt 1 ] && [ "$WARM_DSH_PID" != "$$" ] \
       && kill -0 "$WARM_DSH_PID" 2>/dev/null; then
      kill -TERM -- "-$WARM_DSH_PID" 2>/dev/null || kill -TERM "$WARM_DSH_PID" 2>/dev/null || true
      sleep 1
      if kill -0 "$WARM_DSH_PID" 2>/dev/null; then
        kill -9 -- "-$WARM_DSH_PID" 2>/dev/null || kill -9 "$WARM_DSH_PID" 2>/dev/null || true
      fi
    fi
    rm -f /tmp/dsh-warmup.log
    # 暖机实例已停:清掉它写下的状态(dsh.json/dsh.pid),否则会留下指向已死 dsh 的
    # 残留状态,干扰随后由 LaunchAgent 拉起的真实守护。
    rm -f "$RT_STATE/dsh.json" "$RT_STATE/dsh.pid"
    rm -rf "$WARM_RT_HOME"
  fi
else
  ok "跳过(缺少守护二进制 / node / dsh)"
  warmup_mark skipped "缺少守护二进制 / node / dsh"
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
    # plist 含路径拓扑(非密钥),仍显式收 0600 最小暴露
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
    # bootstrap 失败不能被 || true 静默吞掉:enable 兜底后必须用 launchctl print
    # 确认真实注册状态,否则用户看到"已注册"+自动打开浏览器,守护却从未注册(静默失效)
    if ! launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null; then
      warn "launchctl bootstrap 失败,尝试 enable 兜底(常见原因:job 已注册或被禁用)"
      launchctl enable "gui/$(id -u)/com.dshpwa.daemon" 2>/dev/null || true
    fi
    if launchctl print "gui/$(id -u)/com.dshpwa.daemon" >/dev/null 2>&1; then
      AGENT_OK=1
      ok "com.dshpwa.daemon 已注册(launchd 持有 socket,零常驻;首次访问 http://127.0.0.1:$PORT/ 自动唤醒)"
    else
      warn "LaunchAgent 注册失败(launchctl print 确认 com.dshpwa.daemon 未注册),守护不会自动拉起"
      echo "  手动恢复:launchctl bootstrap gui/$(id -u) '$AGENT'" >&2
      echo "  排查错误:launchctl print gui/$(id -u)/com.dshpwa.daemon" >&2
    fi
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
    if ! launchctl bootstrap "gui/$(id -u)" "$UPDATER" 2>/dev/null; then
      warn "updater launchctl bootstrap 失败,尝试 enable 兜底"
      launchctl enable "gui/$(id -u)/com.dshpwa.updater" 2>/dev/null || true
    fi
    if launchctl print "gui/$(id -u)/com.dshpwa.updater" >/dev/null 2>&1; then
      ok "com.dshpwa.updater 已注册(每天凌晨 2:30 自动检查更新)"
    else
      warn "自动更新器注册失败(launchctl print 确认未注册),自动更新不可用"
      echo "  手动恢复:launchctl bootstrap gui/$(id -u) '$UPDATER'" >&2
    fi
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
echo "  ${D}node v$("$NODE_BIN" --version 2>/dev/null | sed 's/^v//' || echo -) · dsh $CUR_DSH · 包装器 $WRAPPER_VERSION · 运行时 $RT_HOME${R}"
# 暖机结论必须如实出现在收尾摘要里:成功/失败/跳过三态都要点名,
# 不能只在成功时打印一行(否则「没打印」会被读成「不需要」)。
if [ -f "$RT_STATE/warmup.ok" ]; then
  echo "  ${D}暖机完成(首次启动已预热:$(cat "$RT_STATE/warmup.ok" 2>/dev/null || true))${R}"
elif [ -f "$RT_STATE/warmup.failed" ]; then
  echo "  ${Y}!${R} ${D}暖机未完成:$(cat "$RT_STATE/warmup.failed" 2>/dev/null || true)${R}"
elif [ -f "$RT_STATE/warmup.skipped" ]; then
  echo "  ${D}暖机跳过:$(cat "$RT_STATE/warmup.skipped" 2>/dev/null || true)${R}"
fi
if [ "$AGENT_OK" = "1" ]; then
  open "http://127.0.0.1:$PORT/" 2>/dev/null || true
  echo "  ${D}已自动打开 http://127.0.0.1:$PORT/${R}"
fi
