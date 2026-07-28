#!/bin/bash

# ====================================================
# Project: Debian LXD Xray Reality One-Click Script
# Platform: Debian trixie amd64 (20251224_0350)
# Features: Enhanced error handling, systemd, firewall, connectivity checks
# ====================================================

set -e  # 错误时立即退出，避免继续执行
set -u  # 未定义变量时报错

# 0. 自定义基础变量
PORT=52300
SHORT_ID="0123456789abcdef"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/etc/xray/config.json"
XRAY_DIR="/etc/xray"
XRAY_USER="xray"
XRAY_GROUP="xray"
XRAY_LOG="/var/log/xray.log"
SHARE_FILE="/etc/xray/client-link.txt"

# SNI 候选列表（按优先级，可自行调整）
# 注意: REALITY dest 需要目标站支持 TLS1.3 + H2，且服务器能访问其 443
SNI_CANDIDATES=(
    "www.microsoft.com"
    "swdlp.apple.com"
    "www.sony.co.jp"
    "www.samsung.com"
    "www.shopee.sg"
    "www.bmw.com"
    "www.dyson.co.uk"
    "www.intel.com"
    "www.ikea.com"
)

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

extract_key_value() {
    label="$1"
    text="$2"
    echo "$text" | sed -n "s/.*${label}:[[:space:]]*\\([^[:space:]]*\\).*/\\1/p" | head -n 1
}

