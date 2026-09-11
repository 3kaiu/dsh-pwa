# 冒烟测试结果复核 + 整改 — 2026-09-12

- **复核对象**：CI run `34631617230`（`main` @ `8c34bbe`），job `编译 + bats 单测 + 冒烟 + 安全套件`，7m3s
- **状态**：复核完成，5 项整改已实施并验证
- **结论**：`SMOKE OK` 当时为真（已执行断言全过），但**掩盖了一个 100% 必失败的缺陷**。
  该缺陷现已定位根因、修复，并端到端验证通过。

---

## 一、原冒烟结果（复核结论）

5 个步骤无 FAIL、无 SKIP，`ps` 与 launchd GUI 会话均可用，故 3b（并发孤儿）与 5/5
（socket activation）都是真实执行。真实断言仅占 33s，其余约 5m21s 全被 4 次 install 占用。

| 步骤 | 结果 | 耗时 |
|---|---|---|
| 1/5 install | OK（92s） | 含暖机超时 69.6s |
| 2/5 幂等重跑 | OK，但 **74s** | 含暖机超时 68.8s |
| 2b/5 端口被占 | OK | 77s（输出被重定向） |
| 3/5 引导页/唤醒/就绪门控/透传 | OK（token 鉴权） | 8.8s |
| 3b/5 并发双 /wake | OK：恰 1 个 dsh 实例 | 10.2s |
| 4/5 空闲自停 | OK | 8.2s |
| 5/5 socket activation 端到端 | OK（真实执行） | 5.5s |

---

## 二、缺陷 1（高）：暖机 100% 必失败 —— 根因已定位

### 现象

```
18:10:03  ==> 4c) 暖机(填充编译缓存,加速首次启动)
18:11:12    ! 暖机超时(dsh 未在 60s 内就绪),不影响使用
```

4/4 次全部超时（2 次可见 + 2 次输出被重定向），job 白涨 ~4m40s，CI 全绿。

### 根因（构造性死结，与机器快慢、网络、环境均无关）

`install.sh` **整个运行期都持 `$RT_HOME/.install.lock`**（内含自身存活 pid，用于安装互斥）。
而守护的 `update_locked()`（`daemon.c:255-267`）正是读这个文件：

```c
snprintf(p, sizeof p, "%s/.install.lock/pid", RT_HOME);
...
return pid > 0 && kill(pid, 0) == 0;   // 持锁者还活着 → 「更新进行中」
```

`spawn_dsh()`（`daemon.c:296`）据此**直接放弃拉起 dsh**：

```
daemon: 更新进行中(install.lock 持有存活 pid),本轮不拉起 dsh
```

同一把锁既做「安装互斥」，又被守护读作「node_modules 处于半更新状态」。
暖机在 install.sh 内部启动守护 → 必然撞上这把锁 → dsh 永不启动 → 必然超时。

**关键证据**：修复前那次冒烟运行留下的失败日志（本次新增的「失败保留日志」才让它可见）
`$RT_STATE/logs/warmup.log` 内容为：

```
dsh-daemon 前台模式: http://127.0.0.1:53533/ (PWA 端口;dsh 内部端口自动分配)
daemon: 更新进行中(install.lock 持有存活 pid),本轮不拉起 dsh
daemon: 更新进行中(install.lock 持有存活 pid),本轮不拉起 dsh
... (共 26 行,全部是这一条)
```

即 dsh **一次都没被 fork**。这也解释了为何此前「清缓存后暖机 3s 就绪、生成 1307 个缓存文件」
的说法无法复现：那些缓存来自日常 PWA 使用，不是暖机产物。

### 修复

暖机实例改用**独立的无锁临时 `RT_HOME`**（`mktemp -d /tmp/dsh-warmup.XXXXXX`），
复制 `daemon` + `run.json` 进去；`RT_STATE` 仍指向真实目录，因为预热目标正是
`$RT_STATE/node-cache`（`daemon.c:348` 按 RT_STATE 计算 `NODE_COMPILE_CACHE`）。
同时置 `DSH_RT_NO_AUTO_UPDATE=1`（守护从 RT_HOME 还会读 `scripts/update-dsh.sh`，
临时目录里没有，不该去找），并在收尾清理 `dsh.json`/`dsh.pid` 与临时目录。

> 守护从 RT_HOME 只读三处：`run.json`(119)、`.install.lock`(257)、`scripts/update-dsh.sh`(539)
> —— 这是该修复成立的前提，已逐一核对。

