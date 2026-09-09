# dsh-pwa 自动更新功能测试清单

**测试日期:** 2026-09-09  
**测试人员:** 待定  
**状态:** ✅ 代码就绪，待安装测试

---

## 预检清单

### 编译验证
- [x] daemon.c 编译通过（零警告）
- [x] daemon 大小 85KB（universal binary）
- [x] daemon 包含 arm64 + x86_64 架构

### 脚本验证
- [x] update-dsh.sh 语法检查通过
- [x] update-dsh.sh 使用 mkdir 原子锁（macOS 兼容）
- [x] com.dshpwa.updater.plist XML 格式正确
- [x] install.sh 包含 updater 注册逻辑

### 环境变量
- [x] `DSH_RT_NO_AUTO_UPDATE` 控制逻辑已实现
- [x] daemon.c 检查环境变量
- [x] install.sh 检查环境变量

---

## 功能测试（需要真实环境）

### 测试 1：后台异步更新

**前提条件:**
```bash
# 确保没有旧安装残留
launchctl bootout "gui/$(id -u)/com.dshpwa.daemon" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.dshpwa.updater" 2>/dev/null || true
rm -rf ~/.local/share/dsh-runtime ~/.local/state/dsh-runtime
```

**步骤:**
1. 运行 `bash scripts/install.sh`
2. 等待 15 秒（守护进程启动 + 后台更新延迟 10 秒）
3. 检查日志：`tail -20 ~/.local/state/dsh-runtime/logs/update.log`

**预期结果:**
- [ ] 日志文件存在
- [ ] 日志包含 "开始更新 dsh" 或 "已是最新版本" 字样
- [ ] 守护进程启动正常（`ps aux | grep daemon`）
- [ ] PWA 可正常打开（http://127.0.0.1:3080）

---

### 测试 2：定时更新器

**步骤:**
1. 验证 updater 已注册：`launchctl list | grep dshpwa`
2. 手动触发：`launchctl start com.dshpwa.updater`
3. 检查日志：`tail -20 ~/.local/state/dsh-runtime/logs/updater.log`

**预期结果:**
- [ ] `launchctl list` 显示两个服务（daemon + updater）
- [ ] 手动触发后日志有输出
- [ ] 日志显示版本检查逻辑正常

---

### 测试 3：文件锁机制

**步骤:**
```bash
# 同时触发 3 次更新
launchctl start com.dshpwa.updater &
launchctl start com.dshpwa.updater &
launchctl start com.dshpwa.updater &

# 立即检查进程
ps aux | grep update-dsh.sh

# 检查锁目录
ls -ld ~/.local/state/dsh-runtime/update.lock.d
```

**预期结果:**
- [ ] 只有一个 update-dsh.sh 进程在运行
- [ ] 锁目录存在（更新完成后自动删除）
- [ ] 其他两次触发静默退出

---

### 测试 4：禁用自动更新

**步骤:**
```bash
# 清理旧安装
launchctl bootout "gui/$(id -u)/com.dshpwa.daemon" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.dshpwa.updater" 2>/dev/null || true

# 重装并禁用自动更新
export DSH_RT_NO_AUTO_UPDATE=1
bash scripts/install.sh

# 检查 updater 是否未注册
launchctl list | grep dshpwa
```

**预期结果:**
- [ ] `launchctl list` 只显示 com.dshpwa.daemon
- [ ] 没有 com.dshpwa.updater
- [ ] 守护进程启动正常

---

### 测试 5：更新日志轮转

**步骤:**
```bash
# 模拟 10 次更新
for i in {1..10}; do
  launchctl start com.dshpwa.updater
  sleep 3
done

# 检查日志大小
wc -l ~/.local/state/dsh-runtime/logs/updater.log
```

**预期结果:**
- [ ] 日志文件不超过 100KB（合理大小）
- [ ] 包含所有 10 次更新记录

---

### 测试 6：网络故障降级

**步骤:**
```bash
# 断网测试（关闭 Wi-Fi 或拔网线）
# 或者修改脚本临时屏蔽 npm registry

# 触发更新
launchctl start com.dshpwa.updater

# 检查日志
tail -10 ~/.local/state/dsh-runtime/logs/updater.log

# 检查 dsh 是否仍可启动
open http://127.0.0.1:3080
```

**预期结果:**
- [ ] 更新脚本静默退出（无报错）
- [ ] dsh 使用现有版本正常启动
- [ ] PWA 功能完全正常

---

### 测试 7：版本验证

