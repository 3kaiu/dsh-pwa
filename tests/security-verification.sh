#!/usr/bin/env bash
# 安全修复验证测试套件
# 验证所有已实施的安全控制是否按预期工作
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0

# 公共 helper:daemon_compile / daemon_start_foreground / daemon_wait_health / daemon_stop
# shellcheck source=/dev/null
source "$ROOT/tests/lib/daemon-helpers.sh"

# 颜色输出
if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; RST=$'\033[0m'
else
  G=""; R=""; B=""; D=""; RST=""
fi

ok()   { echo "  ${G}✓${RST} $*"; ((PASS++)) || true; }
fail() { echo "  ${R}✗${RST} $*"; ((FAIL++)) || true; }
info() { echo "  ${D}$*${RST}"; }
h1()   { echo; echo "${B}$*${RST}"; }

cd "$ROOT"

h1 "1. 供应链完整性验证"

# 1.1 检查 release.yml 是否生成 SHA256
info "检查 CI 是否生成 SHA256 校验和..."
if grep -q "shasum -a 256 dsh-pwa.zip > dsh-pwa.zip.sha256" .github/workflows/release.yml; then
  ok "Release workflow 生成 SHA256 校验和"
else
  fail "Release workflow 缺少 SHA256 生成步骤"
fi

# 1.2 检查 release.yml 是否上传 SHA256
if grep "gh release" .github/workflows/release.yml | grep -q "dsh-pwa.zip.sha256"; then
  ok "Release workflow 上传 SHA256 文件"
else
  fail "Release workflow 未上传 SHA256 文件"
fi

# 1.3 检查 install.sh 是否验证 SHA256
info "检查 install.sh 是否验证 SHA256..."
if grep -q "shasum -a 256 -c pkg.zip.sha256" scripts/install.sh; then
  ok "install.sh 验证 SHA256 校验和"
else
  fail "install.sh 缺少 SHA256 验证"
fi

# 1.4 检查 install.sh 是否 fail-closed
if grep -q 'warn "SHA256 校验文件缺失' scripts/install.sh && grep -q 'exit 1' scripts/install.sh; then
  ok "install.sh 使用 fail-closed 策略"
else
  fail "install.sh 未使用 fail-closed 策略"
fi

# 1.5 检查版本固定支持
if grep -q 'RELEASE_TAG="${DSH_RT_RELEASE_TAG:-latest}"' scripts/install.sh; then
  ok "install.sh 支持版本固定(DSH_RT_RELEASE_TAG)"
else
  fail "install.sh 不支持版本固定"
fi

# 1.6 检查 universal binary
if grep -q -- "-arch arm64 -arch x86_64" .github/workflows/release.yml; then
  ok "Release workflow 构建 universal binary"
else
  fail "Release workflow 仅构建单架构二进制"
fi

h1 "2. CSRF 防护验证"

# 2.1 运行时验证 - 启动临时 daemon 测试 CSRF
info "启动临时 daemon 进行运行时 CSRF 测试..."
TMPD="$(mktemp -d)"
TEST_PORT=$((30000 + RANDOM % 10000))

