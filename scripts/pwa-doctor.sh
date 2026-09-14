#!/usr/bin/env bash
set -uo pipefail
# PWA 身份诊断:采集「程序坞里的名称/图标为什么不对」判定所需的全部事实。
#
# 为什么需要它:这类症状的成因横跨三层,证据分散在三处 ——
#   一是已装守护是**哪一版**(二进制里的字符串);
#   二是守护此刻在**发哪份 manifest / 图标**(HTTP 响应);
#   三是 app 包里**烘的是哪份图标**(bundle 的 icns 与 Info.plist)。
# 让报告者手工拼这些命令,结果总是缺层;而**缺一层就会把「旧版包装器」误判成「图标缓存」**
# (本项目真实踩过:对着本机缓存查了一整轮,真因在另一台机器的已装二进制里)。
#
# **只读**:不改任何配置与状态(仅在 /tmp 落一个临时响应体用于算哈希,随即删除)。
# 输出可直接贴出 —— /health 的 token 已脱敏。
#
# 用法: bash pwa-doctor.sh [PORT]     (PORT 默认 $DSH_RT_PORT 或 3080)
# 环境: DSH_RT_HOME DSH_RT_STATE(与守护一致)
#
# 判定口径(脚本末尾会给结论):
#   旧版守护      → 二进制里仍有自造路由 ⇒ **先升级包装器**,再删掉 Web App 重加
#   新版·非官方   → 新版却仍发出自造 manifest ⇒ 中间有代理/缓存,把本输出发来
#   新版·已透传   → 透传正常 ⇒ 症状在 app 包或系统图标缓存,删掉重加(必要时 killall Dock)

RT_HOME="${DSH_RT_HOME:-$HOME/.local/share/dsh-runtime}"
RT_STATE="${DSH_RT_STATE:-$HOME/.local/state/dsh-runtime}"
PORT="${1:-${DSH_RT_PORT:-3080}}"
BASE="http://127.0.0.1:$PORT"
BIN="$RT_HOME/daemon"

h() { printf '\n== %s ==\n' "$1"; }
# 刻意**不做列对齐**:中文标签的显示宽度无法用 printf 的 %-Ns 得到 —— bash 的 `${#s}`
# 在本机(以及 CI 的 bash 3.2)按**字节**计数,中文一个字 3 字节,按字节补齐必然错位。
# 与其用半套宽度计算(还要依赖 UTF-8 locale),不如固定成「标签: 值」,任何 locale 都整齐。
kv() { printf '  %s: %s\n' "$1" "$2"; }

printf 'dsh-pwa PWA 身份诊断(只读)\n'
kv "时间" "$(date '+%Y-%m-%d %H:%M:%S %z')"
kv "RT_HOME" "$RT_HOME"
kv "端口" "$PORT"

# ---------- ① 已装守护是哪一版 ----------
# 判据是**二进制里的字符串**,不是文件大小:ad-hoc 签名会让同一份源码的产物相差约 50KB
# (120136 → 170624),按大小比会得出错误结论。
h "① 已装守护"
if [ -x "$BIN" ]; then
  kv "路径" "$BIN"
  kv "大小/mtime" "$(stat -f '%z B  %Sm' -t '%Y-%m-%d %H:%M:%S' "$BIN" 2>/dev/null || echo '未知')"
  if command -v strings >/dev/null 2>&1; then
    ICON_ROUTES="$(strings "$BIN" 2>/dev/null | grep -c '/icon\.svg' || true)"
    OLD_GLYPH="$(strings "$BIN" 2>/dev/null | grep -c 'M18 21l11 11' || true)"
    WVER="$(strings "$BIN" 2>/dev/null | grep -c 'wrapper_version' || true)"
  else
    # 无 strings(未装 CLT)时退化为直接在二进制上匹配,只求「有/无」而非精确计数
    ICON_ROUTES="$(LC_ALL=C grep -ac '/icon\.svg' "$BIN" 2>/dev/null || true)"
    OLD_GLYPH="$(LC_ALL=C grep -ac 'M18 21l11 11' "$BIN" 2>/dev/null || true)"
    WVER="$(LC_ALL=C grep -ac 'wrapper_version' "$BIN" 2>/dev/null || true)"
  fi
  kv "自造图标路由数" "$ICON_ROUTES   (非 0 = 旧版仍在自造 PWA 身份)"
  kv "旧图标路径数" "$OLD_GLYPH   (非 0 = 旧版内嵌的 >_ 图标)"
  kv "wrapper_version" "$WVER   (0 = 该版早于自我版本特性,无法上报落后)"
