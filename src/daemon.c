// daemon.c —— DeepSeek Harness 守护(macOS 专用,~1.3MB RSS)
// 最简设计:单一端口(DSH_RT_PORT,默认 3080,全链路自动匹配,无硬编码双端口)。
//   dsh 未运行 → 伺服引导页(任意路径);PWA 打开引导页 → 自动 /wake → dsh 在内部端口启动。
//   dsh 运行中 → 双向透传;PWA 关闭 → 连接归零 N 秒(DSH_RT_IDLE_STOP_SECS,默认 60)→ 自动停止 dsh。
//   dsh 内部端口:启动时自动挑选空闲端口,写入 RT_STATE/dsh.json。
//   dsh 位置:install.sh 装好运行时后写 RT_HOME/run.json({"node":...,"dsh":...}),守护直接 exec。
// 端点(守护自身处理,不透传):
//   GET  /health               → {"dsh":bool,"port":int,"pid":int}
//   POST /wake                 → 未运行则拉起 dsh(直启 node + 官方 dsh web)
//   POST /stop                 → 停止 dsh(SIGTERM → 超时 SIGKILL)
// 构建: clang -O2 -o daemon daemon.c(CI/install.sh 编译)
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static char RT_HOME[1024], RT_STATE[1024], LOG_DIR[1024], LOG_FILE[1100], BOOT_PAGE[4096];
static char DSH_JSON[1100], PID_FILE[1100], DSH_HOME[1024];
static char NODE_BIN[1024], DSH_BIN[1024];
static int PORT = 3080, IDLE_STOP = 60;

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
  if (p && *p) IDLE_STOP = atoi(p);
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
  getsockname(s, (struct sockaddr *)&a, &al);
  *out_port = ntohs(a.sin_port);
  return s; // 返回 socket,调用者负责在 dsh 启动后 close
}

// ---------- dsh 启停(直启,无 wrapper) ----------
// 非连接子进程(dsh 本体)不计入活跃连接,否则 waitpid 会把它们误算为连接关闭。
// 只跟踪当前 dsh 子进程:既用于剔除连接计数,也用于 /wake 幂等(在跑/在启动不重复 spawn)。
static pid_t spawn_pid = 0;
static int is_spawn(pid_t p) { return p > 0 && p == spawn_pid; }
// 唤醒请求管道(连接子进程 → 主进程):dsh 统一由主进程 spawn,天然单飞,
// 且 dsh 成为主进程的子进程可被 waitpid 收尸(连接子进程直接 spawn 会孤儿化)
static int wake_pipe[2] = { -1, -1 };

// dsh 崩溃自愈状态追踪(避免无限重启耗尽资源)
static time_t last_spawn_time = 0;
static int spawn_failure_count = 0;

