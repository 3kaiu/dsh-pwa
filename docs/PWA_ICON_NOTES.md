# PWA 身份:名称与图标为什么以 dsh 官方为准

记录 2026-09-14 的一次实测排查,以及随后据此做的设计取舍。结论先行:**PWA 的名称、图标、
显示模式全部来自 dsh 自带的 manifest,由守护原样透传;包装器不定义、也不覆盖其中任何一项。**

有两条机制与用户直接相关,且都容易误判:

- 图标在「添加到程序坞」**那一刻**被烘进 app 包,此后**不再重绘**(改 manifest 也没用);
- Safari 取图标时,若拿不到 manifest 的 `icons`,会**回落到页面自身的图标**。

## 为什么不由包装器定义

一度自造过一份 manifest 与一套图标,现已撤掉。撤掉的三个理由:

- **官方 manifest 已经是 origin 相对路径。** 它的 `id` / `start_url` / `scope` 全是 `"/"`,
  经守护透传后自然绑定到守护监听的端口 —— dsh 的内部端口从不出现在 manifest 里。当初自造的
  理由是「dsh 的 manifest 会把 PWA 绑到它自己的内部端口」,该理由**不成立**。
- **自造一份的代价不可逆。** 图标在添加那一刻烘进 app 包且不再重绘,于是「官方图标」与
  「包装器图标」谁生效取决于 Safari 的取用时机;一旦落到用户机器上,只能靠删掉重加来更正。
- **两份图标必然漂移。** 包装器那份要自己画、自己维护,与官方图标之间没有任何机制保证同步,
  而用户实际看到哪一份又不可控。

故 `/manifest.webmanifest`、`/favicon.svg` 等路径**不做拦截**,直接透传。

## 机制:图标在添加那一刻定格

导出已安装 Web App 的图标,即可看到它当时取到的是哪一份:

```bash
sips -s format png ~/Applications/deepseek.app/Contents/Resources/ApplicationIcon.icns \
     --out /tmp/appicon.png && open /tmp/appicon.png
```

同一 app 包的 `Info.plist` 里记着 Safari 添加时读到的 manifest:

```bash
plutil -p ~/Applications/deepseek.app/Contents/Info.plist | grep -A12 Manifest
```

两者时间戳不一致即为证据:`ApplicationIcon.icns` 停在**添加那一刻**,而 `Info.plist` 的
`Manifest` 会在之后的每次启动被刷新。实测见过「图标文件比 manifest 记录旧两天」的错位 ——
正是这个错位证明了两件事:**manifest 会被重读,图标不会被重画。**

## 排查:程序坞里的图标不对

按顺序核对,能定位到具体是哪一层:

1. **官方资产本身是否正常** —— 直连 dsh(绕过守护)取 `/manifest.webmanifest` 与
   `/favicon.svg`,确认 dsh 自己发出来的就是预期的那份。
2. **守护是否真的在透传** —— 经守护端口取同样两个路径,响应应与上一步**逐字节一致**。
   若不一致,说明有拦截逻辑残留(这正是本项目撤掉自造 manifest 时要根除的状态)。
3. **app 包里的图标是什么** —— 用上面的 `sips` 导出,与官方 favicon 对照。
4. 以上都对但程序坞仍显示旧图标,则是「图标在添加那一刻定格」那条机制在起作用,按下一节重加。

## 已经装过的人怎么修

**顺序不能反:先升级包装器,再重加。** 只重加不升级,等于把同一份旧图标再烘一遍 —— 看起来像
「改了没用」。

### 第 0 步(最容易漏):确认包装器本身已是最新

旧版守护会**自己应答** `/manifest.webmanifest` 与图标路径(那时它就是「自造 PWA 身份」的),
于是装出来的 Web App 用的是**包装器那份**名称与图标。典型特征:名字 `DSH` + 深色底终端 `>_`
图标,而不是官方的鲸鱼。**这不是图标缓存问题,是二进制问题:**

```bash
# 非 0 = 这份已装二进制仍在自造 PWA 身份(旧版)
strings ~/.local/share/dsh-runtime/daemon | grep -c '/icon.svg'
```

包装器**不会自我更新**:`update-dsh.sh` 只更新 dsh(见 `launchd/com.dshpwa.updater.plist` 注释
「职责单一:仅更新 dsh」);包装器自身的版本机制只把 `wrapper.latest` 写下来、由守护在 `/health`
里比较并暴露 `wrapper_outdated` —— **只报告,不升级**。升级 = 重跑 `install.sh`。

**但「重跑 `install.sh`」要先有新发行版才有效。** `curl | bash` 装的是
`releases/latest/download/dsh-pwa.zip`,包里是**预编译 `daemon`**(install.sh 的「发行包预编译优先」
分支),而撤掉自造身份那次只改了源码 —— 在发新 release 之前,重跑只会装回**同一份旧 daemon**。
两条可行路径:

- **发版**:推一个 tag → `release.yml` 重新编译 `daemon` 并打包。这也是让 `wrapper_outdated`
  真正有意义的前提:已发布的 v0.3.3 那份二进制里**根本没有** `wrapper_version` 字段。
- **源码安装(发版前的临时办法)**:仓库根没有预编译 `daemon`,`DAEMON_SRC` 会命中
  `src/daemon.c` → 本地 clang 编译 HEAD。
  ```bash
  git clone https://github.com/3kaiu/dsh-pwa && cd dsh-pwa && bash scripts/install.sh
  # 验证:应为 0
  strings ~/.local/share/dsh-runtime/daemon | grep -c '/icon.svg'
  ```

### 第 1 步:删掉重新添加

图标在添加那一刻定格,**改 manifest 不会自动更新**,必须删掉重新添加:

```bash
# 1) 从程序坞右键「选项 → 从程序坞移除」,然后删除 Web App
rm -rf ~/Applications/deepseek.app
# 2) Safari 打开 http://127.0.0.1:3080/ ,菜单「文件 → 添加到程序坞」
# 3) 若程序坞仍显示旧图标(系统图标缓存),重启程序坞:
killall Dock
```

## 门禁

`tests/unit/daemon-cases.bats` 断言守护**不自造** PWA 身份:源码里不存在自有的 manifest /
图标定义,路由上不存在对应的拦截分支。这样「有人再加回一份自造图标」会在 CI 变红,而不是在
用户程序坞里变成一次不可逆的取用。

引导页自身声明的 manifest 与图标路径,另有一条门禁钉住它们必须是官方路径 —— 引导页是包装器
自己的 HTML,它的引用是本项目唯一能写错的地方。

## 已知缺口

- **旧版用户收不到任何升级提醒。** 上一版二进制里根本没有 `wrapper_version` 字段
  (`strings ~/.local/share/dsh-runtime/daemon | grep -c wrapper_version` = 0),所以「你该升级了」
  这条信息只能靠 README 与发版说明传达,而读到 README 的人本来就不是需要被提醒的人。
  要让提示真正到达用户,得让引导页把 `/health` 的 `wrapper_outdated` 显示出来 —— **刻意未做**,
  因为引导页是「dsh 没起来时」的兜底,加一块升级提示会与它「尽快把用户送进 dsh」的职责相冲突。
  记录在此,不假装覆盖。
- **端到端门禁用的是桩上游,不是真实 dsh。** 有一条用例断言「守护**逐字转发**上游给的
  manifest 与 favicon」,足以证明守护不再插自己的内容(带反向断言:自造图标的视框一旦出现即失败)。
  但**上游内容的正确性**属于 dsh 自己的发布契约,不在本项目管辖内。
  已用**真实 dsh** 人工复核过一次:经守护取 `/manifest.webmanifest` 与 `/favicon.svg`,
  与 `dsh-web-frontend/dist/` 下的文件 `cmp` 逐字节相同,`Content-Type` 分别为
  `application/manifest+json` 与 `image/svg+xml`。这一步**没有**做成自动门禁 —— 它需要一份
  真实安装的 dsh,不适合放进单测。
- **未就绪窗口内取不到 PWA 资产。** dsh 未启动时,守护对**所有**非控制路径都回引导页,
  manifest 与 favicon 也在其中。该窗口是**自愈**的(reload 进 dsh 后重新取一次),且安装身份
  只在「添加到程序坞」那一刻被真正读取,而那时 dsh 必然已在服务(用户正看着它的界面)。
  若将来要让这个窗口也可安装,需要让守护在未就绪时另发一份官方 manifest —— 那又会把官方内容
  复制一份进来,与本文的取舍直接冲突,故**刻意未做**,并在此写明而不是假装覆盖。

## 仍未验证的部分

- Web App 的显示名。本机装出来叫 `deepseek`(小写),与官方 manifest 的 `short_name`(`DSH`)
  对不上;而另一台跑旧版包装器的机器上装出来叫 `DSH` —— 恰好等于**包装器那份** manifest 的
  `short_name`。两点合起来支持「显示名与图标一样在添加那一刻定格、取自当时的 manifest」,
  但本机的 `deepseek` 究竟取自哪一份(`name` 的首词?页面 `<title>`?)仍**未经确认**。
- 官方 manifest 用 SVG 作 `icons`,而 Safari 对 SVG manifest 图标的接受度本次**未测出结论**。
  这一点已不再是本项目的取舍 —— 官方发什么就用什么,真出问题也是 dsh 侧的发布契约。
  记录在此只为说明:前面「已经装过的人怎么修」那节的重加步骤里,若重加后图标仍不对,
  值得先怀疑这一层。
