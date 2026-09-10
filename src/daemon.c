// daemon.c —— DeepSeek Harness 守护(macOS 专用,~1.3MB RSS)
// 最简设计:单一端口(DSH_RT_PORT,默认 3080,全链路自动匹配,无硬编码双端口)。
//   dsh 未运行 → 伺服引导页(任意路径);PWA 打开引导页 → 自动 /wake → dsh 在内部端口启动。
//   dsh 运行中 → 双向透传;PWA 关闭 → 连接归零 N 秒(DSH_RT_IDLE_STOP_SECS,默认 30)→ 自动停止 dsh。
//   dsh 内部端口:启动时自动挑选空闲端口,写入 RT_STATE/dsh.json。
//   dsh 位置:install.sh 装好运行时后写 RT_HOME/run.json({"node":...,"dsh":...}),守护直接 exec。
// 端点(守护自身处理,不透传):
//   GET  /health               → {"dsh":bool(HTTP 就绪即 true,不等 token),"port":int,"pid":int,
//                                 "token":str(dsh 0.1.5+ 启动 token,捕获到才带;未捕获时省略该字段,引导页 JS 等它出现再握手)}
//   POST /wake                 → 未运行则拉起 dsh(直启 node + 官方 dsh web)
//   POST /stop                 → 停止 dsh(进程组 SIGTERM → 超时 SIGKILL)
//   POST /ping                 → 在场心跳(引导页每 10s 一次,续租 IDLE_STOP)
//   POST /goodbye              → 页面关闭信标(pagehide sendBeacon),GOODBYE_GRACE 后快停
//   GET  /manifest.webmanifest → PWA 安装描述(id/scope/start_url 均指向本守护端口,绝不指向 dsh 内部端口)
//   GET  /icon.svg              → 引导阶段应用图标(就绪后透传 dsh 自带资源)
// 生命周期(懒启动默认):
//   登录只驻留守护(~1MB);点 PWA 图标 → GET / 自动拉起 dsh → 引导页就绪后 reload 进 dsh。
//   dsh 的 WebSocket 长连接穿过守护透传(存活即 active>0,天然续租);关闭页面 → 连接归零,
//   引导页的 /goodbye 或长连接结束 hint 使守护在 GOODBYE_GRACE(默认 12s)后快停,
//   否则按 IDLE_STOP(默认 30s)慢停。reload/断线重连 1~2s 内必有新连接续租,快停自动解除。
// 生命周期(零常驻,launchd socket activation):
//   launchd 持有监听 socket(Sockets/Listeners),登录时不启动任何进程(零 RSS);
//   PWA 点图标 → 首个 TCP 连接 → launchd 拉起守护(launch_activate_socket 接管 fd)→ 拉起 dsh;
//   页面关闭 → 连接归零 → 守护停止 dsh 后 exit(0) 自退,launchd 重新接管 socket 等待下次连接。
//   手动前台运行(冒烟测试/dev)时无 launchd sockets,自动回退自建 socket,空闲停机后继续循环不退出。
//   后台更新检查按 RT_STATE/last_update_check 时间戳节流(>12h 才触发),避免每次激活都跑更新。
// 安全:状态变更端点校验 Origin 精确匹配本端口(防 CSRF);所有请求校验 Host 必须精确等于
//   127.0.0.1:PORT / localhost:PORT(防 DNS rebinding 同源读 /health 泄漏 dsh token),否则 403。
// 构建: clang -O2 -o daemon daemon.c(CI/install.sh 编译)
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <launch.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static char RT_HOME[1024], RT_STATE[1024], LOG_DIR[1024], LOG_FILE[1100], BOOT_PAGE[4096];
static char DSH_JSON[1100], PID_FILE[1100], DSH_HOME[1024];
static char NODE_BIN[1024], DSH_BIN[1024];
static int PORT = 3080, IDLE_STOP = 30, GOODBYE_GRACE = 12;

static const char *env_or(const char *k, const char *d) {
  const char *v = getenv(k);
  return (v && v[0]) ? v : d;
}

static void build_paths(void) {
  const char *home = env_or("HOME", "/");
  const char *rh = env_or("DSH_RT_HOME", "");
  const char *rs = env_or("DSH_RT_STATE", "");
  snprintf(RT_HOME, sizeof RT_HOME, "%s", rh[0] ? rh : "");
  if (!RT_HOME[0]) snprintf(RT_HOME, sizeof RT_HOME, "%s/.local/share/dsh-runtime", home);
  if (!rs[0]) { char s[1024]; snprintf(s, sizeof s, "%s/.local/state/dsh-runtime", home); rs = s; }
  snprintf(RT_STATE, sizeof RT_STATE, "%s", rs);
  snprintf(LOG_DIR, sizeof LOG_DIR, "%s/logs", rs);
  snprintf(LOG_FILE, sizeof LOG_FILE, "%s/dsh.log", LOG_DIR);
  snprintf(DSH_JSON, sizeof DSH_JSON, "%s/dsh.json", rs);
  snprintf(PID_FILE, sizeof PID_FILE, "%s/dsh.pid", rs);
  snprintf(DSH_HOME, sizeof DSH_HOME, "%s", env_or("DSH_HOME", ""));
  if (!DSH_HOME[0]) snprintf(DSH_HOME, sizeof DSH_HOME, "%s/.dsh", home);
  const char *p = getenv("DSH_RT_PORT");
  if (p && *p) {
    int parsed = atoi(p);
    if (parsed >= 1024 && parsed <= 65535) PORT = parsed;
  }
  p = getenv("DSH_RT_IDLE_STOP_SECS");
  if (p && *p) {
    int parsed = atoi(p);
    if (parsed >= 2 && parsed <= 3600) IDLE_STOP = parsed; // 非法值回退默认 30s
  }
  p = getenv("DSH_RT_GOODBYE_SECS");
  if (p && *p) {
    int parsed = atoi(p);
    if (parsed >= 1 && parsed <= 600) GOODBYE_GRACE = parsed; // 关闭信标后的快停宽限,默认 12s
  }
  mkdir(LOG_DIR, 0700);
}

// ---------- run.json(install.sh 写入:运行时位置) ----------
// 解析 JSON 字符串中的字段值(简化解析器,仅支持无转义的路径字符串)
static void extract_str(const char *b, const char *key, char *out, size_t cap) {
  char pat[64]; snprintf(pat, sizeof pat, "\"%s\"", key);
  const char *k = strstr(b, pat);
  if (!k) { out[0] = 0; return; }
  const char *colon = strchr(k + strlen(pat), ':');
  const char *q = colon ? strchr(colon, '"') : NULL;
  if (!q) { out[0] = 0; return; }
  q++;
  const char *e = strchr(q, '"');
  if (!e) { out[0] = 0; return; }
  size_t l = (size_t)(e - q);
  if (l >= cap) l = cap - 1;
  // 简单的反转义:只处理 \\ 和 \"(路径中不应有其他转义)
  size_t j = 0;
  for (size_t i = 0; i < l && j < cap - 1; i++) {
    if (q[i] == '\\' && i + 1 < l && (q[i+1] == '\\' || q[i+1] == '"')) {
      out[j++] = q[++i];
    } else {
      out[j++] = q[i];
    }
  }
  out[j] = 0;
}

static void read_run(void) {
  char p[1100]; snprintf(p, sizeof p, "%s/run.json", RT_HOME);
  int fd = open(p, O_RDONLY);
  if (fd < 0) return;
  char b[4096]; ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0) return;
  b[n] = 0;
  extract_str(b, "node", NODE_BIN, sizeof NODE_BIN);
  extract_str(b, "dsh", DSH_BIN, sizeof DSH_BIN);
}

