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
ENABLE_SOCKS="${ENABLE_SOCKS:-0}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
SOCKS_INBOUND_JSON=""
SOCKS_INFO_TEXT=""
SHORT_ID="0123456789abcdef"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/etc/xray/config.json"
XRAY_DIR="/etc/xray"
XRAY_USER="xray"
XRAY_GROUP="xray"
XRAY_LOG="/var/log/xray.log"
SHARE_FILE="/etc/xray/client-link.txt"

# SNI 候选列表（多地域：美国/欧洲/印度/俄罗斯/亚太）
# REALITY: 安装期强制校验 DNS/TCP443/HTTPS/TLS1.3，失败则中止
SNI_CANDIDATES=(
    # 美国 / 北美
    "www.microsoft.com"
    "www.apple.com"
    "www.cloudflare.com"
    "www.amazon.com"
    "www.nvidia.com"
    "www.intel.com"
    "www.adobe.com"
    "www.costco.com"
    # 欧洲
    "www.ikea.com"
    "www.sap.com"
    "www.nokia.com"
    "www.ericsson.com"
    "www.bmw.com"
    "www.dyson.co.uk"
    "www.sony.co.jp"
    "www.volkswagen.com"
    # 印度
    "www.infosys.com"
    "www.tcs.com"
    "www.airtel.in"
    "www.flipkart.com"
    "www.india.gov.in"
    # 俄罗斯
    "www.yandex.ru"
    "www.vk.com"
    "www.mail.ru"
    "www.sberbank.ru"
    "www.wildberries.ru"
    # 亚太兜底
    "www.samsung.com"
    "www.shopee.sg"
    "www.toyota.com"
    "www.singaporeair.com"
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
        ip=$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '\n' | head -n 1 || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
        ip=""
    done
    ip=$(curl -fsS --connect-timeout 5 --max-time 8 "https://ifconfig.me" 2>/dev/null | tr -d '\n' | head -n 1 || true)
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



# ------------------------------------------------------------
# Reality 伪装目标（SNI/dest）严格校验
# 必须: DNS + TCP443 + HTTPS/TLS 可建连
# 加分: TLS1.3、HTTP/2、低延迟
# 全部失败则安装中止，避免客户端 -1ms
# ------------------------------------------------------------
probe_sni_target() {
    local sni="$1"
    local region="${2:-unknown}"
    local score=0
    local tls13=0
    local h2=0
    local connect_time="9999"
    local http_code="000"
    local curl_out=""

    # DNS
    if command -v getent >/dev/null 2>&1; then
        if ! getent ahosts "$sni" >/dev/null 2>&1; then
            echo "FAIL dns region=$region sni=$sni" >&2
            return 1
        fi
        score=$((score + 10))
    elif command -v nslookup >/dev/null 2>&1; then
        if ! nslookup "$sni" >/dev/null 2>&1; then
            echo "FAIL dns region=$region sni=$sni" >&2
            return 1
        fi
        score=$((score + 10))
    else
        score=$((score + 5))
    fi

    # TCP 443（快速失败）
    if command -v nc >/dev/null 2>&1; then
        if ! nc -z -w 3 "$sni" 443 >/dev/null 2>&1; then
            echo "FAIL tcp443 region=$region sni=$sni" >&2
            return 1
        fi
        score=$((score + 20))
    elif command -v timeout >/dev/null 2>&1; then
        if ! timeout 3 bash -c "echo >/dev/tcp/${sni}/443" >/dev/null 2>&1; then
            echo "FAIL tcp443 region=$region sni=$sni" >&2
            return 1
        fi
        score=$((score + 20))
    fi

    # 一次 curl 同时取 http_code + time_connect（允许 3xx/403）
    curl_out=$(curl -sS -o /dev/null -w "%{http_code} %{time_connect}" \
        --connect-timeout 3 --max-time 6 -I "https://${sni}" 2>/dev/null || echo "000 9999")
    http_code=$(echo "$curl_out" | awk '{print $1}')
    connect_time=$(echo "$curl_out" | awk '{print $2}')
    if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
        echo "FAIL https region=$region sni=$sni code=000" >&2
        return 1
    fi
    score=$((score + 30))

    # TLS1.3（Reality 强烈建议）
    if curl -sS -o /dev/null --connect-timeout 3 --max-time 6 --tlsv1.3 -I "https://${sni}" 2>/dev/null; then
        tls13=1
        score=$((score + 30))
    fi

    # HTTP/2
    if curl -sS -o /dev/null --connect-timeout 3 --max-time 6 --http2 -I "https://${sni}" 2>/dev/null; then
        h2=1
        score=$((score + 15))
    fi

    # openssl TLS1.3 复检（有则加分；明确失败且 curl 也没过 tls13 则淘汰）
    if command -v openssl >/dev/null 2>&1; then
        if echo | timeout 5 openssl s_client -tls1_3 -connect "${sni}:443" -servername "$sni" >/dev/null 2>&1; then
            score=$((score + 15))
            tls13=1
        fi
    fi
    # TLS1.3 不作为单站硬淘汰条件（避免旧 curl/openssl 误杀），但无 TLS1.3 会大幅降低评分
    if [ "$tls13" -eq 0 ]; then
        echo "WARN weak-tls region=$region sni=$sni (no TLS1.3 detected, deprioritized)" >&2
    fi

    local ms
    ms=$(awk -v t="$connect_time" 'BEGIN{printf "%d", (t+0)*1000}')
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

    local best_sni=""
    local best_score=-1
    local best_latency=99999
    local best_meta=""
    local sni region result score latency tls13 h2 code
    local ok_count=0
    local fail_count=0
    local region_hits=""

    for sni in "${SNI_CANDIDATES[@]}"; do
        [ -z "$sni" ] && continue
        region=$(sni_region_of "$sni")

        if result=$(probe_sni_target "$sni" "$region"); then
            ok_count=$((ok_count + 1))
            region_hits="${region_hits}${region} "
            score=$(echo "$result" | cut -d'|' -f1)
            latency=$(echo "$result" | cut -d'|' -f2)
            tls13=$(echo "$result" | cut -d'|' -f5)
            h2=$(echo "$result" | cut -d'|' -f6)
            code=$(echo "$result" | cut -d'|' -f7)

            if [ "$score" -gt "$best_score" ] || { [ "$score" -eq "$best_score" ] && awk -v a="$latency" -v b="$best_latency" 'BEGIN{exit !(a<b)}'; }; then
                best_score=$score
                best_latency=$latency
                best_sni=$sni
                best_meta="region=$region tls13=$tls13 h2=$h2 code=$code score=$score"
            fi
        else
            fail_count=$((fail_count + 1))
        fi
    done

    echo "" >&2
    echo "检测汇总: 通过 $ok_count / 失败 $fail_count" >&2
    if [ -n "$region_hits" ]; then
        echo "可用区域命中: $region_hits" >&2
    fi

    if [ -n "$best_sni" ]; then
        local ms
        ms=$(awk -v t="$best_latency" 'BEGIN{printf "%.0f", (t+0)*1000}')
        echo "✅ 选定伪装目标: $best_sni  (${best_meta}, latency≈${ms}ms)" >&2
        echo "$best_sni"
        return 0
    fi

    echo "❌ 所有候选伪装目标均未通过校验" >&2
    echo "   无可用 SNI/dest 时 Reality 会握手失败，客户端表现为延迟 -1ms" >&2
    echo "   请检查: VPS 出站 443、DNS、是否屏蔽国外站点" >&2
    return 1
}

assert_sni_usable() {
    local sni="$1"
    local region result tls13
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



# ------------------------------------------------------------
# 可选 SOCKS5 入站（默认关闭）
# 交互: 询问是否启用；启用后再问端口/用户名/密码
# 非交互: ENABLE_SOCKS=1 SOCKS_PORT=10808 SOCKS_USER=xx SOCKS_PASS=yy
# ------------------------------------------------------------
json_escape() {
    # Robust JSON string escape for SOCKS user/pass.
    # Prefer python3/jq; never use fragile shell case/sed backslash branches.
    if command -v python3 >/dev/null 2>&1; then
        SOCKS_JSON_ESC_IN="$1" python3 -c 'import json,os,sys; sys.stdout.write(json.dumps(os.environ.get("SOCKS_JSON_ESC_IN",""))[1:-1])'
        return $?
    fi
    if command -v python >/dev/null 2>&1; then
        SOCKS_JSON_ESC_IN="$1" python -c 'import json,os,sys; sys.stdout.write(json.dumps(os.environ.get("SOCKS_JSON_ESC_IN",""))[1:-1])'
        return $?
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -rn --arg s "$1" '$s|tojson' | awk 'BEGIN{ORS=""} {print substr($0,2,length($0)-2)}'
        return $?
    fi
    if printf %s "$1" | grep -Eq '^[A-Za-z0-9._@+-]+$'; then
        printf %s "$1"
        return 0
    fi
    echo "json_escape: need python3 or jq to escape special chars; install python3" >&2
    return 1
}




is_truthy() {
    case "$(printf %s "$1" | tr "A-Z" "a-z")" in
        1|y|yes|true|on) return 0 ;;
        *) return 1 ;;
    esac
}

