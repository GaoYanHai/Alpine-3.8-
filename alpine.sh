cat << 'EOF' > alpine_xray.sh
#!/bin/sh

# 1. 环境准备
apk update && apk add curl gcompat ca-certificates unzip
mkdir -p /etc/xray /usr/bin

# 2. 下载最新 Xray (针对 amd64)
curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o /tmp/xray.zip xray -d /usr/bin/
chmod +x /usr/bin/xray
rm /tmp/xray.zip

# 3. 自动生成密钥
KEYS=$(xray x25519)
# 针对你那个特殊版本的内核提取逻辑 (适配你之前的输出格式)
PRIV_KEY=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
PUB_KEY=$(echo "$KEYS" | grep "Password" | awk '{print $2}')

# 4. 创建配置文件 (填入你验证过的宜家节点)
cat << CONF > /etc/xray/config.json
{
    "inbounds": [{
        "port": 52300,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "111111111111111111111111", "flow": "xtls-rprx-vision"}],
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
                "privateKey": "$PRIV_KEY",
                "shortIds": ["0123456789abcdef"]
            }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
CONF

# 5. 系统优化 (BBR + MTU + TCP)
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
ifconfig eth0 mtu 1380

# 6. 设置开机自启 (OpenRC local 模式)
cat << START > /etc/local.d/xray.start
#!/bin/sh
ifconfig eth0 mtu 1380
nohup /usr/bin/xray run -c /etc/xray/config.json > /dev/null 2>&1 &
START
chmod +x /etc/local.d/xray.start
rc-update add local default
rc-service local restart

# 7. 定时任务 (凌晨4点重启)
echo "0 4 * * * rc-service local restart" >> /var/spool/cron/crontabs/root

echo "-------------------------------------------------------"
echo "安装完成！"
echo "公网 IP: $(curl -s ifconfig.me)"
echo "端口: 111111111"
echo "UUID: 11111111111111111111111"
echo "Public Key (客户端填这个): $PUB_KEY"
echo "SNI: www.ikea.com"
echo "Flow: xtls-rprx-vision"
echo "-------------------------------------------------------"
EOF

chmod +x alpine_xray.sh
./alpine_xray.sh
