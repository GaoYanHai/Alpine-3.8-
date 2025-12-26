# 🏔️ Alpine LXC Xray Reality 一键调优脚本

[![Platform](https://img.shields.io/badge/OS-Alpine_Linux-blue?logo=alpine&logoColor=white)](https://alpinelinux.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Xray](https://img.shields.io/badge/Core-Xray--core-orange)](https://github.com/XTLS/Xray-core)

这是一款专为 **Alpine Linux**（特别是 **LXC** 虚拟化架构）设计的轻量级 Xray 安装与优化脚本。针对 **512M 小内存** 及 **NAT 网络** 进行了深度调优，旨在高延迟环境下提供极致的连接速度。

---

## ✨ 核心特性

* **🚀 传输加速**：自动检测并开启 `TCP BBR` 拥塞控制算法。
* **📡 网络优化**：针对 NAT 环境强制设置 `MTU 1380`，彻底解决长距离传输下的丢包与卡顿。
* **🛡️ 顶级伪装**：采用 `VLESS` + `TCP` + `REALITY` + `Vision` 组合，目前最强的抗封锁方案。
* **🍃 极简占用**：原生 `OpenRC` 启动管理，无多余监控程序，内存占用极低。
* **🔒 动态安全**：安装时现场生成 UUID 和密钥对，**拒绝硬编码**，确保 GitHub 源码泄露也不会威胁你的服务器安全。
* **🕒 自我修复**：预设每日凌晨自动重启，确保持续稳定运行，防止小内存溢出（OOM）。

---

## 🛠️ 快速安装

在您的 Alpine 终端中直接复制并执行以下命令：

```bash
curl -O [https://raw.githubusercontent.com/您的用户名/仓库名/main/alpine_xray.sh](https://raw.githubusercontent.com/您的用户名/仓库名/main/alpine_xray.sh) && chmod +x alpine_xray.sh && ./alpine_xray.sh


📋 客户端配置指南脚本运行完成后，终端会输出您的专属连接信息。请参照以下参数配置您的客户端（如 v2rayN, Clash Meta, Shadowrocket 等）：配置项参数值协议 (Protocol)VLESS流控 (Flow)xtls-rprx-vision加密 (Encryption)none传输层安全 (Security)REALITYSNI / ServerNamewww.ikea.comFingerprintchromePublicKey / pbk脚本输出的 Password 字段ShortId / sid0123456789abcdef⚙️ 进阶运维由于 Alpine 不使用 systemd，请使用以下 OpenRC 命令管理服务：重启服务：rc-service local restart停止服务：rc-service local stop查看运行状态：ps | grep xray修改配置：vi /etc/xray/config.json实时调试：若连接失败，可运行 xray run -c /etc/xray/config.json 查看报错日志。⚠️ 常见问题网卡适配：脚本默认针对 eth0 网卡进行 MTU 优化。若您的网卡名称不同（可通过 ip addr 查看），请修改脚本中第 67 行的网卡名称。NAT 端口映射：请确保在您的 VPS 商家面板中，已将内网端口 52300 正确映射至您的公网端口。内存管理：若机器频繁失联，请检查 free -m。若内存依然吃紧，建议在终端运行 dd if=/dev/zero of=/swapfile bs=1M count=512 && mkswap /swapfile && swapon /swapfile 以开启虚拟内存。📜 开源协议基于 MIT License 许可发行。
