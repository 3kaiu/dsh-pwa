# dsh-pwa 自动更新功能实现

**实现日期:** 2026-09-09  
**功能目标:** 确保每次启动 dsh 时永远使用 `@deepseek-ai/dsh@latest`

---

## 实现内容

### 1. 后台异步更新（阶段 1）

**新增文件:**
- `scripts/update-dsh.sh` - 自动更新脚本(install.sh 部署到 `$RT_HOME/scripts/`,与 install.sh 共用 `.install.lock` 防并发)

**修改文件:**
- `src/daemon.c` - 新增 `trigger_background_update()` 函数
- `src/daemon.c: main()` - 预热后触发后台更新

**工作流程:**
```
PWA 连接触发 → launchd 激活 daemon → 预热 dsh → 激活时触发 $RT_HOME/scripts/update-dsh.sh(12h 节流)
                           ↓
        npm view 解析 @latest dist-tag 的真实版本号
                    ↓
                    与本地实际版本比较 → 版本不同 → pnpm update(增量,与 install.sh 同一引导方式)
                    ↓
                    下次启动使用新版本(刷新 run.json)
```

**特点:**
- ✅ 用户无感知延迟（首次启动 0 等待）
- ✅ 网络失败自动降级（使用现有版本）
- ✅ 与 install.sh 共用 `$RT_HOME/.install.lock`(mkdir 原子锁 + pid 存活检测),防止更新与安装并发
- ✅ pnpm 不可用时失败记日志,绝不回退 npm(避免损坏 pnpm 依赖树)

---

### 2. 定时自动更新（阶段 2）

**新增文件:**
- `launchd/com.dshpwa.updater.plist` - LaunchAgent 定时任务

**修改文件:**
- `scripts/install.sh` - 自动注册 updater LaunchAgent

**工作流程:**
```
LaunchAgent 每天凌晨 2:30 触发
            ↓
    运行 $RT_HOME/scripts/update-dsh.sh
            ↓
    解析 @latest 真实版本并比较(与本地实际版本号比较,非 dist-tag 字符串)
            ↓
    版本不同 → pnpm 增量更新 + cleanup-deps.sh 清理
            ↓
    日志写入 ~/.local/state/dsh-runtime/logs/update.log(updater.log 为 launchd 的 stdout/stderr)
```

**特点:**
- ✅ 零启动延迟（守护进程启动逻辑完全不变）
- ✅ 永远保持最新（每天自动更新）
- ✅ 职责分离（更新逻辑与守护进程解耦）

---

## 环境变量控制

### `DSH_RT_NO_AUTO_UPDATE`
禁用所有自动更新功能（后台更新 + 定时更新）：
```bash
export DSH_RT_NO_AUTO_UPDATE=1
bash scripts/install.sh
```

### `DSH_RT_NO_PREWARM`
禁用预热功能（也会跳过后台更新触发）：
```bash
export DSH_RT_NO_PREWARM=1
curl -fsS http://127.0.0.1:3080/health   # 触发 socket activation 激活 daemon
```

---

## 更新日志位置

- **后台更新日志:** `~/.local/state/dsh-runtime/logs/update.log`
- **定时更新日志:** `~/.local/state/dsh-runtime/logs/updater.log`

示例日志内容：
```
==> 2026-09-09 02:30:15 开始更新 dsh: 1.2.0 -> 1.3.0
✓ 更新完成: 1.3.0
```

---

## 卸载

完整卸载包含 updater：
```bash
launchctl bootout "gui/$(id -u)/com.dshpwa.daemon"
launchctl bootout "gui/$(id -u)/com.dshpwa.updater"
rm -f ~/Library/LaunchAgents/com.dshpwa.daemon.plist
rm -f ~/Library/LaunchAgents/com.dshpwa.updater.plist
rm -rf ~/.local/share/dsh-runtime ~/.local/state/dsh-runtime
```

---

## 验证步骤

### 1. 验证后台更新
```bash
# 安装旧版本 dsh(模拟):改 package.json 后用 pnpm(与 install.sh 同一方式)
cd ~/.local/share/dsh-runtime/app
sed -i '' 's/"@deepseek-ai\/dsh": "[^"]*"/"@deepseek-ai\/dsh": "0.1.4"/' package.json
npm exec --yes --package=pnpm@10 -- pnpm --dir . install

# 重启守护进程(触发 socket activation)
curl -fsS http://127.0.0.1:3080/health

# 等待后台更新完成后检查日志
sleep 15
tail -20 ~/.local/state/dsh-runtime/logs/update.log
```

