# dsh-pwa —— 零常驻 macOS PWA 包装器
#
# ⚠️ 本 formula **刻意不在 install 阶段安装运行时**。原因(改这个行为前请先读):
#
#   运行时安装(install.sh)会做三件 Homebrew 不该悄悄做的事:
#     1) 从 nodejs.org 下载 Node LTS(~40MB)并解压到用户状态目录;
#     2) 用 npm/pnpm 把 @deepseek-ai/dsh 装到用户状态目录;
#     3) `launchctl bootout` + `bootstrap` 注册 LaunchAgent。
#   第 3 点是硬理由:`launchctl bootstrap` 在**非图形会话**(SSH / CI / agent 沙箱)中
#   必返 `5: Input/output error`,而 `bootout` 却可能成功 —— 于是会自动把用户本来可用的
#   LaunchAgent **注销掉且无法恢复**。让 `brew install` 自动踩这条路径等于埋雷:
#   Homebrew 完全可能被非图形上下文调用。
#   故本 formula 只做两件事:把**版本化的安装载荷**落进 Cellar,并暴露一个显式入口
#   (`dsh-pwa-install`),由用户在自己的终端里执行。升级同理:重跑该命令。
#
# 载荷版本与 sha256 由 scripts/bump-homebrew-formula.sh 维护(见 packaging/homebrew/README.md)。
class DshPwa < Formula
  desc "Zero-resident macOS wrapper that turns DeepSeek Harness into a desktop PWA"
  homepage "https://github.com/3kaiu/dsh-pwa"
  url "https://github.com/3kaiu/dsh-pwa/releases/download/v0.3.3/dsh-pwa.zip"
  sha256 "d6172276e4496916b18c974446afc0e7370905c45242d0dbced8b461af27061a"
  license "MIT"

  # 仅 macOS:零常驻直接建立在 launchd socket activation 上,Linux/Windows 无等价机制。
  # 不声明最低版本 —— 上游仓库从未声明过版本下限,不在这里凭空发明一个。
  depends_on :macos

  def install
    # 载荷必须**整体保留包根布局**(install.sh 与 daemon / scripts/ / launchd/ 平级),
    # 因为 install.sh 用「自身所在目录」推导 ROOT。
    # 用 Dir.children 而非 Dir["*"]:后者不含点文件,会漏掉 `.daemon.md5` ——
    # install.sh 靠它判断「预编译 daemon 与包内 daemon.c 是否一致」,漏了会静默退化。
    libexec.install Dir.children(".").reject { |f| f == ".brew" }

    # 显式入口。两条约束决定了它的写法:
    #   · 不能把 install.sh 直接 symlink 进 bin —— 那样 $0 是 bin 下的路径,
    #     install.sh 推导出的 ROOT 会指向 bin,找不到载荷;
    #   · 不能用 `exec <path>` 直接执行 —— 包内 install.sh 的权限位是 0644(不可执行),
    #     必须交给 bash 解释(与 README 的 `bash install.sh` 一致)。
    (libexec/"dsh-pwa-install").write <<~SH
      #!/bin/bash
      # 让 install.sh 知道「我是从哪个发行版装的」,用于 $RT_HOME/.wrapper-version。
      # 包内 VERSION 文件自 v0.3.4 起才随包发布;v0.3.3 的载荷没有它,不设此变量
      # 包装器版本会退化成 RELEASE_TAG 的默认值 "latest"。
      # 用户显式设置的值优先,不覆盖。
      export DSH_RT_RELEASE_TAG="${DSH_RT_RELEASE_TAG:-v#{version}}"
      exec bash "#{libexec}/install.sh" "$@"
    SH
    chmod 0755, libexec/"dsh-pwa-install"
    bin.write_exec_script libexec/"dsh-pwa-install"
  end

  def caveats
    <<~EOS
      本 formula 只提供了安装载荷,运行时**尚未安装**(原因见 formula 内注释)。
      请在你自己的终端里执行:

        dsh-pwa-install

      它会下载 Node LTS 与 @deepseek-ai/dsh、安装守护进程、注册 LaunchAgent。
      升级也用这条命令(重跑即跟随上游最新;已装版本不变则跳过)。

      卸载运行时:按 README 的「卸载」一节清理用户数据,然后
        brew uninstall dsh-pwa
    EOS
  end

  test do
    # 只验证载荷完整性(与 release.yml 打包处的硬断言同源),**不触发任何系统改动**。
    %w[install.sh daemon daemon.c pnpm-lock.yaml .daemon.md5].each do |f|
      assert_path_exists libexec/f, "载荷缺少 #{f}"
    end
    %w[cleanup-deps.sh update-dsh.sh dsh-probe.sh].each do |s|
      assert_path_exists libexec/"scripts"/s, "载荷缺少 scripts/#{s}"
    end
    %w[com.dshpwa.daemon.plist com.dshpwa.updater.plist].each do |p|
      assert_path_exists libexec/"launchd"/p, "载荷缺少 launchd/#{p}"
    end
    # 注:VERSION 自 v0.3.4 起随包发布,故此处不断言(v0.3.3 载荷没有它);
    #     「包里必须有 VERSION」这条硬约束由 release.yml 的打包断言负责。
  end
end