# 兼容多版本 x25519 输出；新版 Password 字段 = 客户端 PublicKey
extract_reality_keys() {
    text="$1"
    local priv=""
    local pub=""

    priv=$(extract_key_value "PrivateKey" "$text")
    [ -z "$priv" ] && priv=$(extract_key_value "Private key" "$text")
    [ -z "$priv" ] && priv=$(extract_key_value "privateKey" "$text")

    pub=$(extract_key_value "Password" "$text")
    if [ -z "$pub" ]; then
        pub=$(echo "$text" | sed -n 's/.*Password[[:space:]]*(PublicKey):[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)
    fi
    [ -z "$pub" ] && pub=$(extract_key_value "PublicKey" "$text")
    [ -z "$pub" ] && pub=$(extract_key_value "Public key" "$text")
    [ -z "$pub" ] && pub=$(extract_key_value "publicKey" "$text")

    # 防止误把 Hash32 当公钥
    if [ -n "$pub" ] && echo "$text" | grep -q "Hash32:[[:space:]]*$pub"; then
        pub=""
    fi

    printf '%s\n%s\n' "$priv" "$pub"
}

validate_b64_key() {
    local key="$1"
    local name="$2"
    local len
    len=$(printf %s "$key" | wc -c | tr -d ' ')
    if [ "$len" -lt 40 ] || [ "$len" -gt 64 ]; then
        error_exit "$name 长度异常($len)，x25519 解析可能失败"
    fi
    if [[ ! "$key" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
        error_exit "$name 含非法字符: $key"
    fi
}

get_public_ip() {
    local ip=""
    local url
    for url in \
        "https://api.ipify.org" \
        "https://ifconfig.me/ip" \
        "https://ipv4.icanhazip.com" \
        "https://api.ip.sb/ip"
    do
        ip=$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '\r\n' | head -n 1 || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
        ip=""
    done
    ip=$(curl -fsS --connect-timeout 5 --max-time 8 "https://ifconfig.me" 2>/dev/null | tr -d '\r\n' | head -n 1 || true)
    if [ -n "$ip" ]; then
        echo "$ip"
    else
        echo "获取失败（NAT/LXD 环境请填宿主机公网 IP）"
    fi
}

open_firewall_port() {
    local port="$1"
    local opened=0
    echo "正在尝试开放防火墙 TCP $port ..."

    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qi "Status: active"; then
            ufw allow "${port}/tcp" >/dev/null 2>&1 && opened=1 && echo "✅ ufw 已放行 ${port}/tcp"
        fi
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        if firewall-cmd --state 2>/dev/null | grep -qi running; then
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            opened=1
            echo "✅ firewalld 已放行 ${port}/tcp"
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            if iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                opened=1
                echo "✅ iptables 已放行 ${port}/tcp"
            fi
        else
            opened=1
            echo "✅ iptables 已存在 ${port}/tcp 放行规则"
        fi
    fi

    if [ "$opened" -eq 0 ]; then
        echo "⚠️  容器内未检测到可配置防火墙（LXD 常见，通常正常）"
    fi
    echo "⚠️  若客户端延迟 -1ms：请检查云安全组 + LXD 代理/端口映射是否放行 TCP $port"
}

urlencode() {
    if command -v python3 >/dev/null 2>&1; then
        printf %s "$1" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))' 2>/dev/null && return 0
    fi
    printf %s "$1" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g'
}

# 自动检测延迟最低的 SNI
detect_best_sni() {
    echo "正在检测延迟最低的 SNI..." >&2
    echo "候选 SNI 列表: ${SNI_CANDIDATES[*]}" >&2
    echo "" >&2

    local best_sni=""
    local best_latency=99999
    local sni latency latency_ms

    for sni in "${SNI_CANDIDATES[@]}"; do
        # 先确认 443 通，再比 TLS 连接时延
        if ! (echo >/dev/tcp/${sni}/443) >/dev/null 2>&1; then
            if ! curl -fsSI --connect-timeout 3 --max-time 5 "https://${sni}" >/dev/null 2>&1; then
                echo "🔍 $sni: 不可达，跳过" >&2
                continue
            fi
        fi

        latency=$(curl -w "%{time_connect}" -o /dev/null -s --connect-timeout 3 --max-time 5 "https://${sni}" 2>/dev/null || echo "9999")
        latency_ms=$(echo "$latency * 1000" | bc 2>/dev/null || echo "9999000")
        echo "🔍 $sni: ${latency_ms}ms" >&2

        if command -v bc >/dev/null 2>&1; then
            if [ "$(echo "$latency < $best_latency" | bc -l)" = "1" ]; then
                best_latency=$latency
                best_sni=$sni
            fi
        else
            # 无 bc 时用整数毫秒近似比较
            local ms_int
            ms_int=${latency_ms%.*}
            ms_int=${ms_int:-9999000}
            local best_ms
            best_ms=$(echo "$best_latency * 1000" | awk '{printf "%d", $1}' 2>/dev/null || echo 9999000)
            if [ "$ms_int" -lt "$best_ms" ] 2>/dev/null; then
                best_latency=$latency
                best_sni=$sni
            fi
        fi
    done

    echo "" >&2
    if [ -n "$best_sni" ]; then
        echo "✅ 最优 SNI: $best_sni (延迟: $(echo "$best_latency * 1000" | bc 2>/dev/null || echo "$best_latency")ms)" >&2
        echo "$best_sni"
    else
        echo "⚠️  无法检测 SNI，使用默认值 www.microsoft.com" >&2
        echo "www.microsoft.com"
    fi
}

# 0.5 检测并设置时区和编码
echo "正在检查时区..."
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")
if [ "$CURRENT_TZ" != "Asia/Shanghai" ]; then
    echo "  当前时区: $CURRENT_TZ，正在设置为 Asia/Shanghai..."
    timedatectl set-timezone Asia/Shanghai 2>/dev/null || ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && echo "Asia/Shanghai" > /etc/timezone 2>/dev/null
    echo "✅ 时区已设置为 Asia/Shanghai"
else
    echo "✅ 时区已是 Asia/Shanghai，无需修改"
fi

# 设置 UTF-8 编码
CURRENT_LOCALE=$(locale charmap 2>/dev/null || echo "unknown")
if [ "$CURRENT_LOCALE" != "UTF-8" ]; then
    echo "  当前编码: $CURRENT_LOCALE，正在设置为 UTF-8..."
    apt-get install -y locales > /dev/null 2>&1 || true
    sed -i 's/# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true
    sed -i 's/# *zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen 2>/dev/null || true
    locale-gen en_US.UTF-8 zh_CN.UTF-8 > /dev/null 2>&1 || true
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    echo "✅ 编码已设置为 UTF-8"
else
    echo "✅ 编码已是 UTF-8，无需修改"
fi

# 1. 环境准备与依赖安装
echo "正在安装基础依赖..."
export DEBIAN_FRONTEND=noninteractive
run_cmd apt-get update -y
run_cmd apt-get install -y curl ca-certificates unzip jq iproute2 openssl chrony bc python3

# 时间同步（REALITY 对时钟敏感，误差过大直接握手失败）
echo "正在配置时间同步..."
systemctl enable chrony 2>/dev/null || systemctl enable chronyd 2>/dev/null || true
systemctl start chrony 2>/dev/null || systemctl start chronyd 2>/dev/null || true
chronyc -a makestep 2>/dev/null || true
date
timedatectl 2>/dev/null | head -n 5 || true

# 创建必要目录与用户
run_cmd mkdir -p "$XRAY_DIR" "$(dirname "$XRAY_BIN")" /var/log
if ! id "$XRAY_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$XRAY_USER" 2>/dev/null || true
fi

# 2. 下载并安装最新版 Xray-core（带重试）
echo "正在下载 Xray-core..."
XRAY_ZIP="/tmp/xray-$$.zip"
trap 'rm -f "$XRAY_ZIP"' EXIT

RETRY=0
MAX_RETRIES=3
while [ $RETRY -lt $MAX_RETRIES ]; do
    if curl -L --connect-timeout 10 --max-time 90 -o "$XRAY_ZIP" \
        "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"; then
        break
    fi
    RETRY=$((RETRY + 1))
    if [ $RETRY -lt $MAX_RETRIES ]; then
        echo "下载失败，5秒后重试 $RETRY/$MAX_RETRIES..."
        echo "请设置代理后重试: export https_proxy=http://代理地址:端口" >&2
        sleep 5
    fi
done

if [ $RETRY -eq $MAX_RETRIES ]; then
    error_exit "无法下载 Xray-core，超过最大重试次数"
fi

if [ ! -f "$XRAY_ZIP" ] || [ ! -s "$XRAY_ZIP" ]; then
    error_exit "下载的 Xray 文件无效或为空"
fi

run_cmd unzip -o "$XRAY_ZIP" xray -d "$(dirname "$XRAY_BIN")"
run_cmd chmod +x "$XRAY_BIN"

if ! "$XRAY_BIN" version >/dev/null 2>&1; then
    error_exit "Xray 二进制文件损坏或架构不兼容"
fi
echo "Xray 版本: $("$XRAY_BIN" version 2>/dev/null | head -n 1)"

# 2.5 自动检测最优 SNI
echo ""
SNI=$(detect_best_sni)
DEST_SITE="${SNI}:443"

# 3. 动态生成身份凭证
echo ""
echo "正在生成加密密钥..."
USER_UUID=$("$XRAY_BIN" uuid)
KEYS_OUTPUT=$("$XRAY_BIN" x25519)

echo "调试信息 - Xray x25519 输出:" >&2
echo "$KEYS_OUTPUT" >&2

mapfile -t KEY_ARR < <(extract_reality_keys "$KEYS_OUTPUT")
PRIV_KEY="${KEY_ARR[0]:-}"
PUB_KEY="${KEY_ARR[1]:-}"

if [ -z "$PRIV_KEY" ]; then
    echo "❌ 错误: 无法提取私钥" >&2
    echo "原始输出: $KEYS_OUTPUT" >&2
    error_exit "无法提取私钥"
fi
if [ -z "$PUB_KEY" ]; then
    echo "❌ 错误: 无法提取公钥" >&2
    echo "原始输出: $KEYS_OUTPUT" >&2
    error_exit "无法提取公钥"
fi
if [ -z "$USER_UUID" ]; then
    error_exit "无法生成 UUID"
fi
validate_b64_key "$PRIV_KEY" "PrivateKey"
validate_b64_key "$PUB_KEY" "PublicKey"
if [ "$PRIV_KEY" = "$PUB_KEY" ]; then
    error_exit "私钥与公钥相同，密钥解析错误"
fi

echo "✅ 密钥生成成功"
echo "  PrivateKey 长度: $(printf %s "$PRIV_KEY" | wc -c | tr -d ' ')"
echo "  PublicKey  长度: $(printf %s "$PUB_KEY" | wc -c | tr -d ' ')"
echo "  说明: 新版 Xray 的 Password 字段 = 客户端 PublicKey（已自动映射，不要填 Hash32）"

# 3.5 检查伪装站
echo "正在检查伪装目标 $DEST_SITE ..."
if curl -fsSI --connect-timeout 5 --max-time 8 "https://${SNI}" >/dev/null 2>&1; then
    echo "✅ 伪装目标 HTTPS 可达"
else
    echo "⚠️  无法访问 https://${SNI} （REALITY 可能握手失败，建议更换 SNI）"
fi

# 4. 生成 Xray 配置文件
echo "正在生成配置文件..."
touch "$XRAY_LOG" 2>/dev/null || true
chown "$XRAY_USER:$XRAY_GROUP" "$XRAY_LOG" 2>/dev/null || true

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
                "shortIds": ["", "$SHORT_ID"]
            }
        },
        "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls", "quic"]
        }
    }],
    "outbounds": [{
        "protocol": "freedom",
        "settings": {}
    }]
}
CONF

