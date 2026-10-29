#!/bin/bash
# 仅更新订阅文件和订阅服务，复用现有 Reality 节点与订阅口令。
set -eu
umask 077

case "${1:-}" in
    --https) CLASH_SUB_HTTPS=cloudflare ;;
    --help|-h)
        echo "用法: bash subscription-update.sh [--https]"
        echo "默认保留原订阅域名、证书、端口和口令；--https 启动 Cloudflare DNS-01 HTTPS 向导。"
        exit 0 ;;
    '') ;;
    *) echo "未知参数，使用 --help 查看用法" >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || { echo "参数过多" >&2; exit 1; }

[ "$(id -u)" = 0 ] || { echo "请以 root 运行" >&2; exit 1; }
for cmd in python3 base64; do
    command -v "$cmd" >/dev/null || { echo "缺少命令: $cmd" >&2; exit 1; }
done

XRAY_CONFIG=/etc/xray/config.json
SHARE_FILE=/etc/xray/client-link.txt
CLASH_FILE=/etc/xray/clash-meta.yaml
XRAY_CLIENT_FILE=/etc/xray/xray-client.json
V2RAYN_SUB_FILE=/etc/xray/v2rayn.txt
SUB_ENV=/etc/xray/clash-sub.env

task_tmp=$(mktemp -d)
trap 'rm -rf -- "$task_tmp"' EXIT
if [ -f /etc/alpine-release ]; then
    installer=alpine_xray_improved.sh
    CLIENT_NODE_NAME=Alpine-Reality
else
    installer=debian_xray_improved.sh
    CLIENT_NODE_NAME=Debian-Reality
fi
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
source_script="${SUBSCRIPTION_SOURCE:-$script_dir/$installer}"
if [ ! -f "$source_script" ]; then
    source_script="$task_tmp/installer.sh"
    curl -fSL --connect-timeout 10 --max-time 60 \
        "https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/$installer" -o "$source_script"
fi

# 仅提取订阅函数定义，绝不执行安装脚本的主流程。
python3 - "$source_script" "$task_tmp/functions.sh" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
block = source.split('write_clash_sub_httpd() {', 1)[1].split('\nis_truthy() {', 1)[0]
block = 'write_clash_sub_httpd() {' + block
if 'V2RAYN_SUB_FILE' not in block or 'CLASH_SUB_TLS_CERT' not in block:
    sys.exit('源脚本版本过旧，请把最新版安装脚本与本工具放在同一目录')
Path(sys.argv[2]).write_text(block)
PY
bash -n "$task_tmp/functions.sh"

# 使用 shlex 编码后再读取，节点或环境文件中的内容不能成为 shell 命令。
python3 - "$XRAY_CONFIG" "$SHARE_FILE" "$SUB_ENV" > "$task_tmp/node.env" <<'PY'
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
selected = None
for link in links:
    uri = urlsplit(link)
    query = parse_qs(uri.query, keep_blank_values=True)
    for inbound in config.get('inbounds', []):
        reality = inbound.get('streamSettings', {}).get('realitySettings', {})
        clients = inbound.get('settings', {}).get('clients', [])
        if (inbound.get('protocol') == 'vless'
                and uri.port == inbound.get('port')
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
values = dict(SHARE_LINK=link, CLEAR_IP=uri.hostname, PORT=str(uri.port),
              USER_UUID=uri.username, SNI=query['sni'][0],
              SHORT_ID=query.get('sid', [''])[0], PUB_KEY=query['pbk'][0])
if Path(sys.argv[3]).is_file():
    allowed = {'CLASH_SUB_PORT', 'CLASH_SUB_PUBLIC_PORT', 'CLASH_SUB_TOKEN', 'CLASH_SUB_HOST', 'CLASH_SUB_TLS_CERT', 'CLASH_SUB_TLS_KEY'}
    for line in Path(sys.argv[3]).read_text().splitlines():
        key, sep, value = line.partition('=')
        if sep and key in allowed:
            values[key] = os.environ.get(key, value.strip())
for key, value in values.items():
    print(key + '=' + shlex.quote(value))
PY
. "$task_tmp/node.env"
CLASH_SUB_PORT="${CLASH_SUB_PORT:-58472}"
CLASH_SUB_TOKEN="${CLASH_SUB_TOKEN:-}"
CLASH_SUB_HOST="${CLASH_SUB_HOST:-}"
CLASH_SUB_TLS_CERT="${CLASH_SUB_TLS_CERT:-}"
CLASH_SUB_TLS_KEY="${CLASH_SUB_TLS_KEY:-}"

error_exit() { echo "$*" >&2; exit 1; }
open_firewall_port() { echo "请保持 NAT 宿主机映射和防火墙放行 TCP $1"; }
. "$task_tmp/functions.sh"
command -v configure_subscription_https >/dev/null || error_exit "安装脚本版本过旧，请下载最新版安装脚本后重试"
configure_subscription_https

backup_dir="/etc/xray/subscription-backup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup_dir"
for file in "$SHARE_FILE" "$CLASH_FILE" "$XRAY_CLIENT_FILE" "$V2RAYN_SUB_FILE" "$SUB_ENV" /usr/local/bin/xray-clash-sub.py; do
    [ ! -f "$file" ] || cp -p "$file" "$backup_dir/"
done
write_client_routing_files
start_clash_sub_service
if [ "$installer" = debian_xray_improved.sh ]; then
    systemctl is-active --quiet xray-clash-sub.service || error_exit "订阅服务启动失败，请检查证书、端口和服务日志"
else
    pgrep -f /usr/local/bin/xray-clash-sub.py >/dev/null || error_exit "订阅服务启动失败，请检查 /var/log/xray-clash-sub.log"
fi
subscription_verify_local
echo "订阅已更新。原有订阅文件备份: $backup_dir"
echo "保留 Clash 策略组：使用 clash.yaml，内核为 mihomo；原生 VLESS：使用 vless.txt，内核选择 Xray。"
echo "若从 HTTP 切换至 HTTPS，请在客户端替换订阅地址后更新。"
