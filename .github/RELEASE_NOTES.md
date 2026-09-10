# dsh-pwa

把 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) 变成 macOS 桌面 PWA:
零常驻架构(launchd socket activation)——登录后没有任何用户态进程,点 PWA 图标时 launchd
自动拉起守护进程与 dsh,关闭页面后 dsh 与守护进程全部退出;Safari「添加到程序坞」即得全屏 Web App。

## 本发行包含

- `install.sh` — 一键安装/升级脚本
- `daemon` — 预编译 universal 守护二进制(arm64 + x86_64,免本地编译)
- `daemon.c` + `.daemon.md5` — 守护源码与其指纹(供后续源码安装判断免编译)
- `launchd/` — 守护与更新器 LaunchAgent 模板
- `scripts/` — 自动更新(`update-dsh.sh`)与依赖清理(`cleanup-deps.sh`)
- `pnpm-lock.yaml` — 预解析依赖树(安装跳解析、提速)

## 安装

方式一(推荐,一条命令自动完成):

```bash
curl -fsSL https://raw.githubusercontent.com/3kaiu/dsh-pwa/main/scripts/install.sh | bash
```

方式二(手动下载发行包):

```bash
curl -LO https://github.com/3kaiu/dsh-pwa/releases/latest/download/dsh-pwa.zip && unzip dsh-pwa.zip && bash install.sh
```

安装完成会自动打开 dsh 页面;Safari 菜单栏 文件 → 添加到程序坞,应用名 **DeepSeek Harness**。

## 亮点

- **零常驻:** 登录不驻留任何进程(零 RSS);首次点图标才经 launchd socket activation 拉起
- **供应链校验:** 发行包 SHA-256 fail-closed 校验;node 二进制取自 nodejs.org 官方
- **安全:** Origin / Host 精确校验(防 CSRF 与 DNS rebinding);状态/日志目录 0700
- **自动更新:** 每天凌晨 2:30 检查并增量更新,失败回滚;活跃会话自动跳过

升级:重跑 install.sh(自动跟随官方 node LTS / dsh latest)。
