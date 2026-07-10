# 🏔️ Alpine LXC & Debian LXD Xray Reality 一键调优脚本

[![Alpine](https://img.shields.io/badge/OS-Alpine_Linux-blue?logo=alpine&logoColor=white)](https://alpinelinux.org/)
[![Debian](https://img.shields.io/badge/OS-Debian_trixie-red?logo=debian&logoColor=white)](https://www.debian.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Xray](https://img.shields.io/badge/Core-Xray--core-orange)](https://github.com/XTLS/Xray-core)
[![Security](https://img.shields.io/badge/Security-REALITY-red)](https://github.com/XTLS/Xray-core/releases)

这是一款专为 **Alpine Linux**（LXC 容器）和 **Debian trixie**（LXD 容器）设计的高性能 Xray 安装与优化脚本。针对 **512MB 小内存** 和 **NAT/LXD 网络环境** 进行了多项兼容性与稳定性修复。

---

## 🆕 更新说明

### 修复补丁（2026-07-10）

本次提交包含对 Alpine 兼容性及可靠性的若干修复：

- ✅ 修复使用了 BusyBox grep 不支持的 `grep -P` 与 Perl lookbehind 导致的脚本立即退出问题，替换为兼容的 awk 提取方式。
- ✅ 在安装阶段添加必要依赖：`iproute2`, `procps`, `jq`，以确保 `ip`, `pidof/pgrep`, `jq` 等命令可用。
- ✅ 使用 `jq` 对 JSON 配置进行安全修改，避免直接用 sed 替换私钥/UUID 时因特殊字符导致的替换失败或 JSON 损坏问题；当 `jq` 不可用时使用经转义的 sed 回退方案。
- ✅ 修复了 `trap` 中变量展开问题，改为更安全的单引号形式并在退出时清理临时文件。
- ✅ 防止覆盖 root 的 crontab：改为追加并检查是否已存在相同任务，避免破坏已有定时任务。
- ✅ 改进 MTU 与网卡检测逻辑（使用 awk 替代不兼容的 grep -P），并在无法修改时优雅降级。
- ✅ 启动与健康检查增加了 pgrep/pidof/ss 多种回退检测方式，提高在不同容器环境的可用性。
- ✅ 备份并更谨慎地更新 /etc/sysctl.conf，避免意外丢失现有配置。

这些更改主要集中在 `alpine_xray_improved.sh`，以提升在最小化 Alpine 容器（BusyBox）上的可运行性和健壮性。

---

## 🛠️ 快速安装

### Alpine LXC 版本（推荐原 Alpine 用户）

#### 方式一：一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/alpine_xray_improved.sh | sh
```

#### 方式二：本地执行

```bash
wget -O alpine_xray_improved.sh https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/alpine_xray_improved.sh
chmod +x alpine_xray_improved.sh
sudo sh alpine_xray_improved.sh
```

---

(其余内容保持不变，文档其余部分略)
