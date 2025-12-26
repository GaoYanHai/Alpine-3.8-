Alpine LXC 极简 Xray Reality 一键脚本
🚀 项目简介
本项目专为 Alpine Linux (特别是 LXC 虚拟化架构) 的轻量级 VPS 打造。针对 512M 内存、NAT 网络 以及 长距离/高延迟（如欧洲至中国） 的线路进行了深度优化。

由于 Alpine 默认不使用 systemd，且 LXC 环境对内核参数有限制，本脚本采用了 OpenRC + local.d 的方式实现开机自启。

✨ 优化特性
内核加速：自动检测并开启 TCP BBR 拥塞控制算法。

网络调优：强制设置 MTU 为 1380，解决 NAT 转发导致的丢包与卡顿。

极简占用：无多余监控程序，适合 512M 甚至更低内存的“小鸡”。

抗封锁：使用目前主流的 VLESS + TCP + REALITY + Vision 组合。

自我修复：内置每日凌晨 4:00 自动重启任务，防止内存溢出导致断连。

🛠️ 安装方法
在 Alpine 终端执行以下命令（请先确保已安装 curl）：

Bash

# 1. 下载脚本
curl -L -o alpine_xray.sh https://raw.githubusercontent.com/你的用户名/你的仓库名/main/alpine_xray.sh

# 2. 赋予执行权限
chmod +x alpine_xray.sh

# 3. 运行脚本
./alpine_xray.sh
📋 客户端配置说明
脚本运行完成后，会输出以下关键信息，请将其填入 v2rayN 或 Clash：

地址 (Address): 你的服务器公网 IP

端口 (Port): 52300 (或你在脚本中自定义的端口)

用户 ID (UUID): 97b8a903-842c-4339-bb84-2abdd773f3d9

流控 (Flow): xtls-rprx-vision

传输层安全 (Security): reality

SNI: www.ikea.com (推荐使用北欧站点优化)

Fingerprint: chrome

PublicKey: (脚本运行后生成的 Password 字段)

ShortId: 0123456789abcdef

🔍 运维常用命令
查看运行状态：ps | grep xray

手动重启服务：rc-service local restart

查看配置信息：cat /etc/xray/config.json

查看系统负载：top

实时查看日志 (调试用)：xray run -c /etc/xray/config.json

⚠️ 注意事项
网卡名称：脚本默认优化 eth0 网卡。如果你的网卡名称不同（可通过 ip addr 查看），请手动修改脚本中的 eth0 字样。

NAT 端口映射：请确保你的 NAT 商家后台已将外网端口正确映射至内网的 52300。

虚拟内存：如果 512M 内存依然频繁崩溃，建议手动创建 Swap 分区。
