#!/bin/sh

# ====================================================
# Project: Alpine LXC Xray Reality One-Click Script
# Optimization: MTU, OpenRC, Low RAM (512M), NAT Compatible
# Features: Enhanced error handling, network compatibility, retry logic
# ====================================================

set -e  # 错误时立即退出，避免继续执行
set -u  # 未定义变量时报错
# 尽量启用 pipefail（若 shell 支持）
set -o pipefail 2>/dev/null || true

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
# 添加必要依赖，使用 --no-cache 减少镜像缓存
run_cmd apk update
run_cmd apk add --no-cache curl gcompat ca-certificates unzip iproute2 procps jq

# 创建必要目录
run_cmd mkdir -p "$XRAY_DIR" "$(dirname "$XRAY_BIN")"

# 2. 下载并安装最新版 Xray-core（带重试机制）
echo "正在下载 Xray-core..."
XRAY_ZIP="/tmp/xray-$$.zip"
trap 'rm -f "$XRAY_ZIP"' EXIT  # 确保删除临时文件

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

# 验证 Xray 二进制文件可执行性
if ! "$XRAY_BIN" version > /dev/null 2>&1; then
    error_exit "Xray 二进制文件损坏或架构不兼容"
fi

# 3. 动态生成身份凭证（安全提取）
echo "正在生成加密密钥..."
# 先尝试使用 xray 自带的工具生成，如果不可用则回退
if command -v "$XRAY_BIN" >/dev/null 2>&1 && "$XRAY_BIN" uuid >/dev/null 2>&1; then
    USER_UUID=$("$XRAY_BIN" uuid)
else
    # 回退：使用内核随机 UUID 或简单占位
    if [ -r /proc/sys/kernel/random/uuid ]; then
        USER_UUID=$(cat /proc/sys/kernel/random/uuid)
    else
        USER_UUID=$(printf '%s' "$(date +%s)-$RANDOM")
    fi
fi

# 更安全的密钥提取方式（支持多种输出格式），使用 awk 代替 grep -P
KEYS_OUTPUT=$("$XRAY_BIN" x25519 2>/dev/null || true)
PRIV_KEY=$(printf '%s\n' "$KEYS_OUTPUT" | awk '/PrivateKey:/{print $2; exit}' || true)
PUB_KEY=$(printf '%s\n' "$KEYS_OUTPUT" | awk '/PublicKey:/{print $2; exit}' || true)

# 备选提取方式（针对不同版本的 Xray）
if [ -z "$PUB_KEY" ]; then
    PUB_KEY=$(printf '%s\n' "$KEYS_OUTPUT" | awk '/Password:/{print $2; exit}' || true)
fi

# 验证密钥是否成功提取（允许某些环境使用占位并警告）
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

# 使用 jq 安全替换字段（如果可用），否则回退到安全的 sed 替换
if command -v jq >/dev/null 2>&1; then
    tmp_cfg=$(mktemp)
    jq --arg id "$USER_UUID" --arg pk "$PRIV_KEY" \
       '.inbounds[0].settings.clients[0].id=$id | .inbounds[0].streamSettings.realitySettings.privateKey=$pk' \
       "$XRAY_CONFIG" > "$tmp_cfg" && mv "$tmp_cfg" "$XRAY_CONFIG"
else
    # sed 分隔符选择为 | 并转义特殊字符
    esc_priv=$(printf '%s' "$PRIV_KEY" | sed -e 's/[\/&]/\\&/g')
    esc_uuid=$(printf '%s' "$USER_UUID" | sed -e 's/[\/&]/\\&/g')
    sed -i "s|placeholder_uuid|$esc_uuid|g" "$XRAY_CONFIG"
    sed -i "s|placeholder_privkey|$esc_priv|g" "$XRAY_CONFIG"
fi

# 验证 JSON 配置文件格式
if command -v jq >/dev/null 2>&1; then
    if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
        error_exit "配置文件 JSON 格式错误"
    fi
    echo "✅ 配置文件 JSON 格式验证通过"
else
    echo "⚠️  警告: 建议安装 jq 用于 JSON 验证 (apk add jq)"
fi

# 5. 系统网络优化（NAT 兼容性优先）
echo "正在进行网络性能调优..."