prompt_input() {
    prompt_msg="$1"
    default_val="${2-}"
    ans=""
    if [ -r /dev/tty ]; then
        if [ -n "$default_val" ]; then
            printf "%s [%s]: " "$prompt_msg" "$default_val" > /dev/tty
        else
            printf "%s: " "$prompt_msg" > /dev/tty
        fi
        IFS= read -r ans < /dev/tty || true
    fi
    if [ -z "$ans" ]; then
        ans="$default_val"
    fi
    printf %s "$ans"
}

validate_port() {
    p="$1"
    echo "$p" | grep -Eq '^[0-9]+$' || return 1
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}


# SOCKS5 协议本身几乎不限制账号格式；这里做“安全可用性”校验，避免弱口令公网裸奔
# 用户名: 1-64，字母数字._-@
# 密码: 8-128；至少包含字母+数字；允许大小写/符号；禁止与用户名相同、禁止常见弱口令
validate_socks_username() {
    u="$1"
    len=$(printf %s "$u" | wc -c | tr -d ' ')
    if [ "$len" -lt 1 ] || [ "$len" -gt 64 ]; then
        echo "用户名长度须为 1-64 个字符（当前: $len）" >&2
        return 1
    fi
    # 禁止空白和控制字符
    if printf %s "$u" | grep -q '[[:space:]]'; then
        echo "用户名不能包含空格/空白字符" >&2
        return 1
    fi
    # 建议字符集：常见客户端兼容
    if ! printf %s "$u" | grep -Eq '^[A-Za-z0-9._@+-]+$'; then
        echo "用户名仅允许字母/数字/._@+-" >&2
        return 1
    fi
    return 0
}

