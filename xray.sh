#!/bin/sh
# Xray Reality 管理：Alpine/OpenRC 与 Debian/systemd 共用一个入口。
# 将管道输入完整落盘后再读取菜单，避免交互命令吞掉脚本内容。
if [ ! -f "$0" ]; then
    (
        umask 077
        manager_tmp=$(mktemp /tmp/xray-manager-XXXXXX) || exit 1
        trap 'rm -f -- "$manager_tmp"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        cat > "$manager_tmp" || exit 1
        sh "$manager_tmp" "$@"
    )
    exit $?
fi

# 0. 自定义基础变量
PORT="${PORT:-52300}"
NODE_PUBLIC_PORT="${NODE_PUBLIC_PORT:-}" # NAT 公网节点端口，默认与监听端口相同
CLASH_SUB_PORT="${CLASH_SUB_PORT:-58472}"   # Clash / v2rayN 订阅端口
CLASH_SUB_HTTPS="${CLASH_SUB_HTTPS:-auto}" # auto/cloudflare/existing/import/off
CLASH_SUB_PUBLIC_PORT="${CLASH_SUB_PUBLIC_PORT:-}" # NAT 外部端口，默认等于监听端口
CLASH_SUB_HOST="${CLASH_SUB_HOST:-}"       # 可选：订阅域名，不改变 Reality 节点地址
CLASH_SUB_TLS_CERT="${CLASH_SUB_TLS_CERT:-}" # 可选：PEM 完整证书链
CLASH_SUB_TLS_KEY="${CLASH_SUB_TLS_KEY:-}"   # 可选：PEM 私钥路径
ENABLE_SOCKS="${ENABLE_SOCKS:-0}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
SOCKS_INBOUND_JSON=""
SOCKS_USER_ESC=""
SOCKS_PASS_ESC=""
SOCKS_INFO_TEXT=""
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

CLASH_FILE="/etc/xray/clash-meta.yaml"
XRAY_CLIENT_FILE="/etc/xray/xray-client.json"
CLIENT_NODE_NAME="Reality"
XRAY_USER="xray"
XRAY_GROUP="xray"
CLASH_SUB_URL=""
V2RAYN_SUB_URL=""
V2RAYN_SUB_FILE="/etc/xray/v2rayn.txt"
CLASH_SUB_TOKEN="${CLASH_SUB_TOKEN:-}"

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
        ip=$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '\n' | head -n 1 || true)
        # 粗略校验 IPv4
        echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && break
        ip=""
    done
    if [ -z "$ip" ]; then
        ip=$(curl -fsS --connect-timeout 5 --max-time 8 "https://ifconfig.me" 2>/dev/null | tr -d '\n' | head -n 1 || true)
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
        if openssl s_client -tls1_3 -connect "${sni}:443" -servername "$sni" </dev/null >/dev/null 2>&1; then
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
        sni=$(echo "$line" | cut -d'|' -f1 | tr -d ' \n')
        region=$(echo "$line" | cut -d'|' -f2 | tr -d ' \n')
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




# ------------------------------------------------------------
# ACL4SSR 客户端分流（规则模式，不要开全局）
# 规则思路对齐 https://github.com/ACL4SSR/ACL4SSR
# 安装后生成:
#   /etc/xray/clash-meta.yaml     Clash Verge / mihomo
#   /etc/xray/xray-client.json    NekoBox / v2rayN 自定义 / Xray
# ------------------------------------------------------------
CLASH_FILE="${CLASH_FILE:-/etc/xray/clash-meta.yaml}"
XRAY_CLIENT_FILE="${XRAY_CLIENT_FILE:-/etc/xray/xray-client.json}"
CLIENT_NODE_NAME="${CLIENT_NODE_NAME:-Reality}"

write_clash_sub_httpd() {
    cat > /usr/local/bin/xray-clash-sub.py << 'PY'
#!/usr/bin/env python3
import os
import ssl
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

def load_env(path="/etc/xray/clash-sub.env"):
    env = {}
    if not os.path.isfile(path):
        sys.stderr.write("missing %s\n" % path)
        sys.exit(1)
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            env[key.strip()] = val.strip().strip('"').strip("'")
    return env

cfg = load_env()
PORT = int(cfg.get("CLASH_SUB_PORT", "58472"))
TOKEN = cfg.get("CLASH_SUB_TOKEN", "")
FILE = cfg.get("CLASH_SUB_FILE", "/etc/xray/clash-meta.yaml")
V2RAYN_FILE = cfg.get("V2RAYN_SUB_FILE", "/etc/xray/v2rayn.txt")
TLS_CERT = cfg.get("CLASH_SUB_TLS_CERT", "")
TLS_KEY = cfg.get("CLASH_SUB_TLS_KEY", "")
if not TOKEN:
    sys.exit("empty CLASH_SUB_TOKEN")
REQ_PATH = "/" + TOKEN + "/clash.yaml"
ROUTES = {
    REQ_PATH: (FILE, "text/yaml; charset=utf-8"),
    "/" + TOKEN + "/vless.txt": (V2RAYN_FILE, "text/plain; charset=utf-8"),
}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        route = ROUTES.get(path)
        if route is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        try:
            with open(route[0], "rb") as fh:
                data = fh.read()
        except OSError:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", route[1])
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    if TLS_CERT or TLS_KEY:
        if not TLS_CERT or not TLS_KEY:
            sys.exit("both CLASH_SUB_TLS_CERT and CLASH_SUB_TLS_KEY are required")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(TLS_CERT, TLS_KEY)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()
PY
    chmod 755 /usr/local/bin/xray-clash-sub.py 2>/dev/null || true
}


start_clash_sub_service() {
    case "$XRAY_PLATFORM" in
        alpine) start_clash_sub_alpine ;;
        debian) start_clash_sub_debian ;;
        *) error_exit "不支持的系统" ;;
    esac
}

start_clash_sub_alpine() {
    write_clash_sub_httpd
    open_firewall_port "$CLASH_SUB_PORT"
    cat > /etc/local.d/clash-sub.start << 'START'
#!/bin/sh
[ -f /etc/xray/clash-sub.env ] || exit 0
if command -v pkill >/dev/null 2>&1; then
    pkill -f "/usr/local/bin/xray-clash-sub.py" 2>/dev/null || true
fi
sleep 1
python3 /usr/local/bin/xray-clash-sub.py >> /var/log/xray-clash-sub.log 2>&1 &
START
    cat > /etc/local.d/clash-sub.stop << 'STOP'
#!/bin/sh
if command -v pkill >/dev/null 2>&1; then
    pkill -f "/usr/local/bin/xray-clash-sub.py" 2>/dev/null || true
fi
STOP
    chmod +x /etc/local.d/clash-sub.start /etc/local.d/clash-sub.stop 2>/dev/null || true
    sh /etc/local.d/clash-sub.stop 2>/dev/null || true
    sh /etc/local.d/clash-sub.start 2>/dev/null || true
    sleep 1
    if pgrep -f "xray-clash-sub.py" >/dev/null 2>&1 || ps | grep -q "[x]ray-clash-sub.py"; then
        echo "✅ Clash 本机订阅服务已启动 (TCP $CLASH_SUB_PORT)"
    else
        echo "⚠️  Clash 本机订阅服务启动失败，仍可用 $CLASH_FILE 本地导入"
    fi
}

start_clash_sub_debian() {
    write_clash_sub_httpd
    open_firewall_port "$CLASH_SUB_PORT"
    pybin=$(command -v python3 || echo /usr/bin/python3)
    cat > /etc/systemd/system/xray-clash-sub.service << SYSTEMD
[Unit]
Description=Xray local Clash subscription (ACL4SSR yaml)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${pybin} /usr/local/bin/xray-clash-sub.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD
    chmod 644 /etc/systemd/system/xray-clash-sub.service
    systemctl daemon-reload
    systemctl enable xray-clash-sub.service >/dev/null 2>&1 || true
    systemctl restart xray-clash-sub.service
    sleep 1
    if systemctl is-active --quiet xray-clash-sub.service; then
        echo "✅ Clash 本机订阅服务已启动 (TCP $CLASH_SUB_PORT)"
    else
        echo "⚠️  Clash 本机订阅服务启动失败，仍可用 $CLASH_FILE 本地导入"
        systemctl status xray-clash-sub.service --no-pager -l | tail -n 20 || true
    fi
}

write_client_routing_files() {
    node_name="${CLIENT_NODE_NAME:-Reality}"
    client_addr="${CLEAR_IP:-YOUR_PUBLIC_IP}"
    if ! echo "$client_addr" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        client_addr="YOUR_PUBLIC_IP"
    fi
    acl_cdn="https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash"

    cat > "$CLASH_FILE" << YAML
# Clash Meta / mihomo
# 分流规则来源: ACL4SSR (https://github.com/ACL4SSR/ACL4SSR)
# 请使用「规则模式」(mode: rule)，不要开全局模式
mixed-port: 7890
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: info
ipv6: false
unified-delay: true
tcp-concurrent: true
external-controller: 127.0.0.1:9090

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - localhost.ptlogin2.qq.com
    - "+.srv.nintendo.net"
    - "+.stun.playstation.net"
    - "xbox.*.microsoft.com"
    - "*.msftconnecttest.com"
    - "*.msftncsi.com"
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  # 直连连接使用国内 DNS；国外备用 DoH 显式经过节点选择组。
  direct-nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  fallback:
    - "https://dns.google/dns-query#🚀 节点选择"
    - "https://cloudflare-dns.com/dns-query#🚀 节点选择"
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4

proxies:
  - name: ${node_name}
    type: vless
    server: ${client_addr}
    port: ${NODE_PUBLIC_PORT:-$PORT}
    uuid: ${USER_UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUB_KEY}
      short-id: "${SHORT_ID}"
      support-x25519mlkem768: true

proxy-groups:
  - name: 🚀 节点选择
    type: select
    proxies:
      - ♻️ 自动选择
      - ${node_name}
      - DIRECT
  - name: ♻️ 自动选择
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
      - ${node_name}
  - name: 🌍 国外媒体
    type: select
    proxies:
      - 🚀 节点选择
      - 🎯 全球直连
  - name: 📲 电报信息
    type: select
    proxies:
      - 🚀 节点选择
      - 🎯 全球直连
  - name: 💬 OpenAi
    type: select
    proxies:
      - 🚀 节点选择
      - 🎯 全球直连
  - name: Ⓜ️ 微软服务
    type: select
    proxies:
      - 🎯 全球直连
      - 🚀 节点选择
      - DIRECT
  - name: 🍎 苹果服务
    type: select
    proxies:
      - 🚀 节点选择
      - 🎯 全球直连
      - DIRECT
  - name: 🌏 国内媒体
    type: select
    proxies:
      - 🎯 全球直连
      - 🚀 节点选择
  - name: 🎯 全球直连
    type: select
    proxies:
      - DIRECT
      - 🚀 节点选择
  - name: 🛑 广告拦截
    type: select
    proxies:
      - REJECT
      - DIRECT
  - name: 🍃 应用净化
    type: select
    proxies:
      - REJECT
      - DIRECT
  - name: 🐟 漏网之鱼
    type: select
    proxies:
      - 🚀 节点选择
      - 🎯 全球直连
      - DIRECT

rule-providers:
  LocalAreaNetwork:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/LocalAreaNetwork.list"
    path: ./ruleset/LocalAreaNetwork.yaml
    interval: 86400
  UnBan:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/UnBan.list"
    path: ./ruleset/UnBan.yaml
    interval: 86400
  BanAD:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/BanAD.list"
    path: ./ruleset/BanAD.yaml
    interval: 86400
  BanProgramAD:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/BanProgramAD.list"
    path: ./ruleset/BanProgramAD.yaml
    interval: 86400
  GoogleCN:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/GoogleCN.list"
    path: ./ruleset/GoogleCN.yaml
    interval: 86400
  SteamCN:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/Ruleset/SteamCN.list"
    path: ./ruleset/SteamCN.yaml
    interval: 86400
  Microsoft:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/Microsoft.list"
    path: ./ruleset/Microsoft.yaml
    interval: 86400
  Apple:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/Apple.list"
    path: ./ruleset/Apple.yaml
    interval: 86400
  Telegram:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/Telegram.list"
    path: ./ruleset/Telegram.yaml
    interval: 86400
  OpenAi:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/Ruleset/OpenAi.list"
    path: ./ruleset/OpenAi.yaml
    interval: 86400
  ProxyMedia:
    type: http
    behavior: classical
    format: yaml
    url: "${acl_cdn}/Providers/ProxyMedia.yaml"
    path: ./ruleset/ProxyMedia-provider.yaml
    interval: 86400
  ProxyGFWlist:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/ProxyGFWlist.list"
    path: ./ruleset/ProxyGFWlist.yaml
    interval: 86400
  ChinaMedia:
    type: http
    behavior: classical
    format: yaml
    url: "${acl_cdn}/Providers/ChinaMedia.yaml"
    path: ./ruleset/ChinaMedia-provider.yaml
    interval: 86400
  ChinaDomain:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/ChinaDomain.list"
    path: ./ruleset/ChinaDomain.yaml
    interval: 86400
  ChinaCompanyIp:
    type: http
    behavior: classical
    format: text
    url: "${acl_cdn}/ChinaCompanyIp.list"
    path: ./ruleset/ChinaCompanyIp.yaml
    interval: 86400

rules:
  - RULE-SET,LocalAreaNetwork,🎯 全球直连
  - RULE-SET,UnBan,🎯 全球直连
  - RULE-SET,BanAD,🛑 广告拦截
  - RULE-SET,BanProgramAD,🍃 应用净化
  - RULE-SET,GoogleCN,🎯 全球直连
  - RULE-SET,SteamCN,🎯 全球直连
  - RULE-SET,Microsoft,Ⓜ️ 微软服务
  - RULE-SET,Apple,🍎 苹果服务
  - RULE-SET,Telegram,📲 电报信息
  - RULE-SET,OpenAi,💬 OpenAi
  - RULE-SET,ProxyMedia,🌍 国外媒体
  - RULE-SET,ProxyGFWlist,🚀 节点选择
  - RULE-SET,ChinaMedia,🌏 国内媒体
  - RULE-SET,ChinaDomain,🎯 全球直连
  - RULE-SET,ChinaCompanyIp,🎯 全球直连
  - GEOSITE,private,🎯 全球直连
  - GEOSITE,category-ads-all,🛑 广告拦截
  - GEOSITE,openai,💬 OpenAi
  - GEOSITE,telegram,📲 电报信息
  - GEOSITE,google,🚀 节点选择
  - GEOSITE,gfw,🚀 节点选择
  - "GEOSITE,geolocation-!cn,🚀 节点选择"
  - GEOSITE,cn,🎯 全球直连
  - GEOIP,telegram,📲 电报信息
  - GEOIP,LAN,🎯 全球直连
  - GEOIP,CN,🎯 全球直连
  - MATCH,🐟 漏网之鱼
YAML

    cat > "$XRAY_CLIENT_FILE" << JSON
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": 10808,
            "protocol": "socks",
            "settings": {
                "udp": true
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        },
        {
            "tag": "http-in",
            "listen": "127.0.0.1",
            "port": 10809,
            "protocol": "http",
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }
    ],
    "outbounds": [
        {
            "tag": "proxy",
            "protocol": "vless",
            "settings": {
                "vnext": [{
                    "address": "${client_addr}",
                    "port": ${NODE_PUBLIC_PORT:-$PORT},
                    "users": [{
                        "id": "${USER_UUID}",
                        "encryption": "none",
                        "flow": "xtls-rprx-vision"
                    }]
                }]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "serverName": "${SNI}",
                    "fingerprint": "chrome",
                    "publicKey": "${PUB_KEY}",
                    "shortId": "${SHORT_ID}",
                    "spiderX": "/"
                }
            }
        },
        {
            "tag": "direct",
            "protocol": "freedom",
            "settings": {}
        },
        {
            "tag": "block",
            "protocol": "blackhole",
            "settings": {}
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "domain": ["geosite:category-ads-all"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "protocol": ["bittorrent"],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "domain": ["geosite:private"],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:google",
                    "geosite:youtube",
                    "geosite:telegram",
                    "geosite:twitter",
                    "geosite:facebook",
                    "geosite:gfw",
                    "geosite:geolocation-!cn"
                ],
                "outboundTag": "proxy"
            },
            {
                "type": "field",
                "ip": ["geoip:telegram"],
                "outboundTag": "proxy"
            },
            {
                "type": "field",
                "domain": ["geosite:cn"],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "ip": ["geoip:cn"],
                "outboundTag": "direct"
            }
        ]
    }
}
JSON



    # 原生节点订阅供 v2rayN 使用，避免完整 Clash YAML 切换到 mihomo。
    printf '%s\n' "$SHARE_LINK" | base64 | tr -d '\r\n' > "$V2RAYN_SUB_FILE"
    printf '\n' >> "$V2RAYN_SUB_FILE"
    chmod 600 "$V2RAYN_SUB_FILE" 2>/dev/null || true
    sub_scheme=http
    sub_host="${CLASH_SUB_HOST:-$client_addr}"
    if [ -n "$CLASH_SUB_TLS_CERT" ] || [ -n "$CLASH_SUB_TLS_KEY" ]; then
        [ -n "$CLASH_SUB_TLS_CERT" ] && [ -n "$CLASH_SUB_TLS_KEY" ] || error_exit "HTTPS 订阅必须同时设置证书和私钥路径"
        [ -r "$CLASH_SUB_TLS_CERT" ] && [ -r "$CLASH_SUB_TLS_KEY" ] || error_exit "HTTPS 订阅证书或私钥文件不可读"
        [ -n "$CLASH_SUB_HOST" ] || error_exit "HTTPS 订阅请设置证书对应的 CLASH_SUB_HOST 域名"
        sub_scheme=https
    fi

    if [ -z "${CLASH_SUB_TOKEN:-}" ]; then
        CLASH_SUB_TOKEN=$(openssl rand -hex 16 2>/dev/null || true)
    fi
    if [ -z "$CLASH_SUB_TOKEN" ] && [ -r /proc/sys/kernel/random/uuid ]; then
        CLASH_SUB_TOKEN=$(tr -d '-' </proc/sys/kernel/random/uuid)
    fi
    if [ -z "$CLASH_SUB_TOKEN" ]; then
        CLASH_SUB_TOKEN=$(date +%s | md5sum 2>/dev/null | awk '{print $1}')
    fi
    cat > "${SUB_ENV:-/etc/xray/clash-sub.env}" << ENV