**步骤:**
```bash
# 强制降级到旧版本（模拟）
cd ~/.local/share/dsh-runtime/app
npm install @deepseek-ai/dsh@1.0.0 --force

# 重启守护进程
launchctl kickstart -k gui/$(id -u)/com.dshpwa.daemon

# 等待后台更新
sleep 15

# 检查版本
node -e 'console.log(require(process.argv[1]).version)' \
  ~/.local/share/dsh-runtime/app/node_modules/@deepseek-ai/dsh/package.json

# 检查日志
tail -20 ~/.local/state/dsh-runtime/logs/update.log
```

**预期结果:**
- [ ] 日志显示 "1.0.0 -> X.X.X" 升级记录
- [ ] 最终版本是 npm registry 的 @latest
- [ ] dsh 正常启动并使用新版本

---

### 测试 8：僵尸锁清理

**步骤:**
```bash
# 手动创建一个过期锁（模拟更新进程被 kill -9）
mkdir ~/.local/state/dsh-runtime/update.lock.d
touch -t 202609080000 ~/.local/state/dsh-runtime/update.lock.d

# 触发更新
launchctl start com.dshpwa.updater

# 检查锁是否被清理
sleep 5
ls -ld ~/.local/state/dsh-runtime/update.lock.d 2>/dev/null || echo "锁已清理 ✓"
```

**预期结果:**
- [ ] 旧锁被自动清理（超过 1 小时）
- [ ] 更新正常执行
- [ ] 日志显示版本检查逻辑

---

## 卸载测试

**步骤:**
```bash
launchctl bootout "gui/$(id -u)/com.dshpwa.daemon"
launchctl bootout "gui/$(id -u)/com.dshpwa.updater"
rm -f ~/Library/LaunchAgents/com.dshpwa.daemon.plist
rm -f ~/Library/LaunchAgents/com.dshpwa.updater.plist
rm -rf ~/.local/share/dsh-runtime ~/.local/state/dsh-runtime

# 验证清理干净
launchctl list | grep dshpwa
ls ~/Library/LaunchAgents/com.dshpwa*.plist
```

**预期结果:**
- [ ] 所有服务已卸载
- [ ] 所有文件已删除
- [ ] 端口 3080 已释放

---

## 性能测试

### 启动延迟对比

**步骤:**
```bash
# 测试原版启动延迟
time curl -I http://127.0.0.1:3080/

# 测试带自动更新的启动延迟
# （应该相同，因为更新在后台延迟 10 秒）
```

**预期结果:**
- [ ] 启动延迟 < 3 秒（与原版一致）
- [ ] 后台更新不影响首次响应

### 资源占用

**步骤:**
```bash
# 守护进程内存占用
ps aux | grep daemon | grep -v grep

# 更新进程内存占用（更新期间）
launchctl start com.dshpwa.updater &
sleep 2
ps aux | grep update-dsh.sh
```

**预期结果:**
- [ ] daemon 内存 ~1.3MB（不变）
- [ ] update-dsh.sh 内存 < 50MB
- [ ] npm update 内存 < 500MB

---

## 安全测试

### 文件权限

**步骤:**
```bash
stat -f%p ~/.local/state/dsh-runtime/logs/update.log
stat -f%p ~/.local/state/dsh-runtime/logs/updater.log
```

**预期结果:**
- [ ] 日志文件权限 0600（用户私有）

### 路径注入防护

**步骤:**
```bash
# 尝试路径注入（应该无效）
export DSH_RT_HOME="/tmp/evil; rm -rf /tmp/test"
bash scripts/update-dsh.sh
```

**预期结果:**
- [ ] 脚本正常退出或报错
- [ ] 没有执行注入的命令

---

## 已知问题

### 问题 1：首次安装后立即更新
**现象:** 如果 npm registry 的 @latest 比 install.sh 安装的版本新，首次安装后会立即触发更新
**影响:** 轻微，仅首次安装
**缓解:** 已是预期行为（确保永远最新）

### 问题 2：网络环境差时更新失败
**现象:** 弱网环境下 curl/npm 可能超时
**影响:** 中等，更新失败但不影响现有版本使用
**缓解:** 已实现降级逻辑（网络失败静默跳过）

---

## 测试签署

**编译验证:** ✅ 已完成  
**安装测试:** ⏳ 待执行  
**功能测试:** ⏳ 待执行  
**性能测试:** ⏳ 待执行  
**安全测试:** ⏳ 待执行

**测试人员:** _____________  
**测试日期:** _____________  
**审核人员:** _____________
