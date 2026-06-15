#!/bin/bash

# ====================================================
# Project: Debian LXD Xray Reality One-Click Script
# Platform: Debian trixie amd64 (20251224_0350)
# Features: Enhanced error handling, systemd integration, auto SNI detection, Debian compatibility
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

# SNI 候选列表（按优先级，可自行调整）
SNI_CANDIDATES=(
    "www.microsoft.com"
    "swdlp.apple.com"
    "www.sony.co.jp"
    "www.samsung.com"
    "www.shopee.sg"
    "www.bmw.com"
    "www.dyson.co.uk"
    "www.intel.com"
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

# 自动检测延迟最低的 SNI
detect_best_sni() {
    echo "正在检测延迟最低的 SNI..." >&2
    echo "候选 SNI 列表: ${SNI_CANDIDATES[*]}" >&2
    echo "" >&2

    local best_sni=""
    local best_latency=99999

    for sni in "${SNI_CANDIDATES[@]}"; do
        # 使用 curl 的 TLS 连接时间来测试延迟
        local latency=$(curl -w "%{time_connect}" -o /dev/null -s --max-time 5 "https://${sni}" 2>/dev/null || echo "9999")

        # 转换为毫秒（便于阅读）
        local latency_ms=$(echo "$latency * 1000" | bc 2>/dev/null || echo "9999000")

        echo "🔍 $sni: ${latency_ms}ms" >&2

        # 比较延迟
        if [ "$(echo "$latency < $best_latency" | bc -l)" = "1" ]; then
            best_latency=$latency
            best_sni=$sni
        fi
    done

    echo "" >&2
    if [ -n "$best_sni" ]; then
        echo "✅ 最优 SNI: $best_sni (延迟: $(echo "$best_latency * 1000" | bc 2>/dev/null || echo "$best_latency")ms)" >&2
        echo "$best_sni"
    else
        echo "⚠️  无法检测 SNI，使用默认值 www.google.com" >&2
        echo "www.google.com"
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
echo ""

# 1. 环境准备与依赖安装（Debian apt-get）
echo "正在安装基础依赖..."
run_cmd apt-get update
run_cmd apt-get install -y curl ca-certificates unzip jq bc

# 创建 Xray 用户和必要目录
if ! id "$XRAY_USER" >/dev/null 2>&1; then
    useradd -r -s /bin/false "$XRAY_USER"
fi

run_cmd mkdir -p "$XRAY_DIR" "$(dirname "$XRAY_BIN")"
run_cmd chown -R "$XRAY_USER:$XRAY_GROUP" "$XRAY_DIR"

# 2. 检测已有 Xray 核心，不存在则下载
if [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version > /dev/null 2>&1; then
    echo "✅ 检测到已安装的 Xray: $("$XRAY_BIN" version 2>&1 | head -1)"
    echo "   跳过下载，直接使用现有版本"
else
    echo "正在下载 Xray-core..."
    XRAY_ZIP=$(mktemp /tmp/xray-XXXXXX.zip)
    cleanup() { rm -f "$XRAY_ZIP"; }
    trap cleanup EXIT

    RETRY=0
    MAX_RETRIES=10
    while [ $RETRY -lt $MAX_RETRIES ]; do
        echo "尝试下载 ($((RETRY+1))/$MAX_RETRIES)..."
        CURL_ERR=$(mktemp /tmp/curl-err-XXXXXX)
        if curl -L --connect-timeout 15 --max-time 120 -o "$XRAY_ZIP" \
            "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" 2>"$CURL_ERR"; then
            if head -c 4 "$XRAY_ZIP" 2>/dev/null | od -A n -t x1 | tr -d ' \n' | grep -q '^504b0304'; then
                rm -f "$CURL_ERR"
                echo "✅ 下载成功"
                break
            fi
            echo "  下载内容不是有效 ZIP，重试中..."
        else
            CURL_EXIT=$?
            echo "  curl 失败 (exit $CURL_EXIT): $(tail -1 "$CURL_ERR" 2>/dev/null)"
        fi
        rm -f "$CURL_ERR"
        RETRY=$((RETRY + 1))
        if [ $RETRY -lt $MAX_RETRIES ]; then
            sleep 3
        fi
    done

    if [ $RETRY -eq $MAX_RETRIES ]; then
        echo "" >&2
        echo "❌ 自动下载失败（GitHub 可能无法访问）" >&2
        echo "请设置代理后重试: export https_proxy=http://代理地址:端口" >&2
        exit 1
    fi

    run_cmd unzip -o "$XRAY_ZIP" xray -d "$(dirname "$XRAY_BIN")"
    run_cmd chmod +x "$XRAY_BIN"
    run_cmd chown "$XRAY_USER:$XRAY_GROUP" "$XRAY_BIN"
fi

# 验证 Xray 二进制文件可执行性
if ! "$XRAY_BIN" version > /dev/null 2>&1; then
    error_exit "Xray 二进制文件损坏或架构不兼容"
fi

# 2.5 自动检测最优 SNI（新增功能）
echo ""
SNI=$(detect_best_sni)
DEST_SITE="${SNI}:443"

# 3. 动态生成身份凭证（安全提取）
echo ""
echo "正在生成加密密钥..."
USER_UUID=$("$XRAY_BIN" uuid)

KEYS_OUTPUT=$("$XRAY_BIN" x25519)

# 调试输出
echo "调试信息 - Xray x25519 输出:" >&2
echo "$KEYS_OUTPUT" >&2

# 提取密钥（适配不同 Xray 版本的输出格式）
# 新版格式: PrivateKey: xxx  /  Password (PublicKey): xxx
# 旧版格式: PrivateKey: xxx  /  PublicKey: xxx
PRIV_KEY=$(echo "$KEYS_OUTPUT" | sed -n 's/.*PrivateKey:[[:space:]]*\([^[:space:]]*\).*/\1/p')
PUB_KEY=$(echo "$KEYS_OUTPUT" | sed -n 's/.*Password.*:[[:space:]]*\([^[:space:]]*\).*/\1/p')

# 兜底：如果 Password 行没匹配到，尝试 PublicKey
if [ -z "$PUB_KEY" ]; then
    PUB_KEY=$(echo "$KEYS_OUTPUT" | sed -n 's/.*PublicKey:[[:space:]]*\([^[:space:]]*\).*/\1/p')
fi

# 验证密钥是否成功提取
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

echo "✅ 密钥生成成功"

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
if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
    error_exit "配置文件 JSON 格式错误"
fi
echo "✅ 配置文件 JSON 格式验证通过"

# 设置文件权限
run_cmd chmod 640 "$XRAY_CONFIG"
run_cmd chown "$XRAY_USER:$XRAY_GROUP" "$XRAY_CONFIG"

# 5. 系统网络优化（Debian 兼容）
echo "正在进行网络性能调优..."

# 尝试启用 BBR（可能不支持，失败也继续）
{
    if [ -f /etc/sysctl.conf ]; then
        grep -v '^net\.core\.default_qdisc=' /etc/sysctl.conf | grep -v '^net\.ipv4\.tcp_congestion_control=' || true
    fi
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

# 9. 配置定时重启任务（使用 systemd timer 替代 cron，兼容 LXD 环境）
echo "正在配置定时重启任务..."

# 创建 systemd timer 单位（比 cron 更适合容器环境）
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

# 尝试启用 systemd timer
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable xray-restart.timer 2>/dev/null && systemctl start xray-restart.timer 2>/dev/null && \
        echo "✅ 定时重启任务已配置（systemd timer，每日 04:00）" || \
        echo "⚠️  警告: systemd timer 配置失败，但 Xray 服务正常运行"
else
    echo "⚠️  警告: systemd 不可用，跳过定时重启配置"
fi

# 可选：如果环境支持 cron，也安装它作为备选
if command -v apt-get >/dev/null 2>&1 && ! command -v crontab >/dev/null 2>&1; then
    echo "正在尝试安装 cron 作为备选定时方案..."
    apt-get install -y cron 2>/dev/null || echo "⚠️  cron 安装失败，使用 systemd timer"
fi

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
SNI: $SNI（自动检测的最优选择）
公钥 (PublicKey): $PUB_KEY
ShortID: $SHORT_ID
Fingerprint: chrome
-------------------------------------------------------
🔒 安全提示:
   请不要在公共评论区贴出以上信息！
   • 配置文件位于: $XRAY_CONFIG
   • 服务文件位于: /etc/systemd/system/xray.service
   • 网络配置脚本: /usr/local/bin/setup-xray-network.sh
   • 定时任务已配置：systemd timer（每日 04:00 自动重启清理内存）

🌍 Debian LXD 环境兼容说明:
   • SNI 自动检测：检测延迟最低的域名作为代理目标
   • MTU 已设置为 1380（解决长距离丢包）
   • 若 MTU 设置失败：此环境不支持修改（继续使用系统默认值）
   • BBR 自动检测：支持则启用，不支持则降级使用 cubic
   • 使用 systemd 管理服务和定时任务（替代 cron）
   • 所有容错机制均已启用，确保低权限环境下可用

📋 故障排查:
   • 验证服务: systemctl status xray.service
   • 查看日志: journalctl -u xray.service -n 50
   • 查看配置: cat /etc/xray/config.json
   • 检查内存: free -m
   • 手动重启: systemctl restart xray.service
   • 停止服务: systemctl stop xray.service
   • 启动服务: systemctl start xray.service
   • 查看定时任务: systemctl list-timers xray-restart.timer

🔧 更换 SNI（如需调整）:
   编辑配置文件，在 realitySettings 中修改：
   "dest": "新域名:443"
   "serverNames": ["新域名"]
   然后运行: systemctl restart xray.service
-------------------------------------------------------
EOF
