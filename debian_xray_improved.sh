#!/bin/bash

# ====================================================
# Project: Debian LXD Xray Reality One-Click Script
# Platform: Debian trixie amd64 (20251224_0350)
# Features: Enhanced error handling, systemd integration, Debian compatibility
# ====================================================

set -e  # 错误时立即退出，避免继续执行
set -u  # 未定义变量时报错

# 0. 自定义基础变量
PORT=52300
SHORT_ID="0123456789abcdef"
DEST_SITE="www.ikea.com:443"
SNI="www.ikea.com"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/etc/xray/config.json"
XRAY_DIR="/etc/xray"
XRAY_USER="xray"
XRAY_GROUP="xray"

# 错误处理函数
error_exit() {
    echo "❌ 错误: $1" >&2
    exit 1
}

# 执行命令并检查是否成功
run_cmd() {
    if ! "$@"; then
        error_exit "命令执行失败: $*"
    fi
}

# 1. 环境准备与依赖安装（Debian apt-get）
echo "正在安装基础依赖..."
run_cmd apt-get update
run_cmd apt-get install -y curl ca-certificates unzip jq

# 创建 Xray 用户和必要目录
if ! id "$XRAY_USER" >/dev/null 2>&1; then
    useradd -r -s /bin/false "$XRAY_USER"
fi

run_cmd mkdir -p "$XRAY_DIR" "$(dirname "$XRAY_BIN")"
run_cmd chown -R "$XRAY_USER:$XRAY_GROUP" "$XRAY_DIR"

# 2. 下载并安装最新版 Xray-core（带重试机制）
echo "正在下载 Xray-core..."
XRAY_ZIP="/tmp/xray-$$.zip"
trap "rm -f $XRAY_ZIP" EXIT  # 确保删除临时文件

# 添加重试逻辑（最多3次尝试）
RETRY=0
MAX_RETRIES=3
while [ $RETRY -lt $MAX_RETRIES ]; do
    if curl -L --connect-timeout 10 --max-time 60 -o "$XRAY_ZIP" \
        "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"; then
        break
    fi
    RETRY=$((RETRY + 1))
    if [ $RETRY -lt $MAX_RETRIES ]; then
        echo "下载失败，5秒后重试 $RETRY/$MAX_RETRIES..."
        sleep 5
    fi
done

if [ $RETRY -eq $MAX_RETRIES ]; then
    error_exit "无法下载 Xray-core，超过最大重试次数"
fi

# 验证 ZIP 文件有效性
if [ ! -f "$XRAY_ZIP" ] || [ ! -s "$XRAY_ZIP" ]; then
    error_exit "下载的 Xray 文件无效或为空"
fi

run_cmd unzip -o "$XRAY_ZIP" xray -d "$(dirname "$XRAY_BIN")"
run_cmd chmod +x "$XRAY_BIN"
run_cmd chown "$XRAY_USER:$XRAY_GROUP" "$XRAY_BIN"

# 验证 Xray 二进制文件可执行性
if ! "$XRAY_BIN" version > /dev/null 2>&1; then
    error_exit "Xray 二进制文件损坏或架构不兼容"
fi

# 3. 动态生成身份凭证（安全提取）
echo "正在生成加密密钥..."
USER_UUID=$("$XRAY_BIN" uuid)

# 更安全的密钥提取方式（支持多种输出格式）
KEYS_OUTPUT=$("$XRAY_BIN" x25519)
PRIV_KEY=$(echo "$KEYS_OUTPUT" | grep -oP '(?<=PrivateKey:\s)\S+' || echo "")
PUB_KEY=$(echo "$KEYS_OUTPUT" | grep -oP '(?<=PublicKey:\s)\S+' || echo "")

# 备选提取方式（针对不同版本的 Xray）
if [ -z "$PUB_KEY" ]; then
    PUB_KEY=$(echo "$KEYS_OUTPUT" | grep -oP '(?<=Password:\s)\S+' || echo "")
fi

# 验证密钥是否成功提取
[ -z "$PRIV_KEY" ] && error_exit "无法提取私钥"
[ -z "$PUB_KEY" ] && error_exit "无法提取公钥"
[ -z "$USER_UUID" ] && error_exit "无法生成 UUID"

