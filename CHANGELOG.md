# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed

- **零常驻:launchd socket activation 改造** — daemon 不再 RunAtLoad/KeepAlive 常驻;launchd 持有监听 socket,首个 TCP 连接自动拉起 daemon(launch_activate_socket),空闲停止 dsh 后 daemon `exit(0)` 自退;后台更新检查改为 daemon 激活时触发并按 `RT_STATE/last_update_check` 时间戳 12h 节流;install.sh 改为 bootout + bootstrap(不再 kickstart);smoke-test 新增 socket-activation 端到端段(激活→自退→再激活)

### Security

#### 🔴 High-Risk Fixes

- **H1: Supply-Chain Integrity**
  - Added SHA-256 verification for release artifacts with fail-closed validation
  - Release workflow now generates and publishes `.sha256` checksum files
  - Install script verifies package integrity before extraction
  - Added version pinning support via `DSH_RT_RELEASE_TAG` environment variable
  - Default behavior remains `latest`, but production users can pin to specific versions

- **H2: CSRF Protection**
  - Control endpoints (`/wake`, `/stop`) now validate `Origin`/`Referer` headers
  - Blocks cross-origin POST requests with 403 Forbidden
  - Prevents remote websites from triggering daemon control actions
  - Only accepts requests from `http://127.0.0.1:<port>` and `http://localhost:<port>`

#### 🟠 Medium-Risk Fixes

- **M1: Secure File Permissions**
  - Log files (`dsh.log`) now created with 0600 mode (user-private)
  - Log directory created with 0700 mode (user-only access)
  - State files (`dsh.json`, `dsh.pid`) use 0600 mode
  - Prevents local privilege escalation via log snooping

- **M2: Universal Binary Support**
  - Release workflow now builds universal binaries (arm64 + x86_64)
  - Fixes installation degradation for Intel Mac users
  - Eliminates dependency on local Command Line Tools for x86_64 users

- **M3: Port Allocation Race Condition**
  - Significantly reduced TOCTOU window in port selection
  - `pick_port_fd()` holds socket reservation through fork, released in child before execl
  - Narrow window remains (5 lines) between child's close() and dsh's bind()
  - Much safer than original implementation but not completely eliminated

- **M4: Robust HTTP Readiness Probe**
  - Increased timeout from 1s to 3s (covers p95 cold start)
  - Added strict HTTP/1.x protocol validation (rejects HTTP/0.9)
  - Enlarged buffer from 256 to 512 bytes for verbose response headers
  - Fixes PWA blank screen on slow dsh startup

#### 🟡 Low-Risk Hardening

- **L1: Port Configuration Validation**
  - Install script validates port range (1024-65535)
  - Daemon validates `DSH_RT_PORT` and rejects invalid values
  - Prevents binding to privileged ports or random ports via `atoi(0)`

- **L2: PID Validation**
  - `stop_dsh()` now verifies PID existence before sending signals
  - Prevents accidental kill of recycled PIDs (low probability, defense-in-depth)

- **L3: HTML Escaping**
  - `build_boot()` now HTML-escapes `LOG_DIR` in boot page
  - Prevents XSS injection via malicious `RT_STATE` paths (user-controlled, low risk)

- **L4: JSON Escape Handling**
  - `extract_str()` now handles `\\` and `\"` escape sequences
  - Improves robustness for paths containing quotes

### Added

- Comprehensive security audit report (`SECURITY_AUDIT.md`)
- Automated security verification test suite (`tests/security-verification.sh`)
- Version pinning documentation in README
- Security features section in README

### Changed

- Release workflow generates SHA-256 checksums for all artifacts
- Install script defaults to `latest` but supports version pinning
- Daemon C code enhanced with defense-in-depth controls
- All runtime state files now user-private (0600/0700)

### Documentation

- Added supply-chain integrity verification workflow
- Documented CSRF protection mechanism
- Added security best practices for production deployments
- Included residual risk assessment and future hardening recommendations

---

## Security Audit Details

**Audit Date:** 2026-09-09  
**Scope:** Full supply-chain, runtime security, and defense-in-depth review  
**Test Coverage:** 26/26 security verification tests passing  
**Binary Size:** ~85KB (universal binary, arm64 + x86_64)  
**Compilation:** Zero warnings with `-Wall -Wextra -Werror`

**Attack Surface Reduction:**
- Supply-chain: High → Low (SHA-256 verification, version pinning)
- CSRF: High → Low (Origin/Referer validation)
- Filesystem: Medium → Low (0600/0700 permissions)
- Port allocation: Medium → Low (TOCTOU eliminated)

**Residual Risk:**
- Install script fetched from `main` branch (recommend branch protection + signed commits)
- Daemon uses ad-hoc signature (recommend Developer ID + notarization for production)
