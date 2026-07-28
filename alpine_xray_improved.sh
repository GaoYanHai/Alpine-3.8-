#!/bin/sh

# ====================================================
# Project: Alpine LXC Xray Reality One-Click Script
# Optimization: MTU, OpenRC, Low RAM (512M), NAT Compatible
# Features: Enhanced error handling, firewall open, connectivity checks
# ====================================================

set -e  # 错误时立即退出，避免继续执行
set -u  # 未定义变量时报错

# 0. 自定义基础变量
PORT=52300
SHORT_ID="0123456789abcdef"
DEST_SITE=""
SNI=""
# 多地域 Reality 伪装目标候选（美国/欧洲/印度/俄罗斯/亚太）
# 每行: domain|region
SNI_CANDIDATES="
www.microsoft.com|US
www.apple.com|US
www.cloudflare.com|US
www.amazon.com|US
www.nvidia.com|US
www.intel.com|US
www.adobe.com|US
www.costco.com|US
www.ikea.com|EU
www.sap.com|EU
www.nokia.com|EU
www.ericsson.com|EU
www.bmw.com|EU
www.dyson.co.uk|EU
www.sony.co.jp|EU
www.volkswagen.com|EU
www.infosys.com|IN
www.tcs.com|IN
www.airtel.in|IN
www.flipkart.com|IN
www.india.gov.in|IN
www.yandex.ru|RU
www.vk.com|RU
www.mail.ru|RU
www.sberbank.ru|RU
www.wildberries.ru|RU
www.samsung.com|APAC
www.shopee.sg|APAC
www.toyota.com|APAC
www.singaporeair.com|APAC
"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/etc/xray/config.json"
XRAY_DIR="/etc/xray"
XRAY_LOG="/var/log/xray.log"
SHARE_FILE="/etc/xray/client-link.txt"

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

# 从 x25519 输出中提取密钥（兼容 BusyBox / 多版本 Xray 输出）
# 支持:
#   PrivateKey: / PublicKey:
#   PrivateKey: / Password:            (Password = Reality 客户端公钥)
#   Password (PublicKey):
#   Private key: / Public key:
extract_key_value() {
    label="$1"
    text="$2"
    echo "$text" | sed -n "s/.*${label}:[[:space:]]*\\([^[:space:]]*\\).*/\\1/p" | head -n 1
}

extract_reality_keys() {
    text="$1"
    priv=""
    pub=""

    priv=$(extract_key_value "PrivateKey" "$text")
    [ -z "$priv" ] && priv=$(extract_key_value "Private key" "$text")
    [ -z "$priv" ] && priv=$(extract_key_value "private key" "$text")
    [ -z "$priv" ] && priv=$(extract_key_value "privateKey" "$text")

    # 新版 Xray: Password 字段就是 Reality 客户端要用的 PublicKey
    pub=$(extract_key_value "Password" "$text")
    if [ -z "$pub" ]; then
        pub=$(echo "$text" | sed -n 's/.*Password[[:space:]]*(PublicKey):[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)
    fi
    [ -z "$pub" ] && pub=$(extract_key_value "PublicKey" "$text")
    [ -z "$pub" ] && pub=$(extract_key_value "Public key" "$text")
    [ -z "$pub" ] && pub=$(extract_key_value "public key" "$text")
    [ -z "$pub" ] && pub=$(extract_key_value "publicKey" "$text")

    # 绝不能把 Hash32 当成公钥
    if [ -n "$pub" ] && echo "$text" | grep -q "Hash32:[[:space:]]*$pub"; then
        pub=""
    fi

    echo "$priv"
    echo "$pub"
}

validate_b64_key() {
    # Reality x25519 key 一般是 43~44 字符的 URL-safe base64
    key="$1"
    name="$2"
    len=$(printf %s "$key" | wc -c | tr -d ' ')
    if [ "$len" -lt 40 ] || [ "$len" -gt 64 ]; then
        error_exit "$name 长度异常($len)，原始 x25519 输出可能解析失败"
    fi
    case "$key" in
        *[!A-Za-z0-9+/=_-]*)
            error_exit "$name 含非法字符，解析失败: $key"
            ;;
    esac
}