NODE_PUBLIC_PORT=${NODE_PUBLIC_PORT:-$PORT}
CLASH_SUB_PORT=$CLASH_SUB_PORT
CLASH_SUB_PUBLIC_PORT=${CLASH_SUB_PUBLIC_PORT:-$CLASH_SUB_PORT}
CLASH_SUB_HOST=$CLASH_SUB_HOST
CLASH_SUB_TOKEN=$CLASH_SUB_TOKEN
CLASH_SUB_FILE=${SUBSCRIPTION_LIVE_CLASH_FILE:-$CLASH_FILE}
V2RAYN_SUB_FILE=${SUBSCRIPTION_LIVE_V2RAYN_FILE:-$V2RAYN_SUB_FILE}
CLASH_SUB_TLS_CERT=$CLASH_SUB_TLS_CERT
CLASH_SUB_TLS_KEY=$CLASH_SUB_TLS_KEY
ENV
    chmod 600 "${SUB_ENV:-/etc/xray/clash-sub.env}" 2>/dev/null || true
    CLASH_SUB_URL="${sub_scheme}://${sub_host}:${CLASH_SUB_PUBLIC_PORT:-$CLASH_SUB_PORT}/${CLASH_SUB_TOKEN}/clash.yaml"
    V2RAYN_SUB_URL="${sub_scheme}://${sub_host}:${CLASH_SUB_PUBLIC_PORT:-$CLASH_SUB_PORT}/${CLASH_SUB_TOKEN}/vless.txt"


    if [ -f "$SHARE_FILE" ]; then
        cat >> "$SHARE_FILE" << NOTE

Clash 订阅（本机提供，不经过任何第三方转换站）:
$CLASH_SUB_URL

v2rayN 原生 VLESS 订阅（使用 Xray，路由选「绕过大陆」）:
$V2RAYN_SUB_URL

用法: Clash Verge / mihomo → 新建订阅 → 粘贴上面链接 → 更新
      模式选「规则」，不要开全局
      安全组 / LXC 映射需放行 TCP $CLASH_SUB_PORT
      链接含随机口令，不要发给别人

本地配置:
  Clash Meta: $CLASH_FILE
  Xray / NekoBox: $XRAY_CLIENT_FILE
  规则来源: https://github.com/ACL4SSR/ACL4SSR
NOTE
    fi

    echo "✅ 已生成本机 Clash 订阅（不经过第三方）"
    echo "  $CLASH_SUB_URL"
    echo "  v2rayN 原生订阅: $V2RAYN_SUB_URL"
    echo "  本地备份: $CLASH_FILE"
    if [ "$client_addr" = "YOUR_PUBLIC_IP" ]; then
        echo "⚠️  未检测到公网 IP，请把配置里的 YOUR_PUBLIC_IP 改成宿主机公网 IP"
    fi
}

# BEGIN subscription HTTPS wizard
subscription_prompt() {
    # Read the terminal rather than stdin, including curl | sh installations.
    sub_reply=""
    if [ -t 3 ] 2>/dev/null; then
        printf '%s [%s]: ' "$1" "${2:-}" >&3
        IFS= read -r sub_reply <&3 || return 1
    else
        return 1
    fi
    printf '%s' "${sub_reply:-${2:-}}"
}

subscription_validate_options() {
    python3 - "$CLASH_SUB_HOST" "$CLASH_SUB_PORT" "$CLASH_SUB_PUBLIC_PORT" "${PORT:-52300}" "${NODE_PUBLIC_PORT:-${PORT:-52300}}" <<'PY'
import ipaddress
import re
import sys
host, port, public_port, reality_port, reality_public_port = sys.argv[1:]
if host:
    if len(host) > 253 or '.' not in host or any(not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label) for label in host.split('.')):
        sys.exit('订阅域名无效：只填写完整域名，不带 https://、端口或路径。')
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        sys.exit('HTTPS 订阅请使用域名，而不是 IP。')
for value in (port, public_port):
    if not re.fullmatch(r'[0-9]{1,5}', value) or not 1 <= int(value) <= 65535:
        sys.exit('订阅端口必须在 1–65535 之间。')
if int(port) == int(reality_port):
    sys.exit('订阅监听端口不能与 Reality 端口相同。')
if int(public_port) == int(reality_public_port):
    sys.exit('订阅公网端口不能与 Reality 公网端口相同。')
PY
}

subscription_validate_tls() {
    [ -n "$CLASH_SUB_HOST" ] && [ -n "$CLASH_SUB_TLS_CERT" ] && [ -n "$CLASH_SUB_TLS_KEY" ] || return 1
    python3 - "$CLASH_SUB_TLS_CERT" "$CLASH_SUB_TLS_KEY" <<'PY'
import ssl
import sys
if any(c in path for path in sys.argv[1:] for c in '\r\n'):
    sys.exit('证书路径不能含换行。')
ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER).load_cert_chain(*sys.argv[1:])
PY
    [ "$?" -eq 0 ] || return 1
    openssl x509 -in "$CLASH_SUB_TLS_CERT" -noout -checkend 86400 || return 1
    # Verify both hostname and public trust; reject Cloudflare Origin CA for grey-cloud access.
    openssl verify -purpose sslserver -verify_hostname "$CLASH_SUB_HOST" \
        -untrusted "$CLASH_SUB_TLS_CERT" "$CLASH_SUB_TLS_CERT" || return 1
}

subscription_install_acme() (
    umask 077
    if [ ! -f /root/.acme.sh/acme.sh ]; then
        echo "正在从 acme.sh 官方仓库安装证书工具..."
        sub_acme_tmp=$(mktemp -d) || exit 1
        trap 'rm -rf -- "$sub_acme_tmp"' EXIT
        trap 'exit 1' HUP INT TERM
        curl -fSL --retry 2 --connect-timeout 15 --max-time 120 \
            https://codeload.github.com/acmesh-official/acme.sh/tar.gz/refs/heads/master \
            -o "$sub_acme_tmp/acme.tar.gz" || exit 1
        tar -xzf "$sub_acme_tmp/acme.tar.gz" -C "$sub_acme_tmp" || exit 1
        (cd "$sub_acme_tmp/acme.sh-master" && sh ./acme.sh --install \
            --home /root/.acme.sh --no-profile --no-cron) || exit 1
    fi
    chmod 700 /root/.acme.sh || exit 1
)

subscription_write_reload_hook() {
    # Initial certificate installation may precede creation of the subscription service.
    mkdir -p /usr/local/bin || return 1
    cat > /usr/local/bin/xray-sub-cert-reload <<'HOOK'
#!/bin/sh
set -e
if [ -f /etc/xray/clash-sub.env ] && grep -q '^CLASH_SUB_TLS_CERT=.' /etc/xray/clash-sub.env; then
    if [ -f /etc/alpine-release ]; then
        [ ! -f /etc/local.d/clash-sub.start ] || sh /etc/local.d/clash-sub.start
    elif [ -f /etc/systemd/system/xray-clash-sub.service ]; then
        systemctl restart xray-clash-sub.service
    fi
fi
HOOK
    chmod 700 /usr/local/bin/xray-sub-cert-reload
}