else
  kv "状态" "未找到($BIN 不存在或不可执行)"
fi

h "② 包装器版本(落后与否)"
# 两个文件都缺 = 该版早于「自我版本」特性,或尚未做过更新检查 —— **缺失不报落后**,只说未知。
for f in "$RT_HOME/.wrapper-version" "$RT_STATE/wrapper.latest"; do
  if [ -f "$f" ]; then
    kv "$(basename "$f")" "$(head -n 1 "$f" 2>/dev/null || true)"
  else
    kv "$(basename "$f")" "缺失(该版早于自我版本特性 / 尚未检查)"
  fi
done

# ---------- ③ 守护此刻在发什么 ----------
h "③ /health(token 已脱敏)"
HEALTH="$(curl -s --max-time 5 --noproxy '*' "$BASE/health" 2>/dev/null || true)"
if [ -z "$HEALTH" ]; then
  kv "响应" "空(守护未在监听该端口?)"
else
  printf '  %s\n' "$(printf '%s' "$HEALTH" | sed -E 's/"token"[[:space:]]*:[[:space:]]*"[^"]*"/"token":"<redacted>"/g')"
fi

h "④ 经守护取 /manifest.webmanifest"
MANIFEST="$(curl -s --max-time 5 --noproxy '*' "$BASE/manifest.webmanifest" 2>/dev/null || true)"
if [ -z "$MANIFEST" ]; then
  kv "响应" "空"
else
  printf '  %s\n' "$MANIFEST"
  kv "icons[].src" "$(printf '%s' "$MANIFEST" | LC_ALL=C grep -o '"src":"[^"]*"' | head -1 || true)"
  kv "display" "$(printf '%s' "$MANIFEST" | LC_ALL=C grep -o '"display":"[^"]*"' | head -1 || true)"
  kv "short_name" "$(printf '%s' "$MANIFEST" | LC_ALL=C grep -o '"short_name":"[^"]*"' | head -1 || true)"
  if printf '%s' "$MANIFEST" | LC_ALL=C grep -q '"/icon\.svg"'; then
    MANIFEST_KIND="self-authored(自造那份 ⇒ 旧版守护)"
  elif printf '%s' "$MANIFEST" | LC_ALL=C grep -q 'favicon\.svg'; then
    MANIFEST_KIND="official(官方那份 ⇒ 透传正常)"
  elif printf '%s' "$MANIFEST" | LC_ALL=C grep -q '<!DOCTYPE html>'; then
    MANIFEST_KIND="boot-page(守护回了引导页 ⇒ dsh 未就绪,或该路径未被拦截)"
  else
    MANIFEST_KIND="unknown(形态无法识别,请把本输出发来)"
  fi
  kv "判定" "$MANIFEST_KIND"
fi

h "⑤ 经守护取图标路径"
# 响应体先落临时文件再算哈希,而不是把 body 塞进 $() 再哈希:命令替换会**吃掉结尾换行**,
# 于是「守护发的那份」与「官方产物那份」的 sha256 会因尾换行差异而无谓地对不上。
# 临时文件走 mktemp + trap 收尾 —— 本仓库对「在 /tmp 留孤儿文件」有成文禁忌。
BODY_TMP="$(mktemp -t pwa-doctor.body 2>/dev/null || echo "/tmp/.pwa-doctor.body.$$")"
trap 'rm -f "$BODY_TMP" 2>/dev/null || true' EXIT INT TERM
for p in /favicon.svg /icon.svg /icon.png; do
  # 单行 curl:仓库的 curl 门禁逐行检查 --max-time / --noproxy,跨行会被判成缺项
  line="$(curl -s --max-time 5 --noproxy '*' -o "$BODY_TMP" -w '%{http_code} %{content_type} %{size_download}' "$BASE$p" 2>/dev/null || true)"
  sum="$(shasum -a 256 "$BODY_TMP" 2>/dev/null | cut -c1-16 || true)"
  kv "$p" "http/type/bytes = ${line:-无响应}   sha256[0:16]=${sum:-}"
done
printf '  %s\n' "提示:/icon.svg 返回 200 且约 464 字节 = 旧版内嵌的那个 >_ 图标。"

# ---------- ④ 官方产物对照(本机若装有 dsh) ----------
h "⑥ 官方产物(用于比对「守护发的是不是官方那份」)"
# maxdepth 要够深:真实路径是 app/node_modules/.pnpm/<pkg>/node_modules/@deepseek-ai/
# dsh-web-frontend/dist/… —— 到 manifest 有 9 层,设 6 会「找不到」而被误读成「未安装 dsh」。
OFFICIAL="$(find "$RT_HOME/app/node_modules" -maxdepth 10 -path '*dsh-web-frontend/dist/manifest.webmanifest' 2>/dev/null | head -1 || true)"
if [ -n "$OFFICIAL" ]; then
  kv "manifest" "$OFFICIAL"
  printf '  %s\n' "$(cat "$OFFICIAL" 2>/dev/null || true)"
  FAV="$(dirname "$OFFICIAL")/favicon.svg"
  if [ -f "$FAV" ]; then
    kv "favicon.svg" "$(stat -f '%z B' "$FAV" 2>/dev/null || echo '?')   sha256[0:16]=$(shasum -a 256 "$FAV" 2>/dev/null | cut -c1-16 || true)"
  fi
else
  kv "状态" "未找到 dsh-web-frontend/dist(未安装 dsh?)"
fi

# ---------- ⑤ app 包里烘的是哪份 ----------
h "⑦ 已安装的 Web App 包"
found=0
for app in "$HOME"/Applications/*.app; do
  [ -f "$app/Contents/Info.plist" ] || continue
  wk="$(plutil -extract WKManifestURL raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
  [ -n "$wk" ] || continue
  found=1
  printf '  %s\n' "$(basename "$app")"
  kv "WKManifestURL" "$wk"
  kv "icns mtime" "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$app/Contents/Resources/ApplicationIcon.icns" 2>/dev/null || echo '无 icns')"
  kv "plist mtime" "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$app/Contents/Info.plist" 2>/dev/null || echo '?')"
  printf '  %s\n' "  —— Safari 添加时读到的 manifest(烘死在 plist 里):"
  plutil -p "$app/Contents/Info.plist" 2>/dev/null | sed -n '/"Manifest" => {/,/^  }/p' | sed 's/^/    /'
  printf '  %s\n' "  图标是添加那一刻取到的、此后不重绘;上面 icns mtime 与 plist mtime 的错位即证据。"
done
[ "$found" = "1" ] || kv "状态" "未找到任何 Web App 包($HOME/Applications/*.app)"

# ---------- 结论 ----------
h "结论"
case "${MANIFEST_KIND:-}" in
  "self-authored(自造那份 ⇒ 旧版守护)")
    printf '  %s\n' "已装守护仍是旧版:它自己应答 manifest 与图标 ⇒ 你装出来的 Web App 用的是包装器那份名称/图标。"
    printf '  %s\n' "修法(顺序不能反):① 升级包装器(重跑 install.sh,curl|bash 装的是 releases/latest 的预编译 daemon)"
    printf '  %s\n' "                ② 删掉该 Web App 重新添加(图标烘死,改 manifest 不会重绘)"
    printf '  %s\n' "升级前想立刻拿到,可源码安装:git clone https://github.com/3kaiu/dsh-pwa && cd dsh-pwa && bash scripts/install.sh"
    ;;
  "official(官方那份 ⇒ 透传正常)")
    if [ "${ICON_ROUTES:-0}" != "0" ]; then
      printf '  %s\n' "守护二进制里仍有自造路由(见 ①),但它此刻发的是官方 manifest —— 说明已装守护较新、旧路由未生效。"
    fi
    printf '  %s\n' "透传正常:守护发的是官方 manifest。若程序坞图标仍不对,则问题在 app 包(图标烘死)或系统图标缓存。"
    printf '  %s\n' "修法:删掉该 Web App 重新添加;仍不对再 killall Dock。"
    ;;
  "boot-page(守护回了引导页 ⇒ dsh 未就绪,或该路径未被拦截)")
    printf '  %s\n' "守护回了引导页(dsh 未就绪),此刻取不到 PWA 资产。先让 dsh 起来(Safari 打开该地址)再重跑本脚本。"
    ;;
  *)
    printf '  %s\n' "无法判定 —— 请把以上完整输出发来(已脱敏,可直接贴)。"
    ;;
esac
printf '\n'
exit 0
