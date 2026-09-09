# npm 缓存层优化方案

**目标:** 降低 dsh 升级时的下载量，从211MB全量下载优化为5-20MB增量更新

---

## 🎯 当前问题

### 现状
- **首次安装:** 下载 211MB (451个npm包)
- **升级:** 再次下载 211MB (npm清理旧版本后重新安装)
- **网络消耗:** 每次升级均为全量下载

### 用户痛点
- 慢速网络环境升级时间过长
- 流量敏感用户成本高
- 办公网络限速场景体验差

---

## 💡 优化方案

### 方案1: npm本地缓存 (推荐)

**原理:** 利用npm自带的缓存机制，保留node_modules

```bash
# 当前策略 (install.sh:134-148)
rm -rf "$NODE_DIR"  # 删除旧版本
npm install         # 全量下载

# 优化后策略
npm update          # 仅更新变化的包
```

**实施步骤:**

1. **修改 install.sh 升级逻辑**
```bash
# scripts/install.sh:156行附近
if [ -n "$LATEST" ] && [ "$CUR_DSH" != "$LATEST" ]; then
  if [ -z "$CUR_DSH" ]; then
    # 首次安装: 全量 npm install
    npm install --prefix "$APP_DIR"
  else
    # 升级: 使用 npm update
    echo "  ${D}增量升级 dsh@$CUR_DSH → $LATEST${R}"
    npm update --prefix "$APP_DIR" @deepseek-ai/dsh
  fi
fi
```

**预期收益:**
- 首次安装: 211MB (不变)
- 升级: 5-20MB (视版本差异)
- 实施难度: ⭐ (简单)

**风险:**
- npm update可能留下孤立依赖
- 需要定期 `npm prune` 清理

---

### 方案2: 共享全局缓存目录

**原理:** 多个安装共享同一缓存目录

```bash
# 创建共享缓存
CACHE_DIR="$HOME/.local/share/dsh-runtime/.npm-cache"
npm install --cache "$CACHE_DIR" --prefer-offline
```

**实施步骤:**

```bash
# scripts/install.sh 新增环境变量
export npm_config_cache="$RT_HOME/.npm-cache"
npm install --prefer-offline --prefix "$APP_DIR"
```

**预期收益:**
- 首次安装: 211MB下载 + 缓存
- 升级: 从本地缓存快速恢复 (网络请求 < 1MB)
- 多用户/多版本共享缓存

**风险:**
- 缓存目录膨胀 (~500MB)
- 需要定期清理 `npm cache clean`

---

### 方案3: pnpm / yarn PnP (激进)

**原理:** 使用更先进的包管理器

```bash
# 使用 pnpm (硬链接共享)
pnpm install --store-dir "$RT_HOME/.pnpm-store"
```

**预期收益:**
- 磁盘占用: 211MB → ~120MB (硬链接去重)
- 安装速度: 提升 30-50%
- 缓存复用率高

**风险:**
- ⚠️ **引入新依赖** (pnpm需要单独安装)
- 兼容性风险 (dsh可能依赖npm特性)
- 增加维护成本

**不推荐原因:** 违背"纯PWA封装"定位

---

## 🚀 推荐实施方案

### 阶段1: npm update 优化 (立即可用)

**变更文件:** `scripts/install.sh`

```bash
# 第156-167行替换为:
if [ -n "$LATEST" ] && [ "$CUR_DSH" != "$LATEST" ] || [ -z "$CUR_DSH" ]; then
  printf '{"name":"dsh-runtime-app","private":true,"dependencies":{"@deepseek-ai/dsh":"%s"}}\n' "${LATEST:-latest}" > "$APP_DIR/package.json"
  [ -f "$ROOT/package-lock.json" ] && cp "$ROOT/package-lock.json" "$APP_DIR/"
  
  NPM_START="$SECONDS"
  if [ -z "$CUR_DSH" ]; then
    # 首次安装
    echo "  ${D}npm install dsh@${LATEST:-latest}(451 个依赖,首次约 3~10 分钟)${R}"
    npm install --prefer-offline --no-audit --no-fund --prefix "$APP_DIR"
  else
    # 增量升级
    echo "  ${D}增量升级 dsh: $CUR_DSH → ${LATEST} (仅下载变化部分)${R}"
    npm update --prefer-offline --no-audit --prefix "$APP_DIR"
  fi
  
  [ $? -eq 0 ] || { warn "dsh 安装失败"; exit 1; }
  ok "完成($(( SECONDS - NPM_START ))s)"
fi
```

**预期效果:**
| 场景 | 优化前 | 优化后 | 改善 |
|------|--------|--------|------|
| 首次安装 | 211MB / 3-10分钟 | 211MB / 3-10分钟 | 无变化 |
| 小版本升级 | 211MB / 3-10分钟 | 10-30MB / 1-3分钟 | **70-85%** |
| 大版本升级 | 211MB / 3-10分钟 | 50-100MB / 2-5分钟 | **50-60%** |

---

### 阶段2: 全局缓存优化 (可选)

**变更文件:** `scripts/install.sh`

```bash
# 第161行前添加:
export npm_config_cache="$RT_HOME/.npm-cache"
mkdir -p "$npm_config_cache"
```

**清理脚本:** 添加到卸载流程
```bash
# README.md 卸载章节
launchctl bootout "gui/$(id -u)/com.dshpwa.daemon"
rm -f ~/Library/LaunchAgents/com.dshpwa.daemon.plist
rm -rf ~/.local/share/dsh-runtime ~/.local/state/dsh-runtime
# 可选: 清理 npm 缓存
rm -rf ~/.local/share/dsh-runtime/.npm-cache  # 节省 ~500MB
```

---

## 📊 方案对比

| 方案 | 磁盘占用 | 升级速度 | 实施难度 | 兼容性 | 推荐度 |
|------|----------|----------|----------|--------|--------|
| npm update | +0MB | 提升70% | ⭐ | ✅ 完美 | ⭐⭐⭐⭐⭐ |
| 全局缓存 | +500MB | 提升85% | ⭐⭐ | ✅ 良好 | ⭐⭐⭐⭐ |
| pnpm | -90MB | 提升50% | ⭐⭐⭐⭐ | ⚠️ 未知 | ⭐⭐ |

---

## ⚠️ 注意事项

### 1. npm update 局限性
- **孤立依赖:** 旧包可能残留，需要 `npm prune`
- **不适用于破坏性变更:** 大版本升级可能失败

### 2. 降级策略
```bash
# 如果 npm update 失败，回退到全量安装
if ! npm update ...; then
  warn "增量升级失败，回退到全量重装"
  rm -rf "$APP_DIR/node_modules"
  npm install ...
fi
```

### 3. 用户控制
添加环境变量让用户选择:
```bash
# 强制全量重装 (不使用缓存)
DSH_RT_FORCE_REINSTALL=1 bash install.sh
```

---

## 🎯 实施优先级

**立即实施:**
1. ✅ npm update 优化 (无副作用，大幅提升升级体验)

**短期优化 (1-2周):**
2. 全局缓存 + 定期清理脚本

**不建议:**
3. ❌ 切换到pnpm (增加复杂度，收益不明确)

---

## 🔗 相关资源

- [npm update 文档](https://docs.npmjs.com/cli/v10/commands/npm-update)
- [npm cache 文档](https://docs.npmjs.com/cli/v10/commands/npm-cache)
- [npm配置](https://docs.npmjs.com/cli/v10/using-npm/config)

---

**最后更新:** 2026-09-09  
**状态:** 方案设计完成，待实施