subscription_schedule_renewal() {
    if [ -f /etc/alpine-release ]; then
        cat > /etc/periodic/daily/xray-sub-renew <<'CRON'
#!/bin/sh
umask 077
exec sh /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> /var/log/xray-sub-renew.log 2>&1
CRON
        chmod 700 /etc/periodic/daily/xray-sub-renew || return 1
        rc-update add crond default || return 1
        rc-service crond start || return 1
    else
        cat > /etc/systemd/system/xray-sub-renew.service <<'SERVICE'
[Unit]
Description=Renew Xray subscription HTTPS certificate
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
UMask=0077
ExecStart=/bin/sh /root/.acme.sh/acme.sh --cron --home /root/.acme.sh
SERVICE
        cat > /etc/systemd/system/xray-sub-renew.timer <<'TIMER'
[Unit]
Description=Daily check for Xray subscription certificate renewal
[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
TIMER
        systemctl daemon-reload || return 1
        systemctl enable --now xray-sub-renew.timer || return 1
    fi
}

subscription_setup_cloudflare() (
    # Restrict newly created certificate / ACME account files, including the saved renewal token.
    set +x
    umask 077
    echo "Cloudflare → 个人资料 → API 令牌 → 创建令牌 → 编辑区域 DNS。"
    echo "权限：区域/DNS/编辑 + 区域/区域/读取；资源仅包含此域名所属区域。"
    echo "Token 只在本机输入；acme.sh 会保存它供自动续期使用。"
    if [ -z "${CF_Token:-}" ]; then
        CF_Token=$(python3 - <<'PY'
import getpass
import sys
try:
    with open('/dev/tty', 'w') as tty:
        if not tty.isatty():
            sys.exit('无终端：请通过 CF_Token 环境变量提供 Cloudflare API Token。')
        token = getpass.getpass('Cloudflare API Token（隐藏输入）: ', stream=tty)
except OSError:
    sys.exit('无终端：请通过 CF_Token 环境变量提供 Cloudflare API Token。')
if not token or any(c.isspace() for c in token):
    sys.exit('API Token 不能为空或含空白。')
print(token, end='')
PY
        ) || exit 1
    fi
    export CF_Token
    subscription_install_acme || exit 1
    subscription_write_reload_hook || exit 1
    echo "正在使用 Let's Encrypt DNS-01 签发证书（无需入站 80/443）..."
    if sh /root/.acme.sh/acme.sh --issue --home /root/.acme.sh --dns dns_cf \
        -d "$CLASH_SUB_HOST" --server letsencrypt --keylength ec-256; then
        :
    else
        sub_issue_status=$?
        # acme.sh returns 2 when the existing certificate is not due for renewal.
        [ "$sub_issue_status" -eq 2 ] || exit "$sub_issue_status"
    fi
    mkdir -p /etc/xray/tls || exit 1
    chmod 700 /etc/xray/tls || exit 1
    sh /root/.acme.sh/acme.sh --install-cert --home /root/.acme.sh \
        -d "$CLASH_SUB_HOST" --ecc \
        --key-file "$CLASH_SUB_TLS_KEY" --fullchain-file "$CLASH_SUB_TLS_CERT" \
        --reloadcmd /usr/local/bin/xray-sub-cert-reload || exit 1
    chmod 600 "$CLASH_SUB_TLS_KEY" || exit 1
    subscription_validate_tls || exit 1
    subscription_schedule_renewal || exit 1
    echo "✅ 已配置每日续期检查，证书更新后自动重启订阅服务。"
)

subscription_certificate_bundle() {
    # PKCS#12 encrypts the certificate and private key. Passwords never enter argv.
    python3 - "$@" <<'PY'
import getpass
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import tempfile

def command(args, data=None):
    result = subprocess.run(['openssl', *args], input=data, capture_output=True)
    if result.returncode:
        raise ValueError('OpenSSL 操作失败：密码错误、备份损坏或证书无效。')
    return result.stdout

def valid_host(host):
    return len(host) <= 253 and '.' in host and all(re.fullmatch(
        r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', part) for part in host.split('.'))

def write_private(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as output:
        output.write(data)

def password(action):
    value = os.environ.get('CERT_BUNDLE_PASSWORD')
    if value is None:
        with open('/dev/tty', 'w') as tty:
            if not tty.isatty():
                raise ValueError('无终端：请通过 CERT_BUNDLE_PASSWORD 环境变量提供备份密码。')
            value = getpass.getpass('证书备份密码（隐藏输入）: ', stream=tty)
            if action == 'export' and value != getpass.getpass('再次输入备份密码: ', stream=tty):
                raise ValueError('两次密码不一致。')
    if len(value) < 8 or '\n' in value or '\r' in value or '\0' in value:
        raise ValueError('备份密码至少 8 个字符，不能含换行或 NUL。')
    return (value+'\n').encode('utf-8')

try:
    action, bundle, host, cert, key = sys.argv[1:]
    path = Path(bundle).expanduser()
    if action == 'export':
        if path.exists() or path.is_symlink():
            raise ValueError('备份文件已存在，请指定新文件名，避免覆盖。')
        secret = password(action)
        data = command(['pkcs12', '-export', '-in', cert, '-inkey', key,
                        '-name', host, '-keypbe', 'AES-256-CBC', '-certpbe', 'AES-256-CBC',
                        '-macalg', 'sha256', '-iter', '200000', '-passout', 'stdin'], secret)
        write_private(path, data)
        print('✅ 已导出加密证书备份: '+str(path))
        print('请把备份下载到本机保存；文件含私钥，密码遗失无法恢复。')
        print('备份仅包含证书链和私钥，不包含 Cloudflare Token、节点参数或订阅口令。')
    elif action == 'import':
        if not path.is_file() or path.stat().st_size > 2*1024*1024:
            raise ValueError('备份不存在或超过 2 MiB。')
        secret = password(action)
        with tempfile.TemporaryDirectory(prefix='xray-cert-') as tmp:
            folder = Path(tmp)
            leaf = command(['pkcs12', '-in', str(path), '-clcerts', '-nokeys', '-passin', 'stdin'], secret)
            chain = command(['pkcs12', '-in', str(path), '-cacerts', '-nokeys', '-passin', 'stdin'], secret)
            raw_key = command(['pkcs12', '-in', str(path), '-nocerts', '-nodes', '-passin', 'stdin'], secret)
            pattern = rb'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----'
            leaves = re.findall(pattern, leaf, re.S)
            if len(leaves) != 1:
                raise ValueError('备份应包含一个站点证书及对应私钥。')
            pem = b'\n'.join(leaves+re.findall(pattern, chain, re.S))+b'\n'
            staged_cert, staged_key = folder/'fullchain.pem', folder/'key.pem'
            write_private(staged_cert, pem)
            write_private(staged_key, command(['pkey'], raw_key))
            if not host:
                # Our exports store the exact hostname as the PKCS#12 friendly name.
                names = re.findall(rb'^\s*friendlyName: ([^\r\n]+)', leaf, re.M)
                if names:
                    candidate = names[0].decode('utf-8')
                    if valid_host(candidate):
                        host = candidate
                if not host:
                    san = command(['x509', '-in', str(staged_cert), '-noout', '-ext', 'subjectAltName'])
                    host = next((v for v in re.findall(r'DNS:([^,\s]+)', san.decode('utf-8'))
                                 if valid_host(v)), '')
            if not valid_host(host):
                raise ValueError('请通过 CLASH_SUB_HOST 指定证书对应的完整域名。')
            ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER).load_cert_chain(staged_cert, staged_key)
            command(['x509', '-in', str(staged_cert), '-noout', '-checkend', '86400'])
            command(['verify', '-purpose', 'sslserver', '-verify_hostname', host,
                     '-untrusted', str(staged_cert), str(staged_cert)])
            # Only publish validated files; use a unique directory so failed imports
            # cannot overwrite an existing working certificate or its renewal targets.
            target = Path(cert)
            target.mkdir(mode=0o700, parents=True, exist_ok=True)
            installed = Path(tempfile.mkdtemp(prefix='import-', dir=target))
            try:
                write_private(installed/'fullchain.pem', pem)
                write_private(installed/'key.pem', staged_key.read_bytes())
            except BaseException:
                for item in installed.iterdir():
                    item.unlink()
                installed.rmdir()
                raise
            # Fixed three-line output is consumed by the shell, never evaluated.
            print(host)
            print(installed/'fullchain.pem')
            print(installed/'key.pem')
    else:
        raise ValueError('未知证书操作。')
except (OSError, ValueError, ssl.SSLError) as error:
    sys.exit('证书'+('导出' if sys.argv[1:2] == ['export'] else '导入')+'失败: '+str(error))
PY
}

subscription_export_certificate() (
    set +x
    umask 077
    [ "$(id -u)" = 0 ] || { echo "请以 root 运行" >&2; exit 1; }
    for sub_cmd in python3 openssl; do
        command -v "$sub_cmd" >/dev/null || { echo "缺少依赖: $sub_cmd" >&2; exit 1; }
    done
    # Only read data from the subscription env file; never source it as shell code.
    sub_saved_tls=$(python3 - <<'PY'
import os
from pathlib import Path
import shlex
values = {}
path = Path('/etc/xray/clash-sub.env')
allowed = ('CLASH_SUB_HOST', 'CLASH_SUB_TLS_CERT', 'CLASH_SUB_TLS_KEY')
if path.is_file():
    for line in path.read_text().splitlines():
        key, sep, value = line.partition('=')
        if sep and key in allowed:
            values[key] = value.strip()
for key in allowed:
    print(key+'='+shlex.quote(os.environ.get(key) or values.get(key, '')))
PY
    ) || exit 1
    eval "$sub_saved_tls"
    [ -n "$CLASH_SUB_HOST$CLASH_SUB_TLS_CERT$CLASH_SUB_TLS_KEY" ] || { echo "没有可导出的 HTTPS 证书" >&2; exit 1; }
    subscription_validate_tls || { echo "当前证书未通过校验，停止导出" >&2; exit 1; }
    subscription_certificate_bundle export "$1" "$CLASH_SUB_HOST" "$CLASH_SUB_TLS_CERT" "$CLASH_SUB_TLS_KEY"
)

subscription_import_certificate() {
    sub_imported=$(subscription_certificate_bundle import "$CLASH_SUB_CERT_BUNDLE" \
        "$CLASH_SUB_HOST" /etc/xray/tls "") || error_exit "证书导入失败，原证书和订阅配置未改动"
    CLASH_SUB_HOST=$(printf '%s\n' "$sub_imported" | sed -n '1p')
    CLASH_SUB_TLS_CERT=$(printf '%s\n' "$sub_imported" | sed -n '2p')
    CLASH_SUB_TLS_KEY=$(printf '%s\n' "$sub_imported" | sed -n '3p')
    echo "✅ 已导入 $CLASH_SUB_HOST 的证书，无需重新申请。"
    echo "迁移后请将 Cloudflare 灰云 A 记录改为新 NAT 公网 IP，确认公网订阅端口映射。"
    echo "证书备份不含续期账户/Token。请运行 sh xray.sh，选择 3，重新接入自动续期。"
    echo "新节点参数和订阅口令以本机输出为准；证书导入不会恢复旧节点或旧订阅地址。"
}

configure_subscription_https() {
    CLASH_SUB_HTTPS="${CLASH_SUB_HTTPS:-auto}"
    CLASH_SUB_HOST="${CLASH_SUB_HOST:-}"
    CLASH_SUB_TLS_CERT="${CLASH_SUB_TLS_CERT:-}"
    CLASH_SUB_TLS_KEY="${CLASH_SUB_TLS_KEY:-}"
    CLASH_SUB_PUBLIC_PORT="${CLASH_SUB_PUBLIC_PORT:-$CLASH_SUB_PORT}"
    CLASH_SUB_CERT_BUNDLE="${CLASH_SUB_CERT_BUNDLE:-}"
    sub_https_reuse=0
    # This subshell check avoids a fatal /dev/tty redirection in noninteractive sh.
    if ( : </dev/tty ) 2>/dev/null; then
        exec 3<>/dev/tty
    fi
    if [ "$CLASH_SUB_HTTPS" = auto ]; then
        if [ -n "$CLASH_SUB_CERT_BUNDLE" ]; then
            CLASH_SUB_HTTPS=import
        elif [ -n "$CLASH_SUB_TLS_CERT$CLASH_SUB_TLS_KEY" ]; then
            CLASH_SUB_HTTPS=existing
            sub_https_reuse=1
        elif [ -n "$CLASH_SUB_HOST" ]; then
            CLASH_SUB_HTTPS=cloudflare
        elif [ -t 3 ] 2>/dev/null; then
            echo "订阅访问方式：1) Cloudflare 自动申请 HTTPS（推荐） 2) 已有公开证书 3) HTTP 4) 导入加密证书备份"
            sub_choice=$(subscription_prompt "请选择" 1) || error_exit "订阅向导已中断"
            case "$sub_choice" in
                1) CLASH_SUB_HTTPS=cloudflare ;;
                2) CLASH_SUB_HTTPS=existing ;;
                3) CLASH_SUB_HTTPS=off ;;
                4) CLASH_SUB_HTTPS=import ;;
                *) error_exit "无效选择，请重新运行并选择 1、2、3 或 4" ;;
            esac
        else
            CLASH_SUB_HTTPS=off
            echo "无交互终端且未指定 HTTPS 参数：保持 HTTP。稍后可运行 sh xray.sh，选择 3。"
        fi
    fi
    if [ "$CLASH_SUB_HTTPS" = import ]; then
        if [ -z "$CLASH_SUB_CERT_BUNDLE" ]; then
            CLASH_SUB_CERT_BUNDLE=$(subscription_prompt "证书备份包路径（.p12）" "") || error_exit "请设置 CLASH_SUB_CERT_BUNDLE"
        fi
        subscription_import_certificate
    fi
    case "$CLASH_SUB_HTTPS" in
        off)
            [ -z "$CLASH_SUB_TLS_CERT$CLASH_SUB_TLS_KEY" ] || error_exit "已有 TLS 配置，不能用 off 静默降级；请保留 HTTPS"
            ;;
        cloudflare|existing|import)
            if [ -z "$CLASH_SUB_HOST" ]; then
                CLASH_SUB_HOST=$(subscription_prompt "完整订阅域名，例如 zor.zor.de5.net" "") || error_exit "请设置 CLASH_SUB_HOST"
            fi
            if [ "$sub_https_reuse" -eq 0 ] && [ -t 3 ] 2>/dev/null; then
                CLASH_SUB_PUBLIC_PORT=$(subscription_prompt "公网订阅端口（NAT 外部端口）" "$CLASH_SUB_PUBLIC_PORT") || error_exit "订阅向导已中断"
            fi
            subscription_validate_options || error_exit "请修正订阅域名或端口后重试"
            echo "请在 Cloudflare DNS 添加 A 记录：$CLASH_SUB_HOST → ${CLEAR_IP:-NAT宿主机公网IP}，选择仅 DNS（灰云）。"
            echo "NAT/安全组：公网 TCP $CLASH_SUB_PUBLIC_PORT → 容器 TCP $CLASH_SUB_PORT；不需要开放 80/443。"
            echo "Cloudflare 边缘证书不能下载使用；Origin CA 不适用于灰云直连。"
            if [ "$sub_https_reuse" -eq 0 ] && [ -t 3 ] 2>/dev/null; then
                sub_ready=$(subscription_prompt "确认上述 DNS 和端口映射已设置后按回车，输入 q 退出" "继续") || error_exit "订阅向导已中断"
                [ "$sub_ready" != q ] || error_exit "已退出；设置完成后可重新运行订阅更新工具"
            fi
            if [ "$CLASH_SUB_HTTPS" = cloudflare ]; then
                # Keep each domain's ACME files separate so a hostname change
                # cannot overwrite the working certificate needed for rollback.
                sub_domain_tls="$XRAY_DIR/tls/acme-$CLASH_SUB_HOST"
                mkdir -p "$sub_domain_tls" || error_exit "无法创建证书目录"
                chmod 700 "$sub_domain_tls" || error_exit "无法设置证书目录权限"
                CLASH_SUB_TLS_CERT="$sub_domain_tls/fullchain.pem"
                CLASH_SUB_TLS_KEY="$sub_domain_tls/key.pem"
                subscription_setup_cloudflare || error_exit "HTTPS 配置未完成，原订阅文件尚未改写。检查 Token 权限/网络后运行 sh xray.sh，选择 3 重试；不要反复重装 Xray。"
            else
                if [ -z "$CLASH_SUB_TLS_CERT" ]; then
                    CLASH_SUB_TLS_CERT=$(subscription_prompt "完整证书链路径" /etc/xray/tls/fullchain.pem) || error_exit "请设置 CLASH_SUB_TLS_CERT"
                fi
                if [ -z "$CLASH_SUB_TLS_KEY" ]; then
                    CLASH_SUB_TLS_KEY=$(subscription_prompt "私钥路径" /etc/xray/tls/key.pem) || error_exit "请设置 CLASH_SUB_TLS_KEY"
                fi
                subscription_validate_tls || error_exit "证书无效：请检查证书链、公私钥、域名和有效期；灰云直连不能使用 Origin CA"
                if [ "$CLASH_SUB_HTTPS" != import ]; then
                    echo "使用已有证书；请在原证书工具续期后重启订阅服务以加载证书。"
                fi
            fi
            ;;
        *) error_exit "CLASH_SUB_HTTPS 仅支持 auto、cloudflare、existing、import、off" ;;
    esac
    subscription_validate_options || error_exit "订阅域名或端口无效"
    exec 3>&-
}
subscription_verify_local() {
    python3 - "$CLASH_SUB_HOST" "$CLASH_SUB_PORT" "$CLASH_SUB_TOKEN" "$CLASH_SUB_TLS_CERT" <<'PY'
import http.client
import socket
import ssl
import sys
host, port, token, cert = sys.argv[1:]
try:
    stream = socket.create_connection(('127.0.0.1', int(port)), timeout=8)
    if cert:
        stream = ssl.create_default_context().wrap_socket(stream, server_hostname=host)
    with stream:
        stream.sendall(('GET /' + token + '/clash.yaml HTTP/1.1\r\nHost: ' + (host or 'localhost') + '\r\nConnection: close\r\n\r\n').encode())
        response = http.client.HTTPResponse(stream)
        response.begin()
        if response.status != 200 or not response.read():
            sys.exit('订阅本机自检失败：未返回有效配置，请检查订阅服务日志。')
except (OSError, ssl.SSLError, http.client.HTTPException):
    sys.exit('订阅本机自检失败：请检查监听端口、证书和订阅服务日志。')
print('✅ 订阅本机自检通过' + ('（HTTPS 证书验证成功）' if cert else '（HTTP）'))
PY
    [ "$?" -eq 0 ] || error_exit "订阅服务未通过自检"
    echo "请从客户端访问打印的订阅链接，确认公网 DNS、安全组和 NAT 映射；本机自检不代表公网可达。"
}
# END subscription HTTPS wizard


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