# 编译并启动 daemon
if daemon_compile "$TMPD/daemon" -arch arm64 -arch x86_64; then
  # 准备最小运行环境
  mkdir -p "$TMPD/rt" "$TMPD/state/logs" "$TMPD/home"
  echo '{"node":"/usr/bin/node","dsh":"/usr/bin/true"}' > "$TMPD/rt/run.json"
  
  # 后台启动 daemon
  export DSH_RT_HOME="$TMPD/rt" DSH_RT_STATE="$TMPD/state" DSH_HOME="$TMPD/home" DSH_RT_PORT="$TEST_PORT"
  DAEMON_PID="$(daemon_start_foreground "$TMPD/daemon" "$TMPD/daemon.log")"
  
  # 等待 daemon 就绪(梯度退避,6s 上限)
  if daemon_wait_health "$TEST_PORT" any 6; then
  # 测试1: 缺少 Origin 应返回 403
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$TEST_PORT/wake" 2>/dev/null)
  if [ "$HTTP_CODE" = "403" ]; then
    ok "CSRF 运行时：无 Origin 返回 403"
  else
    fail "CSRF 运行时：无 Origin 应返回 403，实际返回 $HTTP_CODE"
  fi
  
  # 测试2: 错误端口应返回 403（端口严格校验）
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$((TEST_PORT + 1))" \
    "http://127.0.0.1:$TEST_PORT/wake" 2>/dev/null)
  if [ "$HTTP_CODE" = "403" ]; then
    ok "CSRF 运行时：错误端口返回 403（端口严格校验）"
  else
    fail "CSRF 运行时：错误端口应返回 403，实际返回 $HTTP_CODE"
  fi
  
  # 测试3: 正确 Origin 应返回 200
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: http://127.0.0.1:$TEST_PORT" \
    "http://127.0.0.1:$TEST_PORT/wake" 2>/dev/null)
  if [ "$HTTP_CODE" = "200" ]; then
    ok "CSRF 运行时：正确 Origin 返回 200"
  else
    fail "CSRF 运行时：正确 Origin 应返回 200，实际返回 $HTTP_CODE"
  fi

  # 测试4: 恶意 Host(DNS rebinding 模拟)应返回 403
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Host: evil.com" \
    "http://127.0.0.1:$TEST_PORT/health" 2>/dev/null)
  if [ "$HTTP_CODE" = "403" ]; then
    ok "Host 校验：恶意 Host(evil.com)返回 403"
  else
    fail "Host 校验：恶意 Host 应返回 403，实际返回 $HTTP_CODE"
  fi

  # 测试5: 正常 Host(127.0.0.1:PORT)应返回 200
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$TEST_PORT/health" 2>/dev/null)
  if [ "$HTTP_CODE" = "200" ]; then
    ok "Host 校验：正常 Host(127.0.0.1:$TEST_PORT)返回 200"
  else
    fail "Host 校验：正常 Host 应返回 200，实际返回 $HTTP_CODE"
  fi
  else
    fail "daemon 未就绪，跳过运行时 CSRF 测试"
  fi
  
  # 清理
  daemon_stop "$DAEMON_PID"
  rm -rf "$TMPD"
else
  fail "daemon 编译失败，跳过运行时 CSRF 测试"
  rm -rf "$TMPD"
fi

# 2.4 代码静态检查
info "检查 daemon.c CSRF 防护代码..."
if grep -q "CSRF 防护" src/daemon.c && grep -q 'find_header(buf, "Origin")' src/daemon.c; then
  ok "daemon.c 包含 CSRF 防护逻辑"
else
  fail "daemon.c 缺少 CSRF 防护"
fi

# 2.5 检查端口严格校验
if grep -q "origin_ok" src/daemon.c && grep -q "snprintf.*http://127.0.0.1:%d" src/daemon.c; then
  ok "daemon.c 实现端口严格校验"
else
  fail "daemon.c 缺少端口严格校验"
fi

# 2.6 检查 Host 校验(DNS rebinding 防护)
if grep -q "host_ok" src/daemon.c && grep -q "snprintf.*127.0.0.1:%d" src/daemon.c; then
  ok "daemon.c 实现 Host 校验(防 DNS rebinding)"
else
  fail "daemon.c 缺少 Host 校验"
fi

h1 "3. 文件权限安全"

# 3.1 检查日志文件权限
info "检查日志文件权限设置..."
if grep -q "open(LOG_FILE.*0600" src/daemon.c; then
  ok "dsh.log 使用 0600 权限"
else
  fail "dsh.log 未使用安全权限"
fi

# 3.2 检查日志目录权限
if grep -q "mkdir(LOG_DIR, 0700)" src/daemon.c; then
  ok "LOG_DIR 使用 0700 权限"
else
  fail "LOG_DIR 未使用安全权限"
fi