if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
    error_exit "配置文件 JSON 格式错误"
fi
echo "✅ 配置文件 JSON 格式验证通过"

run_cmd chmod 644 "$XRAY_CONFIG"
run_cmd chown root:root "$XRAY_CONFIG"

# 5. 系统网络优化
echo "正在进行网络性能调优..."
{
    if [ -f /etc/sysctl.conf ]; then
        grep -v "net.core.default_qdisc" /etc/sysctl.conf 2>/dev/null || true
        grep -v "net.ipv4.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null || true
    fi
    echo "net.core.default_qdisc=fq"
    echo "net.ipv4.tcp_congestion_control=bbr"
} > /etc/sysctl.conf.tmp && mv /etc/sysctl.conf.tmp /etc/sysctl.conf

if sysctl -p >/dev/null 2>&1; then
    echo "✅ BBR 配置已应用"
else
    echo "⚠️  警告: BBR 在当前环境不可用，降级使用系统默认算法"
    sed -i '/tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
fi

# 5.5 防火墙
open_firewall_port "$PORT"

# 6. 配置 systemd 服务
echo "正在配置 systemd 服务..."
cat > /etc/systemd/system/xray.service << 'SYSTEMD'
[Unit]
Description=Xray Reality Protocol Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
# 网络脚本需要改 MTU，必须用 root 预执行（+ 前缀）
ExecStartPre=+/usr/local/bin/setup-xray-network.sh
# LXD/小内存环境优先稳定性：以 root 运行，避免权限/沙箱导致“服务起不来”
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
# 控制台日志进 journal，业务日志仍由 config.json 写入 /var/log/xray.log
StandardOutput=journal
StandardError=journal
# 容器场景避免过严沙箱；过严时常见现象就是 systemctl start 直接失败
NoNewPrivileges=true
PrivateTmp=true

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
CURRENT_MTU=$(ip link show "$NETIF" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}' || echo "")
if [ "$CURRENT_MTU" = "1380" ]; then
    echo "✅ MTU 已设置为 1380"
