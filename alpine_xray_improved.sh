#!/bin/sh

# ====================================================
# Project: Alpine LXC Xray Reality One-Click Script
# Optimization: MTU, OpenRC, Low RAM (512M), NAT Compatible
# Features: Enhanced error handling, network compatibility, retry logic
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
XRAY_LOG="/var/log/xray.log"

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

# 从 x25519 输出中提取密钥（兼容 BusyBox，不依赖 grep -P）
extract_key_value() {
    label="$1"
    text="$2"
    echo "$text" | sed -n "s/.*${label}:[[:space:]]*\\([^[:space:]]*\\).*/\\1/p" | head -n 1
}

# 1. 环境准备与依赖安装
echo "正在安装基础依赖..."
run_cmd apk update
run_cmd apk add curl gcompat ca-certificates unzip openrc iproute2 chrony

# 创建必要目录
run_cmd mkdir -p "$XRAY_DIR" "$(dirname "$XRAY_BIN")" /var/log /etc/local.d

# 1.5 时间同步（REALITY 对时间误差非常敏感）
echo "正在配置时间同步..."
if [ -f /etc/chrony/chrony.conf ]; then
    if ! grep -q "pool.ntp.org" /etc/chrony/chrony.conf 2>/dev/null; then
        echo "server pool.ntp.org iburst" >> /etc/chrony/chrony.conf
    fi
fi
rc-update add chronyd default 2>/dev/null || true
rc-service chronyd start 2>/dev/null || true
chronyc -a makestep 2>/dev/null || true
date

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

# 验证 Xray 二进制文件可执行性
if ! "$XRAY_BIN" version > /dev/null 2>&1; then
    error_exit "Xray 二进制文件损坏或架构不兼容"
fi

# 3. 动态生成身份凭证（安全提取）
echo "正在生成加密密钥..."
USER_UUID=$("$XRAY_BIN" uuid)

# 更安全的密钥提取方式（支持多种输出格式，兼容 BusyBox）
# 新版格式: PrivateKey: xxx  /  Password: xxx  (Password 即 PublicKey)
# 旧版格式: PrivateKey: xxx  /  PublicKey: xxx
KEYS_OUTPUT=$("$XRAY_BIN" x25519)
echo "调试信息 - Xray x25519 输出:" >&2
echo "$KEYS_OUTPUT" >&2

PRIV_KEY=$(extract_key_value "PrivateKey" "$KEYS_OUTPUT")
PUB_KEY=$(extract_key_value "Password" "$KEYS_OUTPUT")

# 兜底：旧版 PublicKey 标签
if [ -z "$PUB_KEY" ]; then
    PUB_KEY=$(extract_key_value "PublicKey" "$KEYS_OUTPUT")
fi

