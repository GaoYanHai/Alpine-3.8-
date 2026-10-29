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
| 🧭 ACL4SSR 分流 | 安装后生成 Clash Meta / Xray 客户端规则配置，国内直连、广告拦截，无需全局模式 |
| 🔐 HTTPS 订阅向导 | Cloudflare DNS-01 自动签发、安装公开证书，配置每日续期检查和服务重载；支持 NAT 高位端口 |

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

两个安装脚本都包含订阅向导，单文件运行即可。交互安装时会提示选择 **Cloudflare 自动申请 HTTPS（默认选项）**、已有公开证书或 HTTP。选择自动申请后，按提示填写完整域名、公网订阅端口、设置 Cloudflare 灰云 A 记录与 NAT 映射，再隐藏输入 API Token；脚本自动安装 acme.sh、申请证书、配置续期和订阅服务，最后验证本机订阅。

无交互终端且未指定 HTTPS 参数时，脚本保持 HTTP 并打印后续开启方法。域名托管在 Cloudflare 并不等于 VPS 已有可供客户端直接信任的证书，具体权限和步骤见下方「NAT VPS + Cloudflare 域名启用 HTTPS」。

### 诊断（连不上 / 延迟 -1ms 时先跑）

```bash
wget -O xray-diagnostic.sh https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/xray-diagnostic.sh
chmod +x xray-diagnostic.sh
sudo sh xray-diagnostic.sh
```

---

## 📋 客户端配置指南

安装结束后终端会输出参数，并保存到：

- `/etc/xray/client-link.txt` — 参数与分享链接
- `/etc/xray/config.json` — 服务端配置
- `/etc/xray/clash-meta.yaml` — Clash 规则模式分流
- `/etc/xray/xray-client.json` — Xray 客户端分流

**推荐用法：把安装结束时打印的本机 Clash 订阅链接，粘到 Clash Verge / mihomo「新建订阅」。**
这条链接指向你自己的 VPS，不经过第三方转换站。导入后自动出现直连、苹果、漏网之鱼等分组；模式保持「规则」。
`vless://` 只是单节点，不会带分组。

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

### 🧭 分流规则（ACL4SSR，本机订阅）

机场能自动出「直连 / 苹果 / 漏网之鱼」，是因为订阅内容本身就是 Clash 配置 + ACL4SSR 规则。
`vless://` 只有节点，所以用 v2rayN 导入分享链接**不会**出现那些分组。

安装脚本会在 **你自己的 VPS** 上生成 Clash 配置，并输出带随机口令的订阅地址。选择 HTTPS 时，例如：

`https://sub.example.com:58472/<随机口令>/clash.yaml`

交互安装默认推荐 HTTPS。选择 HTTP 或无交互且未配置 HTTPS 时，地址为 `http://<公网IP>:58472/<随机口令>/clash.yaml`；随机口令不提供传输加密。也可以使用已有证书、现有网站反向代理，或通过 SSH/SCP 下载配置后在客户端本地导入。仅修改 URL 的协议不能启用 TLS。

**不会**把节点发到 `api.v1.mk` 之类的第三方转换站。

1. 打开 Clash Verge / mihomo
2. 新建订阅，把终端打印的 `https://.../clash.yaml` 或 `http://.../clash.yaml` 贴进去
3. 点更新；模式保持 **Rule / 规则**，不要开全局
4. 云安全组和 LXC/LXD 映射放行 **TCP 58472**（Clash 订阅口；改脚本顶部 `CLASH_SUB_PORT` 即可换端口）

| 客户端 | 怎么用 |
|--------|--------|
| Clash Verge / mihomo | 贴本机订阅链接（推荐） |
| v2rayN | 推荐使用安装输出的 `vless.txt` 原生订阅，节点内核选 Xray，路由选「绕过大陆」 |
| 订阅打不开 | 检查终端里那个高位端口的映射；或 `scp` 拉取 `/etc/xray/clash-meta.yaml` 本地导入 |

订阅监听端口默认 58472，可以通过 `CLASH_SUB_PORT` 环境变量覆盖。NAT 外部端口不同时，通过向导或 `CLASH_SUB_PUBLIC_PORT` 指定；输出链接使用外部端口，服务仍监听内部端口。

v2rayN 7.16.9 会把完整 Clash YAML 作为 **mihomo 自定义配置** 导入，和普通 VLESS 节点使用不同的内核处理路径。若 VLESS 可用但 Clash 订阅节点测速超时，可新建订阅分组，使用同一口令路径下的 `vless.txt`：

`https://sub.example.com:58472/<随机口令>/vless.txt`（选择 HTTP 时使用脚本输出的 HTTP 地址）

