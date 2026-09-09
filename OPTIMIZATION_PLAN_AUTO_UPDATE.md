# dsh 自动更新优化方案

## 目标
每次启动 dsh 时确保使用 `@deepseek-ai/dsh@latest`，无需用户手动重跑 `install.sh`。

---

## 方案 A：启动前同步检查更新（最简单，冷启动 +2-5秒）

### 实现
在 `spawn_dsh()` 之前调用 shell 脚本检查并更新：

```c
// daemon.c: spawn_dsh() 之前
static int ensure_latest_dsh(void) {
  // 调用轻量级更新脚本 (scripts/update-dsh.sh)
  pid_t pid = fork();
  if (pid == 0) {
    execl("/bin/bash", "bash", "-c", 
          "bash $DSH_RT_HOME/../scripts/update-dsh.sh >/dev/null 2>&1",
          (char *)NULL);
    _exit(1);
  }
  int status;
  waitpid(pid, &status, 0);
  return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static void spawn_dsh(void) {
  ensure_latest_dsh(); // 启动前先更新
  // ... 原有逻辑
}
```

**新增文件: `scripts/update-dsh.sh`**
```bash
#!/usr/bin/env bash
set -euo pipefail
# 快速版本检查 + 增量更新
LATEST=$(curl -fsS --max-time 5 \
  https://registry.npmjs.org/@deepseek-ai/dsh/latest 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null || echo "")
[ -z "$LATEST" ] && exit 0  # 网络失败时静默跳过

CUR=$(node -e 'console.log(require(process.argv[1]).version)' \
  "$DSH_RT_HOME/app/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null || echo "")

if [ "$CUR" != "$LATEST" ]; then
  npm update --prefix "$DSH_RT_HOME/app" --prefer-offline --no-audit --no-fund
fi
```

### 优点
- ✅ 简单直接，零架构改动
- ✅ 失败时自动降级（网络超时 → 使用现有版本）
- ✅ 增量更新快（npm update 只下载变化的包）

### 缺点
- ❌ 冷启动延迟 +2-5 秒（首次点击 PWA 需要等更新完成）
- ❌ 启动后引导页转圈时间变长（用户感知等待）

---

## 方案 B：后台异步更新（推荐，用户无感）

### 实现
启动时用当前版本，同时触发后台更新，下次启动时自动使用新版本：

```c
// daemon.c: main() 启动时触发后台更新
static void trigger_background_update(void) {
  pid_t pid = fork();
  if (pid == 0) {
    setsid(); // 独立会话，守护进程退出不影响更新
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    
    // 延迟 10 秒启动（避免干扰首次 dsh 启动）
    sleep(10);
    
    execl("/bin/bash", "bash", "-c",
          "bash $DSH_RT_HOME/../scripts/update-dsh.sh",
          (char *)NULL);
    _exit(0);
  }
  // 父进程不等待，立即返回
}

int main(void) {
  // ... 现有初始化代码
  
  // 预热后立即触发后台更新
  if (!getenv("DSH_RT_NO_PREWARM") && NODE_BIN[0] && DSH_BIN[0]) {
    spawn_dsh();
    trigger_background_update(); // 不阻塞启动
  }
  
  // ... 主循环
}
```

**更新脚本增加锁机制**：
```bash
#!/usr/bin/env bash
# scripts/update-dsh.sh
LOCK="$DSH_RT_STATE/update.lock"
# 防止并发更新
exec 200>"$LOCK"
flock -n 200 || exit 0

# ... 原有更新逻辑
```

### 优点
- ✅ **用户无感**：首次启动使用现有版本，秒开
- ✅ **永远最新**：下次启动时自动使用更新后的版本
- ✅ **资源友好**：更新在空闲时后台进行

### 缺点
- ⚠️ 首次启动时不是最新版（但第二次启动就是）
- ⚠️ 需要增加文件锁防止并发更新

---

## 方案 C：LaunchAgent 定时更新（最优雅）

### 实现
新增一个独立的 LaunchAgent 每天自动更新 dsh：

**新增文件: `launchd/com.dshpwa.updater.plist`**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dshpwa.updater</string>
  <key>ProgramArguments</key>
  <array>
    <string>__RT_HOME__/../scripts/update-dsh.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>2</integer>
    <key>Minute</key><integer>30</integer>
  </dict>
  <key>StandardOutPath</key><string>__LOG_DIR__/updater.log</string>
  <key>StandardErrorPath</key><string>__LOG_DIR__/updater.log</string>
</dict>
</plist>
```

### 优点
- ✅ **零启动延迟**：守护进程启动逻辑完全不变
- ✅ **永远最新**：每天凌晨 2:30 自动更新
- ✅ **职责分离**：更新逻辑与守护进程解耦

### 缺点
- ⚠️ 新安装后首次启动不是最新版（需要等到第二天）
- ⚠️ 需要额外的 LaunchAgent（多一个系统服务）

---

## 方案 D：混合方案（性能 + 保障）

结合方案 B 和 C：
1. LaunchAgent 每天定时更新（主力）
2. 守护进程启动时快速版本检查（1 秒超时）
   - 如果本地版本 > 24 小时没更新 → 触发后台更新
   - 否则直接启动

```bash
# scripts/quick-check.sh (< 1 秒)
UPDATED=$(stat -f%m "$DSH_RT_HOME/app/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null || echo 0)
NOW=$(date +%s)
if [ $((NOW - UPDATED)) -gt 86400 ]; then
  # 超过 24 小时 → 触发后台更新
  nohup bash update-dsh.sh >/dev/null 2>&1 &
fi
```

---

## 推荐方案

### 短期（立即可用）：方案 B - 后台异步更新
- 改动最小（仅 daemon.c + 新增 update-dsh.sh）
- 用户无感知延迟
- 24-48 小时内自动更新到最新版

### 长期（生产级）：方案 D - 混合方案
- 定时更新 + 兜底检查
- 零启动延迟
- 确保永远在 24 小时内更新到最新

---

## 实现清单

### 阶段 1：后台异步更新（方案 B）
- [ ] 创建 `scripts/update-dsh.sh`
- [ ] 修改 `daemon.c: main()` 增加 `trigger_background_update()`
- [ ] 增加文件锁机制（防止并发更新）
- [ ] 测试：安装旧版本 → 启动 → 等待 10 秒 → 验证后台更新

### 阶段 2：定时更新器（方案 C）
- [ ] 创建 `launchd/com.dshpwa.updater.plist`
- [ ] 修改 `install.sh` 自动注册 updater LaunchAgent
- [ ] 测试：手动触发 `launchctl start com.dshpwa.updater`

### 阶段 3：混合优化（方案 D）
- [ ] 创建 `scripts/quick-check.sh`（快速版本检查）
- [ ] 修改 daemon 启动逻辑调用 quick-check
- [ ] 增加环境变量 `DSH_RT_AUTO_UPDATE=0` 禁用自动更新

---

## 回滚方案

如果自动更新导致问题，用户可以：
```bash
# 禁用自动更新
launchctl bootout gui/$(id -u)/com.dshpwa.updater
export DSH_RT_AUTO_UPDATE=0

# 固定版本
export DSH_VERSION_LOCK=1.2.3
bash install.sh
```
