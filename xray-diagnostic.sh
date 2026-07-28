#!/bin/sh

# ====================================================
# Xray REALITY 诊断脚本
# 重点排查：客户端延迟一直 -1ms / 超时 / 端口通但连不上
# 兼容: Alpine(OpenRC) + Debian(systemd)
# ====================================================

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
[ -z "$SNI" ] && SNI="unknown"
[ -z "$LISTEN" ] && LISTEN="(未显式配置，默认 0.0.0.0)"

echo "配置摘要"
echo "  配置文件: $XRAY_CONFIG"
echo "  监听: $LISTEN"
echo "  端口: $XRAY_PORT"
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
echo "  Test-NetConnection -ComputerName <公网IP> -Port $XRAY_PORT"
echo "  # 或"
echo "  telnet <公网IP> $XRAY_PORT"
echo "  # Linux/macOS"
echo "  nc -vz <公网IP> $XRAY_PORT"
echo "  curl -v telnet://<公网IP>:$XRAY_PORT"
echo ""
echo "若本机监听正常，但你电脑 Test-NetConnection 失败 = 100% 是"
echo "  云安全组 / 运营商防火墙 / LXC·LXD 端口未映射 问题，"
echo "  客户端会稳定显示延迟 -1ms。"
echo ""

# 总结
echo "=========================================="
echo "📊 诊断汇总"
echo "=========================================="
echo "通过: $SCORE_OK   警告: $SCORE_WARN   严重: $SCORE_BAD"
echo ""
echo "延迟 -1ms 最常见根因排序:"
echo "  1. 云安全组未放行 TCP $XRAY_PORT"
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
echo "  lxc config device add <实例> xrayproxy proxy listen=tcp:0.0.0.0:$XRAY_PORT connect=tcp:127.0.0.1:$XRAY_PORT"
echo "  # 重装/刷新（会重新生成密钥，客户端需同步更新）"
echo "  curl -fsSL https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/alpine_xray_improved.sh | sh"
echo "  curl -fsSL https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/debian_xray_improved.sh | bash"
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