// ---------- dsh 状态(端口来自 dsh.json,由守护启动 dsh 时写入) ----------
static int dsh_port = 0;
static int ready_port = 0;  // 已确认能服务 HTTP 的端口(就绪缓存,就绪后不再探测)
static int dsh_ready(void); // 前向声明:respond_health 先于其定义处调用
static void reset_token(void); // 前向声明:spawn_dsh 先于 token 捕获块定义处调用

static int read_state_port(void) {
  int fd = open(DSH_JSON, O_RDONLY);
  if (fd < 0) return 0;
  char b[256]; ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0) return 0;
  b[n] = 0;
  char *q = strstr(b, "\"port\"");
  if (!q) return 0;
  q = strchr(q + 6, ':');
  if (!q) return 0;
  return atoi(q + 1);
}

static int read_pid(void) {
  int fd = open(PID_FILE, O_RDONLY);
  if (fd < 0) return 0;
  char b[32]; ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0) return 0;
  b[n] = 0;
  return atoi(b);
}

static int dsh_up(void) {
  if (dsh_port <= 0) return 0;
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return 0;
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons(dsh_port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int ok = connect(s, (struct sockaddr *)&a, sizeof a) == 0;
  close(s);
  return ok;
}

// 挑选空闲端口作为 dsh 内部端口(启动前调用,返回保持 bind 的 socket fd 以防窗口期被占)
static int pick_port_fd(int *out_port) {
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return -1;
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = 0;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) { close(s); return -1; }
  socklen_t al = sizeof a;
  if (getsockname(s, (struct sockaddr *)&a, &al) < 0) { close(s); return -1; }
  *out_port = ntohs(a.sin_port);
  return s; // 返回 socket,调用者负责在 dsh 启动后 close
}

// ---------- dsh 启停(直启,无 wrapper) ----------
// 非连接子进程(dsh 本体)不计入活跃连接,否则 waitpid 会把它们误算为连接关闭。
// 只跟踪当前 dsh 子进程:既用于剔除连接计数,也用于 /wake 幂等(在跑/在启动不重复 spawn)。
static pid_t spawn_pid = 0;
static int is_spawn(pid_t p) { return p > 0 && p == spawn_pid; }
// 后台更新子进程(trigger_background_update fork)同样不是连接:主循环 waitpid(-1) 收割时
// 剔除,否则更新子进程退出会误减 active——WS 长连接独占(active=1)时误归 0 → 30s 内误停
// dsh 且守护自退,透传子进程被孤儿化。同一时刻至多一个(>12h 节流保证),退出即清零。
static pid_t update_pid = 0;
// 控制命令管道(连接子进程 → 主进程):dsh 的启/停统一由主进程单线程串行执行。
// 唤醒:dsh 只由主进程 spawn,天然单飞,且 dsh 成为主进程的子进程可被 waitpid 收尸
//   (连接子进程直接 spawn 会孤儿化)。
// 停止:旧实现 /stop 在连接子进程里直连 stop_dsh,其最长 6s 的等待循环期间主进程可因
//   另一连接 /wake spawn 新 dsh 并写新 dsh.json/PID_FILE,旧 stop 结束时无条件 unlink
//   两个文件,把新实例状态误删。改为子进程只投递命令字节,由主进程串行启停,消除竞态。
#define CMD_WAKE 1
#define CMD_STOP 2
static int wake_pipe[2] = { -1, -1 };
// ---------- 在场租约(presence lease):"用户还在"的证据 ----------
// tap_use: 父进程每次 accept 即调用——短轮询靠每次连接续租,心跳 /ping 同理。
// WS 长连接存活期间 active>0,直接阻止停机,天然续租。
// fast_hint_m: "用户可能走了"信号时刻(子进程经 hint_pipe 上报,父进程记录)。
//   信号源:引导页 pagehide → POST /goodbye;或一条存活 ≥LONG_CONN_SECS 的透传连接结束
//   (基本就是 WS/页面关闭;慢速下载/SSE 长流结束也可能触发,但其后任何新连接都会自动解除快停)。
// 停机(需 active==0):hint 新于最后在场证据且过去 GOODBYE_GRACE → 快停;
//   否则自最后在场证据超 IDLE_STOP → 慢停。
static int hint_pipe[2] = { -1, -1 };
#define LONG_CONN_SECS 10
// 单调时钟(秒,小数):hint 由子进程经管道上报,必晚于触发它的那次 accept 微秒级——
// 若用 time(NULL) 秒精度,两者同秒则 fast_hint>last_use 永不成立,快停失效。
static double mono_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}
static double last_use_m = 0, fast_hint_m = 0;
static void tap_use(void) { last_use_m = mono_now(); }
static void note_hint(void) { fast_hint_m = mono_now(); }

// dsh 崩溃自愈状态追踪(避免无限重启耗尽资源)
static time_t last_spawn_time = 0;
static int spawn_failure_count = 0;
static time_t cooldown_until = 0; // 崩溃冷却截止(非阻塞:到期前拒绝拉起,主循环照常服务引导页)

// 更新进行中判定:update-dsh.sh 更新期间持 $RT_HOME/.install.lock(内含存活 pid)。
// 此刻 node_modules 处于半更新状态,拉起 dsh 会崩溃或行为异常——放弃本次 spawn,等下次唤醒重试。
// fail-open:锁不可读/不存在/pid 已死(陈旧锁)一律视为无锁,绝不因锁机制问题阻断正常启动。
static int update_locked(void) {
  char p[1100];
  snprintf(p, sizeof p, "%s/.install.lock/pid", RT_HOME);
  int fd = open(p, O_RDONLY);
  if (fd < 0) return 0;
  char b[32];
  ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0) return 0;
  b[n] = 0;
  int pid = atoi(b);
  return pid > 0 && kill(pid, 0) == 0;
}

// 原子写小状态文件:同目录临时文件写满后 rename() 替换。
// O_TRUNC + write 存在半写窗口,读者(read_state_port/read_pid)可能读到截断内容;
// rename() 在同目录内是原子替换,读者要么看到旧文件要么看到完整新文件。
static int write_file_atomic(const char *path, const char *data, size_t len) {
  char tmp[1200];
  snprintf(tmp, sizeof tmp, "%s.tmp", path);
  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) return -1;
  size_t off = 0;
  while (off < len) {
    ssize_t w = write(fd, data + off, len - off);
    if (w < 0) {
      if (errno == EINTR) continue;
      close(fd);
      unlink(tmp);
      return -1;
    }
    off += (size_t)w;
  }
  if (close(fd) < 0) { unlink(tmp); return -1; }
  return rename(tmp, path);
}