else
    echo "⚠️  MTU 设置失败（在此 LXD 环境可能无法修改），使用系统默认值继续运行"
fi
NETSCRIPT

run_cmd chmod +x /usr/local/bin/setup-xray-network.sh

# 8. 重新加载 systemd 并启动服务
echo "正在启动 Xray 服务..."

run_cmd chmod 755 "$XRAY_BIN"
touch "$XRAY_LOG" 2>/dev/null || true
chmod 666 "$XRAY_LOG" 2>/dev/null || chmod 644 "$XRAY_LOG" 2>/dev/null || true

if ! "$XRAY_BIN" run -test -c "$XRAY_CONFIG" >/tmp/xray-test.out 2>&1; then
    echo "❌ Xray 配置测试失败，输出如下：" >&2
    cat /tmp/xray-test.out >&2 || true
    error_exit "Xray 配置测试失败"
fi
echo "✅ Xray 配置测试通过"

run_cmd systemctl daemon-reload
systemctl reset-failed xray.service 2>/dev/null || true
run_cmd systemctl enable xray.service

if ! systemctl start xray.service; then
    echo "❌ systemctl start 失败，状态与日志如下：" >&2
    systemctl status xray.service --no-pager -l || true
    journalctl -u xray.service -n 80 --no-pager || true
    echo "---- /var/log/xray.log ----" >&2
    tail -n 80 "$XRAY_LOG" 2>/dev/null || true
    error_exit "命令执行失败: systemctl start xray.service"