validate_socks_password() {
    p="$1"
    u="${2-}"
    len=$(printf %s "$p" | wc -c | tr -d ' ')
    if [ "$len" -lt 8 ] || [ "$len" -gt 128 ]; then
        echo "密码长度须为 8-128 个字符（当前: $len）" >&2
        return 1
    fi
    if printf %s "$p" | grep -q '[[:space:]]'; then
        echo "密码不能包含空格/空白字符" >&2
        return 1
    fi
    # 至少同时有字母和数字（不强制大小写混合，避免过于苛刻；但会提示）
    has_alpha=0
    has_digit=0
    has_upper=0
    has_lower=0
    has_special=0
    printf %s "$p" | grep -Eq '[A-Za-z]' && has_alpha=1
    printf %s "$p" | grep -Eq '[0-9]' && has_digit=1
    printf %s "$p" | grep -Eq '[A-Z]' && has_upper=1
    printf %s "$p" | grep -Eq '[a-z]' && has_lower=1
    printf %s "$p" | grep -Eq '[^A-Za-z0-9]' && has_special=1

    if [ "$has_alpha" -ne 1 ] || [ "$has_digit" -ne 1 ]; then
        echo "密码须同时包含字母和数字" >&2
        return 1
    fi
    if [ -n "$u" ] && [ "$p" = "$u" ]; then
        echo "密码不能与用户名相同" >&2
        return 1
    fi
    # 常见弱口令黑名单（小写比较）
    pl=$(printf %s "$p" | tr 'A-Z' 'a-z')
    case "$pl" in
        12345678|password|password1|qwerty123|admin123|socks123|abcdefg1|11111111|00000000|deuser0001|user1234|passw0rd)
            echo "密码过于常见/弱，请更换" >&2
            return 1
            ;;
    esac
    # 连续相同字符过多
    if printf %s "$p" | grep -Eq '(.)\1\1\1\1'; then
        echo "密码包含过多连续重复字符" >&2
        return 1
    fi

    # 非强制：给出强度提示
    score=$((has_alpha + has_digit + has_upper + has_lower + has_special))
    if [ "$len" -ge 12 ]; then score=$((score + 1)); fi
    if [ "$score" -lt 4 ]; then
        echo "提示: 建议密码含大小写+数字+符号，且不少于 12 位（当前可过校验，但偏弱）" >&2
    fi
    return 0
}