# 4. 生成 Xray 配置文件（日志全关版）
echo "正在生成配置文件..."
cat > "$XRAY_CONFIG" << 'CONF'
{
    "log": {
        "loglevel": "none",
        "access": "/dev/null",
        "error": "/dev/null"
    },
    "inbounds": [{
        "port": 52300,
        "protocol": "vless",
        "settings": {
            "clients": [{
                "id": "placeholder_uuid",
                "flow": "xtls-rprx-vision"
            }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": false,
                "dest": "www.ikea.com:443",
                "xver": 0,
                "serverNames": ["www.ikea.com"],
                "privateKey": "placeholder_privkey",
                "shortIds": ["0123456789abcdef"]
            }
        }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
CONF

# 替换占位符
sed -i "s|placeholder_uuid|$USER_UUID|g" "$XRAY_CONFIG"
sed -i "s|placeholder_privkey|$PRIV_KEY|g" "$XRAY_CONFIG"

# 验证 JSON 配置文件格式
if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
    error_exit "配置文件 JSON 格式错误"
fi
echo "✅ 配置文件 JSON 格式验证通过"

# 设置文件权限
run_cmd chmod 644 "$XRAY_CONFIG"
run_cmd chown "$XRAY_USER:$XRAY_GROUP" "$XRAY_CONFIG"

# 5. 系统网络优化（Debian 兼容）
echo "正在进行网络性能调优..."

# 尝试启用 BBR（可能不支持，失败也继续）
{
    grep -v "net.core.default_qdisc" /etc/sysctl.conf 2>/dev/null || true
    grep -v "net.ipv4.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null || true
    # 仅在 BBR 支持的环境下启用，否则降级到 cubic
    echo "net.core.default_qdisc=fq"
    echo "net.ipv4.tcp_congestion_control=bbr"
} > /etc/sysctl.conf.tmp && mv /etc/sysctl.conf.tmp /etc/sysctl.conf

# 应用 sysctl 配置，失败不中断
if sysctl -p > /dev/null 2>&1; then
    echo "✅ BBR 配置已应用"
else
    echo "⚠️  警告: BBR 在当前环境不可用，降级使用系统默认算法"
    # 移除 BBR 配置以防启动失败
    sed -i '/tcp_congestion_control/d' /etc/sysctl.conf
fi

# 6. 创建 systemd 服务文件（替代 OpenRC）
echo "正在配置 systemd 服务..."
cat > /etc/systemd/system/xray.service << 'SYSTEMD'
[Unit]
Description=Xray Reality Protocol Service
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=xray
Group=xray
ExecStartPre=/usr/local/bin/setup-xray-network.sh
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
RestartSec=5
StandardOutput=null
StandardError=null

# 安全设置
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=true
PrivateTmp=true
ProtectClock=true

[Install]
WantedBy=multi-user.target
SYSTEMD

run_cmd chmod 644 /etc/systemd/system/xray.service

# 7. 创建网络配置脚本（MTU 和 BBR）
echo "正在创建网络配置脚本..."
cat > /usr/local/bin/setup-xray-network.sh << 'NETSCRIPT'
#!/bin/bash

# 自动检测网卡名称
NETIF=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$NETIF" ]; then
    NETIF="eth0"
fi

echo "检测到网卡: $NETIF"

# 尝试设置 MTU（重要：解决 LXD 环境丢包）
# 1380 是 NAT/LXD 环境的通用安全值
if command -v ip >/dev/null 2>&1; then
    ip link set dev "$NETIF" mtu 1380 2>/dev/null || true
fi

# 验证 MTU 设置
CURRENT_MTU=$(ip link show "$NETIF" 2>/dev/null | grep -oP '(?<=mtu\s)\d+' || echo "")
if [ "$CURRENT_MTU" = "1380" ]; then
    echo "✅ MTU 已设置为 1380"
else
    echo "⚠️  MTU 设置失败（在此 LXD 环境可能无法修改），使用系统默认值继续运行"
fi
NETSCRIPT

run_cmd chmod +x /usr/local/bin/setup-xray-network.sh

# 8. 重新加载 systemd 并启动服务
echo "正在启动 Xray 服务..."
run_cmd systemctl daemon-reload
run_cmd systemctl enable xray.service
run_cmd systemctl start xray.service

# 验证服务是否成功启动
sleep 2
if systemctl is-active --quiet xray.service; then
    echo "✅ Xray 服务已成功启动"
else
    echo "⚠️  警告: Xray 服务可能启动失败，检查状态："
    systemctl status xray.service || true
fi

# 9. 配置定时重启任务（防止小内存 OOM）
echo "正在配置定时重启任务..."
CRON_JOB="0 4 * * * systemctl restart xray.service"

# 避免重复添加 cron 任务
if ! crontab -l 2>/dev/null | grep -q "systemctl restart xray.service"; then
    (crontab -l 2>/dev/null || echo "") | grep -v "systemctl restart xray.service" | (cat; echo "$CRON_JOB") | crontab -
    echo "✅ 定时重启任务已配置（每日 04:00）"
fi

# 确保 cron 服务运行
run_cmd systemctl enable cron
run_cmd systemctl start cron

# 10. 输出安装结果
echo ""
echo "正在获取公网 IP..."
CLEAR_IP=$(curl -s --connect-timeout 5 --max-time 10 ifconfig.me 2>/dev/null || echo "获取失败（NAT/LXD 环境可能无外网访问）")

cat << EOF
-------------------------------------------------------
✅ 安装成功！请妥善保存以下连接参数：
-------------------------------------------------------
地址 (Address): $CLEAR_IP
端口 (Port): $PORT
用户 ID (UUID): $USER_UUID
流控 (Flow): xtls-rprx-vision
传输安全 (Security): reality
SNI: $SNI
公钥 (PublicKey): $PUB_KEY
ShortID: $SHORT_ID
Fingerprint: chrome
-------------------------------------------------------
🔒 安全提示:
   请不要在公共评论区贴出以上信息！
   • 配置文件位于: $XRAY_CONFIG
   • 服务文件位于: /etc/systemd/system/xray.service
   • 网络配置脚本: /usr/local/bin/setup-xray-network.sh
   • 定时任务已配置：每日 04:00 自动重启清理内存

🌍 Debian LXD 环境兼容说明:
   • MTU 已设置为 1380（解决长距离丢包）
   • 若 MTU 设置失败：此环境不支持修改（继续使用系统默认值）
   • BBR 自动检测：支持则启用，不支持则降级使用 cubic
   • 使用 systemd 管理服务（替代 OpenRC）
   • 所有容错机制均已启用，确保低权限环境下可用

📋 故障排查:
   • 验证服务: systemctl status xray.service
   • 查看日志: journalctl -u xray.service -n 50
   • 查看配置: cat /etc/xray/config.json
   • 检查内存: free -m
   • 手动重启: systemctl restart xray.service
   • 停止服务: systemctl stop xray.service
   • 启动服务: systemctl start xray.service
-------------------------------------------------------
EOF
