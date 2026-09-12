#!/usr/bin/env bash
# 把 packaging/homebrew/dsh-pwa.rb 的 url / sha256 更新到指定发行版(默认最新 release)。
#
# 用法:
#   bash scripts/bump-homebrew-formula.sh            # 跟随最新 release
#   bash scripts/bump-homebrew-formula.sh v0.3.4     # 指定 tag
#
# 为什么要有这个脚本:formula 里的 url 与 sha256 是**手写常量**,每次发版都要改 ——
# 这正是本项目反复踩到的漂移源(README 计数、app manifest 都是同类)。把它变成一条命令,
# 并且**顺手做一次真实校验**:下载资产、比对发布清单,不一致直接失败。
#
# 只改 `url "` 与 `sha256 "` 两行(锚定行首缩进),不碰其余内容;
# 幂等:已指向该 tag 且哈希一致时不产生任何改动。
#
# 注意:本脚本**不会**把 formula 推到 tap 仓库(需要凭据,见 packaging/homebrew/README.md)。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${DSH_RT_REPO:-3kaiu/dsh-pwa}"
FORMULA="$ROOT/packaging/homebrew/dsh-pwa.rb"
TAG="${1:-}"

[ -f "$FORMULA" ] || { echo "找不到 formula: $FORMULA" >&2; exit 1; }

# ---- 解析 tag(默认跟随最新 release) ----
if [ -z "$TAG" ]; then
  # 用 releases/latest 的重定向目标取 tag,避免依赖 gh 认证
  eff="$(curl -fsSL --max-time 20 -o /dev/null -w '%{url_effective}' \
    "https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
  TAG="${eff##*/}"
fi
case "$TAG" in
  v[0-9]*) ;;
  *) echo "无法解析 tag(拿到 '$TAG');请显式传入,如: $0 v0.3.4" >&2; exit 1 ;;
esac

# ---- 下载资产并校验(下载物哈希必须等于发布清单里的哈希) ----
DL="https://github.com/$REPO/releases/download/$TAG/dsh-pwa.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 下载 $TAG 的发行资产"
# 注:下面第二个 curl 的 `--max-time` 与数值之间是**两个空格**(与上一行对齐)。这是刻意的:
# 它是 curl 门禁的活体样本 —— 旧门禁正则 `--max-time[= ][0-9]` 只认「恰好一个分隔符」,
# 会把这种合法写法误报成「无超时」。若有人把门禁改窄,本行会立刻变红。
curl -fsSL --max-time 180 -o "$TMP/dsh-pwa.zip"        "$DL"        || { echo "下载 dsh-pwa.zip 失败" >&2; exit 1; }
curl -fsSL --max-time  30 -o "$TMP/dsh-pwa.zip.sha256" "$DL.sha256" || { echo "下载清单失败" >&2; exit 1; }

SHA="$(shasum -a 256 "$TMP/dsh-pwa.zip" | awk '{print $1}')"
MANIFEST="$(awk 'NR==1{print $1}' "$TMP/dsh-pwa.zip.sha256")"
if [ "$SHA" != "$MANIFEST" ]; then
  echo "资产哈希与发布清单不一致,拒绝写入 formula:" >&2
  echo "  下载物: $SHA" >&2
  echo "  清单:   $MANIFEST" >&2
  exit 1
fi
echo "  ✓ 哈希一致: $SHA"

# ---- 改 formula(锚定行首缩进,避免误伤注释/正文里出现的同一字符串) ----
BEFORE="$(cat "$FORMULA")"
{
  sed -E "s|^  url \".*\"$|  url \"$DL\"|" "$FORMULA" \
    | sed -E "s|^  sha256 \".*\"$|  sha256 \"$SHA\"|"
} > "$TMP/formula.new"
AFTER="$(cat "$TMP/formula.new")"

# 反空转:两处锚点都必须真的命中,否则会「什么都没改却报成功」
grep -qE "^  url \"$DL\"$"    "$TMP/formula.new" || { echo "url 行未命中锚点(缩进/格式变了?)" >&2; exit 1; }
grep -qE "^  sha256 \"$SHA\"$" "$TMP/formula.new" || { echo "sha256 行未命中锚点" >&2; exit 1; }

if [ "$BEFORE" = "$AFTER" ]; then
  echo "  · formula 已是最新,无改动"
else
  cp "$TMP/formula.new" "$FORMULA"
  echo "  ✓ 已更新 formula → $TAG"
fi
