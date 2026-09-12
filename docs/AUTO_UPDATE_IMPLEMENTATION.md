# dsh-pwa 自动更新功能实现

> **体例说明(2026-09-12 补):** 本文是**活文档** —— 正文描述自动更新功能**当前**的行为,
> 并纳入 `install-validation.bats` 的文档防漂移门禁。
>
> **例外:** 标注「实现期快照」的小节(如「代码变更统计」)记录的是 2026-09-09 实现**当时**的
> 状态,其数字**刻意保留原样**、不随代码变化而更新。请勿据此判断现状 ——
> 现状请看代码本身与 CI 门禁。这与 `docs/AUDIT_HISTORY.md` 的处理方式一致,区别是
> AUDIT_HISTORY.md 整篇是快照(故整篇排除在门禁外),而本文只有个别小节是快照。

**实现日期:** 2026-09-09  
**功能目标:** 确保每次启动 dsh 时永远使用 `@deepseek-ai/dsh@latest`

---

## 实现内容

### 1. 后台异步更新（阶段 1）

**新增文件:**
- `scripts/update-dsh.sh` - 自动更新脚本(install.sh 部署到 `$RT_HOME/scripts/`,与 install.sh 共用 `.install.lock` 防并发)

**修改文件:**
- `src/daemon.c` - 新增 `trigger_background_update()` 函数
- `src/daemon.c: main()` - 守护启动时触发后台更新(与预热解耦)

**工作流程:**
```
PWA 连接触发 → launchd 激活 daemon → 激活时评估后台更新(按 RT_STATE/last_update_check 时间戳 12h 节流,>12h 才真正触发)
                           ↓
        npm view 解析 @latest dist-tag 的真实版本号
                    ↓
                    与本地实际版本比较 → 版本不同 → dsh 运行中则跳过本轮;否则 pnpm update(增量,与 install.sh 同一引导方式,失败回滚)
                    ↓
                    下次启动使用新版本(刷新 run.json)
```

**触发时机说明(勘误,2026-09-11):** 预热已默认改为懒启动(登录不再预热,`DSH_RT_PREWARM=1` 才显式开启),后台更新检查与预热完全解耦——守护每次被 launchd 激活启动都会评估是否触发,由 12h 节流决定是否真正执行;`DSH_RT_NO_PREWARM` 只影响预热,不再影响后台更新。

**特点:**
- ✅ 用户无感知延迟（首次启动 0 等待;更新子进程延迟 10s 启动,不干扰首次 dsh 启动）
- ✅ 网络失败自动降级（使用现有版本,保持当前版本不变）
- ✅ dsh 正在运行时跳过本轮更新（守护 `/health` 报 dsh:true 视为用户可能活跃,等下一轮用户不在场时再更新;探测后到更新开始之间若 dsh 被拉起,先经守护 `/stop` 优雅停掉兜底）
- ✅ 更新彻底失败时回滚（增量与全量重装均失败则恢复更新前的依赖树,保证"保持当前版本"是真的保持）
- ✅ node 路径从 `RT_HOME/run.json` 解析（launchd 环境无用户 PATH,`command -v node` 会失败;run.json 是 install.sh 写入的单一事实源,缺失时回落 command -v / 自带 node）
- ✅ 与 install.sh 共用 `$RT_HOME/.install.lock`(mkdir 原子锁 + pid 存活检测 + claim 防抢占),防止更新与安装并发
- ✅ pnpm 不可用时失败记日志,绝不回退 npm(避免损坏 pnpm 依赖树)

---

### 2. 定时自动更新（阶段 2）

**新增文件:**
- `launchd/com.dshpwa.updater.plist` - LaunchAgent 定时任务

**修改文件:**
- `scripts/install.sh` - 自动注册 updater LaunchAgent(打包组件由 release workflow 一并发布)

**工作流程:**
```
LaunchAgent 每天凌晨 2:30 触发
            ↓
    运行 $RT_HOME/scripts/update-dsh.sh
            ↓
    解析 @latest 真实版本并比较(与本地实际版本号比较,非 dist-tag 字符串)
            ↓
    版本不同且 dsh 未在运行 → pnpm 增量更新(失败回滚)+ cleanup-deps.sh 清理
    ↓
    日志写入 ~/.local/state/dsh-runtime/logs/update.log(超 2MB 自动轮转为 update.log.1;updater.log 为 launchd 的 stdout/stderr)
```

**特点:**
- ✅ 零启动延迟（守护进程启动逻辑完全不变）
- ✅ 永远保持最新（每天自动更新;dsh 运行中则推迟到下一轮）
- ✅ 职责分离（更新逻辑与守护进程解耦）
- ✅ node 从 run.json 解析 + PATH 前置(launchd 定时环境无用户 PATH,updater plist 仅注入系统工具 PATH,node 由脚本自解析)

