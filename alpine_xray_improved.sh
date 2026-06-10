#!/bin/sh

# ====================================================
# Project: Alpine LXC Xray Reality One-Click Script
# Optimization: BBR, MTU 1380, OpenRC, Low RAM (512M)
# Logging: Fully Disabled (For 1G Disk)
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

# 1. 环境准备与依赖安装
echo "正在安装基础依赖..."
run_cmd apk update
run_cmd apk add curl gcompat ca-certificates unzip

# 创建必要目录
run_cmd mkdir -p "$XRAY_DIR" "$(dirname "$XRAY_BIN")"

# 2. 下载并安装最新版 Xray-core（带重试机制）
echo "正在下载 Xray-core..."
XRAY_ZIP="/tmp/xray-$$.zip"
trap "rm -f $XRAY_ZIP" EXIT  # 确保删除临时文件

# 添加重试逻辑
RETRY=0
MAX_RETRIES=3
while [ $RETRY -lt $MAX_RETRIES ]; do
    if curl -L --connect-timeout 10 -o "$XRAY_ZIP" \
        "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"; then
        break
    fi
    RETRY=$((RETRY + 1))
    if [ $RETRY -lt $MAX_RETRIES ]; then
        echo "下载失败，重试 $RETRY/$MAX_RETRIES..."
        sleep 5
    fi
done

if [ $RETRY -eq $MAX_RETRIES ]; then
    error_exit "无法下载 Xray-core，超过最大重试次数"
fi

run_cmd unzip -o "$XRAY_ZIP" xray -d "$(dirname "$XRAY_BIN")"
run_cmd chmod +x "$XRAY_BIN"

# 3. 动态生成身份凭证（安全提取）
echo "正在生成加密密钥..."
USER_UUID=$("$XRAY_BIN" uuid)

# 更安全的密钥提取方式
KEYS_OUTPUT=$("$XRAY_BIN" x25519)
PRIV_KEY=$(echo "$KEYS_OUTPUT" | grep -oP '(?<=PrivateKey:\s)\S+' || echo "")
PUB_KEY=$(echo "$KEYS_OUTPUT" | grep -oP '(?<=PublicKey:\s)\S+' || echo "")

# 验证密钥是否成功提取
[ -z "$PRIV_KEY" ] && error_exit "无法提取私钥"
[ -z "$PUB_KEY" ] && error_exit "无法提取公钥"
[ -z "$USER_UUID" ] && error_exit "无法生成 UUID"

# 4. 生成 Xray 配置文件（日志全关版）
echo "正在生成配置文件..."
cat > "$XRAY_CONFIG" << CONF
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

# 验证 JSON 配置文件格式
if ! command -v jq >/dev/null 2>&1; then
    echo "⚠️  警告: 建议安装 jq 用于 JSON 验证"
else
    if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
        error_exit "配置文件 JSON 格式错误"
    fi
fi

# 5. 系统网络优化（BBR + TCP 参数）
echo "正在进行网络性能调优..."
# 安全地更新 sysctl 配置
{
    grep -v "net.core.default_qdisc" /etc/sysctl.conf 2>/dev/null || true
    grep -v "net.ipv4.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null || true
    echo "net.core.default_qdisc=fq"
    echo "net.ipv4.tcp_congestion_control=bbr"
} > /etc/sysctl.conf.tmp && mv /etc/sysctl.conf.tmp /etc/sysctl.conf

sysctl -p > /dev/null 2>&1 || echo "⚠️  警告: sysctl 应用失败"

# 6. 配置开机自启与 MTU 修正
echo "正在配置开机自启..."
cat > /etc/local.d/xray.start << 'START'
#!/bin/sh
# 修正 MTU 解决 NAT 丢包关键
if command -v ifconfig >/dev/null 2>&1; then
    ifconfig eth0 mtu 1380 2>/dev/null || true
else
    ip link set dev eth0 mtu 1380 2>/dev/null || true
fi

# 启动 Xray 并将所有日志重定向到黑洞
/usr/local/bin/xray run -c /etc/xray/config.json > /dev/null 2>&1 &
START

run_cmd chmod +x /etc/local.d/xray.start
run_cmd rc-update add local default
run_cmd rc-service local restart

# 7. 配置定时重启任务（防止小内存 OOM）
echo "正在配置定时重启..."
CRON_DIR="/var/spool/cron/crontabs"
run_cmd mkdir -p "$CRON_DIR"

# 避免重复添加 cron 任务
if ! grep -q "rc-service local restart" "$CRON_DIR/root" 2>/dev/null; then
    echo "0 4 * * * rc-service local restart" >> "$CRON_DIR/root"
fi

run_cmd rc-update add crond default
run_cmd rc-service crond start

# 8. 输出安装结果
echo ""
echo "正在获取公网 IP..."
CLEAR_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "获取失败")

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
  • 请不要在公共评论区贴出以上信息！
  • 配置文件位于: $XRAY_CONFIG
  • 启动脚本位于: /etc/local.d/xray.start
-------------------------------------------------------
EOF