---

## 三、缺陷 2（低-中）：`cleanup-deps.sh:66` 百分比恒为空

CI 打印 `节省空间: 62MB (%)   节省空间: 62MB (%)`。根因：**bash 3.2 下**
「双引号串内嵌 `$( )`、`$( )` 内再用转义双引号」解析错乱——内层 `\"` 破坏外层引号，
`echo` 收到 **2 个参数**（整行打印两遍），`awk` 被调用 **2 次**且程序被截断
（两次 `syntax error`），`$( )` 结果为空。实测 `argc=2`；fish / bash 5 不复现。
命令替换的非零退出不影响 `echo` 的退出码，故 `set -e` 也拦不住。`shellcheck -S warning` 不报。

**修法**：先算进变量再拼进 echo。仓库中该形状**仅此一处**（`install.sh:59` 的单引号写法安全）。

---

## 四、其余整改（低）

| 项 | 内容 |
|---|---|
| 可观测性 | 暖机留下互斥 marker：`warmup.ok` / `warmup.failed` / `warmup.skipped`；失败**保留日志**到 `$LOG_DIR/warmup.log`（旧实现无条件 `rm`），CI 里补 `::warning` |
| 幂等重跑 | 缓存已填充且 dsh 版本未变 → 免做（版本一变缓存即失效，故按版本判定，不能只看目录非空） |
| 暖机预算 | 新增 `DSH_RT_WARMUP_TIMEOUT_SECS`（默认 60，非法值回退）；冒烟用 25s |
| 2b / 冲突后重装 | 置 `DSH_INSTALL_NO_WARMUP=1`——这两步验的是端口冲突，与暖机无关，不该各白等一轮 |
| 步骤 2 文案 | `已装同版应秒过` → `已装同版,重入应成功且不破坏既有安装`（原描述与 74s 实测不符） |
| 日志噪声 | 占位监听器 kill 前 `disown`，消除 `Terminated: 15` 作业控制通知（实测有效） |
| Actions | `checkout` v4.2.2 → v7.0.1、`upload-artifact` v4.6.2 → v7.0.1（均声明 `node24`），消除 4 个 job 的 Node 20 弃用注解 |

---

## 五、验证证据

| 验证 | 结果 |
|---|---|
| 暖机块 harness（真实切片，非重写） | 新代码 **20/20 PASS**；旧代码 **6 PASS / 14 FAIL**（fail-before 成立） |
| harness 关键用例 | 版本变化**不**跳过；失败写 `warmup.failed` **且保留日志**；CI 内发 `::warning`、CI 外不发；成功后重跑**跳过** |
| 端到端冒烟（修复前） | `SMOKE OK`，但 `暖机:失败`，全程 4m0s |
| 端到端冒烟（修复后） | `✓ 暖机完成(编译缓存已填充:1416 个文件)`；重跑 `✓ 缓存已热(1416 个文件,dsh 0.1.5-rc.1 未变),免做`；收尾 `暖机:成功(1416 个缓存文件)`；`SMOKE_RC=0`，全程 **2m0s** |
| 幂等重跑耗时 | **16.7s**（修复前同一路径 49.9s；CI 上 74s） |
| `cleanup-deps.sh` | `节省空间: 9MB (90.0%)`，只打印一次，stderr 为空；darwin 预编译产物仍保留 |
| bats | **43/43** |
| clang / shellcheck / `bash -n` | 全部通过（clang 零告警） |
| workflow | PyYAML 解析通过；`check_run_blocks.mjs`：22 个 run block，0 语法错误 |

---

## 六、环境说明（复核时的干扰项，勿据此改产品）

本次复核在受限沙箱中执行，有两处环境差异**不是产品缺陷**：

1. **`find` 是 toybox 0.8.13 的 shim**（非 macOS `/usr/bin/find`）。toybox 的 `-delete`
   隐含 `-print`，故本地 `cleanup-deps.sh` 会打印 4365 行被删路径；CI（真 BSD find）
   为 0 行。**不要为此改脚本。**
2. `ps` 被拒（`operation not permitted`）、无可用 launchd GUI 会话 → 冒烟 3b 与 5/5 走
   `[SKIP]` 并在收尾点名（行为正确）。

另：清理了 `/tmp/dsh-install-smoke.*` 等临时目录（smoke 脚本用 `mktemp` 创建，可随时重建）。