---

## 环境变量控制

### `DSH_RT_NO_AUTO_UPDATE`

该变量的实际作用范围(如实描述,2026-09-11 勘误):

- **安装期(完全生效):** `install.sh` 看到该变量会跳过 updater LaunchAgent 注册,定时更新不装;daemon 侧 `trigger_background_update()` 也用 `getenv` 检查它。
  ```bash
  export DSH_RT_NO_AUTO_UPDATE=1
  bash scripts/install.sh
  ```
- **已装系统的坑:** launchd 拉起的 daemon 只继承 plist 的 `EnvironmentVariables`(见 `launchd/com.dshpwa.daemon.plist`,当前不含该变量),用户 shell 里的 `export` 传不进去——`export DSH_RT_NO_AUTO_UPDATE=1` 后 curl 触发激活并不会禁用后台更新。对已装系统要禁用后台更新,需任选其一:
  ```bash
  # 方法 A:编辑已安装的 plist 注入变量后重载(永久生效)
  #   ~/Library/LaunchAgents/com.dshpwa.daemon.plist 的 EnvironmentVariables 字典里加:
  #   <key>DSH_RT_NO_AUTO_UPDATE</key><string>1</string>
  launchctl bootout "gui/$(id -u)/com.dshpwa.daemon"
  launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.dshpwa.daemon.plist

  # 方法 B:卸载 updater LaunchAgent(禁用定时更新;后台更新仍会在守护激活时按 12h 节流触发)
  launchctl bootout "gui/$(id -u)/com.dshpwa.updater"
  rm -f ~/Library/LaunchAgents/com.dshpwa.updater.plist
  ```
  手动前台运行 daemon(冒烟测试/dev)时 shell 环境直接继承,`export` 即生效。

### `DSH_RT_PREWARM` / `DSH_RT_NO_PREWARM`
预热已默认改为懒启动:登录只驻留 ~1MB 守护,首次点 PWA 图标才拉起 dsh。`DSH_RT_PREWARM=1` 显式开启登录预热;旧变量 `DSH_RT_NO_PREWARM=1` 继续有效(显式关闭预热)。**两者均不影响后台更新**——后台更新与预热已解耦,守护每次启动都评估(12h 节流):
```bash
curl -fsS http://127.0.0.1:3080/health   # 触发 socket activation 激活 daemon(独立评估后台更新)
```

---

## 更新日志位置

- **后台更新日志:** `~/.local/state/dsh-runtime/logs/update.log`
- **定时更新日志:** `~/.local/state/dsh-runtime/logs/updater.log`
- **日志轮转:** `update.log` 超 2MB 自动滚动为 `update.log.1`(仅保留最近一份)

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

# bootout 会向守护发 SIGTERM，守护收到后**先停 dsh 再退出**（F5），不会留下孤儿 dsh。
# 但这一步只在「守护确实还注册着」时生效 —— 若之前手工 bootout 过、或守护已被强杀，
# dsh 可能仍在跑。下面这条兜底**必须在 rm -rf 之前**，否则会留下一个还在跑、
# 但 node_modules 已被删掉的 dsh。
pkill -f "$HOME/.local/share/dsh-runtime/app" 2>/dev/null || true
pgrep -fl "dsh-runtime" || true   # 确认无残留（应无输出）

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
安装期未设过该变量时,后台更新只受 plist 环境变量控制(见「环境变量控制」一节的说明)——对已装系统,改 plist 注入 `DSH_RT_NO_AUTO_UPDATE=1` 后重载,或直接用方法 2 卸载 updater;手动前台运行 daemon 时 `export DSH_RT_NO_AUTO_UPDATE=1` 即生效。

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

> **实现期快照(2026-09-09)。** 下面的 diffstat 是功能落地**那一刻**的变更量,与今天的代码
> 无关;保留它只为记录当时的改动规模。数字刻意不更新 —— 更新它反而会把它伪装成「现状」。

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
3. ~~增加回滚机制（保留上一版本）~~ 已部分实现:更新彻底失败自动回滚更新前依赖树;保留历史版本供主动降级仍未做
4. 增加更新遥测（上报版本分布）

---

**实现人员:** Kiro  
**状态:** 已上线并迭代多轮(原先的「审核状态: 待测试」「下一步: 编译验证 + smoke test」
已过期,故移除 —— 阶段性标注留在活文档里只会变成误导)  
**遗留项:** 见上方「未来增强」一节
