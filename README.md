# 🏔️ Alpine LXC Xray Reality 一键调优脚本

[![Platform](https://img.shields.io/badge/OS-Alpine_Linux-blue?logo=alpine&logoColor=white)](https://alpinelinux.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Xray](https://img.shields.io/badge/Core-Xray--core-orange)](https://github.com/XTLS/Xray-core)
[![Security](https://img.shields.io/badge/Security-REALITY-red)](https://github.com/XTLS/Xray-core/releases)

这是一款专为 **Alpine Linux**（特别是 **LXC 容器**）设计的高性能 Xray 安装与优化脚本。针对 **512MB 小内存** 和 **NAT 网络环境** 进行了深度调优，具备完整的容错机制。

---

## ✨ 核心特性

| 特性 | 说明 |
|------|------|
| 🌍 **NAT 环境优先** | 自动网卡检测，MTU 失败时优雅降级，支持低权限环境 |
| 📡 **MTU 智能设置** | NAT 环境设置 MTU 1380 解决丢包，失败不中断 |
| 🚀 **BBR 自适应** | 支持则启用，不支持则降级到系统默认算法 |
| 🛡️ **抗审查** | VLESS + TCP + REALITY + Vision，业界最强伪装方案 |
| 🍃 **低占用** | OpenRC 原生管理，无冗余进程，内存占用 < 50MB |
| 🔒 **动态安全** | 运行时生成 UUID 和密钥，源码泄露不威胁服务器 |
| 🕒 **自我修复** | 每天 04:00 自动重启，防止小内存 OOM |
| ⚡ **强化容错** | 下载失败自动重试 3 次，二进制验证，JSON 格式检查 |
| ✅ **配置验证** | 完整的文件有效性检查，防止启动失败 |

---

## 🛠️ 快速安装

### 方式一：一键安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/alpine_xray_improved.sh | sh
```

### 方式二：本地执行

```bash
# 下载脚本
wget -O alpine_xray_improved.sh https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/alpine_xray_improved.sh

# 添加执行权限
chmod +x alpine_xray_improved.sh

# 执行安装
sudo sh alpine_xray_improved.sh
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

Alpine 使用 **OpenRC** 而非 systemd，请使用以下命令：

### 常用命令

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

### 配置文件位置

| 文件 | 用途 |
|------|------|
| `/etc/xray/config.json` | Xray 主配置文件 |
| `/etc/local.d/xray.start` | 开机启动脚本 |
| `/var/spool/cron/crontabs/root` | 定时重启任务 |

---

## 🔧 故障排查

### "三板斧"快速自救

#### 第一步：强制拉起服务
```bash
sh /etc/local.d/xray.start
sleep 2
ps aux | grep xray
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
ntpd -q -p pool.ntp.org  # 强制同步时间（若需要）
```

### 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|--------|
| **连接失败** | Reality 时间误差 > 90s | 运行 `date` 检查，使用 `ntpd` 同步 |
| **频繁断连** | 内存不足 OOM | 检查 `free -m`，开启 Swap 虚拟内存 |
| **MTU 设置失败** | NAT 网络不支持修改 | **继续使用系统默认值**（脚本已优雅降级） |
| **BBR 启用失败** | 内核不支持 BBR | **自动降级到系统默认算法**（脚本已处理） |
| **下载 Xray 失败** | 网络不稳定 | 脚本自动重试 3 次，仍失败可手动下载后再执行 |
| **配置文件格式错误** | JSON 结构破损 | 运行 `jq empty /etc/xray/config.json` 验证 |

### 高级调试

若需查看详细日志，临时修改配置：

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

| 要求 | 说明 |
|------|------|
| **操作系统** | Alpine Linux 3.8+ |
| **内存** | ≥ 512 MB（推荐 1 GB） |
| **磁盘** | ≥ 1 GB 空闲空间 |
| **网络** | NAT 或直连网络均支持 |
| **权限** | 需要 root 权限执行 |

---

## 🌍 NAT 环境兼容性说明

本脚本针对 NAT 环境进行了完整优化：

### 网卡自动检测
```bash
# 自动识别网卡（不依赖 eth0）
NETIF=$(ip route | grep default | awk '{print $5}' | head -1)
```

### MTU 智能设置
- 尝试设置 MTU 1380（NAT 环境推荐值）
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
```bash
# 若需要调整 MTU 为其他值：
vi /etc/local.d/xray.start
# 修改 mtu 1380 为目标值（如 1400, 1500 等）
rc-service local restart
```

### 3. 监控服务健康度
```bash
# 创建监控脚本
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

---

## 📚 相关资源

- 🔗 [Xray-core 官方仓库](https://github.com/XTLS/Xray-core)
- 🔗 [REALITY 协议详解](https://github.com/XTLS/Xray-core/discussions/1713)
- 🔗 [Alpine Linux 官网](https://alpinelinux.org/)
- 🔗 [OpenRC 服务管理](https://wiki.alpinelinux.org/wiki/OpenRC)

---

## 📄 更新日志

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
- 🎉 首次发布

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
- 所有使用者的反馈与支持

---

<div align="center">

**⭐ 如果本项目对你有帮助，请给个 Star 支持一下！**

Made with ❤️ by [GaoYanHai](https://github.com/GaoYanHai)

</div>