prompt_socks_credentials() {
    # 交互循环直到合法；非交互则一次失败即退出
    interactive=0
    [ -r /dev/tty ] && interactive=1

    tries=0
    while :; do
        tries=$((tries + 1))
        if [ "$interactive" -eq 1 ]; then
            if [ -z "$SOCKS_USER" ] || [ "$tries" -gt 1 ]; then
                SOCKS_USER=$(prompt_input "SOCKS5 用户名（1-64，字母数字._@+-）" "${SOCKS_USER}")
            fi
            if [ -z "$SOCKS_PASS" ] || [ "$tries" -gt 1 ]; then
                SOCKS_PASS=$(prompt_input "SOCKS5 密码（>=8，须含字母+数字）" "")
            fi
        fi

        if [ -z "$SOCKS_USER" ] || [ -z "$SOCKS_PASS" ]; then
            if [ "$interactive" -eq 1 ] && [ "$tries" -lt 5 ]; then
                echo "❌ 用户名和密码都不能为空，请重试" >&2
                continue
            fi
            error_exit "启用 SOCKS5 时必须提供用户名和密码（交互输入，或设置 SOCKS_USER / SOCKS_PASS）"
        fi

        user_err=""
        pass_err=""
        if ! user_err=$(validate_socks_username "$SOCKS_USER" 2>&1); then
            echo "❌ 用户名不合法: $user_err" >&2
            if [ "$interactive" -eq 1 ] && [ "$tries" -lt 5 ]; then
                SOCKS_USER=""
                continue
            fi
            error_exit "SOCKS5 用户名不合法: $user_err"
        fi
        if ! pass_err=$(validate_socks_password "$SOCKS_PASS" "$SOCKS_USER" 2>&1); then
            # validate 可能同时输出提示和错误；若 return 1 则整段是失败信息
            echo "❌ 密码不合法: $pass_err" >&2
            if [ "$interactive" -eq 1 ] && [ "$tries" -lt 5 ]; then
                SOCKS_PASS=""
                continue
            fi
            error_exit "SOCKS5 密码不合法: $pass_err"
        else
            # 成功时也可能有“提示:”弱口令建议，透传
            if [ -n "$pass_err" ]; then
                echo "$pass_err" >&2
            fi
        fi
        break
    done
}