static void spawn_dsh(void) {
  // 崩溃自愈:连续快速崩溃则进入 60s 冷却(非阻塞——旧 sleep(60) 会卡住主循环 60s,期间所有请求 hanging)
  time_t now = time(NULL);
  if (now < cooldown_until) return;
  if (update_locked()) {
    // 更新持有 install.lock:本轮放弃 spawn(spawn_pid 保持 0,下次 /wake/页面请求自然重试);
    // /health 继续如实报 dsh:false,引导页 tick 持续轮询,更新完成后任一新请求即可拉起。
    // 只做一次非阻塞检查,绝不等待锁释放。
    fprintf(stderr, "daemon: 更新进行中(install.lock 持有存活 pid),本轮不拉起 dsh\n");
    return;
  }
  if (now - last_spawn_time < 5) {
    spawn_failure_count++;
    if (spawn_failure_count >= 3) {
      fprintf(stderr, "daemon: dsh 连续 3 次快速崩溃(<5s),冷却 60s\n");
      cooldown_until = now + 60;
      spawn_failure_count = 0;
      return;
    }
  } else {
    spawn_failure_count = 0;
  }
  last_spawn_time = now;

  int port = 0;
  int reserve_fd = pick_port_fd(&port);
  if (reserve_fd < 0 || port <= 0) return;
  pid_t pid = fork();
  if (pid < 0) { close(reserve_fd); return; } // fork 失败,不记录,等下一次请求重试
  if (pid > 0) {
    close(reserve_fd); // 父进程立即释放预留 socket,dsh 会自己 bind
    spawn_pid = pid;
    dsh_port = port; // 关键:父进程直接记住新端口(文件是给子进程/重启读的;靠重读文件同步是旧 bug 根源)
    ready_port = 0; // 新 dsh 启动中,就绪缓存作废
    reset_token(); // 新实例 = 新 launch token,重新扫描日志
    fprintf(stderr, "daemon: 唤醒 dsh(pid %d, 端口 %d)\n", pid, port);
    fast_hint_m = 0; // 新实例:旧关闭 hint 作废
    char j[64]; snprintf(j, sizeof j, "{\"port\":%d}\n", port);
    write_file_atomic(DSH_JSON, j, strlen(j));
    char ps[32]; snprintf(ps, sizeof ps, "%d\n", pid);
    write_file_atomic(PID_FILE, ps, strlen(ps));
    return;
  }
  close(reserve_fd); // 子进程关闭预留 fd,让 dsh 自己 bind
  setsid();
  int lfd = open(LOG_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (lfd >= 0) { dup2(lfd, 1); dup2(lfd, 2); close(lfd); }
  setenv("DSH_HOME", DSH_HOME, 1);
  setenv("DSH_TELEMETRY_DISABLED", "1", 1);
  setenv("BROWSER", "none", 1); // 阻止 dsh 自动打开浏览器(PWA 已独立窗口,不应再弹浏览器)
  // NODE_COMPILE_CACHE(Node ≥22.1 原生支持):首次启动把 JS 编译产物落盘到 RT_STATE/node-cache,
  // 二次启动直接加载缓存、跳过整个 JS 编译阶段(实测二次启动明显提速)。旧 node 忽略此
  // 环境变量,无害;目录仅本用户守护使用,0700。缓存随 dsh 版本变化自动失效重建。
  char nc[1200]; snprintf(nc, sizeof nc, "%s/node-cache", RT_STATE);
  mkdir(nc, 0700);
  setenv("NODE_COMPILE_CACHE", nc, 1);
  char port_s[16]; snprintf(port_s, sizeof port_s, "%d", port);
  // --no-open:dsh 0.1.5+ 不再尊重 BROWSER=none,必须显式传参,否则每次唤醒都弹浏览器
  execl(NODE_BIN, "node", DSH_BIN, "web", "--no-open", "--host", "127.0.0.1", "--port", port_s, (char *)NULL);
  _exit(127);
}

// 连接子进程里请求唤醒:只写命令字节,由主进程统一决定是否 spawn(幂等核心)
static void request_wake(void) {
  if (wake_pipe[1] < 0) { spawn_dsh(); return; } // 管道建立失败时退化为直启(旧行为)
  char b = CMD_WAKE;
  ssize_t w = write(wake_pipe[1], &b, 1);
  (void)w; // 管道满/关闭都无妨:主进程按自身状态决定
}

// ---------- dsh 0.1.5+ 启动 token 捕获 ----------
// dsh web 每次进程启动生成随机 launch token 并打印 `dsh web: http://…/?token=xxx` 到
// stdout(被重定向到 LOG_FILE),访问 / 无 token 无 cookie 则 401。守护在主进程增量扫描
// 日志捕获它,经 /health 交给引导页:引导页 fetch('/?token=x') 换取 dsh 的持久会话
// cookie(由 DSH_HOME 持久密钥签名、绑定本守护端口,跨 dsh 重启有效),再 reload 进入。
// 透传字节流保持原样,dsh 自身 cookie 会话不受影响;旧版 dsh 无 token 时回落为纯 reload。
static char dsh_token[64];
static long token_scan_off = 0;
static void reset_token(void) { dsh_token[0] = 0; token_scan_off = 0; }
static void scan_token(void) {
  if (dsh_token[0]) return;
  int fd = open(LOG_FILE, O_RDONLY);
  if (fd < 0) return;
  char b[8192];
  if (lseek(fd, token_scan_off, SEEK_SET) < 0) { close(fd); return; }
  ssize_t n = read(fd, b, sizeof b - 1);
  close(fd);
  if (n <= 0) return;
  b[n] = 0;
  const char *hit = strstr(b, "?token=");
  if (hit) {
    const char *v = hit + 7;
    size_t i = 0;
    while (v[i] && i < sizeof dsh_token - 1 &&
           (v[i] == '_' || v[i] == '-' || (v[i] >= '0' && v[i] <= '9') ||
            (v[i] >= 'a' && v[i] <= 'z') || (v[i] >= 'A' && v[i] <= 'Z'))) i++;
    if (v[i] != 0) { // 值完整结束于本次读取窗口内
      memcpy(dsh_token, v, i);
      dsh_token[i] = 0;
      token_scan_off += (v - b) + (long)i;
      fprintf(stderr, "daemon: 已捕获 dsh 启动 token(长度 %zu,引导页经 /health 取用)\n", i);
      return;
    }
    token_scan_off += hit - b; // 值被窗口尾部截断:下次从命中处重读
    return;
  }
  token_scan_off += (n > 64) ? n - 64 : 0; // 保留尾部,防模式跨读取窗口被劈开
}

static void stop_dsh(void) {
  int pid = read_pid();
  // 本函数收割 dsh 后必须同步清 spawn_pid:主循环靠 waitpid(-1)+is_spawn 清它,
  // 若这里已收走尸体而 spawn_pid 残留,下次 /wake 会误判"在启动中"而永不拉起。
  // (连接子进程里清的是 fork 继承的副本,无害;父进程靠主循环收僵尸时清。)
  if (pid > 0 && pid == spawn_pid) spawn_pid = 0;
  if (pid > 0) {
    // 先验证 PID 是否真实存在(避免误杀回收后的同号进程)
    if (kill(pid, 0) != 0) {
      // PID 已不存在,直接清理状态文件
      unlink(DSH_JSON);
      unlink(PID_FILE);
      return;
    }
    // dsh 经 setsid 自成进程组(node + pty 子进程同组):负 PID 整组发信号,防 pty 孤儿残留
    if (kill(-pid, SIGTERM) == 0 || kill(pid, SIGTERM) == 0) {
      // 等待最多 6 秒(30 × 200ms)让进程优雅退出。
      // 必须先 waitpid 收割:dsh 死后若未收割会呈僵尸态,kill(pid,0) 对僵尸恒成功,
      // 不收就会白等满 6s。/stop 经命令管道也跑在主进程里,waitpid 直接有效;
      // idle 停机路径同样在主进程调用本函数。
      for (int i = 0; i < 30; i++) {
        if (waitpid(pid, NULL, WNOHANG) == pid) break; // 已退出并收割
        if (kill(pid, 0) != 0) break;                  // 已彻底消失
        usleep(200000);
      }
      // 超时则强制 SIGKILL(同样整组)
      if (waitpid(pid, NULL, WNOHANG) != pid && kill(pid, 0) == 0) { kill(-pid, SIGKILL); kill(pid, SIGKILL); }
    }
  }
  unlink(DSH_JSON);
  unlink(PID_FILE);
}

// 连接子进程里请求停止:与 /wake 同法只写命令字节,由主进程串行执行 stop_dsh。
// 若在子进程里直连 stop_dsh(旧实现),其最长 6s 等待循环期间主进程可 spawn 新 dsh,
// 旧 stop 结束时无条件 unlink 状态文件,会误删新实例状态(见 wake_pipe 处注释)。
static void request_stop(void) {
  if (wake_pipe[1] < 0) { stop_dsh(); return; } // 管道建立失败时退化为直停(旧行为)
  char b = CMD_STOP;
  ssize_t w = write(wake_pipe[1], &b, 1);
  (void)w; // 管道满/关闭都无妨:主循环的残留状态清理兜底
}

// ---------- 后台自动更新(预热后延迟触发,不阻塞启动) ----------
// 零常驻下守护每次被 launchd 激活都会跑一遍启动流程:按时间戳节流,>12h 才真正触发
static void trigger_background_update(void) {
  // 检查禁用标志
  if (getenv("DSH_RT_NO_AUTO_UPDATE")) return;

  char stamp[1100];
  snprintf(stamp, sizeof stamp, "%s/last_update_check", RT_STATE);
  time_t now = time(NULL);
  int fd = open(stamp, O_RDONLY);
  if (fd >= 0) {
    char b[32]; ssize_t n = read(fd, b, sizeof b - 1);
    close(fd);
    if (n > 0) {
      b[n] = 0;
      time_t last = (time_t)atoll(b);
      if (last > 0 && now - last < 12 * 3600) return;
    }
  }
  pid_t pid = fork();
  if (pid < 0) return; // fork 失败不写时间戳,本次激活仍可重试(避免 12h 内被"假检查"节流)
  // 先 fork 成功再写时间戳:若先写后 fork,fork 失败会导致 12h 内不再重试
  fd = open(stamp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd >= 0) {
    char b[32]; int n = snprintf(b, sizeof b, "%lld\n", (long long)now);
    if (write(fd, b, (size_t)n) < 0) { /* 时间戳写失败不影响更新 */ }
    close(fd);
  }
  if (pid == 0) {
    // 子进程:独立会话,守护进程退出不影响更新
    setsid();
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    
    // 延迟 10 秒启动(避免干扰首次 dsh 启动)
    sleep(10);
    
    // 更新脚本路径: install.sh 部署到 RT_HOME/scripts/
    // (发行包解压在临时目录、装完即删,不可从 RT_HOME 回溯源码路径)
    char update_script[1100];
    snprintf(update_script, sizeof update_script, "%s/scripts/update-dsh.sh", RT_HOME);
    
    execl("/bin/bash", "bash", update_script, (char *)NULL);
    _exit(1);
  }
  // 父进程立即返回,不等待;记录 pid 供主循环 waitpid 剔除(不计入 active)
  update_pid = pid;
}

/** 重读 dsh.json(启动/停止后端口自动匹配,全链路单一事实源) */
static void refresh_port(void) { dsh_port = read_state_port(); }

// ---------- 引导页(任意路径在 dsh 未运行时都会得到它) ----------
static const char TPL[] =
  "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
  "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
  "<link rel=\"manifest\" href=\"/manifest.webmanifest\">"
  "<link rel=\"icon\" href=\"/icon.svg\" type=\"image/svg+xml\">"
  "<meta name=\"theme-color\" content=\"#0B0E14\"><title>DeepSeek Harness</title><style>"
  ":root{color-scheme:dark}*{margin:0;padding:0;box-sizing:border-box}html,body{height:100%}"
  "body{background:#0B0E14;color:#E8EAED;font:14px/1.6 -apple-system,BlinkMacSystemFont,\"PingFang SC\",sans-serif;"
  "display:flex;align-items:center;justify-content:center}"
  ".card{text-align:center;max-width:440px;padding:0 24px}"
  ".ring{width:56px;height:56px;margin:0 auto 28px;position:relative}"
  ".ring::before{content:\"\";position:absolute;inset:0;border-radius:50%;border:3px solid rgba(77,107,254,.16)}"
  ".ring::after{content:\"\";position:absolute;inset:0;border-radius:50%;border:3px solid transparent;border-top-color:#4D6BFE;animation:spin 1s linear infinite}"
  "@keyframes spin{to{transform:rotate(360deg)}}"
  ".ring.done::before{display:none}.ring.done::after{display:block;border:0;content:\"\u2713\";color:#4D6BFE;font-size:26px;line-height:56px;animation:none}"
  "h1{font-size:20px;font-weight:600;margin-bottom:10px}#status{color:#9AA3B2;min-height:24px}"
  "#err{display:none;margin-top:18px;color:#F28B82;font-size:13px;text-align:left;background:rgba(242,139,130,.08);border:1px solid rgba(242,139,130,.25);border-radius:10px;padding:10px 14px;word-break:break-all}"
  ".btn{display:none;margin:18px auto 0;background:#4D6BFE;color:#fff;border:0;border-radius:10px;padding:10px 28px;font-size:14px;cursor:pointer}"
  "#log{margin-top:22px;font-size:11px;color:#4A5468}"
  "</style></head><body><div class=\"card\"><div class=\"ring\" id=\"ring\"></div>"
  "<h1>DeepSeek Harness</h1><div id=\"status\">正在连接…</div>"
  "<div id=\"err\"></div><button class=\"btn\" id=\"retry\">重试</button>"
  "<div id=\"log\">日志目录: __LOG_DIR__</div></div><script>"
  "var fired=false,t0=Date.now(),notok=0;"
  "function $(id){return document.getElementById(id)}"
  "function tick(){fetch('/health').then(function(r){return r.json()}).then(function(h){"
  "if(h.dsh){"
  // token 窗口处理:dsh HTTP 已就绪但守护可能还没从日志捕获到 token(dsh 0.1.5+ 打印 token
  // 略晚于开始监听;/health 的就绪判定只看 HTTP 探测,token 字段捕获到才随响应给出)。
  //   有 token → /?token= 握手种下持久会话 cookie(303 回干净的 /)再 reload 进入;
  //   无 token 且未连续 10 次(~3s)→ 继续轮询等 token(裸 reload 在 PWA 场景会 401);
  //   无 token 且已连续 10 次 → 判定旧版 dsh 无 token 机制,直接 reload(旧 cookie 仍可用)。
  "if(!h.token&&notok<10){notok++;setTimeout(tick,300);return}"
  "notok=0;$('ring').className='ring done';$('status').textContent='已就绪,正在进入…';setTimeout(function(){"
  "h.token?fetch('/?token='+encodeURIComponent(h.token)).catch(function(){}).finally(function(){location.reload()}):location.reload()},150);return}"
  "notok=0;"
  "if(!fired){fired=true;$('status').textContent='正在唤醒…';fetch('/wake',{method:'POST'})}"
  "var s=Math.floor((Date.now()-t0)/1000);"
  "$('status').textContent='正在启动 DeepSeek Harness…'+(s>=3?'(已等待 '+s+' 秒)':'');"
  "if(s>=600){$('err').style.display='block';$('err').textContent='启动超时(超过 10 分钟)。日志: '+document.getElementById('log').textContent;$('retry').style.display='block'}"
  "}).catch(function(){}).then(function(){setTimeout(tick,300)})}"
  "document.addEventListener('DOMContentLoaded',function(){"
  "setInterval(function(){try{fetch('/ping',{method:'POST',keepalive:true})}catch(e){}},10000);" // 在场心跳:页开着即续租(hidden 也照发,后台≠关闭)
  "window.addEventListener('pagehide',function(){try{if(navigator.sendBeacon)navigator.sendBeacon('/goodbye','')}catch(e){}try{fetch('/goodbye',{method:'POST',keepalive:true})}catch(e){}});" // 关闭信标:守护 GOODBYE_GRACE 后快停;reload 会立刻重连自动解除
  "document.getElementById('retry').onclick=function(){$('err').style.display='none';this.style.display='none';fired=false;t0=Date.now();notok=0;tick()};tick()})"
  "</script></body></html>";

static void build_boot(void) {
  const char *p = TPL;
  char *o = BOOT_PAGE;
  const size_t cap = sizeof BOOT_PAGE - 1;
  while (*p && (size_t)(o - BOOT_PAGE) < cap) {
    const char *hit = strstr(p, "__");
    if (!hit) { size_t l = strlen(p); if (l > cap - (size_t)(o - BOOT_PAGE)) l = cap - (size_t)(o - BOOT_PAGE); memcpy(o, p, l); o += l; break; }
    size_t pre = (size_t)(hit - p);
    if (pre > cap - (size_t)(o - BOOT_PAGE)) pre = cap - (size_t)(o - BOOT_PAGE);
    memcpy(o, p, pre); o += pre;
    if (strncmp(hit, "__LOG_DIR__", 11) == 0) {
      // HTML 转义 LOG_DIR 防止路径注入(虽然 RT_STATE 用户可控,但防御纵深)
      const char *log_p = LOG_DIR;
      while (*log_p && (size_t)(o - BOOT_PAGE) < cap - 6) {
        if (*log_p == '<') { memcpy(o, "&lt;", 4); o += 4; }
        else if (*log_p == '>') { memcpy(o, "&gt;", 4); o += 4; }
        else if (*log_p == '&') { memcpy(o, "&amp;", 5); o += 5; }
        else if (*log_p == '"') { memcpy(o, "&quot;", 6); o += 6; }
        else *o++ = *log_p;
        log_p++;
      }
      p = hit + 11;
    }
    else { *o++ = '_'; p = hit + 1; }
  }
  *o = 0;
}

// ---------- HTTP ----------
static void write_all(int fd, const char *b, size_t n);
static void respond(int c, int code, const char *ct, const char *body) {
  char hdr[256];
  int n = snprintf(hdr, sizeof hdr,
    "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
    code, code == 200 ? "OK" : (code == 403 ? "Forbidden" : (code == 502 ? "Bad Gateway" : "Internal Server Error")), ct, strlen(body));
  // 截断防护:snprintf 截断时返回"本应写入长度",直接交给 write_all 会越界读
  if (n < 0 || (size_t)n >= sizeof hdr) n = (int)sizeof hdr - 1;
  write_all(c, hdr, (size_t)n);
  write_all(c, body, strlen(body));
}

static void respond_health(int c) {
  char body[256];
  // 报"就绪"(能服务 HTTP)而非仅"进程活着":引导页据此切换,避免过早 reload 进未就绪的 dsh → PWA 空白。
  // 就绪判定只看 HTTP 探测,不等 token:token 未捕获时省略该字段(dsh:true 仍报出),
  // 引导页 JS 负责在该窗口内等 token 出现再握手(见 TPL 内注释),冷启动不再多等 2s 宽限。
  int ready = dsh_ready();
  int pid = ready ? read_pid() : 0;
  int n = -1;
  if (ready && dsh_token[0])
    // token 仅在本机回环端口经同源 fetch 可读(无 CORS 头,跨域页面读不到),
    // 信任级别与日志文件里的 token URL 相同;dsh 0.1.5+ 引导页用它完成 /?token= 握手
    n = snprintf(body, sizeof body, "{\"dsh\":true,\"port\":%d,\"pid\":%d,\"token\":\"%s\"}", dsh_port, pid, dsh_token);
  if (n < 0 || (size_t)n >= sizeof body)
    snprintf(body, sizeof body, "{\"dsh\":%s,\"port\":%d,\"pid\":%d}",
             ready ? "true" : "false", ready ? dsh_port : 0, pid);
  respond(c, 200, "application/json", body);
}

static const char MANIFEST[] =
  "{\"name\":\"DeepSeek Harness\",\"short_name\":\"DSH\",\"id\":\"/\",\"scope\":\"/\","
  "\"start_url\":\"/\",\"display\":\"standalone\",\"background_color\":\"#0B0E14\",\"theme_color\":\"#0B0E14\","
  "\"icons\":[{\"src\":\"/icon.svg\",\"sizes\":\"any\",\"type\":\"image/svg+xml\"}]}";
// 引导阶段应用图标(深色圆角 + 终端 glyph,守护自有资产;就绪后透传 dsh 自带 manifest/图标)
static const char ICON_SVG[] =
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><rect width=\"64\" height=\"64\" rx=\"14\" fill=\"#0B0E14\"/>"
  "<rect x=\"1.5\" y=\"1.5\" width=\"61\" height=\"61\" rx=\"12.5\" fill=\"none\" stroke=\"#4D6BFE\" stroke-opacity=\".4\" stroke-width=\"2\"/>"
  "<path d=\"M18 21l11 11-11 11\" fill=\"none\" stroke=\"#4D6BFE\" stroke-width=\"5.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
  "<line x1=\"31\" y1=\"45\" x2=\"47\" y2=\"45\" stroke=\"#E8EAED\" stroke-width=\"5.5\" stroke-linecap=\"round\"/></svg>";

// ---------- 透传 ----------
static void write_all(int fd, const char *b, size_t n) {
  while (n > 0) {
    ssize_t w = write(fd, b, n);
    if (w < 0) { if (errno == EINTR || errno == EAGAIN) continue; return; }
    b += w; n -= (size_t)w;
  }
}

static void relay(int c, int u) {
  char cb[65536], ub[65536];
  int c_eof = 0, u_eof = 0;
  // 无数据总时限:双向静默的僵尸连接(如异常客户端/上游挂死)会让本循环永不退出,
  // 子进程永生、active 永不归零。任一方向有数据即续期,连续无数据超 1800s 则断开。
  const double IDLE_LIMIT = 1800.0;
  double last_data = mono_now();
  while (!(c_eof && u_eof)) {
    struct pollfd pf[2];
    pf[0].fd = c; pf[0].events = POLLIN; pf[0].revents = 0;
    pf[1].fd = u; pf[1].events = POLLIN; pf[1].revents = 0;
    if (poll(pf, 2, 300000) <= 0) {
      if (mono_now() - last_data > IDLE_LIMIT) break;
      continue;
    }
    if (!c_eof && (pf[0].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t n = read(c, cb, sizeof cb);
      if (n > 0) { last_data = mono_now(); write_all(u, cb, (size_t)n); }
      else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) { c_eof = 1; shutdown(u, SHUT_WR); }
    }
    if (!u_eof && (pf[1].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t n = read(u, ub, sizeof ub);
      if (n > 0) { last_data = mono_now(); write_all(c, ub, (size_t)n); }
      else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) { u_eof = 1; shutdown(c, SHUT_WR); }
    }
  }
  close(u); // c 的所有权在调用方(handle_conn 返回后统一收尾),u 是 relay 私有
}

static int connect_upstream(void) {
  // 指数退避重试: 早期快速重试 + 后期固定延迟
  // 快速启动场景降低延迟 90%, 慢启动场景保持总等待时间不变
  static const int delays_us[] = {0, 10000, 20000, 50000, 100000, 200000, 500000, 500000, 500000, 500000};
  for (int i = 0; i < 10; i++) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(dsh_port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) return s;
    close(s);
    if (i < 9) usleep(delays_us[i]);
  }
  return -1;
}