fi

sleep 2
if systemctl is-active --quiet xray.service; then
    echo "✅ Xray 服务已成功启动"
else
    echo "❌ Xray 服务未处于 active 状态，诊断信息：" >&2
    systemctl status xray.service --no-pager -l || true
    journalctl -u xray.service -n 80 --no-pager || true
    tail -n 80 "$XRAY_LOG" 2>/dev/null || true
    error_exit "Xray 服务启动后未保持运行"
fi

# 8.5 安装后自检（专门针对客户端延迟 -1ms）
echo ""
echo "正在进行安装后自检（针对延迟 -1ms）..."
if ss -tln 2>/dev/null | grep -Eq ":${PORT}\\b"; then
    echo "✅ 本机已监听端口 ${PORT}:"
    ss -tlnp 2>/dev/null | grep -E ":${PORT}\\b" || ss -tln 2>/dev/null | grep -E ":${PORT}\\b"
else
    echo "❌ 未检测到端口 ${PORT} 监听 —— 客户端几乎必然显示 -1ms"
    journalctl -u xray.service -n 50 --no-pager || true
fi

# 9. 配置定时重启任务
echo "正在配置定时重启任务..."

cat > /etc/systemd/system/xray-restart.timer << 'TIMER'
[Unit]
Description=Daily Xray Service Restart Timer
Requires=xray-restart.service

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

cat > /etc/systemd/system/xray-restart.service << 'RESTARTSERVICE'
[Unit]
Description=Restart Xray Service
After=xray.service

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart xray.service
RESTARTSERVICE

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable xray-restart.timer 2>/dev/null && systemctl start xray-restart.timer 2>/dev/null && \
        echo "✅ 定时重启任务已配置（systemd timer，每日 04:00）" || \
        echo "⚠️  警告: systemd timer 配置失败，但 Xray 服务正常运行"
else
    echo "⚠️  警告: systemd 不可用，跳过定时重启配置"
fi

if command -v apt-get >/dev/null 2>&1 && ! command -v crontab >/dev/null 2>&1; then
    echo "正在尝试安装 cron 作为备选定时方案..."
    apt-get install -y cron 2>/dev/null || echo "⚠️  cron 安装失败，使用 systemd timer"
fi

# 10. 输出安装结果
echo ""
echo "正在获取公网 IP..."
CLEAR_IP=$(get_public_ip)
PBK_ENC=$(urlencode "$PUB_KEY")
SHARE_LINK="vless://${USER_UUID}@${CLEAR_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PBK_ENC}&sid=${SHORT_ID}&type=tcp#Debian-Reality-${PORT}"