它返回原分享链接的 Base64 订阅，保留全部 Reality 参数；v2rayN 使用 Xray，分流由 v2rayN 路由设置控制，不包含 Clash 策略组。两种订阅都由自己的 VPS 提供。

已有安装遇到订阅异常时，无需重装 Xray：先更新服务器上的 `/etc/xray/clash-meta.yaml`，再在客户端更新订阅。ACL4SSR 的 `.list` 是纯文本，对应 `rule-providers` 项需要在 `behavior: classical` 同级设置 `format: text`；否则可能语法检查通过却加载 0 条规则。`ChinaMedia` 和 `ProxyMedia` 改用官方 `Clash/Providers/*.yaml` 及 `format: yaml`，其中不支持的 `URL-REGEX` 已被上游注释；它们使用新的缓存路径，避免旧文本缓存按 YAML 解析。自动选择组的测速地址使用 `https://www.gstatic.com/generate_204`，Reality 的 `short-id` 应加引号，避免纯数字值或前导零被 YAML 转换。只点「更新订阅」不会修复服务器上原有的文件。

DNS 默认使用国内 DoH，国外备用 Google / Cloudflare DoH 通过 `#🚀 节点选择` 显式走代理，避免在客户端网络直接连接时被阻断。直连流量使用独立的国内 `direct-nameserver`，避免微软等默认直连的服务被国外备用 DNS 超时拖住。若仍有 `dns resolve failed`，检查本机到国内 DNS 的访问以及节点选择组是否选了可用代理。启动后的单次 `-1 ms` 只表示那次测速未成功，需等启动完成后再测；`系统代理设置改变 - ForcedChange` 是客户端代理设置事件。

如果同一节点的 VLESS 链接可用，但 Clash 仍然超时，请对比订阅中的 `server`、`port`、`uuid`、`flow`、`servername`、`client-fingerprint` 和 `reality-opts`，并检查客户端日志。规则加载失败、测速目标不可达和 Reality 握手失败是不同的问题，不能仅凭 HTTP 提示判断节点故障。

若服务端使用新版 Xray，而 mihomo 报 `REALITY authentication failed`，需检查 `reality-opts` 下的 `support-x25519mlkem768: true`。mihomo 默认关闭此选项并移除握手中的 X25519MLKEM768；本项目已将其开启。在 Xray 26.10.21、SNI `www.bmw.com` 的同节点对照测试中，关闭时认证失败，开启后 mihomo 1.19.12 和 1.19.16 均测速成功。该设置面向支持 X25519MLKEM768 的新版服务端，旧版服务端需按兼容情况调整。

#### 已安装 VPS 更新订阅（不重装 Xray）

把最新版 `subscription-update.sh` 和对应系统的安装脚本放在同一目录，运行：

```bash
mkdir -p /root/xray-sub-update
cd /root/xray-sub-update
curl -fSL https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/subscription-update.sh -o subscription-update.sh
# Debian；Alpine 请将文件名替换为 alpine_xray_improved.sh
curl -fSL https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/debian_xray_improved.sh -o debian_xray_improved.sh
bash subscription-update.sh
```

工具复用 `/etc/xray/client-link.txt` 中与现有入站匹配的链接以及原订阅口令，保留已有域名、证书、监听端口和公网端口，备份后更新订阅文件、重启订阅服务，不改动 Xray 配置或重启 Xray。若单独下载工具，它会从本项目 main 获取安装脚本中的订阅函数；同目录已有安装脚本时优先使用该文件，因此请同步更新。当前支持脚本默认的 IPv4、TCP、Vision、chrome 参数；修改过这些参数或入站/出站端口不一致时，请先校对分享链接。

#### NAT VPS + Cloudflare 域名启用 HTTPS

新安装时直接按向导操作。已有节点开启 HTTPS，在上方下载最新版文件后运行：

```bash
bash subscription-update.sh --https
```

向导会提示需要你完成的步骤：

1. 填写完整域名，例如 `zor.zor.de5.net`，不带协议、端口或路径。
2. 在 Cloudflare 添加该域名的 A 记录，指向 **NAT 宿主机公网 IP**，设为 **仅 DNS（灰云）**；记录名称相对于托管区域填写。
3. 在 NAT 面板或宿主机、安全组放行并映射订阅 TCP 端口，例如公网 `58472` → 容器 `58472`。外部端口不同时，在向导里填写实际公网端口。
4. Cloudflare → 个人资料 → API 令牌 → 创建令牌，使用「编辑区域 DNS」模板。权限为 **区域 / DNS / 编辑** 和 **区域 / 区域 / 读取**，资源仅包含这个域名所属区域；将 Token 粘贴到 VPS 的隐藏输入提示中。

