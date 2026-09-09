# dsh-pwa 优化精简方案

**分析日期:** 2026-09-09  
**当前状态:** 212MB 运行时 + 85KB daemon + 257 行安装脚本  
**目标:** 精简体积、优化性能、简化维护

---

## 📊 当前状态分析

### 体积分布
```
总体积: 212MB
├── node_modules: 211MB (99.5%)
│   ├── @deepseek-ai/dsh: 32MB
│   ├── node-pty: 26MB (含 Win32 预编译二进制)
│   ├── @img/sharp: 26MB (图像处理库)
│   ├── @opentelemetry: 21MB (遥测库)
│   └── @mistralai: 15MB
├── daemon (C): 85KB → strip 后 84KB
└── install.sh: 13KB
```

### 运行时特征
- **daemon RSS:** ~672KB (实测)
- **dsh 本体:** 由 npm 包管理，依赖 451 个包
- **node 运行时:** 优先复用系统 node，降级自动安装
- **启动模式:** 预热启动 (登录即拉起 dsh)

---

## 🎯 优化方向

### 方向 1: **依赖瘦身** (潜力最大)

#### 1.1 剔除跨平台冗余二进制

**问题:**
- `node-pty` 包含 Win32 x64/arm64 预编译二进制 (23MB)
- macOS 专用项目无需跨平台支持

**方案:**
```bash
# install.sh 装完 dsh 后立即清理
find "$APP_DIR/node_modules/node-pty/prebuilds" \
  -type d ! -name "darwin-*" -exec rm -rf {} + 2>/dev/null

# 预期减少: ~23MB
```

**风险:** 无 (node-pty 是 dsh 依赖，不影响本项目逻辑)

---

#### 1.2 @img/sharp 多架构库剪枝

**问题:**
- `@img/sharp-wasm32` (8.6MB) 和 `@img/sharp-libvips-darwin-arm64` (17MB) 都存在
- macOS 仅需原生二进制，WASM 版本冗余

**方案:**
```bash
# 删除 WASM 备用方案
rm -rf "$APP_DIR/node_modules/@img/sharp-wasm32"

# 预期减少: ~9MB
```

---

#### 1.3 OpenTelemetry 遥测数据可选

**问题:**
- `@opentelemetry/semantic-conventions` 占 7.3MB
- daemon 已设置 `DSH_TELEMETRY_DISABLED=1`，但 npm 包仍安装

**方案:**
```bash
# 如果 dsh 支持 --no-telemetry 启动标志，可彻底禁用
# 否则仅文档说明:用户不需要时手动删除
```

**保守预期:** 不动 (需确认 dsh 是否强依赖)

---

### 方向 2: **daemon 极简化**

#### 2.1 引导页 HTML 内联优化

**当前:**
- `BOOT_PAGE[16384]` 静态缓冲区，TPL 字符串 3.5KB
- 引导页在未就绪时每次请求都返回

**优化:**
```c
// 1) CSS 压缩 (去除注释和多余空格)
// 当前: 1.8KB → 优化后: ~1.2KB

// 2) JavaScript 简化
// 当前 tick() 轮询 /health → 可改为 EventSource(SSE) 推送就绪事件
// 预期减少 ~500 字节代码 + 降低 CPU 占用
```

**收益:** 代码可读性 vs 体积 (编译后二进制仅减少 ~1KB)

---

#### 2.2 JSON 解析库替换

**当前:**
- 手写 `extract_str()` 函数 (24 行)
- 仅解析 `run.json` 的 2 个字段

**方案:**
保持现状 — 引入 cJSON (10KB) 反而增大体积

---

### 方向 3: **安装流程精简**

#### 3.1 并行化依赖安装

**当前:** 顺序执行
```
1) Node 检测/安装 (0-180s)
2) dsh npm install (30-600s)
3) daemon 编译 (1-5s)
4) LaunchAgent 注册 (1s)
```