# SOCKS5 账号：用户名做基础兼容校验；密码不做强度/长度限制（仅非空）
# 用户名: 1-64，字母数字._@+-
# 密码: 任意非空字符串（允许纯数字/短密码，兼容 TG 等场景）
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
    # 不做长度/复杂度/弱口令校验，仅要求非空
    if [ -z "$p" ]; then
        echo "密码不能为空" >&2
        return 1
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
                SOCKS_PASS=$(prompt_input "SOCKS5 密码（任意非空，不做强度校验）" "")
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
    if [ "$SOCKS_PORT" = "$CLASH_SUB_PORT" ]; then
        error_exit "SOCKS5 端口不能与订阅端口相同 ($CLASH_SUB_PORT)"
    fi

    # 用户名/密码：启用则必填；密码不做强度校验
    echo "账号要求: 用户名 1-64（字母数字._@+-）；密码任意非空（不做长度/复杂度校验）"
    prompt_socks_credentials

    su_esc=$(json_escape "$SOCKS_USER") || error_exit "SOCKS user escape failed"
    sp_esc=$(json_escape "$SOCKS_PASS") || error_exit "SOCKS pass escape failed"

    # Do not inject JSON via heredoc; merge with jq after base config is written
    SOCKS_INBOUND_JSON="1"
    SOCKS_USER_ESC="$su_esc"
    SOCKS_PASS_ESC="$sp_esc"

    SOCKS_INFO_TEXT=$(printf '%s\n' \
        "SOCKS5 enabled" \
        "  port: ${SOCKS_PORT}" \
        "  user: ${SOCKS_USER}" \
        "  pass: ${SOCKS_PASS}" \
        "  auth: username/password" \
        "  NOTE: open cloud SG / LXD map for TCP ${SOCKS_PORT} separately")

    echo "SOCKS5 will be added on 0.0.0.0:${SOCKS_PORT} (user=${SOCKS_USER})"
}




# Alpine 安装流程（OpenRC / apk）。
install_alpine() (
set -eu
# 1. 环境准备与依赖安装
echo "正在安装基础依赖..."
run_cmd apk update
run_cmd apk add curl gcompat ca-certificates unzip openrc iproute2 chrony openssl bind-tools python3 jq

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
if ! "$XRAY_BIN" version </dev/null > /dev/null 2>&1; then
    error_exit "Xray 二进制文件损坏或架构不兼容"
fi
echo "Xray 版本: $("$XRAY_BIN" version </dev/null 2>/dev/null | head -n 1)"

# 3. 动态生成身份凭证（安全提取）
echo "正在生成加密密钥..."
USER_UUID=$("$XRAY_BIN" uuid </dev/null)

KEYS_OUTPUT=$("$XRAY_BIN" x25519 </dev/null)
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

# 3.8 可选 SOCKS5 入站
configure_socks_optional

# 4. 生成 Xray 配置文件
# 说明：
# - 默认监听 0.0.0.0，避免某些 LXC/NAT 环境只绑 loopback
# - 日志改为 warning + 文件，便于排查“端口通但连不上 / 延迟 -1ms”
# - shortIds 同时保留空值和固定值，兼容部分客户端默认空 shortId
echo "正在生成配置文件..."
echo "  (写入 $XRAY_CONFIG )"
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
echo "  基础配置已写入"

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

# Merge SOCKS5 inbound with jq when enabled
if [ "${ENABLE_SOCKS:-0}" = "1" ]; then
    if ! command -v jq >/dev/null 2>&1; then
        error_exit "SOCKS5 requires jq"
    fi
    tmp_cfg="${XRAY_CONFIG}.socks.tmp"
    if ! jq \
        --argjson port "$SOCKS_PORT" \
        --arg user "$SOCKS_USER" \
        --arg pass "$SOCKS_PASS" \
        '.inbounds += [{
            tag: "socks-in",
            listen: "0.0.0.0",
            port: $port,
            protocol: "socks",
            settings: {
                auth: "password",
                accounts: [{user: $user, pass: $pass}],
                udp: true
            },
            sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic"]
            }
        }]' \
        "$XRAY_CONFIG" > "$tmp_cfg"; then
        rm -f "$tmp_cfg" 2>/dev/null || true
        error_exit "failed to merge SOCKS5 inbound with jq"
    fi
    mv "$tmp_cfg" "$XRAY_CONFIG"
    if ! jq -e --argjson port "$SOCKS_PORT" '.inbounds[] | select(.protocol=="socks" and .port==$port)' "$XRAY_CONFIG" >/dev/null; then
        error_exit "SOCKS5 inbound missing after merge"
    fi
    echo "SOCKS5 inbound merged (port=$SOCKS_PORT)"
    jq '.inbounds[] | select(.protocol=="socks") | {tag,listen,port,protocol,auth:.settings.auth,udp:.settings.udp,user:.settings.accounts[0].user}' "$XRAY_CONFIG" 2>/dev/null || true
fi

# 配置测试
if ! "$XRAY_BIN" run -test -c "$XRAY_CONFIG" </dev/null >/tmp/xray-test.out 2>&1; then
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
if [ "${ENABLE_SOCKS:-0}" = "1" ]; then
    open_firewall_port "$SOCKS_PORT"
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
# SOCKS5 local self-check
if [ "${ENABLE_SOCKS:-0}" = "1" ]; then
    echo ""
    echo "Checking SOCKS5 locally..."
    if command -v ss >/dev/null 2>&1; then
        if ss -tln 2>/dev/null | grep -Eq ":${SOCKS_PORT}\\b"; then
            echo "SOCKS port ${SOCKS_PORT} is listening"
            ss -tlnp 2>/dev/null | grep -E ":${SOCKS_PORT}\\b" || true
        else
            echo "SOCKS port ${SOCKS_PORT} NOT listening"
        fi
    fi
    socks_ok=0
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS --connect-timeout 8 --max-time 15 \
            --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
            -U "${SOCKS_USER}:${SOCKS_PASS}" \
            "https://api.ipify.org" >/tmp/socks-test.out 2>/tmp/socks-test.err; then
            _socks_ip=$(tr -d '\r\n' </tmp/socks-test.out 2>/dev/null || true)
            echo "SOCKS5 local proxy OK, egress IP: ${_socks_ip}"
            socks_ok=1
        elif curl -fsS --connect-timeout 8 --max-time 15 \
            -x "socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${SOCKS_PORT}" \
            "https://api.ipify.org" >/tmp/socks-test.out 2>/tmp/socks-test.err; then
            _socks_ip=$(tr -d '\r\n' </tmp/socks-test.out 2>/dev/null || true)
            echo "SOCKS5 local proxy OK, egress IP: ${_socks_ip}"
            socks_ok=1
        fi
    fi
    if [ "$socks_ok" -ne 1 ]; then
        echo "SOCKS5 local proxy test FAILED"
        tail -n 50 "$XRAY_LOG" 2>/dev/null || true
        [ -f /tmp/socks-test.err ] && cat /tmp/socks-test.err 2>/dev/null || true
    fi

    echo "======================================================"
    echo "CRITICAL: SOCKS port is NOT the same as Reality port"
    echo "  Reality may work on TCP ${PORT}, while SOCKS needs TCP ${SOCKS_PORT}"
    echo "  LXD/NAT/security-group usually allow ports ONE BY ONE"
    echo "  ss listening inside container != reachable from internet"
    echo "======================================================"
    echo "Do these now on HOST (not only inside container):"
    echo "  1) Cloud security group: allow inbound TCP ${SOCKS_PORT}"
    echo "  2) LXD proxy (host):"
    echo "     lxc config device add ${HOSTNAME:-INSTANCE} socks${SOCKS_PORT} proxy listen=tcp:0.0.0.0:${SOCKS_PORT} connect=tcp:127.0.0.1:${SOCKS_PORT}"
    echo "     # if connect fails, try container eth IP instead of 127.0.0.1"
    echo "  3) From your PC (not VPS):"
    echo "     Test-NetConnection -ComputerName <PUBLIC_IP> -Port ${PORT}"
    echo "     Test-NetConnection -ComputerName <PUBLIC_IP> -Port ${SOCKS_PORT}"
    echo "     # Expect BOTH True. If 52300 True and ${SOCKS_PORT} False => mapping/SG issue"
    echo "  4) Inside container local SOCKS proof:"
    echo "     curl -fsS --socks5-hostname 127.0.0.1:${SOCKS_PORT} -U \"${SOCKS_USER}:${SOCKS_PASS}\" https://api.ipify.org"
fi

echo "正在获取公网 IP..."
CLEAR_IP=$(get_public_ip)

# 生成可导入的分享链接，减少手工填错（这是 -1ms 的高发原因）
PBK_ENC=$(urlencode "$PUB_KEY")
SHARE_LINK="vless://${USER_UUID}@${CLEAR_IP}:${NODE_PUBLIC_PORT:-$PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PBK_ENC}&sid=${SHORT_ID}&type=tcp#Alpine-Reality-${PORT}"
cat > "$SHARE_FILE" << LINKEOF
地址 (Address): $CLEAR_IP
端口 (Port): ${NODE_PUBLIC_PORT:-$PORT}
容器监听端口: $PORT
用户 ID (UUID): $USER_UUID
流控 (Flow): xtls-rprx-vision
传输安全 (Security): reality
SNI: $SNI（多地域严格校验后的最优选择）
公钥 (PublicKey / pbk): $PUB_KEY
ShortID (sid): $SHORT_ID
Fingerprint (fp): chrome
网络 (Network): tcp

$SOCKS_INFO_TEXT

分享链接:
$SHARE_LINK
LINKEOF

configure_subscription_https
write_client_routing_files
start_clash_sub_service
subscription_verify_local

cat << EOF
-------------------------------------------------------
✅ 安装成功！请妥善保存以下连接参数：
-------------------------------------------------------
地址 (Address): $CLEAR_IP
端口 (Port): ${NODE_PUBLIC_PORT:-$PORT}
容器监听端口: $PORT
用户 ID (UUID): $USER_UUID
流控 (Flow): xtls-rprx-vision
传输安全 (Security): reality
SNI: $SNI
公钥 (PublicKey): $PUB_KEY
ShortID: $SHORT_ID
Fingerprint: chrome
网络 (Network): tcp

$SOCKS_INFO_TEXT
-------------------------------------------------------
📎 一键分享链接（推荐直接导入客户端，避免手填错误）:
$SHARE_LINK

参数已保存: $SHARE_FILE
-------------------------------------------------------
🧭 Clash 订阅（本机提供，不经过第三方转换站）:
$CLASH_SUB_URL

v2rayN 原生 VLESS 订阅（推荐 v2rayN 使用，节点内核选 Xray）:
$V2RAYN_SUB_URL

  用法: Clash Verge / mihomo → 新建订阅 → 粘贴上面链接 → 更新
        模式保持「规则」，不要开全局
        云安全组 / 宿主机映射请放行 TCP $CLASH_SUB_PORT
        链接带随机口令，不要发给别人、不要发到公开处
  规则: ACL4SSR_Online（配置在你自己的 VPS 上生成）
  本地备份: $CLASH_FILE
  证书迁移: 使用最新版脚本 --export-cert /root/sub-cert.p12 导出加密备份
            新机器安装时选「导入加密证书备份」，导入后按提示配置续期
-------------------------------------------------------
🚨 客户端延迟一直是 -1ms 时，按这个顺序查（90% 是前 3 项）:
  1) 云厂商安全组 / 防火墙是否放行 TCP $PORT 入站
  2) LXC 宿主机是否做了端口映射/转发到容器 $PORT
  3) 客户端地址是否填【公网 IP】而不是容器内网 IP
  4) PublicKey 必须用上面输出（来自新版 x25519 的 Password 字段）
  5) Flow=xtls-rprx-vision, fp=chrome, sid=$SHORT_ID, sni=$SNI
  6) 服务器时间误差 < 90 秒: date / chronyc tracking
  7) 本机诊断: sh xray.sh，选择 4
  8) 日志: tail -n 100 $XRAY_LOG
-------------------------------------------------------
🔒 安全提示:
  • 请不要在公共评论区贴出以上信息！
  • 配置文件位于: $XRAY_CONFIG
  • Clash 分流配置: $CLASH_FILE
  • Xray 客户端分流: $XRAY_CLIENT_FILE
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

)

# Debian 安装流程（systemd / apt）。
install_debian() (
set -eu
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

if ! "$XRAY_BIN" version </dev/null >/dev/null 2>&1; then
    error_exit "Xray 二进制文件损坏或架构不兼容"
fi
echo "Xray 版本: $("$XRAY_BIN" version </dev/null 2>/dev/null | head -n 1)"

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
USER_UUID=$("$XRAY_BIN" uuid </dev/null)
KEYS_OUTPUT=$("$XRAY_BIN" x25519 </dev/null)

echo "调试信息 - Xray x25519 输出:" >&2
echo "$KEYS_OUTPUT" >&2

KEY_LINES=$(extract_reality_keys "$KEYS_OUTPUT")
PRIV_KEY=$(printf '%s\n' "$KEY_LINES" | sed -n '1p')
PUB_KEY=$(printf '%s\n' "$KEY_LINES" | sed -n '2p')

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
echo "  (写入 $XRAY_CONFIG )"
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
echo "  基础配置已写入"

if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
    error_exit "配置文件 JSON 格式错误"
fi
echo "✅ 配置文件 JSON 格式验证通过"

# Merge SOCKS5 inbound with jq when enabled
if [ "${ENABLE_SOCKS:-0}" = "1" ]; then
    if ! command -v jq >/dev/null 2>&1; then
        error_exit "SOCKS5 requires jq"
    fi
    tmp_cfg="${XRAY_CONFIG}.socks.tmp"
    if ! jq \
        --argjson port "$SOCKS_PORT" \
        --arg user "$SOCKS_USER" \
        --arg pass "$SOCKS_PASS" \
        '.inbounds += [{
            tag: "socks-in",
            listen: "0.0.0.0",
            port: $port,
            protocol: "socks",
            settings: {
                auth: "password",
                accounts: [{user: $user, pass: $pass}],
                udp: true
            },
            sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic"]
            }
        }]' \
        "$XRAY_CONFIG" > "$tmp_cfg"; then
        rm -f "$tmp_cfg" 2>/dev/null || true
        error_exit "failed to merge SOCKS5 inbound with jq"
    fi
    mv "$tmp_cfg" "$XRAY_CONFIG"
    if ! jq -e --argjson port "$SOCKS_PORT" '.inbounds[] | select(.protocol=="socks" and .port==$port)' "$XRAY_CONFIG" >/dev/null; then
        error_exit "SOCKS5 inbound missing after merge"
    fi
    echo "SOCKS5 inbound merged (port=$SOCKS_PORT)"
    jq '.inbounds[] | select(.protocol=="socks") | {tag,listen,port,protocol,auth:.settings.auth,udp:.settings.udp,user:.settings.accounts[0].user}' "$XRAY_CONFIG" 2>/dev/null || true
fi

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