get_public_ip() {
    ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ifconfig.me/ip" \
        "https://ipv4.icanhazip.com" \
        "https://api.ip.sb/ip"
    do
        ip=$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '\r\n' | head -n 1 || true)
        # 粗略校验 IPv4
        echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && break
        ip=""
    done
    if [ -z "$ip" ]; then
        ip=$(curl -fsS --connect-timeout 5 --max-time 8 "https://ifconfig.me" 2>/dev/null | tr -d '\r\n' | head -n 1 || true)
    fi
    if [ -z "$ip" ]; then
        echo "获取失败（NAT 环境请填宿主机公网 IP）"
    else
        echo "$ip"
    fi
}

open_firewall_port() {
    port="$1"
    echo "正在尝试开放防火墙 TCP $port ..."

    opened=0
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
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && opened=1 && echo "✅ iptables 已放行 ${port}/tcp" || true
        else
            opened=1
            echo "✅ iptables 已存在 ${port}/tcp 放行规则"
        fi
    fi

    if command -v nft >/dev/null 2>&1; then
        nft list ruleset 2>/dev/null | grep -q "dport ${port}" && opened=1 || true
    fi

    if [ "$opened" -eq 0 ]; then
        echo "⚠️  容器内未检测到可配置防火墙（对 LXC 通常正常）"
    fi

    echo "⚠️  若仍是 -1ms：请同时检查【云安全组】和【宿主机 LXC/LXD 端口映射】是否放行 TCP $port"
}

urlencode() {
    # 最小实现：对 Reality 分享链接中需要的字符做编码
    printf %s "$1" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g'
}



# ------------------------------------------------------------
# Reality 伪装目标（SNI/dest）严格校验 - BusyBox/POSIX sh
# ------------------------------------------------------------
probe_sni_target() {
    sni="$1"
    region="${2:-unknown}"
    score=0
    tls13=0
    h2=0
    connect_time="9999"
    http_code="000"
    curl_out=""

    if command -v nslookup >/dev/null 2>&1; then
        if ! nslookup "$sni" >/dev/null 2>&1; then
            echo "FAIL dns region=$region sni=$sni" >&2
            return 1
        fi
        score=$((score + 10))
    elif command -v getent >/dev/null 2>&1; then
        if ! getent ahosts "$sni" >/dev/null 2>&1; then
            echo "FAIL dns region=$region sni=$sni" >&2
            return 1
        fi
        score=$((score + 10))
    else
        score=$((score + 5))
    fi

    if command -v nc >/dev/null 2>&1; then
        if ! nc -z -w 3 "$sni" 443 >/dev/null 2>&1; then
            echo "FAIL tcp443 region=$region sni=$sni" >&2
            return 1
        fi
        score=$((score + 20))
    fi

    curl_out=$(curl -sS -o /dev/null -w "%{http_code} %{time_connect}" \
        --connect-timeout 3 --max-time 6 -I "https://${sni}" 2>/dev/null || echo "000 9999")
    http_code=$(echo "$curl_out" | awk '{print $1}')
    connect_time=$(echo "$curl_out" | awk '{print $2}')
    if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
        echo "FAIL https region=$region sni=$sni code=000" >&2
        return 1
    fi
    score=$((score + 30))

    if curl -sS -o /dev/null --connect-timeout 3 --max-time 6 --tlsv1.3 -I "https://${sni}" 2>/dev/null; then
        tls13=1
        score=$((score + 30))
    fi
    if curl -sS -o /dev/null --connect-timeout 3 --max-time 6 --http2 -I "https://${sni}" 2>/dev/null; then
        h2=1
        score=$((score + 15))
    fi

    if command -v openssl >/dev/null 2>&1; then
        if echo | openssl s_client -tls1_3 -connect "${sni}:443" -servername "$sni" >/dev/null 2>&1; then
            score=$((score + 15))
            tls13=1
        fi
    fi
    if [ "$tls13" -eq 0 ]; then
        echo "WARN weak-tls region=$region sni=$sni (no TLS1.3 detected, deprioritized)" >&2
    fi

    ms=$(awk -v t="$connect_time" 'BEGIN{printf "%d", (t+0)*1000}' 2>/dev/null || echo 9999)
    echo "OK region=$region sni=$sni code=$http_code latency_ms=$ms tls13=$tls13 h2=$h2 score=$score" >&2
    echo "${score}|${connect_time}|${sni}|${region}|${tls13}|${h2}|${http_code}"
    return 0
}

