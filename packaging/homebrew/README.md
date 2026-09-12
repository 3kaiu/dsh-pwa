# Homebrew 打包

`dsh-pwa.rb` 是 Homebrew formula 的**单一真源**,保存在本仓库里;发布时复制到 tap 仓库
(`3kaiu/homebrew-tap`)对外提供。发版后 formula 的 `url` / `sha256` 由
`scripts/bump-homebrew-formula.sh` 更新,不手写。

## 用户侧安装(需先完成下方「一次性准备」)

```bash
brew tap 3kaiu/tap
brew install 3kaiu/tap/dsh-pwa
dsh-pwa-install          # ← 真正的运行时安装,必须在你自己的终端里执行
```

## 本目录内容

| 文件 | 作用 |
|---|---|
| `dsh-pwa.rb` | formula 本体(单一真源) |
| `scripts/bump-homebrew-formula.sh` | 发版后更新 `url` / `sha256`,并顺手校验发布资产 |

## 一次性准备(需仓库所有者操作)

1. 建一个名为 **`homebrew-tap`** 的公开仓库 —— Homebrew 约定 `homebrew-<名字>` 对应
   `brew tap 3kaiu/tap`。
2. 把本目录的 `dsh-pwa.rb` 放到该仓库的 `Formula/dsh-pwa.rb`。
3. **删掉主 README「安装 → Homebrew（打包就绪，尚未发布）」标题里的 `尚未发布` 标记**,
   并把该段里「现在装不到」的说明改为正常用法 —— tap 上线后那段就过时了。

之后每次发版:

```bash
bash scripts/bump-homebrew-formula.sh              # 跟随最新 release
# 或指定: bash scripts/bump-homebrew-formula.sh v0.3.4
cp packaging/homebrew/dsh-pwa.rb <tap 仓库>/Formula/dsh-pwa.rb
cd <tap 仓库> && git commit -am "dsh-pwa v0.3.4" && git push
```

## 自动化(需要凭据,尚未接线)

把上面「复制 + push」接进 `release.yml` 需要一个能推 tap 仓库的 token
(细粒度 PAT,仅该仓库 `contents: write`),存为仓库 secret(例如 `TAP_GITHUB_TOKEN`)。
**尚未接线**:没有凭据时硬接会让 release 作业变红,反而更糟。建议 tap 仓库建好后再加。

## 为什么 formula 不自动安装运行时

见 `dsh-pwa.rb` 顶部注释。一句话:`launchctl bootstrap` 在**非图形会话**(SSH / CI / agent)
中必返 `5: Input/output error`,而 `bootout` 却可能成功 —— 自动执行会把用户本来可用的
LaunchAgent **注销掉且无法恢复**,而 `brew install` 完全可能被非图形上下文调用。
故 formula 只落载荷 + 暴露显式入口 `dsh-pwa-install`。

## 本地校验(不需要 tap 仓库)

```bash
# 建议放到 tap 布局下再 lint,否则会套用 homebrew-core 的配置得出错误结论
mkdir -p /tmp/hbtap/homebrew-tap/Formula
cp packaging/homebrew/dsh-pwa.rb /tmp/hbtap/homebrew-tap/Formula/
cd /tmp/hbtap && brew style homebrew-tap/Formula/dsh-pwa.rb
```

> **lint 位置的坑:** 在**非 tap 目录**下跑 `brew style` 会额外报 `Sorbet/StrictSigil`、
> `Sorbet/TrueSigil`、`Style/FrozenStringLiteralComment` —— 那是 homebrew-core 配置的产物,
> 真实 tap 里的 formula **不报**(已用 `oven-sh/homebrew-bun` 的 formula 做过对照)。
> 别为了消掉这三条去给 formula 加 sigil。
>
> `brew audit` 在 Homebrew 6 下需要**已信任的 tap**(`brew trust`),会改动本机 Homebrew
> 信任状态,故本地默认不跑;`brew style` 已足以覆盖语法与体例。

## ⚠️ 不要在 agent / CI 沙箱里 `brew install` 本 formula

`dsh-pwa-install` 会执行 `install.sh`,而它在沙箱环境有两个已知危害:

- 它用 `command -v node` 取 node,沙箱 PATH 会把 PWA 绑到 WorkBuddy 内部 node;
- `launchctl bootstrap` 在非 Aqua 会话必失败,却可能把用户已有的 LaunchAgent 注销掉。

要验证 formula 的**载荷完整性**,用 `brew test`(只做文件存在性断言,不触发系统改动)。