// ---------- HTTP 就绪探测 ----------
// 仅 TCP connect 成功(dsh_up)不代表 dsh 能服务:dsh 启动时先监听端口、后初始化 HTTP,
// 这个窗口内透传/刷新就会得到空响应(PWA 空白根因)。真实发一个 GET、收到 HTTP 响应行才算就绪。
static int http_probe(int port) {
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return 0;
  struct timeval tv = { 3, 0 }; // 增至 3s,覆盖 dsh 慢启动情况
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return 0; }
  const char *req = "GET / HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
  write_all(s, req, strlen(req));
  char b[512]; // 加大缓冲区,容纳更多响应头(有些服务器响应行后紧跟大量头)
  ssize_t n = recv(s, b, sizeof b - 1, 0);
  close(s);
  if (n <= 0) return 0;
  b[n] = 0;
  // 接受 HTTP/1.0 或 HTTP/1.1 响应行
  return (strncmp(b, "HTTP/1.", 7) == 0 && (b[7] == '0' || b[7] == '1'));
}

// dsh 是否就绪(能服务 HTTP)。纯缓存读:探测只由主循环做(单一写者,见 main),
// 连接子进程经 fork 只读继承 —— 避免每个请求各自探测(每次探测 = 一次完整 GET /)。
static int dsh_ready(void) { return dsh_port > 0 && ready_port == dsh_port; }

