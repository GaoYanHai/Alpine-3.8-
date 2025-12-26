#!/bin/sh

# ====================================================
# Project: Alpine LXC Xray Reality One-Click Script
# Optimization: BBR, MTU 1380, OpenRC, Low RAM (512M)
# Logging: Fully Disabled (For 1G Disk)
# ====================================================

# 0. 自定义基础变量
PORT=52300
SHORT_ID="0123456789abcdef"
DEST_SITE="www.ikea.com:443"
SNI="www.ikea.com"

# 1. 环境准备与依赖安装
echo "正在安装基础依赖..."
apk update && apk add curl gcompat ca-certificates unzip

# 创建必要目录
mkdir -p /etc/xray /usr/bin

# 2. 下载并安装最新版 Xray-core
echo "正在下载 Xray-core..."
curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o /tmp/xray.zip xray -d /usr/bin/
chmod +x /usr/bin/xray
rm /tmp/xray.zip

# 3. 动态生成身份凭证 (安全脱敏)
echo "正在生成加密密钥..."
USER_UUID=$(/usr/bin/xray uuid)
KEYS=$(/usr/bin/xray x25519)
# 适配特定版本输出格式提取密钥
PRIV_KEY=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
PUB_KEY=$(echo "$KEYS" | grep "Password" | awk '{print $2}')

# 4. 生成 Xray 配置文件 (日志全关版)
cat << CONF > /etc/xray/config.json
{
    "log": {
        "loglevel": "none",
        "access": "/dev/null",
        "error": "/dev/null"
    },
    "inbounds": [{
        "port": $PORT,
        "protocol": "vless",
        "settings": {
            "clients": [{
                "id": "$USER_UUID",
                "flow": "xtls-rprx-vision"
            }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": false,
                "dest": "$DEST_SITE",
                "xver": 0,
                "serverNames": ["$SNI"],
                "privateKey": "$PRIV_KEY",
                "shortIds": ["$SHORT_ID"]
            }
        }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
CONF

# 5. 系统网络优化 (BBR + TCP 参数)
echo "正在进行网络性能调优..."
# 尝试启用 BBR
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1

# 6. 配置开机自启与 MTU 修正
# 编写 OpenRC local.d 启动脚本，彻底丢弃所有输出
cat << START > /etc/local.d/xray.start
#!/bin/sh
# 修正 MTU 解决 NAT 丢包关键
ifconfig eth0 mtu 1380
# 启动 Xray 并将所有日志重定向到黑洞
nohup /usr/bin/xray run -c /etc/xray/config.json > /dev/null 2>&1 &
START

chmod +x /etc/local.d/xray.start
rc-update add local default
rc-service local restart

# 7. 配置定时重启任务 (防止小内存 OOM)
# 每天凌晨 4:00 重启服务清理内存
mkdir -p /var/spool/cron/crontabs
echo "0 4 * * * rc-service local restart" >> /var/spool/cron/crontabs/root
# 确保 crond 服务开启
rc-update add crond default
rc-service crond start

# 8. 输出安装结果
CLEAR_IP=$(curl -s ifconfig.me)
echo "-------------------------------------------------------"
echo "✅ 安装成功！请妥善保存以下连接参数："
echo "-------------------------------------------------------"
echo "地址 (Address): $CLEAR_IP"
echo "端口 (Port): $PORT"
echo "用户 ID (UUID): $USER_UUID"
echo "流控 (Flow): xtls-rprx-vision"
echo "传输安全 (Security): reality"
echo "SNI: $SNI"
echo "公钥 (PublicKey): $PUB_KEY"
echo "ShortID: $SHORT_ID"
echo "Fingerprint: chrome"
echo "-------------------------------------------------------"
echo "警告: 请不要在公共评论区贴出以上信息！"