if ! "$XRAY_BIN" run -test -c "$XRAY_CONFIG" </dev/null >/tmp/xray-test.out 2>&1; then
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
# SOCKS5 local self-check
if [ "${ENABLE_SOCKS:-0}" = "1" ]; then
    echo ""
    echo "Checking SOCKS5 locally..."
    if command -v ss >/dev/null 2>&1; then
        if ss -tln 2>/dev/null | grep -Eq ":${SOCKS_PORT}\\b"; then
            echo "SOCKS port ${SOCKS_PORT} is listening"
            ss -tlnp 2>/dev/null | grep -E ":${SOCKS_PORT}\\b" || true
        else
            echo "SOCKS port ${SOCKS_PORT} NOT listening"
        fi
    fi
    socks_ok=0
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS --connect-timeout 8 --max-time 15 \
            --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
            -U "${SOCKS_USER}:${SOCKS_PASS}" \
            "https://api.ipify.org" >/tmp/socks-test.out 2>/tmp/socks-test.err; then
            _socks_ip=$(tr -d '\r\n' </tmp/socks-test.out 2>/dev/null || true)
            echo "SOCKS5 local proxy OK, egress IP: ${_socks_ip}"
            socks_ok=1
        elif curl -fsS --connect-timeout 8 --max-time 15 \
            -x "socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${SOCKS_PORT}" \
            "https://api.ipify.org" >/tmp/socks-test.out 2>/tmp/socks-test.err; then
            _socks_ip=$(tr -d '\r\n' </tmp/socks-test.out 2>/dev/null || true)
            echo "SOCKS5 local proxy OK, egress IP: ${_socks_ip}"
            socks_ok=1
        fi
    fi
    if [ "$socks_ok" -ne 1 ]; then
        echo "SOCKS5 local proxy test FAILED"
        tail -n 50 "$XRAY_LOG" 2>/dev/null || true
        [ -f /tmp/socks-test.err ] && cat /tmp/socks-test.err 2>/dev/null || true
    fi

    echo "======================================================"
    echo "CRITICAL: SOCKS port is NOT the same as Reality port"
    echo "  Reality may work on TCP ${PORT}, while SOCKS needs TCP ${SOCKS_PORT}"
    echo "  LXD/NAT/security-group usually allow ports ONE BY ONE"
    echo "  ss listening inside container != reachable from internet"
    echo "======================================================"
    echo "Do these now on HOST (not only inside container):"
    echo "  1) Cloud security group: allow inbound TCP ${SOCKS_PORT}"
    echo "  2) LXD proxy (host):"
    echo "     lxc config device add ${HOSTNAME:-INSTANCE} socks${SOCKS_PORT} proxy listen=tcp:0.0.0.0:${SOCKS_PORT} connect=tcp:127.0.0.1:${SOCKS_PORT}"
    echo "     # if connect fails, try container eth IP instead of 127.0.0.1"
    echo "  3) From your PC (not VPS):"
    echo "     Test-NetConnection -ComputerName <PUBLIC_IP> -Port ${PORT}"
    echo "     Test-NetConnection -ComputerName <PUBLIC_IP> -Port ${SOCKS_PORT}"
    echo "     # Expect BOTH True. If 52300 True and ${SOCKS_PORT} False => mapping/SG issue"
    echo "  4) Inside container local SOCKS proof:"
    echo "     curl -fsS --socks5-hostname 127.0.0.1:${SOCKS_PORT} -U \"${SOCKS_USER}:${SOCKS_PASS}\" https://api.ipify.org"
fi

echo "正在获取公网 IP..."
CLEAR_IP=$(get_public_ip)
PBK_ENC=$(urlencode "$PUB_KEY")
SHARE_LINK="vless://${USER_UUID}@${CLEAR_IP}:${NODE_PUBLIC_PORT:-$PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PBK_ENC}&sid=${SHORT_ID}&type=tcp#Debian-Reality-${PORT}"

cat > "$SHARE_FILE" << LINKEOF
地址 (Address): $CLEAR_IP
端口 (Port): ${NODE_PUBLIC_PORT:-$PORT}
容器监听端口: $PORT
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

configure_subscription_https
write_client_routing_files
start_clash_sub_service
subscription_verify_local

cat << EOF
-------------------------------------------------------
✅ 安装成功！请妥善保存以下连接参数：
-------------------------------------------------------
地址 (Address): $CLEAR_IP
端口 (Port): ${NODE_PUBLIC_PORT:-$PORT}
容器监听端口: $PORT
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
🧭 Clash 订阅（本机提供，不经过第三方转换站）:
$CLASH_SUB_URL

v2rayN 原生 VLESS 订阅（推荐 v2rayN 使用，节点内核选 Xray）:
$V2RAYN_SUB_URL

  用法: Clash Verge / mihomo → 新建订阅 → 粘贴上面链接 → 更新
        模式保持「规则」，不要开全局
        云安全组 / 宿主机映射请放行 TCP $CLASH_SUB_PORT
        链接带随机口令，不要发给别人、不要发到公开处
  规则: ACL4SSR_Online（配置在你自己的 VPS 上生成）
  本地备份: $CLASH_FILE
  证书迁移: 使用最新版脚本 --export-cert /root/sub-cert.p12 导出加密备份
            新机器安装时选「导入加密证书备份」，导入后按提示配置续期
-------------------------------------------------------
🚨 客户端延迟一直是 -1ms 时，按这个顺序查（90% 是前 3 项）:
  1) 云厂商安全组 / 防火墙是否放行 TCP $PORT 入站
  2) LXD 宿主机是否 proxy device / 端口映射到容器 $PORT
     例: lxc config device add <实例名> xrayproxy proxy listen=tcp:0.0.0.0:$PORT connect=tcp:127.0.0.1:$PORT
  3) 客户端地址是否填【公网 IP】，不要填容器内网 IP（10.x/100.x）
  4) PublicKey 用上面输出（新版 x25519 的 Password 字段）；不要填 Hash32
  5) Flow=xtls-rprx-vision, fp=chrome, sid=$SHORT_ID, sni=$SNI, network=tcp
  6) 服务器时间误差 < 90 秒: timedatectl / chronyc tracking
  7) 本机诊断: sh xray.sh，选择 4
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
   • Clash 分流: cat $CLASH_FILE
   • Xray 客户端分流: cat $XRAY_CLIENT_FILE

🔧 更换 SNI（如需调整）:
   编辑配置文件，在 realitySettings 中修改：
   "dest": "新域名:443"
   "serverNames": ["新域名"]
   然后运行: systemctl restart xray.service
-------------------------------------------------------
EOF

)

load_node_settings() {
# 使用 shlex 编码后再读取，节点或环境文件中的内容不能成为 shell 命令。
python3 - "$XRAY_CONFIG" "$SHARE_FILE" "${SUB_ENV:-/etc/xray/clash-sub.env}" <<'PY'
import ipaddress
import json
import os
import re
import shlex
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

config = json.loads(Path(sys.argv[1]).read_text())
links = re.findall(r'^vless://\S+', Path(sys.argv[2]).read_text(), re.M)
saved = {}
if Path(sys.argv[3]).is_file():
    for line in Path(sys.argv[3]).read_text().splitlines():
        key, sep, value = line.partition('=')
        if sep:
            saved[key] = value.strip()
selected = None
for link in links:
    uri = urlsplit(link)
    query = parse_qs(uri.query, keep_blank_values=True)
    for inbound in config.get('inbounds', []):
        reality = inbound.get('streamSettings', {}).get('realitySettings', {})
        clients = inbound.get('settings', {}).get('clients', [])
        if (inbound.get('protocol') == 'vless'
                and uri.port == int(saved.get('NODE_PUBLIC_PORT') or inbound.get('port', 0))
                and any(c.get('id') == uri.username and c.get('flow') == query.get('flow', [''])[0] for c in clients)
                and query.get('sni', [''])[0] in reality.get('serverNames', [])
                and query.get('sid', [''])[0] in reality.get('shortIds', [])
                and query.get('security') == ['reality']
                and query.get('flow') == ['xtls-rprx-vision']
                and query.get('type') == ['tcp']
                and query.get('fp') == ['chrome']
                and query.get('pbk', [''])[0]):
            selected = (link, uri, query)
            break
    if selected:
        break
if not selected:
    sys.exit('找不到与现有 Xray 配置匹配的 VLESS 分享链接；停止更新，未改动 Xray')
link, uri, query = selected
if ipaddress.ip_address(uri.hostname).version != 4:
    sys.exit('当前订阅模板需要原节点的公网 IPv4 地址')
values = dict(SHARE_LINK=link, CLEAR_IP=uri.hostname, PORT=str(inbound['port']),
              NODE_PUBLIC_PORT=str(uri.port),
              XRAY_LOG_LEVEL=config.get('log', {}).get('loglevel', 'warning'),
              USER_UUID=uri.username, SNI=query['sni'][0],
              SHORT_ID=query.get('sid', [''])[0], PUB_KEY=query['pbk'][0])
allowed = {'CLASH_SUB_PORT', 'CLASH_SUB_PUBLIC_PORT', 'CLASH_SUB_TOKEN', 'CLASH_SUB_HOST', 'CLASH_SUB_TLS_CERT', 'CLASH_SUB_TLS_KEY'}
for key in allowed:
    if key in os.environ:
        values[key] = os.environ[key]
    elif key in saved:
        values[key] = saved[key]
for key, value in values.items():
    print(key + '=' + shlex.quote(value))
PY
}

# 使用现有节点重新生成订阅。
update_subscription() (
    set -eu
    umask 077
    for cmd in python3 base64; do
        command -v "$cmd" >/dev/null || error_exit "缺少命令: $cmd；请先安装本项目 Xray"
    done
    SUB_ENV="$XRAY_DIR/clash-sub.env"
    task_tmp=$(mktemp -d)
    trap 'rm -rf -- "$task_tmp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
load_node_settings > "$task_tmp/node.env"
. "$task_tmp/node.env"
if [ "$CLASH_SUB_HTTPS" = auto ]; then
    if [ -n "$CLASH_SUB_TLS_CERT$CLASH_SUB_TLS_KEY" ]; then
        CLASH_SUB_HTTPS=existing
    else
        CLASH_SUB_HTTPS=off
    fi
fi
CLASH_SUB_PORT="${CLASH_SUB_PORT:-58472}"
CLASH_SUB_TOKEN="${CLASH_SUB_TOKEN:-}"
CLASH_SUB_HOST="${CLASH_SUB_HOST:-}"
CLASH_SUB_TLS_CERT="${CLASH_SUB_TLS_CERT:-}"
CLASH_SUB_TLS_KEY="${CLASH_SUB_TLS_KEY:-}"

configure_subscription_https

backup_dir="$XRAY_DIR/subscription-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup_dir"
for file in "$SHARE_FILE" "$CLASH_FILE" "$XRAY_CLIENT_FILE" "$V2RAYN_SUB_FILE" "$SUB_ENV" /usr/local/bin/xray-clash-sub.py; do
    [ ! -f "$file" ] || cp -p "$file" "$backup_dir/"
done
write_client_routing_files
start_clash_sub_service
if [ "$XRAY_PLATFORM" = debian ]; then
    systemctl is-active --quiet xray-clash-sub.service || error_exit "订阅服务启动失败，请检查证书、端口和服务日志"
else
    pgrep -f /usr/local/bin/xray-clash-sub.py >/dev/null || error_exit "订阅服务启动失败，请检查 /var/log/xray-clash-sub.log"
fi
subscription_verify_local
echo "订阅已更新。原有订阅文件备份: $backup_dir"
echo "保留 Clash 策略组：使用 clash.yaml，内核为 mihomo；原生 VLESS：使用 vless.txt，内核选择 Xray。"
echo "若从 HTTP 切换至 HTTPS，请在客户端替换订阅地址后更新。"

)

run_diagnostic() (
set +eu
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "🔍 Xray REALITY 诊断工具"
echo "   目标现象: 客户端延迟 = -1ms / 连接失败"
echo "=========================================="
echo ""

XRAY_CONFIG="${XRAY_CONFIG:-/etc/xray/config.json}"
XRAY_LOG="${XRAY_LOG:-/var/log/xray.log}"
SHARE_FILE="${SHARE_FILE:-/etc/xray/client-link.txt}"
SCORE_OK=0
SCORE_WARN=0
SCORE_BAD=0

ok() { echo -e "${GREEN}✅ $1${NC}"; SCORE_OK=$((SCORE_OK + 1)); }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; SCORE_WARN=$((SCORE_WARN + 1)); }
bad() { echo -e "${RED}❌ $1${NC}"; SCORE_BAD=$((SCORE_BAD + 1)); }

if [ ! -f "$XRAY_CONFIG" ]; then
    bad "未找到配置文件: $XRAY_CONFIG"
    echo "请确认已运行安装脚本，或 export XRAY_CONFIG=/path/to/config.json"
    exit 1
fi