此后脚本自动下载官方 acme.sh，使用 Let's Encrypt 的 DNS-01 验证签发 ECC 证书，安装到 `/etc/xray/tls/fullchain.pem` 和 `/etc/xray/tls/key.pem`，校验证书链、公私钥、域名及剩余有效期，然后开启订阅 HTTPS。无需开放入站 80/443，也无需修改 Reality 节点地址。

**Cloudflare 边缘证书（Universal SSL）不能下载部署到 VPS；Origin CA 证书不能用于灰云后的客户端直接访问。** 自动向导会另行申请公开受信任证书。API Token 保存在仅 root 可访问的 acme.sh 配置中供续期使用，不写入订阅配置或客户端 URL；不要上传这些配置文件。

安装完成后，用脚本输出的新地址替换客户端原 HTTP 订阅，例如：

```text
https://zor.zor.de5.net:58472/<原口令>/clash.yaml
https://zor.zor.de5.net:58472/<原口令>/vless.txt
```

同一监听端口切换 TLS 后，旧 HTTP 地址不再适用。脚本会通过回环地址验证订阅可读和 HTTPS 证书可信；公网 DNS、NAT 转发与安全组还需从客户端访问链接确认。

自动申请的证书会配置每日续期检查；只在证书需要续期时申请，更新后自动重新加载订阅服务：

| 系统 | 续期任务 | 检查方法 |
|------|----------|----------|
| Debian | systemd timer，支持错过任务后补执行 | `systemctl list-timers xray-sub-renew.timer`；`journalctl -u xray-sub-renew.service` |
| Alpine | `/etc/periodic/daily/xray-sub-renew`，自动启用 crond | `rc-service crond status`；`tail /var/log/xray-sub-renew.log` |

已手动配置 HTTPS 的用户，普通更新会复用证书和原有续期方式；若需要接入本项目的自动续期，可运行 `bash subscription-update.sh --https`。已有证书未到续期时间时不会强制重新申请。

自动签发失败时，脚本停止并给出重试提示，尚不改写订阅文件。先检查 Token 区域范围、DNS 权限、VPS 到 Cloudflare/GitHub/Let's Encrypt 的网络和 ACME 错误信息，再运行 `bash subscription-update.sh --https`；不要为此重装 Xray。Let's Encrypt 有签发频率限制，不要反复强制申请。

也可以使用自己管理的公开证书：

```bash
CLASH_SUB_HTTPS=existing \
CLASH_SUB_HOST=zor.zor.de5.net \
CLASH_SUB_TLS_CERT=/etc/xray/tls/fullchain.pem \
CLASH_SUB_TLS_KEY=/etc/xray/tls/key.pem \
bash subscription-update.sh
```

此模式校验证书但不接管签发和续期。证书工具续期后应执行：Debian 为 `systemctl restart xray-clash-sub.service`，Alpine 为 `sh /etc/local.d/clash-sub.start`。证书须覆盖完整域名，使用完整证书链；私钥保持仅 root 可读。

支持的环境变量（两个安装脚本及订阅更新工具通用）：

| 变量 | 默认 / 用途 |
|------|-------------|
| `CLASH_SUB_HTTPS` | `auto`：复用已有证书，或启动交互选择；`cloudflare`：自动签发；`existing`：自有证书；`off`：HTTP（已有 TLS 时拒绝直接降级） |
| `CLASH_SUB_HOST` | 完整订阅域名；auto 模式下设置域名且无证书时进入 Cloudflare 自动签发 |
| `CLASH_SUB_PORT` | 订阅监听端口，默认 `58472` |
| `CLASH_SUB_PUBLIC_PORT` | NAT 公网订阅端口，默认等于监听端口，写入生成的 URL |
| `CLASH_SUB_TLS_CERT` / `CLASH_SUB_TLS_KEY` | existing 模式的 PEM 完整证书链和私钥路径；设置两者时 auto 自动复用 |
| `CF_Token` | Cloudflare 自动签发时可从环境提供；未设置时隐藏输入，非交互运行必须提供 |

无人值守示例：从安全的本机环境预先导出 `CF_Token`，完成 DNS/NAT 后运行 `CLASH_SUB_HTTPS=cloudflare CLASH_SUB_HOST=sub.example.com bash debian_xray_improved.sh`；Alpine 换成 `sh alpine_xray_improved.sh`。不要将真实 Token 写入公开命令示例或提交到仓库。