### 2. 验证定时更新
```bash
# 手动触发定时任务
launchctl start com.dshpwa.updater

# 检查日志(update.log 为脚本自身日志;updater.log 为 launchd 捕获的 stdout/stderr)
tail -20 ~/.local/state/dsh-runtime/logs/update.log

# 验证版本
node -e 'console.log(require(process.argv[1]).version)' \
  ~/.local/share/dsh-runtime/app/node_modules/@deepseek-ai/dsh/package.json
```

### 3. 验证文件锁
```bash
# 同时触发多次更新（应该只有一个生效）
launchctl start com.dshpwa.updater &
launchctl start com.dshpwa.updater &
launchctl start com.dshpwa.updater &

# 检查进程（应该只有一个 update-dsh.sh）
ps aux | grep update-dsh.sh
```

---

## 性能对比

| 场景 | 首次启动延迟 | 更新到最新版本时间 | 用户感知 |
|------|------------|------------------|---------|
| **原方案** | 2-3 秒 | 需手动重跑 install.sh | 永远用旧版 ❌ |
| **同步检查** | 9-36 秒 | 每次启动立即更新 | 等待转圈 ❌ |
| **后台更新** | 2-3 秒 | 24 小时内自动更新 | 完全无感 ✅ |
| **定时更新** | 2-3 秒 | 每天凌晨 2:30 | 完全无感 ✅ |
| **混合方案** | 2-3 秒 | 24 小时内自动更新 | 完全无感 ✅ |

---

## 回滚方案

如果自动更新导致问题：

### 方法 1：临时禁用
```bash
export DSH_RT_NO_AUTO_UPDATE=1
curl -fsS http://127.0.0.1:3080/health   # 触发 socket activation 激活 daemon
```

### 方法 2：卸载 updater
```bash
launchctl bootout "gui/$(id -u)/com.dshpwa.updater"
rm -f ~/Library/LaunchAgents/com.dshpwa.updater.plist
```

### 方法 3：固定版本
```bash
# 固定到指定版本并禁用自动更新
DSH_VERSION=1.2.3 bash scripts/update-dsh.sh   # 或重跑 install.sh 时设 DSH_VERSION=1.2.3
export DSH_RT_NO_AUTO_UPDATE=1
```

---

## 代码变更统计

```
 launchd/com.dshpwa.updater.plist |  37 +++++++++++
 scripts/update-dsh.sh            |  66 +++++++++++++++++++
 scripts/install.sh               |  13 ++++
 src/daemon.c                     |  24 +++++++
 README.md                        |   9 ++-
 CHANGELOG.md                     |  15 +++++
 6 files changed, 163 insertions(+), 1 deletion(-)
```

---

## 架构图

```
┌─────────────────────────────────────────────┐
│  PWA (Safari 程序坞)                         │
└──────────────┬──────────────────────────────┘
               │ http://127.0.0.1:3080
               ▼
┌─────────────────────────────────────────────┐
│  daemon (按需激活, ~1.3MB)                   │
│  ├─ 引导页伺服                               │
│  ├─ 按需启动 dsh                             │
│  ├─ 透传请求                                 │
│  └─ 空闲自动停止                             │
└──────┬───────────────────┬──────────────────┘
       │                   │
       │ execl()           │ fork()(激活时, 12h 节流)
       ▼                   ▼
┌─────────────────┐  ┌──────────────────────┐
│  dsh (~178MB)   │  │ update-dsh.sh (后台) │
│  官方 npm 包    │  │  ├─ npm view 解析版本│
│  动态端口启动   │  │  ├─ 版本比较          │
└─────────────────┘  │  └─ pnpm update       │
                     └──────────────────────┘
                              ▲
                              │ 每天凌晨 2:30
                     ┌────────┴──────────────┐
                     │ LaunchAgent           │
                     │ com.dshpwa.updater    │
                     └───────────────────────┘
```

---

## 后续优化建议

### 短期（可选）
1. 增加更新通知（写入 `~/.dsh/updates.txt`）
2. 增加更新失败重试（3 次，指数退避）
3. 增加带宽限制（npm 配置 `--maxsockets=3`）

### 长期（生产级）
1. 增加版本校验（SHA-256）
2. 增加灰度策略（10% 用户先更新）
3. 增加回滚机制（保留上一版本）
4. 增加更新遥测（上报版本分布）

---

**实现人员:** Kiro  
**审核状态:** 待测试  
**下一步:** 编译验证 + smoke test