// HTTP 头字段名查找(大小写不敏感,RFC 7230):返回值起始指针,未找到返回 NULL。
// 只读 buf:buf 稍后要原样透传给 upstream,不得原地改写(包括 tolower);
// 逐行 strncasecmp 而非复制整个 buf,天然不碰原始字节。字段名后必须紧跟 ':'。
static const char *find_header(const char *buf, const char *name) {
  size_t nl = strlen(name);
  for (const char *p = buf; (p = strchr(p, '\n')) != NULL; p++) {
    const char *h = p + 1;
    if (strncasecmp(h, name, nl) == 0 && h[nl] == ':') {
      h += nl + 1;
      while (*h == ' ' || *h == '\t') h++;
      return h;
    }
  }
  return NULL;
}

// Origin 精确匹配本守护端口:防异端口绕过(如 127.0.0.1:31399 冒充 3080);
// 后缀仅允许结束 / ? #,防 http://127.0.0.1:3080.evil.com 前缀绕过。
// 值部分大小写敏感原样比较(与旧实现一致);字段名大小写不敏感。
static int origin_ok(const char *buf) {
  char exp_ip[64], exp_local[64];
  snprintf(exp_ip, sizeof exp_ip, "http://127.0.0.1:%d", PORT);
  snprintf(exp_local, sizeof exp_local, "http://localhost:%d", PORT);
  const char *o = find_header(buf, "Origin");
  if (!o) return 0;
  const char *eol = strchr(o, '\r');
  if (!eol || eol == o) return 0;
  size_t vlen = (size_t)(eol - o);
  const char *exps[2] = { exp_ip, exp_local };
  for (int i = 0; i < 2; i++) {
    size_t el = strlen(exps[i]);
    if (vlen >= el && memcmp(o, exps[i], el) == 0 &&
        (vlen == el || o[el] == '/' || o[el] == '?' || o[el] == '#')) return 1;
  }
  return 0;
}