如以后改用 Cloudflare 代理，需使用它支持的 HTTPS 端口（例如 443 或 8443），SSL/TLS 设为 Full (strict)，并正确映射到启用 TLS 的订阅服务；58472 不在常规代理支持范围。

同一节点出现 YAML 慢、VLESS 快时，先在 YAML 的 GLOBAL 分组明确选择同一节点进行对照，再观察实际视频连接与下载速度。全局模式仍沿用 YAML 的 DNS；YouTube 的 Connection Speed 是分段下载估算值，单次波动不能证明规则或内核限速。持续慢时应记录相同视频、清晰度、实际命中节点和测速时间，再比较两个内核。

规则模板：[ACL4SSR_Online.ini](https://github.com/ACL4SSR/ACL4SSR/blob/master/Clash/config/ACL4SSR_Online.ini)

常见策略：

- 🎯 全球直连：局域网、国内域名、国内 IP、Steam 国服、Google 中国
- 🛑 广告拦截 / 🍃 应用净化：广告与追踪
- 📲 电报 / 💬 OpenAI / 🌍 国外媒体 / GFW 列表：走 Reality
- Ⓜ️ 微软：默认直连（可在分组里改成节点）
- 🍎 苹果：默认走节点（可改直连）
- 🐟 漏网之鱼：默认走节点

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
   - 密码（必填，须含字母+数字；不能与用户名相同；**不限制长度**，兼容 TG 短密码）
   - 说明：SOCKS5 协议本身几乎不限制格式；脚本仅做基础安全校验，**不再强制 8 位起**
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
- **卡在「正在生成配置文件...」**：旧版在 `curl|bash` 下可能被 stdin 吞脚本；请拉最新脚本，或改用：
  `curl -fsSL ... -o install.sh && bash install.sh`
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
| `examples/clash-meta-acl4ssr.yaml` | ACL4SSR Clash 规则模板（填 YOUR_* 后导入） |

安装后关键路径：

| 路径 | 说明 |
|------|------|
| `/etc/xray/config.json` | Xray 配置 |
| `/etc/xray/client-link.txt` | 客户端参数与分享链接 |
| `/etc/xray/clash-meta.yaml` | Clash Meta ACL4SSR 规则配置 |
| `/etc/xray/xray-client.json` | Xray 客户端分流配置 |
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

### v3.5（2026-09-17）— ACL4SSR 客户端分流
- 在 VPS 本机生成 Clash 订阅（随机口令 HTTP 路径），导入 Clash Verge 即出 ACL4SSR 分组
- **不使用**第三方订阅转换站，节点信息不会离开你的机器
- 规则模板为 [ACL4SSR_Online](https://github.com/ACL4SSR/ACL4SSR/blob/master/Clash/config/ACL4SSR_Online.ini)
- 同时生成本地备份 `/etc/xray/clash-meta.yaml` 与 `/etc/xray/xray-client.json`

### v3.4.8（2026-07-29）— 取消 SOCKS 密码长度强制限制
- 去掉密码必须 8-128 位的校验，兼容 Telegram 等短密码场景
- 仍保留字母+数字、非空、不与用户名相同等基础校验

### v3.4.7（2026-07-29）— 强调 SOCKS 端口需单独映射
- 明确：Reality `52300` 通不代表 SOCKS 端口通
- 安装/诊断输出补充 LXD proxy 与双端口外部检测说明

### v3.4.6（2026-07-29）— 修复 syntax error near unexpected token (
- 修复插入 SOCKS 自检时截断 `echo "正在获取公网 IP..."` 导致 bash 语法错误
- 加固 SOCKS 本机测试输出

### v3.4.5（2026-07-28）— 修复卡在“正在生成配置文件”
- 修复 `curl | bash` 场景下外部命令吞掉脚本 stdin，导致 heredoc 永久等待
- 管道安装时自动落盘临时文件再 exec；xray uuid/x25519/test 统一 `</dev/null`

### v3.4.4（2026-07-28）— 修复 SOCKS5 一直连接中
- 改用 jq 合并 SOCKS 入站，避免 heredoc 拼接异常
- 安装后本机 curl 经 SOCKS5 自检
- 文档明确：SOCKS 端口需单独安全组/LXD 映射

### v3.4.3（2026-07-28）— 修复 json_escape 语法错误
- 修复 `bash: syntax error near unexpected token out="$out\\"`
- `json_escape` 改为 python3/jq/awk 实现，去掉易碎 case 反斜杠分支

### v3.4.2（2026-07-28）— SOCKS 账号安全校验
- 明确：SOCKS5 协议无强制复杂度，脚本增加安全校验
- 用户名 1-64（字母数字._@+-）；密码须字母+数字（**长度不强制**）
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
