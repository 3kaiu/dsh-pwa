# dsh-pwa 工具集成指南

**集成日期:** 2026-09-09  
**状态:** ✅ 已完成

---

## 集成的工具

### 零依赖工具 (macOS 内置)

#### 1. 性能分析工具

**脚本:** `scripts/profile-daemon.sh`

```bash
bash scripts/profile-daemon.sh
```

**功能:**
- 内存占用 (RSS/VSZ)
- 堆分配详情 (`heap`)
- 系统调用频率 (`dtruss`)
- 文件描述符 (`lsof`)
- 网络连接状态
- 虚拟内存统计 (`vm_stat`)

**使用场景:**
- 验证优化效果 (内存 -12KB, 系统调用 -60%)
- 性能回归检测
- 运行时行为分析

---

#### 2. 二进制分析工具

**脚本:** `scripts/analyze-binary.sh`

```bash
bash scripts/analyze-binary.sh ~/.local/share/dsh-runtime/daemon
```

**功能:**
- 文件大小和修改时间
- Mach-O 段大小分析 (`size -m`)
- 架构验证 (`lipo -info`)
- 动态库依赖 (`otool -L`)
- 导出符号统计 (`nm -g`)
- 代码签名状态 (`codesign -dv`)
- 体积基准对比

**使用场景:**
- 监控二进制膨胀
- 验证 universal binary
- 检查依赖泄露

---

### 需要安装的工具

#### 3. Shellcheck - Bash 脚本质量保障

**安装:**
```bash
brew install shellcheck
```

**使用:**
```bash
shellcheck scripts/*.sh tests/*.sh
```

**功能:**
- Bash 语法检查
- 常见错误检测
- 最佳实践建议

**集成点:**
- ✅ `.github/workflows/ci-enhanced.yml` (CI 自动检查)
- ⚠️ 本仓库未配置 pre-commit hook(如需提交前本地检查,可自建 `.git/hooks/pre-commit`,参见下文「Pre-commit Hook(可选,自建)」)

---

#### 4. Hyperfine - 性能基准测试

**安装:**
```bash
brew install hyperfine
```

**脚本:** `scripts/benchmark.sh`

```bash
bash scripts/benchmark.sh
```

**功能:**
- /health 端点响应延迟
- 并发连接性能
- 统计分析 (中位数/标准差)
- Markdown 报告导出

**使用场景:**
- 量化优化效果
- 性能回归检测
- CI 基准测试

---

#### 5. Bats-core - Bash 单元测试

**安装:**
```bash
brew install bats-core
```

**测试文件:** `tests/unit/install-validation.bats` + `tests/unit/daemon-cases.bats`

```bash
bats tests/unit/
```

**功能:**
- install-validation.bats: 端口验证、编译成功性、二进制体积、脚本语法等安装侧用例
- daemon-cases.bats: 守护进程黑盒用例(就绪门控/透传/启停等),不依赖真实 dsh,复用 `tests/lib/daemon-helpers.sh` 探测助手

**当前覆盖(截至 2026-09-11):**
- 2 个测试文件,共 24 个测试用例(install-validation 8 + daemon-cases 16)
- 覆盖边界情况 (端口范围, 二进制大小, 守护运行时行为)

---

## CI/CD 集成

### 增强的 CI 配置

**文件:** `.github/workflows/ci-enhanced.yml`

**新增 Jobs:**

1. **build-and-test** - 编译 + 冒烟测试
   - 编译 universal binary
   - 代码签名验证
   - 架构验证
   - smoke-test.sh
   - security-verification.sh

2. **static-analysis** - 静态分析
   - Shellcheck (bash 脚本)
   - Clang Static Analyzer (C 代码)
   - 分析报告上传

3. **performance** - 性能基准
   - Hyperfine 基准测试
   - /health 端点延迟
   - 并发性能测试
   - 基准报告上传

4. **binary-analysis** - 二进制分析
   - 体积分析
   - 体积回归检测 (>90KB 警告)

---

## Pre-commit Hook（可选，自建）

本仓库**没有**内置 `.git/hooks/pre-commit`（`.git/hooks` 不入库,CI 已覆盖同等检查）。如需提交前本地把关,可自行创建:

