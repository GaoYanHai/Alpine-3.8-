# 🏔️ Alpine LXC & Debian LXD Xray Reality 一键调优脚本

[![Alpine](https://img.shields.io/badge/OS-Alpine_Linux-blue?logo=alpine&logoColor=white)](https://alpinelinux.org/)
[![Debian](https://img.shields.io/badge/OS-Debian_trixie-red?logo=debian&logoColor=white)](https://www.debian.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Xray](https://img.shields.io/badge/Core-Xray--core-orange)](https://github.com/XTLS/Xray-core)
[![Security](https://img.shields.io/badge/Security-REALITY-red)](https://github.com/XTLS/Xray-core/releases)

这是一款专为 **Alpine Linux**（LXC 容器）和 **Debian trixie**（LXD 容器）设计的高性能 Xray 安装与优化脚本。针对 **512MB 小内存** 和 **NAT/LXD 网络环境** 进行了深度调优。

---

## 🆕 更新说明（2026-06-10）

### 新增 Debian 版本
- ✨ 支持 **Debian trixie amd64 (20251224_0350)** LXD 容器平台
- ✨ 从 OpenRC 迁移到 **systemd** 服务管理
- ✨ 使用 **apt-get** 包管理器替代 apk
- ✨ 完整的 systemd 单元文件和网络配置脚本
- ✨ 保留所有 Alpine 版本的错误处理和可靠性特性

### 版本支持矩阵

| 系统 | 脚本文件 | 初始化系统 | 包管理器 | 容器平台 |
|------|---------|---------|--------|--------|
| **Alpine Linux** | `alpine_xray_improved.sh` | OpenRC | apk | LXC |
| **Debian trixie** | `debian_xray_improved.sh` | systemd | apt-get | LXD |

---

## ✨ 核心特性

| 特性 | 说明 |
|------|------|
| 🌍 **容器环境优先** | 自动网卡检测，MTU 失败时优雅降级，支持低权限环境 |
| 📡 **MTU 智能设置** | LXC/LXD 环境设置 MTU 1380 解决丢包，失败不中断 |
| 🚀 **BBR 自适应** | 支持则启用，不支持则降级到系统默认算法 |
| 🛡️ **抗审查** | VLESS + TCP + REALITY + Vision，业界最强伪装方案 |
| 🍃 **低占用** | 原生 init 管理，无冗余进程，内存占用 < 50MB |
| 🔒 **动态安全** | 运行时生成 UUID 和密钥，源码泄露不威胁服务器 |
| 🕒 **自我修复** | 每天 04:00 自动重启，防止小内存 OOM |
| ⚡ **强化容错** | 下载失败自动重试 3 次，二进制验证，JSON 格式检查 |
| ✅ **配置验证** | 完整的文件有效性检查，防止启动失败 |

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

### Debian LXD 版本（新增！）

#### 方式一：一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/debian_xray_improved.sh | bash
```

#### 方式二：本地执行

```bash
wget -O debian_xray_improved.sh https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/debian_xray_improved.sh
chmod +x debian_xray_improved.sh
sudo bash debian_xray_improved.sh
```

---

## 📋 配置指南

### 客户端连接参数

脚本运行完成后，终端会输出您的专属连接信息。请按以下参数配置客户端（支持 v2rayN、Clash Meta、Shadowrocket 等）：

| 配置项 | 参数值 | 说明 |
|--------|--------|------|
| **协议** | VLESS | 轻量级协议 |
| **地址** | `脚本输出的 IP` | 服务器公网 IP |
| **端口** | 52300 | 默认监听端口 |
| **UUID** | `脚本输出的 UUID` | 用户身份识别 |
| **流控** | xtls-rprx-vision | 完整性校验算法 |
| **加密** | none | VLESS 不需加密 |
| **传输安全** | reality | 伪装为 TLS 流量 |
| **SNI** | www.ikea.com | 伪装目标域名 |
| **Fingerprint** | chrome | 客户端指纹 |
| **PublicKey** | `脚本输出的 PublicKey` | Reality 公钥 |
| **ShortId** | 0123456789abcdef | 短连接 ID |

### ⚠️ 重要提示

- **公钥位置**：请使用脚本输出的 **PublicKey** 字段，NOT ~~Password~~
- **时间同步**：Reality 协议对时间精度要求极高（误差 ≤ 90 秒），部署前请检查系统时间
- **端口开放**：确保防火墙允许 TCP 52300 入站

---

## ⚙️ 服务管理

### Alpine LXC 版本（OpenRC）

```bash
# 重启服务（重新读取配置）
rc-service local restart

# 停止服务
rc-service local stop

# 查看运行状态
ps aux | grep xray

# 查看实时日志（仅调试使用）
/usr/local/bin/xray run -c /etc/xray/config.json

# 查看内存占用
free -m
```

### Debian LXD 版本（systemd）

```bash
# 查看服务状态
systemctl status xray.service

# 重启服务（重新读取配置）
systemctl restart xray.service

# 停止服务
systemctl stop xray.service

# 启动服务
systemctl start xray.service

# 查看日志（最后 50 行）
journalctl -u xray.service -n 50

# 实时查看日志
journalctl -u xray.service -f

# 查看内存占用
free -m
```

### 配置文件位置

#### Alpine 版本

| 文件 | 用途 |
|------|------|
| `/etc/xray/config.json` | Xray 主配置文件 |
| `/etc/local.d/xray.start` | 开机启动脚本 |
| `/var/spool/cron/crontabs/root` | 定时重启任务 |

#### Debian 版本

| 文件 | 用途 |
|------|------|
| `/etc/xray/config.json` | Xray 主配置文件 |
| `/etc/systemd/system/xray.service` | systemd 服务单元 |
| `/usr/local/bin/setup-xray-network.sh` | 网络配置脚本 |
| Crontab | 定时重启任务（由 crontab 管理） |

---

## 🔧 故障排查

### "三板斧"快速自救

#### 第一步：强制拉起服务

**Alpine 版本：**
```bash
sh /etc/local.d/xray.start
sleep 2
ps aux | grep xray
```

**Debian 版本：**
```bash
systemctl restart xray.service
sleep 2
systemctl status xray.service
```

#### 第二步：检查内存

```bash
free -m
# 如果内存不足，考虑开启 Swap：
dd if=/dev/zero of=/swapfile bs=1M count=512
mkswap /swapfile
swapon /swapfile
```

#### 第三步：验证时间

```bash
date
# Alpine: ntpd -q -p pool.ntp.org  # 强制同步时间（若需要）
# Debian: timedatectl set-ntp true && timedatectl show
```

### 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|--------|
| **连接失败** | Reality 时间误差 > 90s | 运行 `date` 检查，使用时间同步 |
| **频繁断连** | 内存不足 OOM | 检查 `free -m`，开启 Swap 虚拟内存 |
| **MTU 设置失败** | 容器网络不支持修改 | **继续使用系统默认值**（脚本已优雅降级） |
| **BBR 启用失败** | 内核不支持 BBR | **自动降级到系统默认算法**（脚本已处理） |
| **下载 Xray 失败** | 网络不稳定 | 脚本自动重试 3 次，仍失败可手动下载后再执行 |
| **配置文件格式错误** | JSON 结构破损 | 运行 `jq empty /etc/xray/config.json` 验证 |
| **Debian 服务无法启动** | systemd 错误 | 运行 `journalctl -u xray.service -n 20` 查看日志 |

### 高级调试

**Alpine 版本：**

```bash
# 修改日志等级为 debug
sed -i 's/"loglevel": "none"/"loglevel": "debug"/g' /etc/xray/config.json

# 重启服务
rc-service local restart

# 前台运行查看日志
/usr/local/bin/xray run -c /etc/xray/config.json

# 恢复日志关闭
sed -i 's/"loglevel": "debug"/"loglevel": "none"/g' /etc/xray/config.json
```

**Debian 版本：**

```bash
# 修改日志等级为 debug
sed -i 's/"loglevel": "none"/"loglevel": "debug"/g' /etc/xray/config.json

# 重启服务
systemctl restart xray.service

# 查看详细日志
journalctl -u xray.service -n 100 --no-pager

# 前台运行查看日志（停止服务后）
systemctl stop xray.service
/usr/local/bin/xray run -c /etc/xray/config.json

# 恢复日志关闭
sed -i 's/"loglevel": "debug"/"loglevel": "none"/g' /etc/xray/config.json
systemctl start xray.service
```

---

## 🔐 安全建议

- ✅ 脚本生成的 UUID 和密钥仅保存于本地配置文件，**不依赖云端**
- ✅ GitHub 源码泄露 ≠ 服务器被攻击（每次运行生成新密钥）
- ✅ 定期备份 `/etc/xray/config.json`（包含私钥信息）
- ⚠️ **不要在公共论坛、GitHub Issues 贴出完整连接参数**
- ⚠️ **不要在截图中暴露 UUID 和 PublicKey**

---

## 📊 性能指标（参考）

| 指标 | 数值 |
|------|------|
| **内存占用** | 40-60 MB（Xray 进程） |
| **CPU 占用** | < 5% （低流量场景） |
| **启动时间** | 2-5 秒 |
| **数据包延迟** | +0ms（无额外开销） |
| **吞吐量** | 受限于网络带宽 |

---

## 📝 系统要求

### Alpine LXC 版本

| 要求 | 说明 |
|------|------|
| **操作系统** | Alpine Linux 3.8+ |
| **内存** | ≥ 512 MB（推荐 1 GB） |
| **磁盘** | ≥ 1 GB 空闲空间 |
| **网络** | NAT 或直连网络均支持 |
| **权限** | 需要 root 权限执行 |

### Debian LXD 版本

| 要求 | 说明 |
|------|------|
| **操作系统** | Debian trixie amd64 (20251224_0350) 或更新版本 |
| **内存** | ≥ 512 MB（推荐 1 GB） |
| **磁盘** | ≥ 1 GB 空闲空间 |
| **网络** | NAT/LXD 或直连网络均支持 |
| **权限** | 需要 root 权限执行 |
| **依赖** | curl, ca-certificates, unzip, jq |

---

## 🌍 LXC/LXD 环境兼容性说明

本脚本针对容器网络环境进行了完整优化：

### 网卡自动检测
```bash
# 自动识别网卡（不依赖 eth0）
NETIF=$(ip route | grep default | awk '{print $5}' | head -1)
```

### MTU 智能设置
- 尝试设置 MTU 1380（LXC/LXD 环境推荐值）
- 失败时**优雅降级**，继续使用系统默认值
- 不会因为权限不足而中断执行

### BBR 自动降级
- 尝试启用 BBR 拥塞控制
- 不支持时自动降级到系统默认算法
- 脚本继续正常执行

### 低权限环境支持
- 即使无法修改 BBR、MTU，脚本仍能完整运行
- 所有网络优化均为可选，不影响核心功能

---

## 🚀 高级优化建议

### 1. 验证 BBR 是否启用
```bash
sysctl net.ipv4.tcp_congestion_control
# 如果输出为 bbr，说明启用成功
# 如果输出为其他值（如 cubic），说明环境不支持，继续使用默认值即可
```

### 2. 自定义 MTU 值

**Alpine 版本：**
```bash
vi /etc/local.d/xray.start
# 修改 mtu 1380 为目标值（如 1400, 1500 等）
rc-service local restart
```

**Debian 版本：**
```bash
vi /usr/local/bin/setup-xray-network.sh
# 修改 mtu 1380 为目标值（如 1400, 1500 等）
systemctl restart xray.service
```

### 3. 监控服务健康度

**Alpine 版本：**
```bash
cat > /usr/local/bin/monitor.sh << 'EOF'
#!/bin/sh
while true; do
    if ! pgrep xray > /dev/null; then
        echo "Xray 已离线，自动重启..." | logger
        rc-service local restart
    fi
    sleep 300  # 每 5 分钟检查一次
done
EOF

chmod +x /usr/local/bin/monitor.sh
```

**Debian 版本：**
```bash
cat > /usr/local/bin/monitor.sh << 'EOF'
#!/bin/bash
while true; do
    if ! systemctl is-active --quiet xray.service; then
        echo "Xray 已离线，自动重启..." | logger
        systemctl restart xray.service
    fi
    sleep 300  # 每 5 分钟检查一次
done
EOF

chmod +x /usr/local/bin/monitor.sh
```

---

## 📚 相关资源

- 🔗 [Xray-core 官方仓库](https://github.com/XTLS/Xray-core)
- 🔗 [REALITY 协议详解](https://github.com/XTLS/Xray-core/discussions/1713)
- 🔗 [Alpine Linux 官网](https://alpinelinux.org/)
- 🔗 [OpenRC 服务管理](https://wiki.alpinelinux.org/wiki/OpenRC)
- 🔗 [Debian 官网](https://www.debian.org/)
- 🔗 [systemd 官方文档](https://systemd.io/)

---

## 📄 更新日志

### v3.0（Debian LXD 支持版）- 2026-06-10
- ✨ **新增 Debian trixie 支持**
- ✨ 从 OpenRC 迁移到 systemd
- ✨ 创建独立的 Debian 脚本版本
- ✨ 新增 systemd 服务单元文件
- ✨ 完整的网络配置脚本
- ✨ 改进 cron 任务管理
- 📚 更新文档支持多系统

### v2.1（NAT 兼容增强版）- 2026-06-10
- ✨ **核心改进**：NAT 环境自动兼容
- ✨ 网卡自动检测，支持非 eth0 网卡
- ✨ MTU/BBR 失败时优雅降级（不中断执行）
- ✨ 增强下载可靠性（3 次重试机制）
- ✨ 文件有效性完整验证
- ✨ 二进制兼容性检查
- ✨ 服务启动验证反馈
- 🐛 修复权限不足导致脚本失败的问题
- 📈 提升低权限环境的可用性
- 📚 完整重写 NAT 环境指南

### v2.0（改进版）- 2026-06-10
- ✨ 新增错误处理与验证机制
- ✨ 实现下载重试机制（3 次失败重试）
- ✨ 添加 JSON 格式校验
- ✨ 完善 Cron 去重检查
- ✨ 支持 `ip` 命令备选（兼容性更好）
- 🐛 修复密钥提取错误（PublicKey 字段识别）
- 📈 优化临时文件管理（自动清理）
- 📚 完整重写文档

### v1.0（原始版本）- 2025-12-26
- 🎉 首次发布（Alpine LXC 版本）

---

## 📧 反馈与支持

如遇问题，请通过以下方式反馈：

- 📌 [GitHub Issues](https://github.com/GaoYanHai/Alpine-3.8-/issues)
- 💬 [讨论区](https://github.com/GaoYanHai/Alpine-3.8-/discussions)

---

## 📜 开源协议

本项目基于 **MIT License** 许可发行。详见 [LICENSE](https://opensource.org/licenses/MIT)

```
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```

---

## 🙏 致谢

- [XTLS Team](https://github.com/XTLS) - Xray-core 开发
- [Alpine Linux 社区](https://alpinelinux.org/) - 轻量级 Linux 发行版
- [Debian 社区](https://www.debian.org/) - 稳定的 Linux 发行版
- 所有使用者的反馈与支持

---

<div align="center">

**⭐ 如果本项目对你有帮助，请给个 Star 支持一下！**

Made with ❤️ by [GaoYanHai](https://github.com/GaoYanHai)

</div>