sni_region_of() {
    case "$1" in
        www.microsoft.com|www.apple.com|www.cloudflare.com|www.amazon.com|www.nvidia.com|www.intel.com|www.adobe.com|www.costco.com) echo US ;;
        www.ikea.com|www.sap.com|www.nokia.com|www.ericsson.com|www.bmw.com|www.dyson.co.uk|www.sony.co.jp|www.volkswagen.com) echo EU ;;
        www.infosys.com|www.tcs.com|www.airtel.in|www.flipkart.com|www.india.gov.in) echo IN ;;
        www.yandex.ru|www.vk.com|www.mail.ru|www.sberbank.ru|www.wildberries.ru) echo RU ;;
        www.samsung.com|www.shopee.sg|www.toyota.com|www.singaporeair.com) echo APAC ;;
        *) echo OTHER ;;
    esac
}

detect_best_sni() {
    echo "正在严格检测多地域伪装目标（SNI/dest）..." >&2
    echo "规则: DNS + TCP443 + HTTPS 必须通过；TLS1.3/H2 高分优先；再比延迟" >&2
    echo "区域覆盖: US / EU / IN / RU / APAC" >&2
    echo "" >&2

    result_file="/tmp/sni-detect-$$.txt"
    : > "$result_file"
    ok_count=0
    fail_count=0

    # 用 for 遍历，避免管道子 shell 丢结果；结果落临时文件
    OLDIFS=$IFS
    IFS='
'
    for line in $SNI_CANDIDATES; do
        IFS=$OLDIFS
        sni=$(echo "$line" | cut -d'|' -f1 | tr -d ' \r')
        region=$(echo "$line" | cut -d'|' -f2 | tr -d ' \r')
        [ -z "$sni" ] && continue
        [ -z "$region" ] && region=$(sni_region_of "$sni")
        if out=$(probe_sni_target "$sni" "$region"); then
            echo "$out" >> "$result_file"
            ok_count=$((ok_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
        IFS='
'
    done
    IFS=$OLDIFS

    echo "" >&2
    echo "检测汇总: 通过 $ok_count / 失败 $fail_count" >&2

    if [ ! -s "$result_file" ]; then
        echo "❌ 所有候选伪装目标均未通过校验" >&2
        echo "   无可用 SNI/dest 时 Reality 会握手失败，客户端表现为延迟 -1ms" >&2
        rm -f "$result_file"
        return 1
    fi

    best=$(awk -F'|' '
        BEGIN { best_score=-1; best_lat=99999; best_sni=""; best_region=""; best_tls=""; best_h2=""; }
        {
          score=$1+0; lat=$2+0; sni=$3; region=$4; tls=$5; h2=$6;
          if (score>best_score || (score==best_score && lat<best_lat)) {
            best_score=score; best_lat=lat; best_sni=sni; best_region=region; best_tls=tls; best_h2=h2;
          }
        }
        END {
          if (best_sni != "") printf "%s %d %s %s %s %s\n", best_sni, best_score, best_lat, best_region, best_tls, best_h2
        }
    ' "$result_file")
    rm -f "$result_file"

    if [ -z "$best" ]; then
        echo "❌ 未能选定伪装目标" >&2
        return 1
    fi

    best_sni=$(echo "$best" | awk '{print $1}')
    best_score=$(echo "$best" | awk '{print $2}')
    best_lat=$(echo "$best" | awk '{print $3}')
    best_region=$(echo "$best" | awk '{print $4}')
    best_tls=$(echo "$best" | awk '{print $5}')
    best_h2=$(echo "$best" | awk '{print $6}')
    ms=$(awk -v t="$best_lat" 'BEGIN{printf "%.0f", (t+0)*1000}')
    echo "✅ 选定伪装目标: $best_sni (region=$best_region score=$best_score tls13=$best_tls h2=$best_h2 latency≈${ms}ms)" >&2
    echo "$best_sni"
    return 0
}

assert_sni_usable() {
    sni="$1"
    region=$(sni_region_of "$sni")
    echo "正在对选定 SNI 做最终校验: $sni ($region)" >&2
    if ! result=$(probe_sni_target "$sni" "$region"); then
        error_exit "选定伪装目标 $sni 最终校验失败（会导致客户端延迟 -1ms）"
    fi
    tls13=$(echo "$result" | cut -d'|' -f5)
    if [ "$tls13" != "1" ]; then
        echo "⚠️  警告: $sni 未探测到 TLS1.3，Reality 兼容性可能较差；建议换候选站" >&2
    fi
    echo "✅ 最终校验通过: $sni" >&2
}


# 1. 环境准备与依赖安装
echo "正在安装基础依赖..."
run_cmd apk update
run_cmd apk add curl gcompat ca-certificates unzip openrc iproute2 chrony openssl bind-tools

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
echo "Xray 版本: $("$XRAY_BIN" version 2>/dev/null | head -n 1)"

# 3. 动态生成身份凭证（安全提取）
echo "正在生成加密密钥..."
USER_UUID=$("$XRAY_BIN" uuid)

KEYS_OUTPUT=$("$XRAY_BIN" x25519)
echo "调试信息 - Xray x25519 输出:" >&2
echo "$KEYS_OUTPUT" >&2

KEY_LINES=$(extract_reality_keys "$KEYS_OUTPUT")
PRIV_KEY=$(echo "$KEY_LINES" | sed -n '1p')
PUB_KEY=$(echo "$KEY_LINES" | sed -n '2p')

# 验证密钥是否成功提取
[ -z "$PRIV_KEY" ] && error_exit "无法提取私钥，原始输出: $KEYS_OUTPUT"
[ -z "$PUB_KEY" ] && error_exit "无法提取公钥，原始输出: $KEYS_OUTPUT"
[ -z "$USER_UUID" ] && error_exit "无法生成 UUID"
validate_b64_key "$PRIV_KEY" "PrivateKey"
validate_b64_key "$PUB_KEY" "PublicKey"
if [ "$PRIV_KEY" = "$PUB_KEY" ]; then
    error_exit "私钥与公钥相同，密钥解析错误"
fi

echo "✅ 密钥生成成功"
echo "  PrivateKey 长度: $(printf %s "$PRIV_KEY" | wc -c | tr -d ' ')"
echo "  PublicKey  长度: $(printf %s "$PUB_KEY" | wc -c | tr -d ' ')"
echo "  说明: 新版 Xray 的 Password 字段 = 客户端 PublicKey（已自动映射）"

# 3.5 多地域伪装目标严格检测（避免 SNI 不可达导致客户端 -1ms）
echo "正在选择并校验 Reality 伪装目标..."
if ! SNI=$(detect_best_sni); then
    error_exit "没有可用的 Reality 伪装目标（SNI/dest）。请检查 VPS 出站 443/DNS 后重试"
fi
assert_sni_usable "$SNI"
DEST_SITE="${SNI}:443"
echo "将使用: SNI=$SNI  DEST=$DEST_SITE  region=$(sni_region_of "$SNI")"

# 4. 生成 Xray 配置文件
# 说明：
# - 默认监听 0.0.0.0，避免某些 LXC/NAT 环境只绑 loopback
# - 日志改为 warning + 文件，便于排查“端口通但连不上 / 延迟 -1ms”
# - shortIds 同时保留空值和固定值，兼容部分客户端默认空 shortId
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

# 配置测试
if ! "$XRAY_BIN" run -test -c "$XRAY_CONFIG" >/tmp/xray-test.out 2>&1; then
    echo "❌ Xray 配置测试失败:" >&2
    cat /tmp/xray-test.out >&2 || true
    error_exit "Xray 配置测试失败"
fi
echo "✅ Xray 配置测试通过"

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

# 5.5 开放端口（容器内防火墙 + 提示宿主机/安全组）
open_firewall_port "$PORT"

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

# 6.5 安装后连通性自检（专门针对客户端延迟 -1ms）
echo ""
echo "正在进行安装后自检（针对延迟 -1ms）..."
if command -v ss >/dev/null 2>&1; then
    if ss -tln 2>/dev/null | grep -Eq ":${PORT}\\b"; then
        echo "✅ 本机已监听 0.0.0.0:${PORT}（或 *: ${PORT}）"
        ss -tln 2>/dev/null | grep -E ":${PORT}\\b" || true
    else
        echo "❌ 未检测到端口 ${PORT} 监听 —— 客户端必现 -1ms"
        echo "   请查看: tail -n 100 $XRAY_LOG"
    fi
elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -E ":${PORT}\\b" && echo "✅ 端口 ${PORT} 已监听" || echo "❌ 端口 ${PORT} 未监听"
else
    echo "⚠️  无 ss/netstat，跳过监听检查"
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
CLEAR_IP=$(get_public_ip)

# 生成可导入的分享链接，减少手工填错（这是 -1ms 的高发原因）
PBK_ENC=$(urlencode "$PUB_KEY")
SHARE_LINK="vless://${USER_UUID}@${CLEAR_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PBK_ENC}&sid=${SHORT_ID}&type=tcp#Alpine-Reality-${PORT}"
cat > "$SHARE_FILE" << LINKEOF
地址 (Address): $CLEAR_IP
端口 (Port): $PORT
用户 ID (UUID): $USER_UUID
流控 (Flow): xtls-rprx-vision
传输安全 (Security): reality
SNI: $SNI（多地域严格校验后的最优选择）
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
SNI: $SNI
公钥 (PublicKey): $PUB_KEY
ShortID: $SHORT_ID
Fingerprint: chrome
网络 (Network): tcp
-------------------------------------------------------
📎 一键分享链接（推荐直接导入客户端，避免手填错误）:
$SHARE_LINK

参数已保存: $SHARE_FILE
-------------------------------------------------------
🚨 客户端延迟一直是 -1ms 时，按这个顺序查（90% 是前 3 项）:
  1) 云厂商安全组 / 防火墙是否放行 TCP $PORT 入站
  2) LXC 宿主机是否做了端口映射/转发到容器 $PORT
  3) 客户端地址是否填【公网 IP】而不是容器内网 IP
  4) PublicKey 必须用上面输出（来自新版 x25519 的 Password 字段）
  5) Flow=xtls-rprx-vision, fp=chrome, sid=$SHORT_ID, sni=$SNI
  6) 服务器时间误差 < 90 秒: date / chronyc tracking
  7) 本机诊断: sh xray-diagnostic.sh
  8) 日志: tail -n 100 $XRAY_LOG
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
  • 容器内已尝试放行端口；宿主机映射与云安全组仍需你确认
-------------------------------------------------------
EOF