configure_socks_optional() {
    # 保留脚本开始前/外部传入的环境变量
    _socks_enable_in="${ENABLE_SOCKS:-0}"
    _socks_port_in="${SOCKS_PORT:-10808}"
    _socks_user_in="${SOCKS_USER:-}"
    _socks_pass_in="${SOCKS_PASS:-}"

    ENABLE_SOCKS=0
    SOCKS_PORT="$_socks_port_in"
    SOCKS_USER="$_socks_user_in"
    SOCKS_PASS="$_socks_pass_in"
    SOCKS_INBOUND_JSON=""
    SOCKS_INFO_TEXT=""

    echo ""
    echo "=========================================="
    echo "可选功能: SOCKS5 入站"
    echo "=========================================="
    echo "说明: 与 VLESS/Reality 并存；默认不启用。"
    echo "安全: 启用后强制用户名+密码，并尝试放行对应端口。"
    echo ""

    choice=""
    if is_truthy "$_socks_enable_in"; then
        choice="y"
        echo "检测到 ENABLE_SOCKS=$_socks_enable_in，将启用 SOCKS5"
    elif [ ! -r /dev/tty ]; then
        choice="n"
        echo "非交互安装且未设置 ENABLE_SOCKS，跳过 SOCKS5"
    else
        choice=$(prompt_input "是否启用 SOCKS5 入站？(y/N)" "N")
    fi

    if ! is_truthy "$choice"; then
        ENABLE_SOCKS=0
        SOCKS_INBOUND_JSON=""
        SOCKS_INFO_TEXT=""
        echo "➡️  不启用 SOCKS5，继续仅安装 Reality"
        return 0
    fi

    ENABLE_SOCKS=1

    # 端口：交互可改；非交互用环境变量/默认
    if [ -r /dev/tty ] && ! is_truthy "$_socks_enable_in"; then
        SOCKS_PORT=$(prompt_input "SOCKS5 端口" "${SOCKS_PORT:-10808}")
    elif [ -r /dev/tty ] && [ "$_socks_port_in" = "10808" ]; then
        # 环境只开了开关、没改端口时，仍允许确认/修改
        SOCKS_PORT=$(prompt_input "SOCKS5 端口" "10808")
    fi
    SOCKS_PORT="${SOCKS_PORT:-10808}"
    if ! validate_port "$SOCKS_PORT"; then
        error_exit "SOCKS5 端口无效: $SOCKS_PORT"
    fi
    if [ "$SOCKS_PORT" = "$PORT" ]; then
        error_exit "SOCKS5 端口不能与 Reality 端口相同 ($PORT)"
    fi

    # 用户名/密码：启用则必填 + 安全校验
    echo "账号要求: 用户名 1-64（字母数字._@+-）；密码 8-128，须含字母+数字，且不能与用户名相同"
    prompt_socks_credentials

    su_esc=$(json_escape "$SOCKS_USER")
    sp_esc=$(json_escape "$SOCKS_PASS")

    # 前导逗号：追加到 VLESS inbound 之后
    SOCKS_INBOUND_JSON=$(printf '%s' ",
    {
        \"tag\": \"socks-in\",
        \"listen\": \"0.0.0.0\",
        \"port\": ${SOCKS_PORT},
        \"protocol\": \"socks\",
        \"settings\": {
            \"auth\": \"password\",
            \"accounts\": [{
                \"user\": \"${su_esc}\",
                \"pass\": \"${sp_esc}\"
            }],
            \"udp\": true
        },
        \"sniffing\": {
            \"enabled\": true,
            \"destOverride\": [\"http\", \"tls\", \"quic\"]
        }
    }")

    SOCKS_INFO_TEXT=$(printf '%s
' \
        "SOCKS5 已启用:" \
        "  地址: (同服务器公网 IP)" \
        "  端口: ${SOCKS_PORT}" \
        "  用户: ${SOCKS_USER}" \
        "  密码: ${SOCKS_PASS}" \
        "  协议: socks5" \
        "  认证: username/password" \
        "  UDP:  true")

    echo "✅ 将写入 SOCKS5 入站: 0.0.0.0:${SOCKS_PORT} (user=${SOCKS_USER})"
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
run_cmd apt-get install -y curl ca-certificates unzip jq iproute2 openssl chrony bc python3 dnsutils

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

# 2.5 自动检测最优伪装目标（多地域 + 严格校验）
# 不可达/无 TLS1.3 的 SNI 直接拒绝安装，避免客户端 -1ms
echo ""
if ! SNI=$(detect_best_sni); then
    error_exit "没有可用的 Reality 伪装目标（SNI/dest）。请检查 VPS 出站访问 443/DNS 后重试"
fi
assert_sni_usable "$SNI"
DEST_SITE="${SNI}:443"
echo "将使用: SNI=$SNI  DEST=$DEST_SITE  region=$(sni_region_of "$SNI")"

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

# 3.5 伪装目标已在 detect/assert 阶段完成严格校验
echo "✅ 伪装目标已校验: $DEST_SITE"

# 3.8 可选 SOCKS5 入站
configure_socks_optional

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
    }$SOCKS_INBOUND_JSON],
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
if [ "${ENABLE_SOCKS:-0}" = "1" ]; then
    open_firewall_port "$SOCKS_PORT"
fi

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

$SOCKS_INFO_TEXT

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
SNI: $SNI（多地域严格校验后的最优选择）
公钥 (PublicKey): $PUB_KEY
ShortID: $SHORT_ID
Fingerprint: chrome
网络 (Network): tcp

$SOCKS_INFO_TEXT
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
   • SNI 自动检测：多地域候选 + DNS/TCP/HTTPS/TLS1.3/H2 严格校验，失败则中止安装
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