**优化:**
```bash
# daemon 编译可与 npm install 并行
{
  npm install --prefix "$APP_DIR" &
  NPM_PID=$!
  
  if [ -f "$ROOT/src/daemon.c" ]; then
    clang -O2 -arch arm64 -arch x86_64 -o "$RT_HOME/daemon" "$ROOT/src/daemon.c" &
    DAEMON_PID=$!
  fi
  
  wait $NPM_PID || exit 1
  [ -n "${DAEMON_PID:-}" ] && wait $DAEMON_PID
}
```

**预期:** 首次安装加速 3-5 秒

---

#### 3.2 预编译 package-lock.json 缓存

**当前:** Release workflow 已生成 `package-lock.json`
**效果:** npm install 跳过解析，节省 30-60s (已实现 ✓)

---

### 方向 4: **功能简化**

#### 4.1 去除预热启动 (可选)

**当前:**
```c
// daemon.c:504
if (!getenv("DSH_RT_NO_PREWARM") && ...) spawn_dsh();
```

**争议:**
- 优点: 首次点击 PWA 秒开
- 缺点: 登录即启动 dsh (占用 ~50MB 内存)

**建议:** 保持默认预热，文档说明 `DSH_RT_NO_PREWARM=1` 可禁用

---

#### 4.2 HTTP 探测简化

**当前:**
- `http_probe()` 发送完整 HTTP/1.0 GET 请求
- 等待 3s 超时，接收 512 字节响应

**优化方案 (激进):**
```c
// 仅 TCP 连接探测 (去除 HTTP 语义)
static int http_probe(int port) {
  int s = socket(AF_INET, SOCK_STREAM, 0);
  struct timeval tv = { 1, 0 }; // 降回 1s
  // ... bind + connect
  close(s);
  return 1; // TCP 成功即认为就绪
}
```

**风险:** 
- 可能误判 (dsh HTTP 服务器未初始化完成)
- 引导页过早 reload → PWA 空白屏

**建议:** 保持当前实现 (安全审计后的稳定版本)

---

## 🚀 推荐实施方案

### 阶段 1: 无风险优化 (立即执行)

**1. 依赖清理脚本**
```bash
# scripts/cleanup-deps.sh
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="${1:?需要 node_modules 路径}"

echo "清理跨平台冗余二进制..."
# node-pty Win32 二进制
find "$APP_DIR/node_modules/node-pty/prebuilds" \
  -type d \( -name "win32-*" -o -name "linux-*" \) \
  -exec rm -rf {} + 2>/dev/null || true

# sharp WASM 备用
rm -rf "$APP_DIR/node_modules/@img/sharp-wasm32" 2>/dev/null || true

# sourcemap (运行时永不加载)
find "$APP_DIR/node_modules" -name "*.map" -delete 2>/dev/null || true

# 文档/测试/examples
find "$APP_DIR/node_modules" -type d \
  \( -name test -o -name tests -o -name __tests__ -o -name examples -o -name docs \) \
  -exec rm -rf {} + 2>/dev/null || true

echo "清理完成"
```

**预期收益:** 
- 体积: 212MB → ~178MB (减少 34MB，16%)
- 安装时间: 无变化
- 风险: 无 (仅删除运行时不需要的文件)

---

**2. 集成到 install.sh**
```bash
# install.sh:168 行之后
ok "npm install 完成($(( SECONDS - NPM_START ))s)"

# 深度清理 node_modules
bash "$ROOT/scripts/cleanup-deps.sh" "$APP_DIR" 2>/dev/null || true

# 剪除 sourcemap/文档/测试(运行时永不加载,纯占空间)
find "$APP_DIR/node_modules" \( -name "*.map" -o -name "*.md" -o -name ".DS_Store" \) -delete 2>/dev/null || true
```

---

### 阶段 2: 渐进式优化 (1-2 周)

**1. 并行编译 daemon**
```bash
# install.sh 重构成并发模式
# 需测试锁机制与错误处理
```

