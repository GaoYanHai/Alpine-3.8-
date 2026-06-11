#!/bin/bash

# ====================================================
# Xray REALITY 诊断脚本
# 用于快速排查连接超时问题
# ====================================================

echo "=========================================="
echo "🔍 Xray REALITY 诊断工具"
echo "=========================================="
echo ""

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 获取配置
XRAY_CONFIG="/etc/xray/config.json"
XRAY_PORT=$(grep -oP '(?<="port":\s)\d+' "$XRAY_CONFIG" | head -1)
SNI=$(grep -oP '(?<="serverNames":\s\[")[^"]+' "$XRAY_CONFIG" | head -1)

echo "📋 基本信息"
echo "配置文件: $XRAY_CONFIG"
echo "监听端口: $XRAY_PORT"
echo "SNI: $SNI"
echo ""

# 1. 检查 Xray 进程
echo "=========================================="
echo "1️⃣  检查 Xray 进程状态"
echo "=========================================="
if systemctl is-active --quiet xray.service; then
    echo -e "${GREEN}✅ Xray 服务正在运行${NC}"
    systemctl status xray.service | head -10
else
    echo -e "${RED}❌ Xray 服务未运行${NC}"
    echo "尝试启动: systemctl start xray.service"
fi
echo ""

# 2. 检查端口监听
echo "=========================================="
echo "2️⃣  检查端口是否监听"
echo "=========================================="
if ss -tlnp 2>/dev/null | grep -q ":$XRAY_PORT "; then
    echo -e "${GREEN}✅ 端口 $XRAY_PORT 正在监听${NC}"
    ss -tlnp 2>/dev/null | grep ":$XRAY_PORT"
else
    echo -e "${RED}❌ 端口 $XRAY_PORT 未监听${NC}"
    echo "可能原因:"
    echo "  1. Xray 进程未启动或崩溃"
    echo "  2. 配置文件错误"
    echo "  3. 端口被其他进程占用"
    echo ""
    echo "尝试这些命令:"
    echo "  systemctl restart xray.service"
    echo "  journalctl -u xray.service -n 50"
fi
echo ""

# 3. 检查防火墙
echo "=========================================="
echo "3️⃣  检查防火墙规则"
echo "=========================================="
if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(ufw status 2>/dev/null | grep "Status:")
    echo "ufw 状态: $UFW_STATUS"
    
    if ufw status | grep -q "inactive"; then
        echo -e "${YELLOW}⚠️  ufw 已禁用${NC}"
    else
        if ufw status | grep -q "$XRAY_PORT"; then
            echo -e "${GREEN}✅ 端口 $XRAY_PORT 已在 ufw 白名单${NC}"
        else
            echo -e "${RED}❌ 端口 $XRAY_PORT 未在 ufw 白名单${NC}"
            echo "修复命令: sudo ufw allow $XRAY_PORT/tcp"
        fi
    fi
else
    echo "⚠️  ufw 未安装"
fi

if command -v iptables >/dev/null 2>&1; then
    echo ""
    echo "iptables 规则 (INPUT 链):"
    iptables -L INPUT -n 2>/dev/null | grep -E "(ACCEPT|DROP|REJECT)" | head -10
fi
echo ""

# 4. 检查 MTU
echo "=========================================="
echo "4️⃣  检查 MTU 设置"
echo "=========================================="
DEFAULT_DEV=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -n "$DEFAULT_DEV" ]; then
    MTU=$(ip link show "$DEFAULT_DEV" | grep -oP '(?<=mtu\s)\d+')
    echo "网卡: $DEFAULT_DEV"
    echo "MTU: $MTU"
    if [ "$MTU" != "1500" ] && [ "$MTU" != "1380" ]; then
        echo -e "${YELLOW}⚠️  MTU 值异常，建议设置为 1380${NC}"
        echo "修复命令: sudo ip link set dev $DEFAULT_DEV mtu 1380"
    else
        echo -e "${GREEN}✅ MTU 设置正常${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  无法检测网卡${NC}"
fi
echo ""

# 5. 测试 SNI 连接
echo "=========================================="
echo "5️⃣  测试 SNI 连接"
echo "=========================================="
echo "测试连接到 $SNI:443..."
if timeout 5 curl -s -w "HTTP 状态码: %{http_code}\n延迟: %{time_connect}s\n" -o /dev/null \
    -I "https://$SNI" 2>/dev/null; then
    echo -e "${GREEN}✅ SNI 连接正常${NC}"
else
    echo -e "${RED}❌ SNI 连接失败${NC}"
    echo "可能原因:"
    echo "  1. DNS 解析失败"
    echo "  2. 网络无法访问 $SNI"
    echo "  3. ISP 或防火墙阻止"
    echo ""
    echo "尝试这些命令排查:"
    echo "  nslookup $SNI"
    echo "  ping $SNI"
    echo "  traceroute $SNI"
fi
echo ""

# 6. 测试本地端口
echo "=========================================="
echo "6️⃣  测试本地 Xray 端口"
echo "=========================================="
if timeout 3 nc -zv 127.0.0.1 "$XRAY_PORT" 2>&1 | grep -q "succeeded"; then
    echo -e "${GREEN}✅ 本地端口 127.0.0.1:$XRAY_PORT 可访问${NC}"
else
    echo -e "${YELLOW}⚠️  本地端口无法连接（这在 REALITY 协议中可能正常）${NC}"
fi
echo ""

# 7. 检查配置文件格式
echo "=========================================="
echo "7️⃣  检查配置文件格式"
echo "=========================================="
if jq empty "$XRAY_CONFIG" 2>/dev/null; then
    echo -e "${GREEN}✅ 配置文件 JSON 格式正确${NC}"
else
    echo -e "${RED}❌ 配置文件 JSON 格式错误${NC}"
    jq empty "$XRAY_CONFIG" 2>&1 | head -5
fi
echo ""

# 8. 显示配置摘要
echo "=========================================="
echo "8️⃣  配置文件摘要"
echo "=========================================="
echo "端口: $XRAY_PORT"
echo "SNI: $SNI"
echo "协议: vless"
echo "流: xtls-rprx-vision"
echo "安全: reality"
echo ""
echo "完整配置:"
cat "$XRAY_CONFIG" | jq '.inbounds[0].streamSettings.realitySettings' 2>/dev/null || echo "无法解析"
echo ""

# 9. 诊断建议
echo "=========================================="
echo "📝 诊断建议"
echo "=========================================="
echo ""
echo "如果连接超时，按以下顺序排查:"
echo ""
echo "1. 确认端口开放："
echo "   telnet <服务器IP> $XRAY_PORT"
echo ""
echo "2. 确认 SNI 可访问："
echo "   ping $SNI"
echo "   curl -v https://$SNI"
echo ""
echo "3. 检查云服务商防火墙 (AWS/Google Cloud/Azure):"
echo "   - 查看安全组规则"
echo "   - 确保允许 TCP $XRAY_PORT 入站"
echo ""
echo "4. 检查 ISP/NAT 问题："
echo "   traceroute <服务器IP>"
echo "   mtr <服务器IP>"
echo ""
echo "5. 查看详细日志："
echo "   journalctl -u xray.service -f"
echo ""
echo "=========================================="
echo "✅ 诊断完成"
echo "=========================================="