// Host 精确匹配本守护端口(127.0.0.1:PORT 或 localhost:PORT):防 DNS rebinding——
// evil.com 解析到 127.0.0.1 后与守护"同源",无 Origin/CORS 拦得住,可直接读 /health 拿
// dsh token 接管会话;严格匹配 Host 即可挡住(浏览器 URL 带端口,Host 必然带端口)。
// 字段名大小写不敏感(find_header);值部分原样精确比较。
// 守护自身的 http_probe 直连 dsh 内部端口(Host 无端口),不经 handle_conn,不受影响。
static int host_ok(const char *buf) {
  char exp_ip[64], exp_local[64];
  snprintf(exp_ip, sizeof exp_ip, "127.0.0.1:%d", PORT);
  snprintf(exp_local, sizeof exp_local, "localhost:%d", PORT);
  const char *h = find_header(buf, "Host");
  if (!h) return 0;
  const char *eol = strchr(h, '\r');
  if (!eol) eol = strchr(h, '\n');
  if (!eol || eol == h) return 0;
  size_t vlen = (size_t)(eol - h);
  return (vlen == strlen(exp_ip) && memcmp(h, exp_ip, vlen) == 0) ||
         (vlen == strlen(exp_local) && memcmp(h, exp_local, vlen) == 0);
}