# 3.3 检查状态文件权限
if grep -q 'write_file_atomic(DSH_JSON' src/daemon.c && grep -q 'write_file_atomic(PID_FILE' src/daemon.c && grep -q "open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600)" src/daemon.c; then
  ok "状态文件(dsh.json, dsh.pid)使用 0600 权限"
else
  fail "状态文件未使用安全权限"
fi

# 3.4 install.sh 必须显式收紧 RT_STATE/LOG_DIR 权限
# (umask 022 下 mkdir -p 建出 0755,且对已存在目录不生效;daemon 的 mkdir(LOG_DIR,0700)
#  对已存在目录静默失败 → 仅靠源码里的 mkdir 调用会产生"假绿",install 侧需 chmod 兜底)
if grep -q 'chmod 0700 "$RT_STATE" "$LOG_DIR"' scripts/install.sh; then
  ok "install.sh 显式 chmod 0700 RT_STATE/LOG_DIR(含存量目录)"
else
  fail "install.sh 未显式收紧 RT_STATE/LOG_DIR 权限"
fi

# 3.5 运行时验证:daemon 自建 LOG_DIR 的真实权限必须为 0700(不再只 grep 源码)
info "运行时验证 LOG_DIR 真实权限(daemon 前台启动自建目录)..."
TMPD_PERM="$(mktemp -d)"
if daemon_compile "$TMPD_PERM/daemon"; then
  mkdir -p "$TMPD_PERM/rt" "$TMPD_PERM/state" "$TMPD_PERM/home"
  echo '{"node":"/usr/bin/true","dsh":"/usr/bin/true"}' > "$TMPD_PERM/rt/run.json"
  # 不预建 logs:让 daemon 自己 mkdir(LOG_DIR, 0700),验证真实落盘权限
  export DSH_RT_HOME="$TMPD_PERM/rt" DSH_RT_STATE="$TMPD_PERM/state" DSH_HOME="$TMPD_PERM/home"
  export DSH_RT_PORT="$((30000 + RANDOM % 10000))"
  PERM_PID="$(daemon_start_foreground "$TMPD_PERM/daemon" /dev/null)"
  for _ in $(seq 1 20); do [ -d "$TMPD_PERM/state/logs" ] && break; sleep 0.2; done
  PERM_MODE="$(stat -f %Lp "$TMPD_PERM/state/logs" 2>/dev/null || true)"
  if [ "$PERM_MODE" = "700" ]; then
    ok "运行时 LOG_DIR 真实权限为 0700"
  else
    fail "运行时 LOG_DIR 权限为 ${PERM_MODE:-缺失}(应为 700,含 token 的日志可被本机其他用户枚举)"
  fi
  daemon_stop "$PERM_PID"
  rm -rf "$TMPD_PERM"
else
  fail "daemon 编译失败,无法运行时验证 LOG_DIR 权限"
  rm -rf "$TMPD_PERM"
fi

# 3.6 端口被占时 install.sh 必须显式失败(而非 launchd bind 失败后静默失效)
if grep -q 'exec 3<>"/dev/tcp/127.0.0.1/$PORT"' scripts/install.sh && \
   grep -q "DSH_RT_PORT=<空闲端口>" scripts/install.sh; then
  ok "install.sh 检测端口占用并显式报错(bootout 之后、bootstrap 之前)"
else
  fail "install.sh 未检测端口占用"
fi

h1 "4. 端口分配安全"

# 4.1 检查端口验证
info "检查端口验证逻辑..."
if grep -q "1024.*65535" scripts/install.sh; then
  ok "install.sh 验证端口范围(1024-65535)"
else
  fail "install.sh 未验证端口范围"
fi

# 4.2 检查 daemon.c 端口验证
if grep -q "parsed >= 1024 && parsed <= 65535" src/daemon.c; then
  ok "daemon.c 验证端口范围"
else
  fail "daemon.c 未验证端口范围"
fi