XRAY_PORT=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$XRAY_CONFIG" | head -1)
SNI=$(sed -n 's/.*"serverNames"[[:space:]]*:[[:space:]]*\[[[:space:]]*"\([^"]*\)".*/\1/p' "$XRAY_CONFIG" | head -1)
PRIV_KEY=$(sed -n 's/.*"privateKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$XRAY_CONFIG" | head -1)
SHORT_ID=$(sed -n 's/.*"shortIds"[[:space:]]*:[[:space:]]*\[[[:space:]]*"\([^"]*\)".*/\1/p' "$XRAY_CONFIG" | head -1)
# shortIds 可能以 "" 开头，再取下一个非空
if [ -z "$SHORT_ID" ]; then
    SHORT_ID=$(grep -o '"shortIds"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$XRAY_CONFIG" | head -1 | grep -o '"[0-9a-fA-F]*"' | tr -d '"' | grep -v '^$' | head -1)
fi
DEST=$(sed -n 's/.*"dest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$XRAY_CONFIG" | head -1)
UUID=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$XRAY_CONFIG" | head -1)
LISTEN=$(sed -n 's/.*"listen"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$XRAY_CONFIG" | head -1)
FLOW=$(sed -n 's/.*"flow"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$XRAY_CONFIG" | head -1)

[ -z "$XRAY_PORT" ] && XRAY_PORT="52300"
XRAY_PUBLIC_PORT=$(sed -n 's/^NODE_PUBLIC_PORT=\([0-9][0-9]*\)$/\1/p' "$XRAY_DIR/clash-sub.env" 2>/dev/null | head -n 1)
validate_port "$XRAY_PUBLIC_PORT" || XRAY_PUBLIC_PORT="$XRAY_PORT"
[ -z "$SNI" ] && SNI="unknown"
[ -z "$LISTEN" ] && LISTEN="(未显式配置，默认 0.0.0.0)"

echo "配置摘要"
echo "  配置文件: $XRAY_CONFIG"
echo "  监听: $LISTEN"
echo "  容器监听端口: $XRAY_PORT；公网客户端端口: $XRAY_PUBLIC_PORT"
echo "  UUID: ${UUID:-未读到}"
echo "  Flow: ${FLOW:-未读到}"
echo "  SNI: $SNI"
echo "  dest: ${DEST:-未读到}"
echo "  ShortId: ${SHORT_ID:-未读到}"
echo "  PrivateKey 长度: $(printf %s "$PRIV_KEY" | wc -c | tr -d ' ')"
echo ""

# 1. 进程 / 服务状态
echo "=========================================="
echo "1️⃣  服务/进程状态"
echo "=========================================="
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^xray.service'; then
    if systemctl is-active --quiet xray.service; then
        ok "systemd: xray.service 为 active"
    else
        bad "systemd: xray.service 未运行"
        systemctl status xray.service --no-pager -l 2>/dev/null | head -n 20 || true
    fi
elif command -v rc-service >/dev/null 2>&1; then
    if pgrep -f "xray run" >/dev/null 2>&1 || ps 2>/dev/null | grep -q "[x]ray run"; then
        ok "检测到 xray 进程（OpenRC/local.d）"
    else
        bad "未检测到 xray 进程"
        echo "尝试: rc-service local restart"
    fi
else
    if pgrep -f "xray" >/dev/null 2>&1 || ps 2>/dev/null | grep -q "[x]ray"; then
        ok "检测到 xray 相关进程"
    else
        bad "未检测到 xray 进程 —— 客户端会显示 -1ms"
    fi
fi
echo ""

# 2. 端口监听（-1ms 最关键）
echo "=========================================="
echo "2️⃣  端口监听检查（-1ms 高发点）"
echo "=========================================="
LISTEN_INFO=""
if command -v ss >/dev/null 2>&1; then
    LISTEN_INFO=$(ss -tlnp 2>/dev/null | grep -E ":${XRAY_PORT}\\b" || true)
elif command -v netstat >/dev/null 2>&1; then
    LISTEN_INFO=$(netstat -tlnp 2>/dev/null | grep -E ":${XRAY_PORT}\\b" || true)
fi

if [ -n "$LISTEN_INFO" ]; then
    ok "端口 $XRAY_PORT 正在监听"
    echo "$LISTEN_INFO"
    if echo "$LISTEN_INFO" | grep -q '127.0.0.1'; then
        if ! echo "$LISTEN_INFO" | grep -Eq '0\.0\.0\.0|\*'; then
            bad "似乎只监听 127.0.0.1 —— 外网必然 -1ms。请把 listen 改为 0.0.0.0"
        fi
    fi
else
    bad "端口 $XRAY_PORT 未监听 —— 客户端延迟几乎一定是 -1ms"
fi
echo ""

# 3. 本机回环连通
echo "=========================================="
echo "3️⃣  本机 TCP 连通"
echo "=========================================="
LOCAL_OK=0
if command -v nc >/dev/null 2>&1; then
    if nc -z -w 3 127.0.0.1 "$XRAY_PORT" 2>/dev/null; then
        ok "127.0.0.1:$XRAY_PORT TCP 可连接"
        LOCAL_OK=1
    fi
fi
if [ "$LOCAL_OK" -eq 0 ] && command -v timeout >/dev/null 2>&1; then
    if timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/$XRAY_PORT" 2>/dev/null; then
        ok "127.0.0.1:$XRAY_PORT TCP 可连接"
        LOCAL_OK=1
    fi
fi
if [ "$LOCAL_OK" -eq 0 ]; then
    warn "本机 TCP 探测失败（REALITY 可能不回普通探测，结合监听结果判断）"
fi
echo ""

# 4. 防火墙
echo "=========================================="
echo "4️⃣  本机防火墙"
echo "=========================================="
if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(ufw status 2>/dev/null || true)
    echo "$UFW_STATUS" | head -n 5
    if echo "$UFW_STATUS" | grep -qi "Status: active"; then
        if echo "$UFW_STATUS" | grep -q "$XRAY_PORT"; then
            ok "ufw 已放行 $XRAY_PORT"
        else
            bad "ufw 已启用但未见 $XRAY_PORT —— 外网会 -1ms"
            echo "修复: sudo ufw allow ${XRAY_PORT}/tcp && sudo ufw reload"
        fi
    else
        ok "ufw 未启用（或 inactive）"
    fi
fi

if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then
    if firewall-cmd --list-ports 2>/dev/null | grep -q "$XRAY_PORT"; then
        ok "firewalld 已放行 $XRAY_PORT"
    else
        bad "firewalld 运行中但可能未放行 $XRAY_PORT"
        echo "修复: firewall-cmd --permanent --add-port=${XRAY_PORT}/tcp && firewall-cmd --reload"
    fi
fi

if command -v iptables >/dev/null 2>&1; then
    echo "iptables INPUT 摘要:"
    iptables -L INPUT -n 2>/dev/null | head -n 12 || true
    if iptables -C INPUT -p tcp --dport "$XRAY_PORT" -j ACCEPT 2>/dev/null; then
        ok "iptables 存在 ${XRAY_PORT}/tcp ACCEPT"
    else
        warn "未找到显式 iptables ACCEPT（若默认策略不是 DROP 可能仍可用）"
    fi
fi
echo ""
warn "容器内防火墙通过 ≠ 外网可达。还必须查：云安全组 + 宿主机端口映射/NAT"
echo ""

# 5. 公网 IP 与地址填写提示
echo "=========================================="
echo "5️⃣  公网 IP / 地址填写"
echo "=========================================="
PUB_IP=""
for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipv4.icanhazip.com"; do
    PUB_IP=$(curl -4 -fsS --connect-timeout 4 --max-time 6 "$url" 2>/dev/null | tr -d '\r\n' || true)
    echo "$PUB_IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && break
    PUB_IP=""
done
LOCAL_IPS=$(ip -4 addr 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | grep -v '^127\.' || true)
echo "检测到的公网 IP: ${PUB_IP:-获取失败}"
echo "容器/主机内网 IP:"
echo "${LOCAL_IPS:-无}"
if [ -n "$PUB_IP" ]; then
    ok "可用公网 IP 参考: $PUB_IP"
    echo "客户端 Address 应填公网 IP（或域名），不要填 10.x / 100.x / 172.16-31.x 内网地址"
else
    warn "无法获取公网 IP（NAT 常见）。客户端请填【宿主机公网 IP】"
fi
if [ -f "$SHARE_FILE" ]; then
    echo "分享参数文件: $SHARE_FILE"
    head -n 20 "$SHARE_FILE" 2>/dev/null || true
fi
echo ""

# 6. MTU
echo "=========================================="
echo "6️⃣  MTU"
echo "=========================================="
DEFAULT_DEV=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -1)
if [ -n "$DEFAULT_DEV" ]; then
    MTU=$(ip link show "$DEFAULT_DEV" 2>/dev/null | sed -n 's/.*mtu \([0-9][0-9]*\).*/\1/p')
    echo "网卡: $DEFAULT_DEV  MTU: ${MTU:-未知}"
    if [ "$MTU" = "1380" ] || [ "$MTU" = "1500" ] || [ "$MTU" = "1450" ] || [ "$MTU" = "1400" ]; then
        ok "MTU 看起来合理"
    else
        warn "MTU 值异常，可尝试: ip link set dev $DEFAULT_DEV mtu 1380"
    fi
else
    warn "无法检测默认网卡"
fi
echo ""

# 7. SNI / dest 可达
echo "=========================================="
echo "7️⃣  伪装目标 SNI/dest 严格校验（-1ms 高发根因）"
echo "=========================================="
echo "目标: SNI=$SNI  dest=${DEST:-$SNI:443}"
SNI_BAD=0
if [ -z "$SNI" ] || [ "$SNI" = "unknown" ]; then
    bad "未读到 serverNames/SNI"
    SNI_BAD=1
else
    # DNS
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup "$SNI" >/dev/null 2>&1; then
            ok "DNS 可解析: $SNI"
        else
            bad "DNS 无法解析 $SNI"
            SNI_BAD=1
        fi
    fi
    # TCP 443
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 4 "$SNI" 443 >/dev/null 2>&1; then
            ok "TCP 443 可达"
        else
            bad "TCP 443 不可达 —— Reality dest 失败会直接导致客户端 -1ms"
            SNI_BAD=1
        fi
    fi
    # HTTPS
    CODE=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 8 -I "https://$SNI" 2>/dev/null || echo "000")
    if [ "$CODE" != "000" ]; then
        ok "HTTPS 有响应 (HTTP $CODE)"
    else
        bad "HTTPS 无响应"
        SNI_BAD=1
    fi
    # TLS1.3
    if curl -sS -o /dev/null --connect-timeout 5 --max-time 8 --tlsv1.3 -I "https://$SNI" 2>/dev/null; then
        ok "TLS1.3 可用（Reality 推荐）"
    else
        warn "TLS1.3 探测失败（部分环境 curl 参数受限；建议 openssl 复核）"
    fi
    # HTTP2
    if curl -sS -o /dev/null --connect-timeout 5 --max-time 8 --http2 -I "https://$SNI" 2>/dev/null; then
        ok "HTTP/2 可用"
    else
        warn "HTTP/2 探测失败"
    fi
    if command -v openssl >/dev/null 2>&1; then
        if echo | openssl s_client -tls1_3 -connect "$SNI:443" -servername "$SNI" >/dev/null 2>&1; then
            ok "openssl TLS1.3 握手成功"
        else
            bad "openssl 无法完成 TLS1.3 握手 —— 不适合作为 Reality dest"
            SNI_BAD=1
        fi
    fi
fi
if [ "$SNI_BAD" -eq 1 ]; then
    echo "修复建议:"
    echo "  1) 重跑最新安装脚本（自动从美国/欧洲/印度/俄罗斯/亚太 30 个候选中挑选可用 SNI）"
    echo "  2) 或手动把 config.json 的 dest/serverNames 改成 VPS 能访问的站点后重启"
fi
echo ""

# 8. 配置完整性
echo "=========================================="
echo "8️⃣  配置完整性"
echo "=========================================="
if command -v jq >/dev/null 2>&1; then
    if jq empty "$XRAY_CONFIG" 2>/dev/null; then
        ok "JSON 格式正确"
    else
        bad "JSON 格式错误"
        jq empty "$XRAY_CONFIG" 2>&1 | head -5
    fi
    echo "realitySettings:"
    jq '.inbounds[0].streamSettings.realitySettings' "$XRAY_CONFIG" 2>/dev/null || true
else
    warn "未安装 jq，跳过深度 JSON 检查"
fi

if [ -z "$PRIV_KEY" ]; then
    bad "未读到 privateKey"
else
    LEN=$(printf %s "$PRIV_KEY" | wc -c | tr -d ' ')
    if [ "$LEN" -ge 40 ] && [ "$LEN" -le 64 ]; then
        ok "privateKey 长度正常 ($LEN)"
    else
        bad "privateKey 长度异常 ($LEN) —— 密钥解析可能错了"
    fi
fi

if [ -z "$UUID" ]; then
    bad "未读到 UUID"
else
    ok "UUID 存在"
fi

if [ "$FLOW" = "xtls-rprx-vision" ]; then
    ok "flow = xtls-rprx-vision"
else
    warn "flow 不是 xtls-rprx-vision（当前: ${FLOW:-空}）"
fi

if [ -z "$SHORT_ID" ]; then
    warn "未读到 shortId（若服务端 shortIds 含空字符串，客户端 sid 可留空）"
else
    ok "ShortId: $SHORT_ID"
fi
echo ""

# 9. 时间与日志
echo "=========================================="
echo "9️⃣  时间与日志（REALITY 关键）"
echo "=========================================="
echo "当前时间: $(date)"
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl 2>/dev/null | head -n 6 || true
fi
if command -v chronyc >/dev/null 2>&1; then
    chronyc tracking 2>/dev/null | head -n 8 || true
fi

# 粗略提醒：如果系统时间年份离谱
YEAR=$(date +%Y 2>/dev/null || echo 0)
if [ "$YEAR" -lt 2024 ] || [ "$YEAR" -gt 2100 ]; then
    bad "系统时间异常（年份 $YEAR）—— Reality 会直接失败"
else
    ok "系统时间年份看起来正常"
fi

if [ -f "$XRAY_LOG" ]; then
    ok "日志文件存在: $XRAY_LOG"
    echo "最近日志:"
    tail -n 40 "$XRAY_LOG" 2>/dev/null || true
else
    warn "未找到 $XRAY_LOG"
fi

if command -v journalctl >/dev/null 2>&1; then
    echo "journalctl -u xray.service 最近记录:"
    journalctl -u xray.service -n 30 --no-pager 2>/dev/null || true
fi
echo ""

# 10. 外网视角提示
echo "=========================================="
echo "🔟 外网可达性（需在【你的电脑】上测）"
echo "=========================================="
echo "下面这些命令请在客户端电脑执行，不要只在 VPS 里测："
echo "  # Windows PowerShell"
echo "  Test-NetConnection -ComputerName <公网IP> -Port $XRAY_PUBLIC_PORT"
echo "  # 或"
echo "  telnet <公网IP> $XRAY_PUBLIC_PORT"
echo "  # Linux/macOS"
echo "  nc -vz <公网IP> $XRAY_PUBLIC_PORT"
echo "  curl -v telnet://<公网IP>:$XRAY_PUBLIC_PORT"
echo ""
echo "若本机监听正常，但你电脑 Test-NetConnection 失败 = 100% 是"
echo "  云安全组 / 运营商防火墙 / LXC·LXD 端口未映射 问题，"
echo "  客户端会稳定显示延迟 -1ms。"
echo ""

# 总结
echo "=========================================="
echo "📊 诊断汇总"
echo "Reality 与 SOCKS5 是独立端口，需要分别配置安全组和 NAT 映射。"
echo "=========================================="
echo "通过: $SCORE_OK   警告: $SCORE_WARN   严重: $SCORE_BAD"
echo ""
echo "延迟 -1ms 最常见根因排序:"
echo "  1. 云安全组未放行公网 TCP $XRAY_PUBLIC_PORT"
echo "  2. LXC/LXD NAT 未做端口映射到容器"
echo "  3. 客户端填了内网 IP，或 PublicKey/UUID/ShortId/SNI 不一致"
echo "  4. 新版 Xray 把 Password 当 PublicKey；误填 Hash32 会失败"
echo "  5. 系统时间偏差过大 / dest 站点服务器访问不了"
echo "  6. xray 未真正监听 0.0.0.0:$XRAY_PORT"
echo ""
echo "建议修复命令:"
echo "  # 看监听"
echo "  ss -tlnp | grep $XRAY_PORT"
echo "  # 看日志"
echo "  tail -n 100 $XRAY_LOG"
echo "  journalctl -u xray.service -n 80 --no-pager"
echo "  # Debian LXD 端口映射示例"
echo "  lxc config device add <实例> xrayproxy proxy listen=tcp:0.0.0.0:$XRAY_PUBLIC_PORT connect=tcp:127.0.0.1:$XRAY_PORT"
echo "  # 返回管理菜单，选择 4 重新诊断；订阅问题选择 2 或 3"
echo ""
if [ "$SCORE_BAD" -gt 0 ]; then
    echo -e "${RED}结论: 发现 $SCORE_BAD 个严重问题，优先处理后再测客户端。${NC}"
    exit 2
fi
if [ "$SCORE_WARN" -gt 0 ]; then
    echo -e "${YELLOW}结论: 服务可能已起来，但仍有 $SCORE_WARN 个警告；若仍 -1ms，重点查安全组与端口映射。${NC}"
    exit 0
fi
echo -e "${GREEN}结论: 本机侧未见明显异常。若客户端仍 -1ms，基本可断定是安全组/NAT 映射/客户端参数问题。${NC}"
echo "=========================================="
echo "✅ 诊断完成"
echo "=========================================="


)

# 菜单和操作分发。各操作在子 shell 执行，失败后仍可返回菜单。
manager_read() {
    printf '%s' "$1" >&2
    IFS= read -r manager_reply <&9 || return 1
    printf '%s' "$manager_reply"
}

manager_platform() (
    if [ -f /etc/alpine-release ]; then
        printf '%s' alpine
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            debian) printf '%s' debian ;;
            *) return 1 ;;
        esac
    else
        return 1
    fi
)