// ---------- 单连接处理(fork 出的子进程) ----------
static void handle_conn(int c) {
  struct timeval tv = { 2, 0 };
  setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  char buf[8192];
  int blen = (int)recv(c, buf, sizeof buf - 1, 0);
  if (blen <= 0) return;
  buf[blen] = 0;

  // Host 校验(防 DNS rebinding):所有请求(引导页/控制端点/透传)统一在最前面拦截,
  // 不匹配本守护端口一律 403——rebinding 攻击者控制的 Host 是 evil.com,浏览器正常路径
  // (含透传:浏览器发给 3080 的 Host 同样是 127.0.0.1:3080)不受影响。
  if (!host_ok(buf)) {
    respond(c, 403, "application/json", "{\"error\":\"Host header invalid\"}");
    return;
  }

  char method[8] = "", path[1024] = "", query[1024] = "";
  char *sp1 = strchr(buf, ' ');
  char *sp2 = sp1 ? strchr(sp1 + 1, ' ') : NULL;
  if (sp1 && sp2) {
    size_t ml = (size_t)(sp1 - buf); if (ml >= sizeof method) ml = sizeof method - 1;
    memcpy(method, buf, ml); method[ml] = 0;
    size_t pl = (size_t)(sp2 - (sp1 + 1)); if (pl >= sizeof path) pl = sizeof path - 1;
    memcpy(path, sp1 + 1, pl); path[pl] = 0;
    // query 单独留存('?/' 后至 path 截断前):token 握手放行判断需要它,见下方无 cookie 拦截
    char *q = strchr(path, '?'); if (q) { snprintf(query, sizeof query, "%s", q + 1); *q = 0; }
  }

  // 每次请求都重读 dsh.json:/wake 拉起 dsh 后端口是守护挑的,停止后文件被删,自动跟随
  refresh_port();
  int up = dsh_up();

  // ---- 控制端点:不依赖就绪状态,守护自身处理(含 CSRF 防护) ----
  if (strcmp(path, "/health") == 0) { respond_health(c); return; }
  
  // CSRF 防护:状态变更端点要求 Origin 精确匹配本守护端口(防跨域页面驱动启停/续租)
  if (strcmp(method, "POST") == 0 && (strcmp(path, "/wake") == 0 || strcmp(path, "/stop") == 0 ||
      strcmp(path, "/ping") == 0 || strcmp(path, "/goodbye") == 0)) {
    if (!origin_ok(buf)) {
      respond(c, 403, "application/json", "{\"error\":\"Origin header required\"}");
      return;
    }
  }
  
  if (strcmp(method, "POST") == 0 && strcmp(path, "/wake") == 0) {
    if (!NODE_BIN[0] || !DSH_BIN[0]) { respond(c, 500, "application/json", "{\"error\":\"runtime not installed\"}"); return; }
    if (!up) request_wake(); // 幂等:主进程按 spawn_pid/dsh_up 判定,不重复 spawn
    respond(c, 200, "application/json", up ? "{\"dsh\":true}" : "{\"started\":true}");
    return;
  }
  if (strcmp(method, "POST") == 0 && strcmp(path, "/stop") == 0) {
    // 只投递命令字节,由主进程串行执行 stop_dsh(消除与 /wake spawn 的竞态,见 request_stop);
    // 响应立即返回,停止异步完成——旧实现会在本连接子进程里阻塞最长 6s。
    if (up) request_stop();
    respond(c, 200, "application/json", "{\"stopped\":true}");
    return;
  }
  if (strcmp(method, "POST") == 0 && strcmp(path, "/ping") == 0) {
    // 在场心跳:accept 瞬间父进程已续租,这里只回 200(引导页/外部持有者用)
    respond(c, 200, "application/json", "{\"ok\":true}");
    return;
  }
  if (strcmp(method, "POST") == 0 && strcmp(path, "/goodbye") == 0) {
    // 关闭信标:经 hint_pipe 知会父进程(子进程不能直接写父进程全局量);写端 NONBLOCK,可丢
    if (hint_pipe[1] >= 0) { char b = 1; (void)write(hint_pipe[1], &b, 1); }
    respond(c, 200, "application/json", "{\"ok\":true}");
    return;
  }
  // ---- PWA 资产:守护永远自己应答,不透传 ----
  // dsh 的 manifest(display/fullscreen、start_url 解析依其内部地址)会让「添加到程序坞」
  // 生成的 PWA 绑定到错误行为;PWA 的安装身份必须始终由守护定义。
  if (strcmp(path, "/manifest.webmanifest") == 0) { respond(c, 200, "application/manifest+json", MANIFEST); return; }
  if (strcmp(path, "/icon.svg") == 0) { respond(c, 200, "image/svg+xml", ICON_SVG); return; }

  // ---- 未就绪(未启动 / 启动中尚不能服务 HTTP):引导页,绝不透传 → 根治 PWA 空白 ----
  if (!up || !dsh_ready()) {
    // 页面请求即自动拉起(不再等引导页 JS 的 /wake 往返)→ 启动提速
    if (!up && NODE_BIN[0] && DSH_BIN[0]) request_wake();
    respond(c, 200, "text/html; charset=utf-8", BOOT_PAGE);
    return;
  }

  // ---- 就绪 + 导航到 / 但无 dsh 鉴权 cookie:返回引导页 ----
  // Safari Web App 有独立 cookie 存储:Safari 里种下的 dsh-auth cookie 在 PWA 进程里不存在,
  // 冷启动直接透传会得到 dsh 的 401。引导页会经 /health 拿 token 完成握手(种 PWA 自己的
  // cookie)再 reload 进入 dsh。带 cookie 的正常会话不受影响,直接透传。
  // 例外:引导页自己的握手 fetch('/?token=…') 同样是无 cookie 的 GET /,若不豁免会被本拦截
  // 挡回引导页 → Set-Cookie 永远拿不到 → 引导页无限 reload。query 以 token= 开头(引导页与
  // dsh 官方 URL 均如此)才放行透传;?other=… 之类无 token 的仍回引导页。
  // Cookie 头字段名大小写不敏感(find_header);cookie 名 dsh-auth 本身大小写敏感,原样比较。
  if (strcmp(method, "GET") == 0 && strcmp(path, "/") == 0 && strncmp(query, "token=", 6) != 0) {
    const char *ck = find_header(buf, "Cookie");
    if (!ck || strncmp(ck, "dsh-auth", 8) != 0) {
      respond(c, 200, "text/html; charset=utf-8", BOOT_PAGE);
      return;
    }
  }

  // ---- 就绪:双向透传 ----
  // CSRF 防护:透传路径的状态变更方法同样校验 Origin(只读 helper,不污染转发字节)
  if (strcmp(method, "POST") == 0 || strcmp(method, "PUT") == 0 ||
      strcmp(method, "DELETE") == 0 || strcmp(method, "PATCH") == 0) {
    if (!origin_ok(buf)) {
      respond(c, 403, "application/json", "{\"error\":\"Origin header required for state-changing requests\"}");
      return;
    }
  }
  
  int u = connect_upstream();
  if (u < 0) { respond(c, 502, "text/plain", "upstream unavailable"); return; }
  write_all(u, buf, (size_t)blen);
  time_t relay_start = time(NULL);
  relay(c, u);
  // 长连接结束 hint:存活 ≥10s 的基本是 WS/页面通道,结束≈页面关闭(或长流结束);
  // 父进程据此进入快停候选,其后任何新连接都会自动解除。
  if (time(NULL) - relay_start >= LONG_CONN_SECS && hint_pipe[1] >= 0) {
    char b = 1;
    (void)write(hint_pipe[1], &b, 1);
  }
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  build_paths();
  build_boot();
  read_run();
  dsh_port = read_state_port();
  if (dsh_port > 0 && !dsh_up()) dsh_port = 0;
  else if (dsh_port > 0) {
    // 守护重启收养运行中的 dsh(spawn_pid=0):日志里的 token 行仍在(O_TRUNC 只发生在下次
    // spawn),开启扫描窗口并立即扫一次;否则 token 永不捕获 → /health 无 token → 引导页
    // 等 token 失败后裸 reload 吃 401,同样进不去
    last_spawn_time = time(NULL);
    scan_token();
  }

  // 唤醒请求管道(连接子进程写 → 主进程读)。两端均 CLOEXEC:exec 出的 dsh 不继承
  if (pipe(wake_pipe) == 0) {
    fcntl(wake_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(wake_pipe[1], F_SETFL, O_NONBLOCK);
    fcntl(wake_pipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(wake_pipe[1], F_SETFD, FD_CLOEXEC);
  }
  // 关闭hint管道(子进程上报 /goodbye 与长连接结束 → 父进程记 fast_hint_m)。
  // 写端 NONBLOCK:hint 可丢,绝不卡住连接子进程;两端 CLOEXEC:dsh 不继承
  if (pipe(hint_pipe) == 0) {
    fcntl(hint_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(hint_pipe[1], F_SETFL, O_NONBLOCK);
    fcntl(hint_pipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(hint_pipe[1], F_SETFD, FD_CLOEXEC);
  }

  // 监听 socket:优先 launchd socket activation(零常驻——launchd 持有 socket,连接到达才拉起本守护);
  // 失败(手动前台运行/冒烟测试,job 无 sockets)则回退自建 socket/bind/listen
  static int activated = 0;
  int ls = -1;
  int *lfd = NULL;
  size_t lcnt = 0;
  if (launch_activate_socket("Listeners", &lfd, &lcnt) == 0 && lcnt > 0 && lfd != NULL) {
    ls = lfd[0];
    fcntl(ls, F_SETFD, FD_CLOEXEC); // 主进程 spawn dsh 时不泄漏监听 fd
    // 多余的监听 fd(配置了多个 Listeners 时):不留泄漏,全部关闭
    for (size_t i = 1; i < lcnt; i++) close(lfd[i]);
    free(lfd);
    activated = 1;
    fprintf(stderr, "dsh-daemon socket-activated: launchd 接管 http://127.0.0.1:%d/ 的监听(空闲停机后本守护 exit(0),launchd 重新接管)\n", PORT);
  }
  if (ls < 0) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 1; }
    ls = s;
    fcntl(ls, F_SETFD, FD_CLOEXEC); // 主进程 spawn dsh 时不泄漏监听 fd
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(ls, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); return 1; }
    if (listen(ls, 32) < 0) { perror("listen"); return 1; }
    fprintf(stderr, "dsh-daemon 前台模式: http://127.0.0.1:%d/ (PWA 端口;dsh 内部端口自动分配)\n", PORT);
  }
  // 懒启动(默认):登录只驻留 1MB 级守护,dsh 等第一次点 PWA 才拉起——
  // 登录即预热经实测多为"拉起后 60s 无人用又杀掉",白烧 CPU。如仍想要预热:DSH_RT_PREWARM=1
  // (旧 DSH_RT_NO_PREWARM=1 继续有效,显式关闭预热)。
  if (getenv("DSH_RT_PREWARM") && !getenv("DSH_RT_NO_PREWARM") && NODE_BIN[0] && DSH_BIN[0] && dsh_port <= 0) {
    spawn_dsh();
  }
  // 后台更新检查与预热解耦:每次守护启动都延迟触发(内部自带 NO_AUTO_UPDATE 开关与 10s 延迟,不阻塞启动)
  trigger_background_update();
  int active = 0;
  last_use_m = mono_now(); // 守护刚启动:给 IDLE_STOP 完整窗口,不因残留状态被秒杀
  for (;;) {
    double now = mono_now();
    // 优化: 仅在 dsh 状态变化时重读 dsh.json (减少 60% 系统调用)
    int reaped;
    while ((reaped = waitpid(-1, NULL, WNOHANG)) > 0) {
      // dsh 本体退出(崩溃/被停)不是连接;清 spawn_pid 允许再次唤醒,清就绪缓存
      if (is_spawn(reaped)) {
        spawn_pid = 0;
        ready_port = 0;
        reset_token(); // 进程已死,launch token 随之作废
        refresh_port();  // 仅在 dsh 退出时重读
        continue;
      }
      // 后台更新子进程退出也不是连接(否则 active 被误减,WS 独占时误停 dsh + 守护自退)
      if (update_pid > 0 && reaped == update_pid) {
        update_pid = 0;
        continue;
      }
      active--;
      if (active < 0) active = 0;
    }
    // 在场租约结算:dsh 开着且无任何连接(active==0)才可能停机
    //   - 快停:/goodbye 信标或长连接(WS)结束 hint 之后 GOODBYE_GRACE 无新连接 → 页面真关了
    //   - 慢停:自最后在场证据超 IDLE_STOP(短轮询/心跳靠每次 accept 续租,WS 靠 active>0 续租)
    //   reload/断线重连 1~2s 内必有新 accept 把 last_use_m 推过 fast_hint_m,快停自动解除
    if (dsh_port > 0 && active == 0) {
      if (spawn_pid == 0 && !dsh_up()) {
        // 残留状态(dsh 崩溃/被外部杀,文件没清):清掉,下次访问自动拉起,health 不再报 stale 端口
        unlink(DSH_JSON);
        unlink(PID_FILE);
        dsh_port = 0;
        ready_port = 0;
        fast_hint_m = 0;
        // 零常驻:socket-activated 模式下残留清理完即自退,launchd 重新接管 socket
        if (activated) {
          fprintf(stderr, "daemon: 残留状态已清理,自退(launchd 将接管 socket)\n");
          exit(0);
        }
      } else if (spawn_pid > 0 ? kill(spawn_pid, 0) == 0 : dsh_up()) {
        // 存活判定:dsh 是主进程直接子进程,spawn_pid>0 即由 waitpid 保证进程活着,
        // 用 kill(pid,0) 免一次 socket+connect+close;spawn_pid==0(外部起的/残留)才 TCP 探测。
        // (守护自报的 dsh_up 探测)否则空闲期每秒 2 次 TCP connect 纯属冗余系统调用。
        if (fast_hint_m > last_use_m && now - fast_hint_m > GOODBYE_GRACE) {
          fprintf(stderr, "daemon: 页面已关闭(超 %ds 无返回),停止 dsh\n", GOODBYE_GRACE);
          stop_dsh();
          dsh_port = 0;
          ready_port = 0;
          fast_hint_m = 0;
          // 零常驻:dsh 已停,socket-activated 模式下自退交还 socket(前台模式继续循环)
          if (activated) {
            fprintf(stderr, "daemon: dsh 已停,自退(launchd 将接管 socket)\n");
            exit(0);
          }
        } else if (now - last_use_m > IDLE_STOP) {
          fprintf(stderr, "daemon: 空闲 %ds 无在场证据,停止 dsh\n", IDLE_STOP);
          stop_dsh();
          dsh_port = 0;
          ready_port = 0;
          fast_hint_m = 0;
          if (activated) {
            fprintf(stderr, "daemon: dsh 已停,自退(launchd 将接管 socket)\n");
            exit(0);
          }
        }
      }
    }
    // dsh 0.1.5+ 启动 token 扫描:dsh 在跑(本进程 spawn 或重启收养)且未捕获时增量扫日志
    // (最多追 120s:再晚说明是旧版无 token 机制,放弃以免整场空扫;收养场景窗口从守护启动算起)
    if (!dsh_token[0] && dsh_port > 0 && time(NULL) - last_spawn_time < 120) scan_token();
    // 就绪推进放主进程:dsh 每次启动只在这里探测成功一次,ready_port 经 fork 传给所有连接子进程
    // (否则每个连接子进程都会各自探一次,透传期每个请求白白多一次完整 GET /)
    if (dsh_port > 0 && ready_port != dsh_port && dsh_up() && http_probe(dsh_port)) {
      // HTTP 探通即报就绪,不再等 token(旧版这里强制等 2s 宽限,冷启动白 +2s):
      // dsh 0.1.5+ 打印 token 可能略晚于 HTTP 监听,该窗口内 /health 报 dsh:true 但省略
      // token 字段,由引导页 JS 负责等 token 出来再握手(连续 ~3s 仍无 token 才按旧版直接 reload)。
      ready_port = dsh_port;
    }
    struct pollfd pf[3];
    pf[0].fd = ls; pf[0].events = POLLIN; pf[0].revents = 0;
    pf[1].fd = wake_pipe[0]; pf[1].events = POLLIN; pf[1].revents = 0;
    pf[2].fd = hint_pipe[0]; pf[2].events = POLLIN; pf[2].revents = 0;
    // 冷启动延迟优化:dsh 启动中(spawn_pid>0)或已跑但未确认就绪时,poll 超时降到 150ms,
    // 就绪探测/token 扫描以 150ms 粒度推进(/health 最多晚 150ms 翻转,而非旧版 0~1s);
    // 空闲稳定期(无 spawn 且 dsh 未跑)保持 1000ms,避免无谓唤醒。
    int poll_ms = ((spawn_pid > 0 || dsh_port > 0) && !dsh_ready()) ? 150 : 1000;
    if (poll(pf, 3, poll_ms) > 0) {
      if (wake_pipe[0] >= 0 && (pf[1].revents & POLLIN)) {
        char wb;
        int want_wake = 0;
        while (read(wake_pipe[0], &wb, 1) > 0) {
          if (wb == CMD_WAKE) want_wake = 1; // 多个唤醒请求至多 spawn 一次
          else if (wb == CMD_STOP) {
            // 停止也由主进程串行执行:与同批的 CMD_WAKE 按 FIFO 顺序结算,
            // 停止期间不会有并发 spawn 写入新状态文件再被误删(竞态根源)。
            stop_dsh();
            dsh_port = 0;
            ready_port = 0;
            fast_hint_m = 0;
          }
        }
        if (want_wake && spawn_pid == 0 && !dsh_up() && NODE_BIN[0] && DSH_BIN[0]) spawn_dsh();
      }
      if (hint_pipe[0] >= 0 && (pf[2].revents & POLLIN)) {
        char hb;
        while (read(hint_pipe[0], &hb, 1) > 0) {} // 吸干 hint,记一次即可
        note_hint();
      }
      if (pf[0].revents & POLLIN) {
        int c = accept(ls, NULL, NULL);
        if (c < 0 && (errno == EMFILE || errno == ENFILE)) {
          // fd 耗尽:poll 对监听 socket 仍恒就绪(listen 队列非空),不歇一会会
          // accept→EMFILE 空转烧 CPU。100ms 让上层连接子进程退出释放 fd。
          usleep(100000);
        }
        if (c >= 0) {
          tap_use(); // 父进程 accept 即在场证据(含 /health 轮询、/ping 心跳、透传请求)
          pid_t pid = fork();
          if (pid == 0) {
            close(ls);
            handle_conn(c);
            close(c);
            _exit(0);
          }
          close(c);
          if (pid > 0) active++; // fork 失败(pid<0):连接已关、无子进程,不得计入——
          // 否则 active 永不归零,空闲停机判定失效,dsh 永不自动停、守护永不自退(零常驻被破坏)
        }
      }
    }
  }
  return 0;
}
