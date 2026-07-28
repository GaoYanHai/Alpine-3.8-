# 🏔️ Alpine LXC & Debian LXD Xray Reality 一键调优脚本

[![Alpine](https://img.shields.io/badge/OS-Alpine_Linux-blue?logo=alpine&logoColor=white)](https://alpinelinux.org/)
[![Debian](https://img.shields.io/badge/OS-Debian_trixie-red?logo=debian&logoColor=white)](https://www.debian.org/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Xray](https://img.shields.io/badge/Core-Xray--core-orange)](https://github.com/XTLS/Xray-core)
[![Security](https://img.shields.io/badge/Security-REALITY-red)](https://github.com/XTLS/Xray-core/releases)

专为 **Alpine Linux（LXC）** 与 **Debian trixie（LXD）** 设计的 Xray Reality 安装/优化脚本。针对 **512MB 小内存**、**NAT/容器网络** 场景做了容错与排障增强。

> 协议组合：`VLESS + TCP + REALITY + Vision`

---

## 🆕 更新说明（2026-07-28c）

### 新增：可选 SOCKS5 入站开关
- 默认不启用；选 `y` 后询问端口、用户名、密码并写入配置
- 与现有 VLESS+Reality 并存，不替换原入口
- `curl | bash` 非交互场景可用环境变量 `ENABLE_SOCKS/SOCKS_PORT/SOCKS_USER/SOCKS_PASS`

## 🆕 更新说明（2026-07-28b）

### 重点：伪装目标（SNI/dest）严格校验

确认根因后：很多 VPS「服务正常、参数也填了」，但客户端一直 `-1ms`，是因为 **Reality 回落/握手依赖的伪装站在服务器侧不可达或不合格**。  
本次把 SNI 从“能 curl 一下就行”升级为**安装期强制校验**，不合格直接中止，避免带着坏 SNI 上线。

#### 校验规则（必须通过）
1. DNS 可解析
2. TCP `443` 可连
3. HTTPS 有响应（允许 301/302/403，只要 TLS 能建连）
4. **TLS1.3 / HTTP/2** 高分优先（探测不到 TLS1.3 会降权并告警，但不一定直接淘汰该站）
5. 全部候选在 DNS/TCP/HTTPS 层失败 → **安装失败退出**（不再静默写死坏 SNI）
6. 选定后再做一次 **最终校验**，写入 config 前确保 dest 可用

#### 新增多地域候选
| 区域 | 示例域名 |
|------|----------|
| 美国/北美 | `www.microsoft.com` `www.apple.com` `www.cloudflare.com` `www.amazon.com` `www.nvidia.com` `www.intel.com` `www.adobe.com` `www.costco.com` |
| 欧洲 | `www.ikea.com` `www.sap.com` `www.nokia.com` `www.ericsson.com` `www.bmw.com` `www.dyson.co.uk` `www.sony.co.jp` `www.volkswagen.com` |
| 印度 | `www.infosys.com` `www.tcs.com` `www.airtel.in` `www.flipkart.com` `www.india.gov.in` |
| 俄罗斯 | `www.yandex.ru` `www.vk.com` `www.mail.ru` `www.sberbank.ru` `www.wildberries.ru` |
| 亚太兜底 | `www.samsung.com` `www.shopee.sg` `www.toyota.com` `www.singaporeair.com` |

脚本会在以上候选中自动挑选 **评分最高且延迟较低** 的目标；Alpine 与 Debian 均已接入。

---

## 🆕 更新说明（2026-07-28）

### 重点修复：客户端延迟一直是 `-1ms`

`-1ms` 在 v2rayN / NekoBox / Shadowrocket 等客户端里，通常 **不是“延迟很差”**，而是 **TCP/REALITY 根本没连上**（超时、拒绝、握手失败）。本次针对该现象做了根因级修复与文档化。

| 根因 | 表现 | 本次处理 |
|------|------|----------|
| 云安全组 / 宿主机未放行或未映射端口 | 服务正常，客户端 -1ms | 安装时自动尝试放行；诊断脚本强提醒；README 给出 LXD proxy 示例 |
| 客户端填了容器内网 IP | 本机正常，外网 -1ms | 多源 IPv4 公网 IP 检测；输出明确“填公网 IP” |
| 新版 Xray `x25519` 字段变化 | 参数“看起来对”但仍失败 | 兼容 `Password` / `Password (PublicKey)` / `PublicKey`；拒绝把 `Hash32` 当公钥 |
| ShortId / 手填参数不一致 | 能握手到端口但 Reality 失败 | `shortIds` 同时支持 `""` 与固定值；生成 `vless://` 分享链接 |
| 系统时间偏差 / dest 不可达 | 间歇或稳定失败 | chrony 时间同步；安装时检查伪装站；诊断增加时间与 dest 检查 |
| 只监听、无日志、难排障 | “VPS 正常但连不上” | 监听 `0.0.0.0`、写 `/var/log/xray.log`、安装后自检、增强 `xray-diagnostic.sh` |

### 脚本改动清单
- 🔐 **密钥解析增强**：统一 Reality 公钥提取；校验长度/字符集；私钥=公钥时直接失败
- 🔥 **防火墙**：自动尝试 `ufw` / `firewalld` / `iptables` 放行 TCP `52300`
- 🌐 **公网 IP**：`ipify` / `ifconfig.me` / `icanhazip` / `ip.sb` 多源，优先 IPv4
- 📎 **分享链接**：安装完成写入 `/etc/xray/client-link.txt`，减少手填错误
- 🧪 **安装后自检**：检查端口是否监听（未监听几乎必现 -1ms）
- 🧰 **诊断脚本重写**：按 -1ms 排查路径打分（进程/监听/防火墙/公网IP/SNI/时间/日志）
- 🧾 **配置**：`shortIds: ["", "0123456789abcdef"]` + `sniffing` 开启

---

## ✨ 核心特性

| 特性 | 说明 |
|------|------|
| 🌍 容器环境优先 | 自动网卡检测，MTU 失败优雅降级 |
| 📡 MTU 智能设置 | LXC/LXD 尝试 MTU 1380，降低长包丢包 |
| 🚀 BBR 自适应 | 支持则启用，否则降级默认算法 |
| 🛡️ 抗审查 | VLESS + TCP + REALITY + Vision |
| 🍃 低占用 | 原生 init，无冗余进程 |
| 🔒 动态凭证 | 运行时生成 UUID / x25519，避免写死密钥 |
| 🕒 自我修复 | 每天 04:00 自动重启，缓解小内存 OOM |
| ⚡ 下载重试 | Xray 二进制下载失败自动重试 3 次 |
| ✅ 配置验证 | JSON / `xray run -test` / 关键字段校验 |

### 版本支持矩阵

| 系统 | 脚本 | Init | 包管理 | 场景 |
|------|------|------|--------|------|
| Alpine Linux | `alpine_xray_improved.sh` | OpenRC | apk | LXC |
| Debian trixie | `debian_xray_improved.sh` | systemd | apt | LXD |

---

## 🛠️ 快速安装

> 需要 root。建议先快照，再执行。

### Alpine LXC

```bash
curl -fsSL https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/alpine_xray_improved.sh | sh
```

或本地执行：

```bash
wget -O alpine_xray_improved.sh https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/alpine_xray_improved.sh
chmod +x alpine_xray_improved.sh
sudo sh alpine_xray_improved.sh
```

### Debian LXD

```bash
curl -fsSL https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/debian_xray_improved.sh | bash
```

或本地执行：

```bash
wget -O debian_xray_improved.sh https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/debian_xray_improved.sh
chmod +x debian_xray_improved.sh
sudo bash debian_xray_improved.sh
```

### 诊断（连不上 / 延迟 -1ms 时先跑）

```bash
wget -O xray-diagnostic.sh https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/xray-diagnostic.sh
chmod +x xray-diagnostic.sh
sudo sh xray-diagnostic.sh
```

---

## 📋 客户端配置指南

安装结束后终端会输出参数，并保存到：

- `/etc/xray/client-link.txt`
- 配置文件：`/etc/xray/config.json`

**推荐直接导入分享链接**，少手填。

| 配置项 | 值 | 说明 |
|--------|----|------|
| 协议 | VLESS | |
| 地址 | 脚本输出的**公网 IP** | 不要填容器内网 IP |
| 端口 | `52300` | 默认 |
| UUID | 脚本输出 | |
| 流控 Flow | `xtls-rprx-vision` | 必填 |
| 加密 | `none` | VLESS |
| 传输 | `tcp` | |
| 安全 | `reality` | |
| SNI | 脚本输出（如 `www.ikea.com`） | 必须与服务端 `serverNames` 一致 |
| Fingerprint | `chrome` | |
| PublicKey | 脚本输出的公钥 | **新版 Xray 来自 `Password` 字段** |
| ShortId | `0123456789abcdef`（或空） | 与服务端 `shortIds` 之一匹配 |

### ⚠️ 关于 PublicKey / Password / Hash32（极易填错）

新版 Xray `xray x25519` 常见输出：

```text
PrivateKey: <服务器私钥，只放服务端 config>
Password:   <客户端 PublicKey / pbk>
Hash32:     <不是客户端公钥，不要填>
```

| 字段 | 用途 |
|------|------|
| PrivateKey | 仅服务端 `realitySettings.privateKey` |
| Password | **就是客户端 PublicKey（pbk）** |
| PublicKey（旧版字段名） | 同客户端公钥 |
| Hash32 | **不要填进客户端** |

脚本已自动把 `Password` 映射并打印为 `PublicKey`，按终端输出填写即可。

---

## 🚨 延迟一直是 -1ms：完整排查手册

### 先理解现象

| 客户端显示 | 真实含义 |
|------------|----------|
| 延迟 `-1ms` / 超时 | 到不了端口，或 TCP 通了但 Reality 握手失败 |
| 延迟正常但网页失败 | 出站/路由/DNS 问题（少见，先排除连通） |

### 排查顺序（按命中率）

#### 1) 云安全组 / 面板防火墙（最高发）

确保 **TCP 52300 入站** 对你的客户端 IP 或 `0.0.0.0/0` 放行。  
仅容器内 `ss` 显示监听 **不等于** 公网可达。

#### 2) LXC / LXD 端口映射

容器若在 NAT 后面，必须在**宿主机**做转发/代理。

**LXD 示例：**

```bash
lxc config device add <实例名> xrayproxy proxy \
  listen=tcp:0.0.0.0:52300 \
  connect=tcp:127.0.0.1:52300
```

**LXC/iptables 示例（宿主机）：**

```bash
# 视实际网卡与容器 IP 调整
iptables -t nat -A PREROUTING -p tcp --dport 52300 -j DNAT --to-destination <容器IP>:52300
iptables -A FORWARD -p tcp -d <容器IP> --dport 52300 -j ACCEPT
```

#### 3) 客户端地址是否填错

- ✅ 宿主机/VPS **公网 IPv4**
- ❌ `10.x` / `100.x` / `172.16-31.x` 等容器网桥地址
- ❌ 仅内网可达的 `tailscale`/`zerotier` IP（除非客户端也在同网）

本机验证：

```bash
ss -tlnp | grep 52300
cat /etc/xray/client-link.txt
```

你的电脑上验证（关键）：

```powershell
# Windows
Test-NetConnection -ComputerName <公网IP> -Port 52300
```

```bash
# Linux / macOS
nc -vz <公网IP> 52300
```

> 服务器监听正常，但你电脑端口不通 → **几乎可以断定是安全组或端口映射问题**，客户端会稳定 `-1ms`。

#### 4) 参数一致性

必须逐项一致：

- UUID
- PublicKey（pbk，来自 Password）
- ShortId（sid）
- SNI
- Flow = `xtls-rprx-vision`
- Fingerprint = `chrome`
- Network = `tcp`
- Security = `reality`

差一个 Reality 都可能失败。优先用 `/etc/xray/client-link.txt` 里的分享链接。

#### 5) 服务是否真的在听 `0.0.0.0`

```bash
ss -tlnp | grep 52300
# 期望类似 0.0.0.0:52300 或 *:52300
# 若只有 127.0.0.1:52300，外网必 -1ms
```

#### 6) 伪装目标 SNI/dest（本次确认的高发根因）

服务器必须能访问 `https://<SNI>`，且尽量 TLS1.3：

```bash
SNI=$(sed -n 's/.*"serverNames"[[:space:]]*:[[:space:]]*\[[[:space:]]*"\([^"]*\)".*/\1/p' /etc/xray/config.json | head -1)
echo "SNI=$SNI"
nslookup "$SNI"
nc -vz "$SNI" 443
curl -I --tlsv1.3 https://"$SNI"
echo | openssl s_client -tls1_3 -connect "$SNI:443" -servername "$SNI" >/dev/null && echo TLS13_OK
```

若这里失败，客户端会稳定 `-1ms`。解决：重跑最新脚本自动换可用 SNI，或手动改 `dest`/`serverNames` 后重启。

#### 7) 时间同步

```bash
date
chronyc tracking 2>/dev/null || timedatectl
curl -I https://<你的SNI>
tail -n 100 /var/log/xray.log
```

Reality 对时间敏感；`dest` 站点若服务器访问失败，握手也容易挂。

#### 7) 一键诊断

```bash
sudo sh xray-diagnostic.sh
```

按脚本输出的 **严重/警告** 项处理即可。

---



## 🧦 可选：SOCKS5 入站

安装脚本支持**可选开关**，默认不启用：

1. 运行脚本时询问：`是否启用 SOCKS5 入站？(y/N)`
2. 选 `N`：不做任何改动，仅 Reality
3. 选 `y`：继续询问
   - 端口（默认 `10808`）
   - 用户名（必填，1-64，字母数字 `._@+-`）
   - 密码（必填，8-128，须含字母+数字；不能与用户名相同；拒绝常见弱口令）
   - 说明：SOCKS5 协议本身几乎不限制格式，以上是脚本侧安全校验
4. 自动写入 `/etc/xray/config.json` 的第二个 `inbounds`，并尝试放行防火墙端口

### 非交互安装（适合 curl | bash）

```bash
export ENABLE_SOCKS=1
export SOCKS_PORT=10808
export SOCKS_USER='myuser'
export SOCKS_PASS='mypass'
curl -fsSL https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/debian_xray_improved.sh | bash
```

### 排障
- 若出现 `syntax error near unexpected token out=`：旧版 `json_escape` 反斜杠语法损坏，请拉取最新脚本
- 若启用 SOCKS 时出现 `sed: unknown option to s`：是旧版用户名转义 bug，请拉取最新脚本重跑

### 安全建议
- 公网暴露 SOCKS5 必须用强密码（建议 >=12 位，大小写+数字+符号）
- 脚本会拒绝过短/纯数字/与用户名相同/常见弱口令
- 云安全组仅对可信 IP 放行 SOCKS 端口
- 若只要本机用，可事后把 `listen` 改成 `127.0.0.1`

## 🔧 日常运维

### Alpine

```bash
# 重启
rc-service local restart
# 日志
tail -n 100 /var/log/xray.log
# 进程
ps | grep xray
```

### Debian

```bash
systemctl status xray.service
systemctl restart xray.service
journalctl -u xray.service -n 80 --no-pager
tail -n 100 /var/log/xray.log
```

### 更换 SNI

编辑 `/etc/xray/config.json` 中：

```json
"dest": "www.microsoft.com:443",
"serverNames": ["www.microsoft.com"]
```

然后重启服务；**客户端 SNI 必须同步修改**。

---

## ❓ 常见问题

**Q: VPS 上脚本显示安装成功，客户端却一直 -1ms？**  
A: 先在你自己电脑对公网 IP:`52300` 做 `Test-NetConnection` / `nc`。不通就查安全组与 LXC/LXD 映射，不是客户端“参数玄学”。

**Q: 端口外面都通了，还是连不上？**  
A: 核对手填 PublicKey（是否误填 Hash32）、UUID、ShortId、SNI、Flow；看 `/var/log/xray.log`；确认时间同步。

**Q: 重跑脚本后旧客户端失效？**  
A: 正常。脚本会重新生成 UUID/密钥，需用新的 `/etc/xray/client-link.txt`。

**Q: 为什么 ShortId 固定为 `0123456789abcdef`？**  
A: 便于排障与文档化；服务端同时允许空 ShortId。若要更安全，可自行改为随机 16 进制并同步客户端。

**Q: MTU / BBR 设置失败？**  
A: 容器权限常见限制，脚本会降级继续；一般不导致 -1ms。

---

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `alpine_xray_improved.sh` | Alpine/OpenRC 一键安装 |
| `debian_xray_improved.sh` | Debian/systemd 一键安装 |
| `xray-diagnostic.sh` | 连通性/ -1ms 诊断 |
| `README.md` | 本文档 |

安装后关键路径：

| 路径 | 说明 |
|------|------|
| `/etc/xray/config.json` | Xray 配置 |
| `/etc/xray/client-link.txt` | 客户端参数与分享链接 |
| `/var/log/xray.log` | 业务日志 |
| `/usr/local/bin/xray` | 核心二进制 |

---

## 🔒 安全提示

- 不要在公共 issue/截图里贴 UUID、PublicKey、完整分享链接
- 尽量限制安全组来源 IP
- 定期 `tail` 日志，确认无异常扫描占用
- 小内存机器保留每日重启策略，或自行加 swap

---

## 📜 更新日志

### v3.4.3（2026-07-28）— 修复 json_escape 语法错误
- 修复 `bash: syntax error near unexpected token out="$out\\"`
- `json_escape` 改为 python3/jq/awk 实现，去掉易碎 case 反斜杠分支

### v3.4.2（2026-07-28）— SOCKS 账号安全校验
- 明确：SOCKS5 协议无强制复杂度，脚本增加安全校验
- 用户名 1-64（字母数字._@+-）；密码 8-128 且字母+数字
- 拒绝与用户名相同、常见弱口令；交互模式可重试输入

### v3.4.1（2026-07-28）— 修复 SOCKS 用户名/密码转义
- 修复启用 SOCKS5 时 `sed: unknown option to s` 导致安装中断
- `json_escape` 改为 python/awk/shell 多级回退，不再用易碎 sed 替换

### v3.4（2026-07-28）— 可选 SOCKS5 入站开关
- 安装时可选择是否启用 SOCKS5（默认否）
- 启用后交互输入端口/用户名/密码，写入 config.json
- 自动放行 SOCKS 端口；支持 ENABLE_SOCKS 环境变量非交互安装

### v3.3（2026-07-28）— 伪装目标严格校验 + 多地域候选
- 安装期强制校验 SNI/dest：DNS、TCP443、HTTPS 必须通过
- TLS1.3/H2 评分优选；最终校验通过后才写入配置
- 新增多地域候选：美国 / 欧洲 / 印度 / 俄罗斯 / 亚太（共 30 个）
- Alpine 同步接入自动选 SNI（不再写死 ikea）
- 全部候选失败则中止安装，避免带着坏伪装目标上线导致 -1ms
- 诊断脚本增强 SNI/dest 逐项检查

### v3.2（2026-07-28）— 针对延迟 -1ms
- 修复/增强 x25519 公钥解析（Password / PublicKey / 防 Hash32）
- 安装时尝试开放防火墙端口
- 多源 IPv4 公网 IP 检测
- 生成 vless 分享链接到 `/etc/xray/client-link.txt`
- shortIds 兼容空值；开启 sniffing
- 安装后监听自检；诊断脚本按 -1ms 路径重写
- README 补充安全组 / NAT 映射 / 客户端自测步骤

### v3.1（2026-07-27）— 端口通但连不上
- Debian 显式 `0.0.0.0` 监听、日志落盘、systemd 启动修复
- Alpine 密钥提取 BusyBox 兼容、补 `xray.stop`、启用 chrony
- 诊断脚本去 `grep -P`

### v3.0 — Debian LXD 支持
- systemd / apt / 自动 SNI 检测

### v2.x — NAT 兼容与稳定性
- MTU/BBR 降级、网卡自检、重试下载、文档完善

---

## 📄 License

MIT