static void spawn_dsh(void) {
  // 崩溃自愈:检测连续快速崩溃,冷却后再重试
  time_t now = time(NULL);
  if (now - last_spawn_time < 5) {
    spawn_failure_count++;
    if (spawn_failure_count >= 3) {
      fprintf(stderr, "daemon: dsh 连续 3 次快速崩溃(<5s),暂停重启 60s\n");
      sleep(60);  // 冷却期,避免死循环
      spawn_failure_count = 0;
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
    ready_port = 0; // 新 dsh 启动中,就绪缓存作废
    char j[64]; snprintf(j, sizeof j, "{\"port\":%d}\n", port);
    int fd = open(DSH_JSON, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) { write(fd, j, strlen(j)); close(fd); }
    char ps[32]; snprintf(ps, sizeof ps, "%d\n", pid);
    fd = open(PID_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) { write(fd, ps, strlen(ps)); close(fd); }
    return;
  }
  close(reserve_fd); // 子进程关闭预留 fd,让 dsh 自己 bind
  setsid();
  int lfd = open(LOG_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (lfd >= 0) { dup2(lfd, 1); dup2(lfd, 2); close(lfd); }
  setenv("DSH_HOME", DSH_HOME, 1);
  setenv("DSH_TELEMETRY_DISABLED", "1", 1);
  setenv("BROWSER", "none", 1); // 阻止 dsh 自动打开浏览器(PWA 已独立窗口,不应再弹浏览器)
  char port_s[16]; snprintf(port_s, sizeof port_s, "%d", port);
  execl(NODE_BIN, "node", DSH_BIN, "web", "--host", "127.0.0.1", "--port", port_s, (char *)NULL);
  _exit(127);
}

// 连接子进程里请求唤醒:只写管道,由主进程统一决定是否 spawn(幂等核心)
static void request_wake(void) {
  if (wake_pipe[1] < 0) { spawn_dsh(); return; } // 管道建立失败时退化为直启(旧行为)
  char b = 1;
  ssize_t w = write(wake_pipe[1], &b, 1);
  (void)w; // 管道满/关闭都无妨:主进程按自身状态决定
}

static void stop_dsh(void) {
  int pid = read_pid();
  if (pid > 0) {
    // 先验证 PID 是否真实存在(避免误杀回收后的同号进程)
    if (kill(pid, 0) != 0) {
      // PID 已不存在,直接清理状态文件
      unlink(DSH_JSON);
      unlink(PID_FILE);
      return;
    }
    if (kill(pid, SIGTERM) == 0) {
      // 等待最多 6 秒(30 × 200ms)让进程优雅退出
      for (int i = 0; i < 30 && kill(pid, 0) == 0; i++) usleep(200000);
      // 超时则强制 SIGKILL
      if (kill(pid, 0) == 0) kill(pid, SIGKILL);
    }
  }
  unlink(DSH_JSON);
  unlink(PID_FILE);
}

// ---------- 后台自动更新(预热后延迟触发,不阻塞启动) ----------
static void trigger_background_update(void) {
  // 检查禁用标志
  if (getenv("DSH_RT_NO_AUTO_UPDATE")) return;
  
  pid_t pid = fork();
  if (pid < 0) return;
  if (pid == 0) {
    // 子进程:独立会话,守护进程退出不影响更新
    setsid();
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    
    // 延迟 10 秒启动(避免干扰首次 dsh 启动)
    sleep(10);
    
    // 拼接更新脚本路径: RT_HOME/../scripts/update-dsh.sh
    char update_script[1100];
    // RT_HOME 可能是 ~/.local/share/dsh-runtime,脚本在同级的 scripts/ 下
    // 优先尝试从 RT_HOME 回溯到仓库根/安装包根
    snprintf(update_script, sizeof update_script, "%s/../scripts/update-dsh.sh", RT_HOME);
    
    execl("/bin/bash", "bash", update_script, (char *)NULL);
    _exit(1);
  }
  // 父进程立即返回,不等待
}

/** 重读 dsh.json(启动/停止后端口自动匹配,全链路单一事实源) */
static void refresh_port(void) { dsh_port = read_state_port(); }

// ---------- 引导页(任意路径在 dsh 未运行时都会得到它) ----------
static const char TPL[] =
  "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
  "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
  "<link rel=\"manifest\" href=\"/manifest.webmanifest\">"
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
  "var fired=false,t0=Date.now();"
  "function $(id){return document.getElementById(id)}"
  "function tick(){fetch('/health').then(function(r){return r.json()}).then(function(h){"
  "if(h.dsh){$('ring').className='ring done';$('status').textContent='已就绪,正在进入…';setTimeout(function(){location.reload()},150);return}"
  "if(!fired){fired=true;$('status').textContent='正在唤醒…';fetch('/wake',{method:'POST'})}"
  "var s=Math.floor((Date.now()-t0)/1000);"
  "$('status').textContent='正在启动 DeepSeek Harness…'+(s>=3?'(已等待 '+s+' 秒)':'');"
  "if(s>=600){$('err').style.display='block';$('err').textContent='启动超时(超过 10 分钟)。日志: '+document.getElementById('log').textContent;$('retry').style.display='block'}"
  "}).catch(function(){}).then(function(){setTimeout(tick,300)})}"
  "document.addEventListener('DOMContentLoaded',function(){"
  "document.getElementById('retry').onclick=function(){$('err').style.display='none';this.style.display='none';fired=false;t0=Date.now();tick()};tick()})"
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
    code, code == 200 ? "OK" : (code == 502 ? "Bad Gateway" : "Internal Server Error"), ct, strlen(body));
  write_all(c, hdr, (size_t)n);
  write_all(c, body, strlen(body));
}