```bash
cat > .git/hooks/pre-commit <<'EOF'
#!/bin/bash
# 1. Shellcheck (如果已安装)
command -v shellcheck >/dev/null && shellcheck scripts/*.sh tests/*.sh || true
# 2. C 编译检查 (零警告)
clang -O2 -Wall -Wextra -Werror -arch arm64 -arch x86_64 -o /tmp/daemon-precommit src/daemon.c || exit 1
# 3. 二进制体积检查 (>90KB 警告)
SIZE=$(stat -f%z /tmp/daemon-precommit)
[ "$SIZE" -gt 92160 ] && echo "⚠️ 二进制超过 90KB: ${SIZE}B"
EOF
chmod +x .git/hooks/pre-commit
```

**跳过方式:** `git commit --no-verify`

---

## 使用指南

### 日常开发

#### 1. 验证代码质量
```bash
# Bash 脚本检查
shellcheck scripts/*.sh tests/*.sh

# C 代码编译检查
clang -O2 -Wall -Wextra -Werror \
  -arch arm64 -arch x86_64 \
  -o /tmp/daemon src/daemon.c
```

#### 2. 性能分析
```bash
# 运行时性能分析
bash scripts/profile-daemon.sh

# 二进制分析
bash scripts/analyze-binary.sh ~/.local/share/dsh-runtime/daemon

# 基准测试 (需要先安装 hyperfine)
bash scripts/benchmark.sh
```

#### 3. 单元测试
```bash
# 运行 Bash 单元测试 (需要先安装 bats-core)
bats tests/unit/
```

---

### CI/CD

#### 触发条件
- `git push` 到 `main` 分支
- Pull Request
- 手动触发 (`workflow_dispatch`)

#### 查看结果
1. GitHub Actions 页面查看 CI 状态
2. 下载 Artifacts:
   - `static-analysis` - 静态分析日志
   - `performance-benchmark` - 性能基准报告

---

## 预期基准

### 性能指标

| 指标 | 优化前 | 优化后 | 当前目标 |
|------|--------|--------|---------|
| **RSS 内存** | ~1330KB | ~1270KB | <1300KB |
| **系统调用** | 5次/秒 | 2次/秒 | <3次/秒 |
| **/health 延迟** | ~10ms | ~5-10ms | <15ms |
| **二进制体积** | 85KB | 83KB | <90KB |

### 质量指标

| 指标 | 目标 |
|------|------|
| **编译警告** | 0 |
| **Shellcheck 问题** | 0 (critical) |
| **单元测试通过率** | 100% |
| **安全测试通过率** | 100% (33/33) |

---

## 故障排查

### 常见问题

#### 1. profile-daemon.sh 提示 "守护进程未运行"
```bash
# 触发 launchd socket activation 拉起守护进程
curl -fsS http://127.0.0.1:3080/health

# 验证启动(零常驻:仅在活跃会话期间可见)
ps aux | grep daemon
```

#### 2. benchmark.sh 提示 "hyperfine 未安装"
```bash
brew install hyperfine
```

#### 3. bats 测试失败
```bash
# 检查 bats-core 安装
brew install bats-core

# 单独运行失败的测试
bats tests/unit/ -f "test_name"
```

---

## 卸载

### 移除工具
```bash
brew uninstall shellcheck hyperfine bats-core
```

### 移除集成
```bash
# 删除新增的脚本
rm -f scripts/profile-daemon.sh
rm -f scripts/analyze-binary.sh
rm -f scripts/benchmark.sh

# 删除 CI 配置
rm -f .github/workflows/ci-enhanced.yml

# 删除 pre-commit hook(若曾按上文自建)
rm -f .git/hooks/pre-commit

# 删除单元测试
rm -rf tests/unit/
```

---

## 下一步

### 短期 (本周)
- [ ] 团队安装 shellcheck/hyperfine/bats-core
- [ ] 运行基准测试建立基线
- [ ] 验证 CI 配置正常运行

### 中期 (下月)
- [ ] 增加更多单元测试用例
- [ ] 集成性能趋势图
- [ ] 添加自动化性能回归检测

### 长期 (季度)
- [ ] 探索 Instruments 自动化
- [ ] 集成内存泄露检测到 CI
- [ ] 建立性能数据仪表板

---

**维护人员:** Kiro  
**最后更新:** 2026-09-09  
**反馈渠道:** GitHub Issues