manager_require_root() {
    [ "$(id -u)" = 0 ] || error_exit "请以 root 运行：sudo sh xray.sh"
}

manager_require_platform() {
    XRAY_PLATFORM=$(manager_platform) || error_exit "目前支持 Alpine Linux（OpenRC）和 Debian（systemd）"
    case "$XRAY_PLATFORM" in
        alpine) CLIENT_NODE_NAME=Alpine-Reality ;;
        debian) CLIENT_NODE_NAME=Debian-Reality ;;
    esac
}

manager_install() {
    manager_require_platform
    [ "$(uname -m)" = x86_64 ] || error_exit "当前安装包仅支持 x86_64 / amd64"
    if [ -f "$XRAY_CONFIG" ]; then
        echo "检测到已有 Xray 配置。重新安装会生成新的 UUID、密钥和订阅口令。"
        echo "更新订阅请选 2，开启 HTTPS 请选 3。"
        manager_confirm=$(manager_read '确认重新安装请输入 y，其他输入取消: ') || return 1
        case "$manager_confirm" in
            y|Y) ;;
            *) echo "已取消安装。"; return 0 ;;
        esac
    fi
    if [ -t 9 ]; then
        PORT=$(manager_read_default 'Reality 容器监听端口' "$PORT") || return 1
        NODE_PUBLIC_PORT=$(manager_read_default 'Reality NAT 公网端口' "${NODE_PUBLIC_PORT:-$PORT}") || return 1
        CLASH_SUB_PORT=$(manager_read_default '订阅容器监听端口' "$CLASH_SUB_PORT") || return 1
        CLASH_SUB_PUBLIC_PORT=$(manager_read_default '订阅 NAT 公网端口' "${CLASH_SUB_PUBLIC_PORT:-$CLASH_SUB_PORT}") || return 1
    fi
    NODE_PUBLIC_PORT="${NODE_PUBLIC_PORT:-$PORT}"
    CLASH_SUB_PUBLIC_PORT="${CLASH_SUB_PUBLIC_PORT:-$CLASH_SUB_PORT}"
    for manager_port in "$PORT" "$NODE_PUBLIC_PORT" "$CLASH_SUB_PORT" "$CLASH_SUB_PUBLIC_PORT"; do
        validate_port "$manager_port" || error_exit "端口必须在 1–65535 之间"
        case "$manager_port" in 0*) error_exit "端口不能带前导零" ;; esac
    done
    [ "$PORT" != "$CLASH_SUB_PORT" ] || error_exit "Reality 与订阅容器监听端口不能相同"
    [ "$NODE_PUBLIC_PORT" != "$CLASH_SUB_PUBLIC_PORT" ] || error_exit "Reality 与订阅公网端口不能相同"
    case "$XRAY_PLATFORM" in
        alpine) install_alpine ;;
        debian) install_debian ;;
    esac
}

manager_show_client() {
    [ -f "$SHARE_FILE" ] || error_exit "未找到节点信息，请先选择 1 安装"
    cat "$SHARE_FILE"
}

manager_restart() {
    manager_require_platform
    [ -f "$XRAY_CONFIG" ] || error_exit "尚未安装，请先选择 1"
    if [ "$XRAY_PLATFORM" = alpine ]; then
        [ -f /etc/local.d/xray.start ] || error_exit "缺少 Xray 启动文件"
        sh /etc/local.d/xray.stop
        sh /etc/local.d/xray.start
        if [ -f /etc/local.d/clash-sub.start ]; then
            sh /etc/local.d/clash-sub.start
        fi
    else
        systemctl restart xray.service
        if [ -f /etc/systemd/system/xray-clash-sub.service ]; then
            systemctl restart xray-clash-sub.service
        fi
    fi
    echo "已执行 Xray 和订阅服务重启。"
}

manager_logs() {
    if [ -f /etc/alpine-release ]; then
        for manager_log in /var/log/xray.log /var/log/xray-clash-sub.log; do
            if [ -f "$manager_log" ]; then
                printf '\n%s\n' "$manager_log"
                tail -n 60 "$manager_log"
            fi
        done
    else
        journalctl -u xray.service -u xray-clash-sub.service -n 80 --no-pager
    fi
}

# 配置编辑只读取数据文件；所有候选文件先写入私有临时目录。
manager_config_stage() {
    python3 - "$XRAY_CONFIG" "$config_tmp" <<'PY'
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import sys
import uuid
from urllib.parse import urlencode

def port(value):
    if not re.fullmatch(r'[0-9]{1,5}', str(value)) or not 1 <= int(value) <= 65535:
        raise ValueError('端口必须为 1–65535 的整数')
    return int(value)

def domain(value):
    if len(value) > 253 or '.' not in value or not all(re.fullmatch(
            r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', v) for v in value.split('.')):
        raise ValueError('请填写完整域名，不带协议、端口、路径或通配符')
    return value.lower()

try:
    config = json.loads(Path(sys.argv[1]).read_text())
    folder = Path(sys.argv[2])
    values = {k: os.environ.get(k, '') for k in (
        'PORT', 'NODE_PUBLIC_PORT', 'CLEAR_IP', 'USER_UUID', 'SNI', 'SHORT_ID', 'PUB_KEY',
        'CLASH_SUB_PORT', 'CLASH_SUB_PUBLIC_PORT', 'CLASH_SUB_TOKEN', 'CLASH_SUB_HOST',
        'CLASH_SUB_TLS_CERT', 'CLASH_SUB_TLS_KEY')}
    nodes = [v for v in config.get('inbounds', []) if v.get('protocol') == 'vless'
             and v.get('streamSettings', {}).get('security') == 'reality'
             and any(c.get('id') == values['USER_UUID'] for c in v.get('settings', {}).get('clients', []))]
    if len(nodes) != 1:
        raise ValueError('找不到唯一匹配的 Reality 入站，停止修改')
    node = nodes[0]
    client = next(c for c in node['settings']['clients'] if c['id'] == values['USER_UUID'])
    reality = node['streamSettings']['realitySettings']
    kind = os.environ['EDIT_KIND']
    value, extra, secret = (os.environ.get(k, '') for k in ('EDIT_VALUE', 'EDIT_EXTRA', 'EDIT_SECRET'))
    if kind == '1':
        node['port'] = port(value)
        values['NODE_PUBLIC_PORT'] = str(port(extra))
    elif kind == '2':
        values['CLASH_SUB_PORT'] = str(port(value))
        values['CLASH_SUB_PUBLIC_PORT'] = str(port(extra))
    elif kind == '3':
        address = ipaddress.ip_address(value)
        if address.version != 4 or address.is_unspecified or address.is_multicast or address.is_loopback:
            raise ValueError('当前模板需要可供客户端访问的公网 IPv4 地址')
        values['CLEAR_IP'] = str(address)
    elif kind == '4':
        values['SNI'] = domain(value)
        reality['serverNames'] = [values['SNI']]
        reality['dest'] = values['SNI']+':443'
        reality.pop('target', None)
    elif kind == '5':
        values['USER_UUID'] = str(uuid.UUID(value))
        client['id'] = values['USER_UUID']
    elif kind == '6':
        if not re.fullmatch(r'(?:[0-9a-fA-F]{2}){1,8}', value):
            raise ValueError('ShortId 须为 2–16 位、偶数长度的十六进制字符')
        values['SHORT_ID'] = value.lower()
        reality['shortIds'] = ['', values['SHORT_ID']]
    elif kind == '7':
        socks = [v for v in config['inbounds'] if v.get('protocol') == 'socks']
        if len(socks) > 1:
            raise ValueError('存在多个 SOCKS 入站，请先手动确认要管理的入站')
        if value == 'off':
            config['inbounds'] = [v for v in config['inbounds'] if v.get('protocol') != 'socks']
        else:
            if not re.fullmatch(r'[A-Za-z0-9._@+-]{1,64}', extra):
                raise ValueError('SOCKS 用户名须为 1–64 位字母、数字或 ._@+-')
            if not secret or any(c in secret for c in '\r\n\0'):
                raise ValueError('SOCKS 密码不能为空或包含换行、NUL')
            inbound = socks[0] if socks else {'tag': 'socks-in', 'listen': '0.0.0.0', 'protocol': 'socks'}
            inbound['port'] = port(value)
            inbound['settings'] = {'auth': 'password', 'accounts': [{'user': extra, 'pass': secret}], 'udp': True}
            if not socks:
                config['inbounds'].append(inbound)
    elif kind == '8':
        if value not in ('debug', 'info', 'warning', 'error', 'none'):
            raise ValueError('日志级别须为 debug / info / warning / error / none')
        config.setdefault('log', {})['loglevel'] = value
    elif kind == '9':
        import secrets
        values['CLASH_SUB_TOKEN'] = secrets.token_hex(16)
    else:
        raise ValueError('未知修改项目')
    values['PORT'] = str(port(node['port']))
    values['NODE_PUBLIC_PORT'] = str(port(values['NODE_PUBLIC_PORT']))
    values['CLASH_SUB_PORT'] = str(port(values['CLASH_SUB_PORT']))
    values['CLASH_SUB_PUBLIC_PORT'] = str(port(values['CLASH_SUB_PUBLIC_PORT'] or values['CLASH_SUB_PORT']))
    if values['CLASH_SUB_HOST']:
        values['CLASH_SUB_HOST'] = domain(values['CLASH_SUB_HOST'])
    ports = [port(v['port']) for v in config['inbounds'] if 'port' in v]
    ports.append(int(values['CLASH_SUB_PORT']))
    if len(set(ports)) != len(ports):
        raise ValueError('Reality、订阅和其他入站的容器监听端口不能重复')
    original = json.loads(Path(sys.argv[1]).read_text())
    old_ports = {port(v['port']) for v in original['inbounds'] if 'port' in v}
    old_ports.add(port(os.environ['CLASH_SUB_PORT']))
    import socket
    for number in set(ports) - old_ports:
        try:
            with socket.socket() as probe:
                probe.bind(('0.0.0.0', number))
        except OSError:
            raise ValueError('新监听端口已被占用或无法绑定：'+str(number))
    # NAT forwards both public TCP ports to one public IP, so these must differ too.
    if values['NODE_PUBLIC_PORT'] == values['CLASH_SUB_PUBLIC_PORT']:
        raise ValueError('Reality 与订阅公网 TCP 端口不能相同')
    params = dict(encryption='none', flow='xtls-rprx-vision', security='reality',
                  sni=values['SNI'], fp='chrome', pbk=values['PUB_KEY'], sid=values['SHORT_ID'], type='tcp')
    values['SHARE_LINK'] = ('vless://'+values['USER_UUID']+'@'+values['CLEAR_IP']+':'+values['NODE_PUBLIC_PORT']
                            +'?'+urlencode(params)+'#Reality-'+values['NODE_PUBLIC_PORT'])
    summary = ('地址 (Address): {CLEAR_IP}\n容器监听端口: {PORT}\n公网端口 (Port): {NODE_PUBLIC_PORT}\n'
               '用户 ID (UUID): {USER_UUID}\n流控 (Flow): xtls-rprx-vision\n传输安全: reality\n'
               'SNI: {SNI}\n公钥 (PublicKey / pbk): {PUB_KEY}\nShortID (sid): {SHORT_ID}\n'
               'Fingerprint: chrome\n网络: tcp\n\n分享链接:\n{SHARE_LINK}\n').format(**values)
    for inbound in config['inbounds']:
        if inbound.get('protocol') == 'socks':
            summary += '\nSOCKS5 容器监听端口: '+str(inbound['port'])+'\n'
            for account in inbound.get('settings', {}).get('accounts', []):
                summary += 'SOCKS5 用户名: '+account.get('user', '')+'\nSOCKS5 密码: '+account.get('pass', '')+'\n'
    (folder/'config.json').write_text(json.dumps(config, ensure_ascii=False, indent=4)+'\n')
    (folder/'client-link.txt').write_text(summary)
    (folder/'changes.env').write_text(''.join(k+'='+shlex.quote(str(v))+'\n' for k,v in values.items()))
except (OSError, ValueError, KeyError, StopIteration) as error:
    sys.exit('配置校验失败：'+str(error))
PY
}

manager_read_default() {
    manager_value=$(manager_read "$1 [$2]: ") || return 1
    printf '%s' "${manager_value:-$2}"
}

manager_read_secret() (
    if [ -t 9 ]; then
        manager_stty=$(stty -g <&9) || exit 1
        trap 'stty "$manager_stty" <&9' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        stty -echo <&9 || exit 1
    fi
    manager_read "$1"
    manager_secret_status=$?
    printf '\n' >&2
    exit "$manager_secret_status"
)

manager_restart_xray() {
    if [ "$XRAY_PLATFORM" = alpine ]; then
        sh /etc/local.d/xray.stop
        sh /etc/local.d/xray.start
    else
        systemctl restart xray.service
        systemctl is-active --quiet xray.service
    fi
}

manager_check_listeners() {
    python3 - "$XRAY_CONFIG" <<'PY'
import json
import socket
import sys
import time
config = json.load(open(sys.argv[1]))
for inbound in config['inbounds']:
    if inbound.get('protocol') not in ('vless', 'socks'):
        continue
    host = inbound.get('listen', '0.0.0.0')
    host = '127.0.0.1' if host == '0.0.0.0' else '::1' if host == '::' else host
    for attempt in range(10):
        try:
            with socket.create_connection((host, int(inbound['port'])), timeout=1):
                break
        except OSError:
            if attempt == 9:
                sys.exit('Xray 新配置未能监听 TCP '+str(inbound['port']))
            time.sleep(0.3)
PY
}

manager_config_finish() {
    config_status=$?
    trap - EXIT INT TERM
    if [ "$config_committed" = 1 ] && [ "$config_success" = 0 ]; then
        echo "新配置未通过启动或自检，正在恢复原配置。" >&2
        for config_name in config.json client-link.txt clash-meta.yaml xray-client.json v2rayn.txt clash-sub.env; do
            if [ -f "$config_backup/$config_name" ]; then
                cp -p "$config_backup/$config_name" "$XRAY_DIR/$config_name" || echo "恢复失败：$config_name" >&2
            else
                rm -f -- "$XRAY_DIR/$config_name"
            fi
        done
        ( manager_restart_xray ) || echo "原 Xray 服务重启失败，请查看日志；备份：$config_backup" >&2
        ( start_clash_sub_service ) || echo "原订阅服务重启失败，请查看日志；备份：$config_backup" >&2
    fi
    [ -z "$config_tmp" ] || rm -rf -- "$config_tmp"
    rmdir "$XRAY_DIR/.manager-config-lock" 2>/dev/null || true
    exit "$config_status"
}

manager_edit_config() (
    set -eu
    umask 077
    manager_require_platform
    [ -f "$XRAY_CONFIG" ] && [ -f "$SHARE_FILE" ] || error_exit "请先选择主菜单 1 安装"
    command -v python3 >/dev/null || error_exit "缺少 python3"
    mkdir "$XRAY_DIR/.manager-config-lock" 2>/dev/null || error_exit "另一个配置修改正在进行；请稍后重试"
    config_tmp=''
    config_backup=''
    config_committed=0
    config_success=0
    trap manager_config_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    config_tmp=$(mktemp -d)
    SUB_ENV="$XRAY_DIR/clash-sub.env"
    load_node_settings > "$config_tmp/current.env"
    . "$config_tmp/current.env"
    EDIT_KIND="$1"
    EDIT_VALUE=''
    EDIT_EXTRA=''
    EDIT_SECRET=''
    case "$EDIT_KIND" in
        1)
            EDIT_VALUE=$(manager_read_default 'Reality 容器监听端口' "$PORT") || exit 1
            EDIT_EXTRA=$(manager_read_default 'Reality NAT 公网端口（客户端连接端口）' "$NODE_PUBLIC_PORT") || exit 1 ;;
        2)
            EDIT_VALUE=$(manager_read_default '订阅容器监听端口' "$CLASH_SUB_PORT") || exit 1
            EDIT_EXTRA=$(manager_read_default '订阅 NAT 公网端口' "${CLASH_SUB_PUBLIC_PORT:-$CLASH_SUB_PORT}") || exit 1 ;;
        3) EDIT_VALUE=$(manager_read_default '客户端连接的公网 IPv4' "$CLEAR_IP") || exit 1 ;;
        4) EDIT_VALUE=$(manager_read_default 'Reality SNI（dest 将同步设为该域名:443）' "$SNI") || exit 1 ;;
        5) EDIT_VALUE=$(manager_read_default '新 UUID（输入 new 自动生成）' "$USER_UUID") || exit 1
           [ "$EDIT_VALUE" != new ] || EDIT_VALUE=$(python3 -c 'import uuid; print(uuid.uuid4())') ;;
        6) EDIT_VALUE=$(manager_read_default 'ShortId（2–16 位偶数长度十六进制）' "$SHORT_ID") || exit 1 ;;
        7)
            EDIT_VALUE=$(manager_read 'SOCKS5：输入 off 关闭，或输入监听端口以启用 / 修改: ') || exit 1
            if [ "$EDIT_VALUE" != off ]; then
                EDIT_EXTRA=$(manager_read 'SOCKS5 用户名: ') || exit 1
                EDIT_SECRET=$(manager_read_secret 'SOCKS5 密码（隐藏输入）: ') || exit 1
            fi ;;
        8) EDIT_VALUE=$(manager_read_default '日志级别 debug/info/warning/error/none' "$XRAY_LOG_LEVEL") || exit 1 ;;
        9) echo "将生成新订阅口令。旧订阅 URL 会失效，请在客户端替换地址。" ;;
        *) error_exit "未知配置项" ;;
    esac
    export EDIT_KIND EDIT_VALUE EDIT_EXTRA EDIT_SECRET
    export PORT NODE_PUBLIC_PORT CLEAR_IP USER_UUID SNI SHORT_ID PUB_KEY
    export CLASH_SUB_PORT CLASH_SUB_PUBLIC_PORT CLASH_SUB_TOKEN CLASH_SUB_HOST CLASH_SUB_TLS_CERT CLASH_SUB_TLS_KEY
    manager_config_stage
    . "$config_tmp/changes.env"
    printf '即将应用：Reality 公网 %s:%s → 容器 TCP %s\n' "$CLEAR_IP" "$NODE_PUBLIC_PORT" "$PORT"
    printf '订阅公网端口 %s → 容器 TCP %s；SNI：%s\n' "$CLASH_SUB_PUBLIC_PORT" "$CLASH_SUB_PORT" "$SNI"
    printf 'UUID：%s；ShortId：%s\n' "$USER_UUID" "$SHORT_ID"
    subscription_validate_options
    if [ -n "$CLASH_SUB_TLS_CERT$CLASH_SUB_TLS_KEY" ]; then
        subscription_validate_tls || error_exit "现有 HTTPS 证书未通过校验，请先修复证书"
    fi
    [ "$EDIT_KIND" != 4 ] || assert_sni_usable "$SNI"
    "$XRAY_BIN" run -test -c "$config_tmp/config.json" </dev/null > "$config_tmp/xray-check.log" 2>&1 || {
        cat "$config_tmp/xray-check.log" >&2
        error_exit "Xray 配置测试失败，原配置未修改"
    }
    # Temporarily redirect outputs, retaining live paths inside the subscription env.
    (
        CLASH_FILE="$config_tmp/clash-meta.yaml"
        XRAY_CLIENT_FILE="$config_tmp/xray-client.json"
        V2RAYN_SUB_FILE="$config_tmp/v2rayn.txt"
        SHARE_FILE="$config_tmp/client-link.txt"
        SUB_ENV="$config_tmp/clash-sub.env"
        SUBSCRIPTION_LIVE_CLASH_FILE="$XRAY_DIR/clash-meta.yaml"
        SUBSCRIPTION_LIVE_V2RAYN_FILE="$XRAY_DIR/v2rayn.txt"
        write_client_routing_files
    ) > "$config_tmp/generated.log"
    config_confirm=$(manager_read '保存并应用以上修改？输入 y 确认，其他输入取消: ') || exit 1
    case "$config_confirm" in y|Y) ;; *) echo "已取消，原配置未修改。"; exit 0 ;; esac
    config_backup="$XRAY_DIR/config-backup-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -m 700 "$config_backup"
    for config_name in config.json client-link.txt clash-meta.yaml xray-client.json v2rayn.txt clash-sub.env; do
        [ ! -f "$XRAY_DIR/$config_name" ] || cp -p "$XRAY_DIR/$config_name" "$config_backup/$config_name"
    done
    config_committed=1
    for config_name in config.json client-link.txt clash-meta.yaml xray-client.json v2rayn.txt clash-sub.env; do
        cp "$config_tmp/$config_name" "$XRAY_DIR/$config_name"
        chmod 600 "$XRAY_DIR/$config_name"
    done
    open_firewall_port "$PORT"
    open_firewall_port "$CLASH_SUB_PORT"
    if [ "$EDIT_KIND" = 7 ] && [ "$EDIT_VALUE" != off ]; then
        open_firewall_port "$EDIT_VALUE"
    fi
    manager_restart_xray
    manager_check_listeners
    start_clash_sub_service
    subscription_verify_local
    config_success=1
    echo "✅ 修改已应用。原配置备份：$config_backup"
    echo "请同步修改宿主机 NAT 映射和云安全组："
    echo "  Reality 公网 TCP $NODE_PUBLIC_PORT → 容器 TCP $PORT"
    echo "  订阅公网 TCP ${CLASH_SUB_PUBLIC_PORT:-$CLASH_SUB_PORT} → 容器 TCP $CLASH_SUB_PORT"
    echo "客户端请更新订阅；使用手动分享链接时，重新导入主菜单 7 中的新链接。"
    cat "$SHARE_FILE"
)