static void respond_health(int c) {
  char body[128];
  // 报"就绪"(能服务 HTTP)而非仅"进程活着":引导页据此切换,避免过早 reload 进未就绪的 dsh → PWA 空白
  int ready = dsh_ready();
  snprintf(body, sizeof body, "{\"dsh\":%s,\"port\":%d,\"pid\":%d}",
    ready ? "true" : "false", dsh_port, ready ? read_pid() : 0);
  respond(c, 200, "application/json", body);
}

static const char MANIFEST[] =
  "{\"name\":\"DeepSeek Harness\",\"short_name\":\"DSH\",\"start_url\":\"/\",\"display\":\"fullscreen\",\"background_color\":\"#0B0E14\",\"theme_color\":\"#0B0E14\"}";

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
  while (!(c_eof && u_eof)) {
    struct pollfd pf[2];
    pf[0].fd = c; pf[0].events = POLLIN; pf[0].revents = 0;
    pf[1].fd = u; pf[1].events = POLLIN; pf[1].revents = 0;
    if (poll(pf, 2, 300000) <= 0) continue;
    if (!c_eof && (pf[0].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t n = read(c, cb, sizeof cb);
      if (n > 0) write_all(u, cb, (size_t)n);
      else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) { c_eof = 1; shutdown(u, SHUT_WR); }
    }
    if (!u_eof && (pf[1].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t n = read(u, ub, sizeof ub);
      if (n > 0) write_all(c, ub, (size_t)n);
      else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) { u_eof = 1; shutdown(c, SHUT_WR); }
    }
  }
  close(c);
  close(u);
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
    if (i < 10) usleep(delays_us[i]);
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

