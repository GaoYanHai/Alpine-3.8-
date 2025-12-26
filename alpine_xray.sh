#!/bin/sh

# ====================================================
# Project: Alpine LXC Xray Reality One-Click Script
# Optimization: BBR, MTU 1380, OpenRC, Low RAM (512M)
# ====================================================

# 设置基础变量
PORT=52300
SHORT_ID="0123456789abcdef"
DEST_SITE="www.ikea.com:443"
SNI="www.ikea.com"

# 1. 环境准备与依赖安装
echo "正在安装依赖..."
apk update && apk add curl gcompat ca-certificates unzip

# 创建目录
mkdir -p /etc/xray /usr/bin

# 2. 下载并安装最新版 Xray-core
echo "正在下载 Xray-core..."
curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o /tmp/xray.zip xray -d /usr/bin/
chmod +x /usr/bin/xray
rm /tmp/xray.zip

# 3. 动态生成身份凭证 (脱敏处理)
echo "正在生成加密密钥..."
USER_UUID=$(/usr/bin/xray uuid)
KEYS=$(/usr/bin/xray x25519)
# 适配 Alpine 环境下的字符提取
PRIV_KEY=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
PUB_KEY=$(echo "$KEYS" | grep "Password" | awk '{print $2}')

# 4. 生成 Xray 配置文件
cat << CONF > /etc/xray/config.json
{
    "log": { "loglevel": "none" },
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
# 启用 BBR (如果内核支持)
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1

# 6. 配置开机自启与 MTU 修正
# 针对 Alpine OpenRC 编写启动脚本
cat << START > /etc/local.d/xray.start
#!/bin/sh
# 修正 MTU 解决 NAT 丢包
ifconfig eth0 mtu 1380
# 启动 Xray
nohup /usr/bin/xray run -c /etc/xray/config.json > /dev/null 2>&1 &
START

chmod +x /etc/local.d/xray.start
rc-update add local default
rc-service local restart

# 7. 配置定时重启任务 (防止小内存溢出)
# 每天凌晨 4:00 重启服务
echo "0 4 * * * rc-service local restart" >> /var/spool/cron/crontabs/root

# 8. 输出安装结果
CLEAR_IP=$(curl -s ifconfig.me)
echo "-------------------------------------------------------"
echo "✅ 安装成功！请妥善保存以下连接信息："
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
echo "提示: 建议将此信息截图或存入备忘录。"