# 再兜底：某些版本输出 "Password (PublicKey):"
if [ -z "$PUB_KEY" ]; then
    PUB_KEY=$(echo "$KEYS_OUTPUT" | sed -n 's/.*Password[[:space:]]*(PublicKey):[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)
fi

# 验证密钥是否成功提取
[ -z "$PRIV_KEY" ] && error_exit "无法提取私钥，原始输出: $KEYS_OUTPUT"
[ -z "$PUB_KEY" ] && error_exit "无法提取公钥，原始输出: $KEYS_OUTPUT"
[ -z "$USER_UUID" ] && error_exit "无法生成 UUID"

echo "✅ 密钥生成成功"
echo "  PrivateKey 长度: $(printf %s "$PRIV_KEY" | wc -c)"
echo "  PublicKey 长度: $(printf %s "$PUB_KEY" | wc -c)"

# 4. 生成 Xray 配置文件
# 说明：
# - 默认监听 0.0.0.0，避免某些 LXC/NAT 环境只绑 loopback
# - 日志改为 warning + 文件，便于排查“端口通但连不上”
echo "正在生成配置文件..."
cat > "$XRAY_CONFIG" << CONF
{
    "log": {
        "loglevel": "warning",
        "access": "$XRAY_LOG",
        "error": "$XRAY_LOG"
    },
    "inbounds": [{
        "listen": "0.0.0.0",
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
    "outbounds": [{
        "protocol": "freedom",
        "settings": {}
    }]
}
CONF

# 验证 JSON 配置文件格式（优先 jq，没有 jq 时做基础检查）
if command -v jq >/dev/null 2>&1; then
    if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
        error_exit "配置文件 JSON 格式错误"
    fi
    echo "✅ 配置文件 JSON 格式验证通过"
else
    if ! grep -q "\"privateKey\": \"$PRIV_KEY\"" "$XRAY_CONFIG"; then
        error_exit "配置文件写入私钥失败"
    fi
    if ! grep -q "\"id\": \"$USER_UUID\"" "$XRAY_CONFIG"; then
        error_exit "配置文件写入 UUID 失败"
    fi
    echo "⚠️  警告: 未安装 jq，已做基础字段检查 (apk add jq 可加强验证)"
fi

# 5. 系统网络优化（NAT 兼容性优先）
echo "正在进行网络性能调优..."

# 尝试启用 BBR（NAT 环境可能不支持，失败也继续）
{
    if [ -f /etc/sysctl.conf ]; then
        grep -v "net.core.default_qdisc" /etc/sysctl.conf 2>/dev/null || true
        grep -v "net.ipv4.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null || true
    fi
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
    sed -i '/tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
fi

# 6. 配置开机自启与 MTU 修正（NAT 环境兼容）
# 关键修复：同时提供 start/stop，避免 rc-service local restart 只启动不杀旧进程
echo "正在配置开机自启..."
cat > /etc/local.d/xray.start << 'START'
#!/bin/sh
# NAT 兼容的网卡检测和 MTU 设置

# 自动检测网卡名称
NETIF=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -1)
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
CURRENT_MTU=$(ip link show "$NETIF" 2>/dev/null | sed -n 's/.*mtu \([0-9][0-9]*\).*/\1/p' || echo "")
if [ "$CURRENT_MTU" = "1380" ]; then
    echo "✅ MTU 已设置为 1380"
else
    echo "⚠️  MTU 设置失败（在此 NAT 环境可能无法修改），使用系统默认值继续运行"
fi

# 防止重复启动导致端口被旧进程占用、新配置不生效
if command -v pkill >/dev/null 2>&1; then
    pkill -f "/usr/local/bin/xray run -c /etc/xray/config.json" 2>/dev/null || true
else
    kill $(ps | grep "[x]ray run -c /etc/xray/config.json" | awk '{print $1}') 2>/dev/null || true
fi
sleep 1

# 启动 Xray；日志写入文件，避免“全黑洞”无法排障
touch /var/log/xray.log 2>/dev/null || true
/usr/local/bin/xray run -c /etc/xray/config.json >> /var/log/xray.log 2>&1 &
START

cat > /etc/local.d/xray.stop << 'STOP'
#!/bin/sh
# OpenRC local 服务 stop 钩子：确保重启时旧 Xray 进程被清理
if command -v pkill >/dev/null 2>&1; then
    pkill -f "/usr/local/bin/xray run -c /etc/xray/config.json" 2>/dev/null || true
else
    kill $(ps | grep "[x]ray run -c /etc/xray/config.json" | awk '{print $1}') 2>/dev/null || true
fi
STOP

run_cmd chmod +x /etc/local.d/xray.start
run_cmd chmod +x /etc/local.d/xray.stop
run_cmd rc-update add local default

# 先停再启，确保旧进程不会残留
rc-service local stop 2>/dev/null || true
# 保险再杀一次
if command -v pkill >/dev/null 2>&1; then
    pkill -f "/usr/local/bin/xray run -c /etc/xray/config.json" 2>/dev/null || true
fi
run_cmd rc-service local start

# 验证服务是否成功启动
sleep 2
if pgrep -f "xray run" > /dev/null 2>&1 || ps | grep -q "[x]ray run"; then
    echo "✅ Xray 服务已成功启动"
else
    echo "⚠️  警告: Xray 服务可能启动失败，检查配置或日志"
    echo "   日志: tail -n 50 $XRAY_LOG"
fi

# 7. 配置定时重启任务（防止小内存 OOM）
echo "正在配置定时重启任务..."
CRON_DIR="/var/spool/cron/crontabs"
run_cmd mkdir -p "$CRON_DIR"

# 避免重复添加 cron 任务（追加，不要整文件覆盖，防止抹掉其他任务）
touch "$CRON_DIR/root"
chmod 600 "$CRON_DIR/root"
if ! grep -q "rc-service local restart" "$CRON_DIR/root" 2>/dev/null; then
    echo "0 4 * * * rc-service local restart" >> "$CRON_DIR/root"
fi

run_cmd rc-update add crond default
run_cmd rc-service crond start

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
  • 停止脚本位于: /etc/local.d/xray.stop
  • 日志文件位于: $XRAY_LOG
  • 定时任务已配置：每日 04:00 自动重启清理内存

🌍 NAT 环境兼容说明:
  • MTU 已设置为 1380（解决长距离丢包）
  • 若 MTU 设置失败：此环境不支持修改（继续使用系统默认值）
  • BBR 自动检测：支持则启用，不支持则降级使用 cubic
  • 已配置 chrony 时间同步（REALITY 对时间敏感）
  • 所有容错机制均已启用，确保低权限环境下可用

📋 故障排查:
  • 验证服务: ps aux | grep xray
  • 查看配置: cat /etc/xray/config.json
  • 查看日志: tail -n 50 /var/log/xray.log
  • 检查时间: date
  • 检查内存: free -m
  • 手动重启: rc-service local restart
-------------------------------------------------------
EOF