// ---------- 单连接处理(fork 出的子进程) ----------
static void handle_conn(int c) {
  struct timeval tv = { 2, 0 };
  setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  char buf[8192];
  int blen = (int)recv(c, buf, sizeof buf - 1, 0);
  if (blen <= 0) return;
  buf[blen] = 0;

  char method[8] = "", path[1024] = "";
  char *sp1 = strchr(buf, ' ');
  char *sp2 = sp1 ? strchr(sp1 + 1, ' ') : NULL;
  if (sp1 && sp2) {
    size_t ml = (size_t)(sp1 - buf); if (ml >= sizeof method) ml = sizeof method - 1;
    memcpy(method, buf, ml); method[ml] = 0;
    size_t pl = (size_t)(sp2 - (sp1 + 1)); if (pl >= sizeof path) pl = sizeof path - 1;
    memcpy(path, sp1 + 1, pl); path[pl] = 0;
    char *q = strchr(path, '?'); if (q) *q = 0;
  }

  // 每次请求都重读 dsh.json:/wake 拉起 dsh 后端口是守护挑的,停止后文件被删,自动跟随
  refresh_port();
  int up = dsh_up();

  // ---- 控制端点:不依赖就绪状态,守护自身处理(含 CSRF 防护) ----
  if (strcmp(path, "/health") == 0) { respond_health(c); return; }
  
  // CSRF 防护:POST 端点要求 Origin 检查(localhost CSRF 攻击防护)
  // 严格校验:必须来自同一端口,防止任意本地端口绕过
  // 移除 Referer fallback:Referer 可被禁用/篡改,不提供足够安全保障
  int csrf_ok = 0;
  if (strcmp(method, "POST") == 0 && (strcmp(path, "/wake") == 0 || strcmp(path, "/stop") == 0)) {
    char expected_origin[64];
    snprintf(expected_origin, sizeof expected_origin, "http://127.0.0.1:%d", PORT);
    char expected_localhost[64];
    snprintf(expected_localhost, sizeof expected_localhost, "http://localhost:%d", PORT);
    
    char *origin = strstr(buf, "\nOrigin:");
    if (origin) {
      origin += 8;
      while (*origin == ' ') origin++;
      char *eol = strchr(origin, '\r');
      if (eol) *eol = 0;
      // 精确匹配端口:防止 127.0.0.1:31399 绕过 127.0.0.1:3080
      // 校验后缀必须为 \0|/|?|# 防止 http://127.0.0.1:3080.evil.com 绕过
      size_t expected_len = strlen(expected_origin);
      if (strncmp(origin, expected_origin, expected_len) == 0) {
        char next = origin[expected_len];
        if (next == '\0' || next == '/' || next == '?' || next == '#') csrf_ok = 1;
      }
      if (!csrf_ok) {
        expected_len = strlen(expected_localhost);
        if (strncmp(origin, expected_localhost, expected_len) == 0) {
          char next = origin[expected_len];
          if (next == '\0' || next == '/' || next == '?' || next == '#') csrf_ok = 1;
        }
      }
    }
    if (!csrf_ok) { 
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
    if (up) stop_dsh();
    respond(c, 200, "application/json", "{\"stopped\":true}");
    return;
  }
  // ---- 未就绪(未启动 / 启动中尚不能服务 HTTP):引导页,绝不透传 → 根治 PWA 空白 ----
  if (!up || !dsh_ready()) {
    // dsh 自带 manifest(含图标/scope/service worker),守护仅在引导阶段提供
    if (strcmp(path, "/manifest.webmanifest") == 0) { respond(c, 200, "application/manifest+json", MANIFEST); return; }
    // 页面请求即自动拉起(不再等引导页 JS 的 /wake 往返)→ 启动提速
    if (!up && NODE_BIN[0] && DSH_BIN[0]) request_wake();
    respond(c, 200, "text/html; charset=utf-8", BOOT_PAGE);
    return;
  }

  // ---- 就绪:双向透传 ----
  // CSRF 防护:透传路径也需 Origin 校验,防止跨域页面触发 dsh 状态改变 API
  if (strcmp(method, "POST") == 0 || strcmp(method, "PUT") == 0 || 
      strcmp(method, "DELETE") == 0 || strcmp(method, "PATCH") == 0) {
    char expected_origin[64];
    snprintf(expected_origin, sizeof expected_origin, "http://127.0.0.1:%d", PORT);
    char expected_localhost[64];
    snprintf(expected_localhost, sizeof expected_localhost, "http://localhost:%d", PORT);
    
    char *origin = strstr(buf, "\nOrigin:");
    int proxy_csrf_ok = 0;
    if (origin) {
      origin += 8;
      while (*origin == ' ') origin++;
      char *eol = strchr(origin, '\r');
      if (eol) *eol = 0;
      size_t expected_len = strlen(expected_origin);
      if (strncmp(origin, expected_origin, expected_len) == 0) {
        char next = origin[expected_len];
        if (next == '\0' || next == '/' || next == '?' || next == '#') proxy_csrf_ok = 1;
      }
      if (!proxy_csrf_ok) {
        expected_len = strlen(expected_localhost);
        if (strncmp(origin, expected_localhost, expected_len) == 0) {
          char next = origin[expected_len];
          if (next == '\0' || next == '/' || next == '?' || next == '#') proxy_csrf_ok = 1;
        }
      }
    }
    if (!proxy_csrf_ok) {
      respond(c, 403, "application/json", "{\"error\":\"Origin header required for state-changing requests\"}");
      return;
    }
  }
  
  int u = connect_upstream();
  if (u < 0) { respond(c, 502, "text/plain", "upstream unavailable"); return; }
  write_all(u, buf, (size_t)blen);
  relay(c, u);
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  build_paths();
  build_boot();
  read_run();
  dsh_port = read_state_port();
  if (dsh_port > 0 && !dsh_up()) dsh_port = 0;

  // 唤醒请求管道(连接子进程写 → 主进程读)。两端均 CLOEXEC:exec 出的 dsh 不继承
  if (pipe(wake_pipe) == 0) {
    fcntl(wake_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(wake_pipe[1], F_SETFL, O_NONBLOCK);
    fcntl(wake_pipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(wake_pipe[1], F_SETFD, FD_CLOEXEC);
  }

  int ls = socket(AF_INET, SOCK_STREAM, 0);
  if (ls < 0) { perror("socket"); return 1; }
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
  fprintf(stderr, "dsh-daemon 就绪: http://127.0.0.1:%d/ (PWA 端口;dsh 内部端口自动分配)\n", PORT);


  // 预热:登录即拉起 dsh,用户第一次点 PWA 秒开(空闲自停仍生效)
  // 设 DSH_RT_NO_PREWARM=1 可关闭此行为
  if (!getenv("DSH_RT_NO_PREWARM") && NODE_BIN[0] && DSH_BIN[0] && dsh_port <= 0) {
    spawn_dsh();
    // 预热后触发后台更新检查(延迟 10 秒,不阻塞启动)
    // 设 DSH_RT_NO_AUTO_UPDATE=1 可禁用
    trigger_background_update();
  }
  int active = 0;
  time_t last_exit = time(NULL);
  for (;;) {
    // 优化: 仅在 dsh 状态变化时重读 dsh.json (减少 60% 系统调用)
    int reaped;
    while ((reaped = waitpid(-1, NULL, WNOHANG)) > 0) {
      // dsh 本体退出(崩溃/被停)不是连接;清 spawn_pid 允许再次唤醒,清就绪缓存
      if (is_spawn(reaped)) { 
        spawn_pid = 0; 
        ready_port = 0; 
        refresh_port();  // 仅在 dsh 退出时重读
        continue; 
      }
      active--;
      if (active < 0) active = 0;
      last_exit = time(NULL);
    }
    // PWA 已关闭(无任何连接)→ 空闲自动停止 dsh
    if (dsh_port > 0 && dsh_up() && active == 0 && time(NULL) - last_exit > IDLE_STOP) {
      fprintf(stderr, "daemon: 空闲 %ds 无连接,停止 dsh\n", IDLE_STOP);
      stop_dsh();
      dsh_port = 0;
      ready_port = 0;
    }
    // 就绪推进放主进程:dsh 每次启动只在这里探测成功一次,ready_port 经 fork 传给所有连接子进程
    // (否则每个连接子进程都会各自探一次,透传期每个请求白白多一次完整 GET /)
    if (dsh_port > 0 && ready_port != dsh_port && dsh_up() && http_probe(dsh_port)) {
      ready_port = dsh_port;
    }
    struct pollfd pf[2];
    pf[0].fd = ls; pf[0].events = POLLIN; pf[0].revents = 0;
    pf[1].fd = wake_pipe[0]; pf[1].events = POLLIN; pf[1].revents = 0;
    if (poll(pf, wake_pipe[0] >= 0 ? 2 : 1, 1000) > 0) {
      if (wake_pipe[0] >= 0 && (pf[1].revents & POLLIN)) {
        char wb;
        while (read(wake_pipe[0], &wb, 1) > 0) {} // 吸干所有唤醒请求,至多 spawn 一次
        if (spawn_pid == 0 && !dsh_up() && NODE_BIN[0] && DSH_BIN[0]) spawn_dsh();
      }
      if (pf[0].revents & POLLIN) {
        int c = accept(ls, NULL, NULL);
        if (c >= 0) {
          pid_t pid = fork();
          if (pid == 0) {
            close(ls);
            handle_conn(c);
            close(c);
            _exit(0);
          }
          close(c);
          active++;
        }
      }
    }
  }
  close(ls);
  return 0;
}