manager_edit_https() (
    set -eu
    umask 077
    manager_require_platform
    [ -f "$XRAY_CONFIG" ] && [ -f "$SHARE_FILE" ] || error_exit "请先选择主菜单 1 安装"
    mkdir "$XRAY_DIR/.manager-config-lock" 2>/dev/null || error_exit "另一个配置修改正在进行；请稍后重试"
    config_tmp=''
    config_backup=''
    config_committed=0
    config_success=0
    trap manager_config_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    config_tmp=$(mktemp -d)
    SUB_ENV="$XRAY_DIR/clash-sub.env"
    load_node_settings > "$config_tmp/current.env"
    . "$config_tmp/current.env"
    echo "订阅访问方式：1) Cloudflare 自动 HTTPS / 续期 2) 已有公开证书 3) 保留当前方式，仅改域名"
    config_https_mode=$(manager_read '请选择 [1–3]: ') || exit 1
    CLASH_SUB_HOST=$(manager_read_default '完整订阅域名' "$CLASH_SUB_HOST") || exit 1
    case "$config_https_mode" in
        1) CLASH_SUB_HTTPS=cloudflare ;;
        2)
            CLASH_SUB_HTTPS=existing
            CLASH_SUB_TLS_CERT=$(manager_read_default 'PEM 完整证书链路径' "${CLASH_SUB_TLS_CERT:-/etc/xray/tls/fullchain.pem}") || exit 1
            CLASH_SUB_TLS_KEY=$(manager_read_default 'PEM 私钥路径' "${CLASH_SUB_TLS_KEY:-/etc/xray/tls/key.pem}") || exit 1 ;;
        3)
            if [ -n "$CLASH_SUB_TLS_CERT$CLASH_SUB_TLS_KEY" ]; then
                CLASH_SUB_HTTPS=existing
            else
                CLASH_SUB_HTTPS=off
            fi ;;
        *) error_exit "无效选项" ;;
    esac
    config_confirm=$(manager_read '应用订阅域名 / HTTPS 修改？输入 y 确认，其他输入取消: ') || exit 1
    case "$config_confirm" in y|Y) ;; *) echo "已取消。"; exit 0 ;; esac
    config_backup="$XRAY_DIR/config-backup-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -m 700 "$config_backup"
    for config_name in config.json client-link.txt clash-meta.yaml xray-client.json v2rayn.txt clash-sub.env; do
        [ ! -f "$XRAY_DIR/$config_name" ] || cp -p "$XRAY_DIR/$config_name" "$config_backup/$config_name"
    done
    export CLASH_SUB_HOST CLASH_SUB_HTTPS CLASH_SUB_TLS_CERT CLASH_SUB_TLS_KEY
    config_committed=1
    update_subscription
    config_success=1
    echo "✅ 订阅设置已更新。原配置备份：$config_backup"
)

manager_config_summary() (
    set -eu
    config_summary=$(load_node_settings) || exit 1
    eval "$config_summary"
    printf '\n当前 Reality：公网 %s:%s → 容器 TCP %s\n' "$CLEAR_IP" "$NODE_PUBLIC_PORT" "$PORT"
    printf '当前订阅：%s，公网端口 %s → 容器 TCP %s\n' "${CLASH_SUB_HOST:-$CLEAR_IP}" "${CLASH_SUB_PUBLIC_PORT:-$CLASH_SUB_PORT}" "$CLASH_SUB_PORT"
    printf '当前 SNI：%s；Xray 日志级别：%s\n' "$SNI" "$XRAY_LOG_LEVEL"
)

manager_config_menu() {
    manager_require_platform
    [ -f "$XRAY_CONFIG" ] && [ -f "$SHARE_FILE" ] || error_exit "请先选择主菜单 1 安装"
    while :; do
        manager_config_summary
        cat <<'CONFIG_MENU'

========== 修改配置 ==========
  1. Reality 容器监听端口 / NAT 公网端口
  2. 订阅容器监听端口 / NAT 公网端口
  3. 节点公网 IPv4 地址
  4. Reality SNI / 伪装目标
  5. 节点 UUID
  6. Reality ShortId
  7. SOCKS5 开关 / 端口 / 用户名 / 密码
  8. Xray 日志级别
  9. 重置订阅访问口令
 10. 订阅域名 / HTTPS / 证书
  0. 返回主菜单
CONFIG_MENU
        config_choice=$(manager_read '请选择 [0–10]: ') || return 0
        case "$config_choice" in
            0) return 0 ;;
            [1-9]) manager_edit_config "$config_choice"; config_result=$? ;;
            10) manager_edit_https; config_result=$? ;;
            *) echo "无效选项，请输入 0–10。"; continue ;;
        esac
        if [ "$config_result" -ne 0 ]; then
            echo "修改未完成（退出码 $config_result），请查看上方提示。"
        fi
    done
}

manager_dispatch() (
    set -eu
    umask 077
    manager_require_root
    case "$1" in
        1) manager_install ;;
        2|3|6)
            manager_require_platform
            [ -f "$XRAY_CONFIG" ] && [ -f "$SHARE_FILE" ] ||
                error_exit "尚未找到本项目节点。请先选择 1 安装；安装向导可导入证书备份。"
            case "$1" in
                3) CLASH_SUB_HTTPS=cloudflare ;;
                6)
                    CLASH_SUB_CERT_BUNDLE=$(manager_read '要导入的证书备份路径 [.p12]: ') || exit 1
                    [ -n "$CLASH_SUB_CERT_BUNDLE" ] || error_exit "备份路径不能为空"
                    CLASH_SUB_HTTPS=import ;;
            esac
            update_subscription ;;
        4) run_diagnostic ;;
        5)
            manager_bundle=$(manager_read '导出路径 [/root/sub-cert.p12]: ') || exit 1
            subscription_export_certificate "${manager_bundle:-/root/sub-cert.p12}" ;;
        7) manager_show_client ;;
        8) manager_restart ;;
        9) manager_logs ;;
        10) set +e; manager_config_menu ;;
        *) error_exit "无效选项，请选择 0–10" ;;
    esac
)

manager_menu() {
    cat <<'MENU'

==========================================
          Xray Reality 管理
==========================================
  1. 安装 / 重新安装 Xray
  2. 更新订阅（保留节点、口令与 HTTPS 配置）
  3. 配置 HTTPS / 接入证书自动续期
  4. 连接诊断（超时 / 延迟 -1ms）
  5. 导出加密证书备份
  6. 导入证书到已有节点
  7. 查看节点参数与订阅地址
  8. 重启 Xray 和订阅服务
  9. 查看最近日志
 10. 修改配置（端口 / NAT / 节点 / SOCKS5 / HTTPS）
  0. 退出
MENU
}

manager_main() {
    case "${1:-}" in
        --help|-h)
            echo "用法：sh xray.sh [0–10]"
            echo "无参数进入菜单；也可直接指定菜单编号。Alpine 与 Debian 使用同一个文件。"
            manager_menu
            return 0 ;;
    esac
    [ "$#" -le 1 ] || { echo "只接受一个菜单编号；使用 --help 查看帮助" >&2; return 1; }
    case "${1:-}" in
        ''|[0-9]|10) ;;
        *) echo "无效选项；使用 sh xray.sh --help 查看帮助" >&2; return 1 ;;
    esac
    # 终端优先；无终端时支持从 stdin 读取编号，EOF 正常退出。
    if ( : </dev/tty ) 2>/dev/null; then
        exec 9<>/dev/tty
    else
        exec 9<&0
    fi
    if [ "$#" -eq 1 ]; then
        [ "$1" != 0 ] || return 0
        manager_dispatch "$1"
        return $?
    fi
    while :; do
        manager_menu
        manager_choice=$(manager_read '请选择 [0–10]: ') || break
        case "$manager_choice" in
            0) break ;;
            [1-9]|10)
                manager_dispatch "$manager_choice"
                manager_result=$?
                if [ "$manager_result" -ne 0 ]; then
                    echo "操作未完成（退出码 $manager_result），请查看上方提示。"
                fi ;;
            *) echo "无效选项，请输入 0–10。" ;;
        esac
    done
}

manager_main "$@"