# 4.3 检查端口预留机制
if grep -q "pick_port_fd" src/daemon.c; then
  ok "daemon.c 使用端口预留机制(消除 TOCTOU)"
else
  fail "daemon.c 存在端口分配竞态条件"
fi

# 4.4 检查 reserve_fd 使用
if grep -q "int reserve_fd = pick_port_fd" src/daemon.c && grep -q "close(reserve_fd)" src/daemon.c; then
  ok "daemon.c 正确管理端口预留 socket"
else
  fail "daemon.c 端口预留实现不完整"
fi

h1 "5. HTTP 就绪探测强化"

# 5.1 检查探测超时
info "检查 HTTP 探测超时配置..."
if grep -q "struct timeval tv = { 3, 0 }" src/daemon.c; then
  ok "HTTP 探测超时增至 3 秒"
else
  fail "HTTP 探测超时仍为 1 秒"
fi

# 5.2 检查协议版本验证
if grep -q 'strncmp(b, "HTTP/1.", 7)' src/daemon.c; then
  ok "HTTP 探测验证协议版本(HTTP/1.x)"
else
  fail "HTTP 探测未验证协议版本"
fi

# 5.3 检查缓冲区大小
if sed -n '/^static int http_probe/,/^}/p' src/daemon.c | grep -q "char b\[512\]"; then
  ok "HTTP 探测使用足够大的缓冲区(512 字节)"
else
  info "HTTP 探测缓冲区可能需要扩大"
fi

h1 "6. 低风险问题修复"

# 6.1 检查 PID 验证
info "检查 stop_dsh 是否验证 PID..."
if sed -n '/^static void stop_dsh/,/^}/p' src/daemon.c | grep -q "kill(pid, 0)"; then
  ok "stop_dsh 在发送信号前验证 PID"
else
  fail "stop_dsh 未验证 PID 存在性"
fi

# 6.2 检查 HTML 转义
if grep -q "HTML 转义" src/daemon.c || grep -q "&lt;" src/daemon.c; then
  ok "build_boot 对 LOG_DIR 进行 HTML 转义"
else
  info "build_boot 可能未转义 LOG_DIR(低风险)"
fi

# 6.3 检查 JSON 转义处理
if grep -q "反转义" src/daemon.c || grep -q '\\\\\\\\' src/daemon.c; then
  ok "extract_str 处理 JSON 转义字符"
else
  info "extract_str 可能未处理转义(低风险)"
fi

h1 "7. 编译测试"

# 7.1 编译 daemon.c
info "编译 daemon.c(universal binary)..."
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

if daemon_compile "$TMPD/daemon" -arch arm64 -arch x86_64; then
  ok "daemon.c 编译成功(无警告)"
else
  fail "daemon.c 编译失败"
fi

# 7.2 检查二进制架构
if [ -f "$TMPD/daemon" ]; then
  FILE_OUT=$(file "$TMPD/daemon")
  if echo "$FILE_OUT" | grep -q "universal binary" && \
     echo "$FILE_OUT" | grep -q "x86_64" && \
     echo "$FILE_OUT" | grep -q "arm64"; then
    ok "daemon 包含 2 个架构(arm64 + x86_64)"
  else
    fail "daemon 不是 universal binary: $FILE_OUT"
  fi
fi

# 7.3 检查符号表清理
if [ -f "$TMPD/daemon" ]; then
  SIZE=$(stat -f%z "$TMPD/daemon")
  # Universal binary 大约 70-100KB
  if [ "$SIZE" -lt 150000 ]; then
    ok "daemon 二进制大小合理($SIZE 字节)"
  else
    info "daemon 二进制较大($SIZE 字节,可能包含调试符号)"
  fi
fi

h1 "测试总结"
echo
if [ "$FAIL" = "0" ]; then
  echo "${G}${B}✓ 全部通过${RST} ($PASS 项测试)"
  exit 0
else
  echo "${R}${B}✗ 发现问题${RST} (${G}$PASS 通过${RST}, ${R}$FAIL 失败${RST})"
  exit 1
fi