**2. 引导页压缩**
```bash
# 使用 htmlmin/csso/terser 压缩 TPL 字符串
# 集成到 release.yml 构建步骤
```

**预期收益:**
- 体积: daemon 二进制 85KB → 84KB (微不足道)
- 安装时间: 首次安装 3-5 秒

---

### 阶段 3: 架构优化 (长期)

**1. dsh 本地缓存层**
```
问题: npm install 每次都下载 211MB 依赖
方案: 共享 node_modules 缓存目录
  ~/.local/share/dsh-runtime/.npm-cache/
  首次: 211MB 下载
  升级: 仅增量包 (~5-20MB)
```

**2. daemon 状态持久化**
```c
// 当前: dsh 停止后端口信息丢失，下次需重新分配
// 优化: 端口持久化到 dsh.json，重启复用
```

---

## 📊 优化效果预测

| 维度 | 当前 | 阶段 1 | 阶段 2 | 阶段 3 |
|------|------|--------|--------|--------|
| **磁盘占用** | 212MB | 178MB (-16%) | 178MB | 150MB* (-29%) |
| **首次安装** | 3-10 分钟 | 2.5-8 分钟 | 2-7 分钟 | 30s-2 分钟* |
| **daemon RSS** | 672KB | 672KB | 670KB | 650KB |
| **安装脚本** | 257 行 | 265 行 | 270 行 | 300 行 |

*阶段 3 需要 dsh 官方支持共享缓存机制

---

## 🛑 不建议的优化

### ❌ 1. 替换 dsh 为精简版

**理由:**
- dsh-pwa 定位是"dsh 的纯 PWA 封装"
- 不应实现 dsh 功能的子集
- 维护成本远超收益

---

### ❌ 2. 用 Go/Rust 重写 daemon

**当前:**
- C 语言 daemon: 556 行，85KB 二进制
- 编译速度: 1-5 秒
- 依赖: 零 (仅标准库)

**Go/Rust 对比:**
| 语言 | 二进制体积 | 编译时间 | 依赖管理 |
|------|------------|----------|----------|
| C | 85KB | 1-5s | 无 |
| Go | ~2-5MB | 5-15s | go.mod |
| Rust | ~500KB-2MB | 30-120s | Cargo.toml + 网络 |

**结论:** C 已是最优选择

---

### ❌ 3. 内联 node 运行时

**方案:** 将 node 二进制打包进 release.zip
**问题:**
- node v22 LTS arm64: ~45MB
- node v22 LTS x64: ~40MB
- Universal binary: ~85MB (lipo 合并)

**当前策略更优:**
- 优先复用系统 node (零占用)
- 降级自动安装 (用户控制)

---

## 📋 实施建议

### 立即执行 (本周)
1. ✅ 创建 `scripts/cleanup-deps.sh`
2. ✅ 集成到 `install.sh` 第 168 行后
3. ✅ 更新 `release.yml` 包含清理脚本
4. ✅ 更新 README 说明优化效果

### 后续优化 (可选)
- 并行编译 daemon (需谨慎测试)
- 引导页 HTML/CSS 压缩 (收益小)
- 文档说明 `DSH_RT_NO_PREWARM` 禁用预热

---

## 🎯 核心结论

**dsh-pwa 已是精简设计:**
- daemon 仅 85KB，无冗余代码
- 安装脚本职责单一，无过度封装
- 依赖膨胀源于上游 dsh 包 (451 个 npm 依赖)

**最大优化空间 = 依赖清理:**
- 删除跨平台二进制: -23MB
- 删除 WASM 备用方案: -9MB
- 删除 sourcemap/docs: -2MB
- **总计可减少 ~34MB (16%)**

**不建议:**
- 重写 daemon (Go/Rust 反而更大)
- 实现 dsh 子集 (违背项目定位)
- 内联 node 运行时 (增加 85MB)

---

**实施优先级:** 阶段 1 > 文档优化 > 阶段 2 (可选)