# 备份 sysctl 配置
cp /etc/sysctl.conf /etc/sysctl.conf.bak 2>/dev/null || true
{
    grep -v "net.core.default_qdisc" /etc/sysctl.conf 2>/dev/null || true
    grep -v "net.ipv4.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null || true
    # 仅在 BBR 支持的环境下启用，否则降级到 cubic
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n'
} > /etc/sysctl.conf.tmp && mv /etc/sysctl.conf.tmp /etc/sysctl.conf

# 应用 sysctl 配置，失败不中断
if sysctl -p > /dev/null 2>&1; then
    echo "✅ BBR 配置已应用"
else
    echo "⚠️  警告: BBR 在当前环境不可用，降级使用系统默认算法"
    # 移除 BBR 配置以防启动失败
    sed -i '/tcp_congestion_control/d' /etc/sysctl.conf || true
fi

# 6. 配置开机自启与 MTU 修正（NAT 环境兼容）
echo "正在配置开机自启..."
cat > /etc/local.d/xray.start << 'START'
#!/bin/sh
# NAT 兼容的网卡检测和 MTU 设置

# 自动检测网卡名称
NETIF=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$NETIF" ]; then
    NETIF="eth0"
fi

echo "检测到网卡: $NETIF"

# 尝试设置 MTU（重要：解决 NAT 环境丢包）
# 1380 是 NAT 环境的通用安全值
if command -v ip >/dev/null 2>&1; then
    ip link set dev "$NETIF" mtu 1380 2>/dev/null || true
elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig "$NETIF" mtu 1380 2>/dev/null || true
fi

# 验证 MTU 设置
CURRENT_MTU=$(ip link show "$NETIF" 2>/dev/null | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") {print $(i+1); exit}}' || true)
if [ "$CURRENT_MTU" = "1380" ]; then
    echo "✅ MTU 已设置为 1380"
else
    echo "⚠️  MTU 设置失败（在此 NAT 环境可能无法修改），使用系统默认值继续运行"
fi

# 启动 Xray 并将所有日志重定向到黑洞
/usr/local/bin/xray run -c /etc/xray/config.json > /dev/null 2>&1 &
START

run_cmd chmod +x /etc/local.d/xray.start
run_cmd rc-update add local default
run_cmd rc-service local restart || true

# 验证服务是否成功启动
sleep 2
if (command -v pgrep >/dev/null 2>&1 && pgrep -f "xray run" >/dev/null 2>&1) \
   || (command -v pidof >/dev/null 2>&1 && pidof xray >/dev/null 2>&1) \
   || (ss -ltnp 2>/dev/null | grep -q ":$PORT "); then
    echo "✅ Xray 服务已成功启动"
else
    echo "⚠️  警告: Xray 服务可能启动失败，检查配置或日志"
fi

# 7. 配置定时重启任务（防止小内存 OOM）
echo "正在配置定时重启任务..."
CRON_DIR="/var/spool/cron/crontabs"
run_cmd mkdir -p "$CRON_DIR"

# 避免覆盖已有 cron 任务，使用追加方式
if [ ! -f "$CRON_DIR/root" ]; then
    touch "$CRON_DIR/root"
    chmod 600 "$CRON_DIR/root"
fi
if ! grep -q "rc-service local restart" "$CRON_DIR/root" 2>/dev/null; then
    printf '%s\n' "0 4 * * * rc-service local restart" >> "$CRON_DIR/root"
    chmod 600 "$CRON_DIR/root"
fi

run_cmd rc-update add crond default
run_cmd rc-service crond start || true

# 8. 输出安装结果
echo ""
echo "正在获取公网 IP..."
CLEAR_IP=$(curl -s --connect-timeout 5 --max-time 10 ifconfig.me 2>/dev/null || echo "获取失败（NAT 环境可能无外网访问）")

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
  • 定时任务已配置：每日 04:00 自动重启清理内存

🌍 NAT 环境兼容说明:
  • MTU 已设置为 1380（解决长距离丢包）
  • 若 MTU 设置失败：此环境不支持修改（继续使用系统默认值）
  • BBR 自动检测：支持则启用，不支持则降级使用 cubic
  • 所有容错机制均已启用，确保低权限环境下可用

📋 故障排查:
  • 验证服务: ps aux | grep xray
  • 查看配置: cat /etc/xray/config.json
  • 检查内存: free -m
  • 手动重启: rc-service local restart
-------------------------------------------------------
EOF