cat > "$SHARE_FILE" << LINKEOF
地址 (Address): $CLEAR_IP
端口 (Port): $PORT
用户 ID (UUID): $USER_UUID
流控 (Flow): xtls-rprx-vision
传输安全 (Security): reality
SNI: $SNI
公钥 (PublicKey / pbk): $PUB_KEY
ShortID (sid): $SHORT_ID
Fingerprint (fp): chrome
网络 (Network): tcp

分享链接:
$SHARE_LINK
LINKEOF

cat << EOF
-------------------------------------------------------
✅ 安装成功！请妥善保存以下连接参数：
-------------------------------------------------------
地址 (Address): $CLEAR_IP
端口 (Port): $PORT
用户 ID (UUID): $USER_UUID
流控 (Flow): xtls-rprx-vision
传输安全 (Security): reality
SNI: $SNI（自动检测的最优选择）
公钥 (PublicKey): $PUB_KEY
ShortID: $SHORT_ID
Fingerprint: chrome
网络 (Network): tcp
-------------------------------------------------------
📎 一键分享链接（推荐直接导入，避免手填导致 -1ms）:
$SHARE_LINK

参数已保存: $SHARE_FILE
-------------------------------------------------------
🚨 客户端延迟一直是 -1ms 时，按这个顺序查（90% 是前 3 项）:
  1) 云厂商安全组 / 防火墙是否放行 TCP $PORT 入站
  2) LXD 宿主机是否 proxy device / 端口映射到容器 $PORT
     例: lxc config device add <实例名> xrayproxy proxy listen=tcp:0.0.0.0:$PORT connect=tcp:127.0.0.1:$PORT
  3) 客户端地址是否填【公网 IP】，不要填容器内网 IP（10.x/100.x）
  4) PublicKey 用上面输出（新版 x25519 的 Password 字段）；不要填 Hash32
  5) Flow=xtls-rprx-vision, fp=chrome, sid=$SHORT_ID, sni=$SNI, network=tcp
  6) 服务器时间误差 < 90 秒: timedatectl / chronyc tracking
  7) 本机诊断: bash xray-diagnostic.sh
  8) 日志: journalctl -u xray.service -n 80  与  tail -n 100 $XRAY_LOG
-------------------------------------------------------
🔒 安全提示:
   请不要在公共评论区贴出以上信息！
   • 配置文件位于: $XRAY_CONFIG
   • 服务文件位于: /etc/systemd/system/xray.service
   • 网络配置脚本: /usr/local/bin/setup-xray-network.sh
   • 定时任务已配置：systemd timer（每日 04:00 自动重启清理内存）

🌍 Debian LXD 环境兼容说明:
   • SNI 自动检测：检测延迟最低且可达的域名作为代理目标
   • MTU 已设置为 1380（解决长距离丢包）
   • 若 MTU 设置失败：此环境不支持修改（继续使用系统默认值）
   • BBR 自动检测：支持则启用，不支持则降级使用 cubic
   • 使用 systemd 管理服务和定时任务（替代 cron）
   • 已启用 chrony；容器内尝试放行端口，宿主机映射仍需确认

📋 故障排查:
   • 验证服务: systemctl status xray.service
   • 查看日志: journalctl -u xray.service -n 50
   • 文件日志: tail -n 50 /var/log/xray.log
   • 检查时间: timedatectl || date
   • 查看配置: cat /etc/xray/config.json
   • 检查内存: free -m
   • 手动重启: systemctl restart xray.service
   • 停止服务: systemctl stop xray.service
   • 启动服务: systemctl start xray.service
   • 查看定时任务: systemctl list-timers xray-restart.timer
   • 分享参数: cat $SHARE_FILE

🔧 更换 SNI（如需调整）:
   编辑配置文件，在 realitySettings 中修改：
   "dest": "新域名:443"
   "serverNames": ["新域名"]
   然后运行: systemctl restart xray.service
-------------------------------------------------------
EOF
