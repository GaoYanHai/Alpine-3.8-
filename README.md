# Xray Reality 管理脚本

面向 Alpine LXC / Debian LXD、NAT VPS 的 VLESS + TCP + REALITY + Vision 管理工具。所有操作集中在 **`xray.sh`**，自动识别系统，通过编号菜单管理安装、订阅、HTTPS、诊断和证书迁移。

支持 x86_64 / amd64；Alpine 使用 OpenRC / apk，Debian 使用 systemd / apt。安装与管理操作需要 root。

## 开始使用

下载后打开菜单，两种系统使用相同命令：

```sh
curl -fSL https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/xray.sh -o xray.sh
sh xray.sh
```

也可以使用 `wget`：

```sh
wget -O xray.sh https://raw.githubusercontent.com/GaoYanHai/Alpine-3.8-/main/xray.sh
sh xray.sh
```

以后进入脚本所在目录，运行 `sh xray.sh` 即可。更新管理工具时重新下载同一个文件，再打开菜单；下载文件本身不会修改正在运行的服务。

```text
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
```

| 要做的事 | 菜单选项 |
|---|---|
| 新机器安装 | **1**，按提示选择 SOCKS5 和订阅访问方式 |
| 升级现有订阅模板、修复分流配置 | **2**，随后在客户端更新订阅 |
| 已有节点开启 HTTPS，或接入自动续期 | **3** |
| 节点超时、测速一直 -1ms | **4** |
| 换机前备份证书 | **5** |
| 已有节点复用其他机器的证书 | **6** |
| 找回分享链接或订阅地址 | **7** |
| 调整端口、节点参数、SOCKS5 或订阅设置 | **10** |

**已有用户也只需下载 `xray.sh`。** 脚本继续使用 `/etc/xray/` 下的现有配置。更新订阅选 **2**，开启 HTTPS 选 **3**。选择 **1** 重新安装会生成新的 UUID、密钥和订阅口令，检测到已有配置时会要求确认。

支持直接指定同一菜单的编号，例如 `sh xray.sh 4`。无参数时进入循环菜单，操作结束或失败后可以继续选择，输入 **0** 退出。帮助：`sh xray.sh --help`。

## 安装与端口

选择 **1** 后，交互安装先询问 Reality 和订阅的容器监听端口、NAT 公网端口，直接回车使用默认值。随后安装 Xray-core、自动生成节点凭证、探测多地域 SNI 目标、生成客户端配置并启动服务。安装过程中可以启用 SOCKS5，并选择 Cloudflare 自动申请 HTTPS、使用已有公开证书、HTTP 或导入加密证书备份。

| 用途 | 默认容器监听端口 | 说明 |
|---|---|---|
| Reality 节点 | TCP `52300` | 客户端连接端口 |
| Clash / v2rayN 订阅 | TCP `58472` | 与节点端口分别放行 |
| 可选 SOCKS5 | TCP `10808` | 默认关闭，开启时必须设置账号密码 |

脚本尝试放行容器内防火墙；**云安全组、NAT 面板或宿主机映射需要自行设置**。Reality 和订阅都支持公网端口与容器监听端口不同，分享链接和客户端配置使用公网端口。已有安装通过主菜单 **10「修改配置」** 调整，不需要重新安装。

LXD 宿主机映射示例（替换实例名，命令在宿主机执行）：

```sh
lxc config device add <实例名> xrayproxy proxy listen=tcp:0.0.0.0:52300 connect=tcp:127.0.0.1:52300
lxc config device add <实例名> subproxy proxy listen=tcp:0.0.0.0:58472 connect=tcp:127.0.0.1:58472
```

同时配置 chrony 时间同步、每日 04:00 自动重启和 MTU / BBR 调优；容器不支持修改 MTU 或 BBR 时保留系统可用设置。首次安装建议先做快照。

## 修改端口和其他配置

运行 `sh xray.sh`，选择 **10「修改配置」**；也可以直接运行 `sh xray.sh 10`：

```text
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
```

例如，将 Reality 改为 **容器监听 `52301`、公网连接 `62443`**：

1. 主菜单选 **10**，子菜单选 **1**。
2. 分别填写 `52301` 和 `62443`，检查提示后输入 `y` 保存。
3. 在宿主机 / NAT 面板配置 **公网 TCP 62443 → 容器 TCP 52301**，同步放行云安全组。
4. 在客户端更新订阅；手动导入节点的用户，通过主菜单 **7** 获取新链接重新导入。

**修改订阅默认监听端口 `58472`，则在同一子菜单选 2。** 两个端口分别填写；只改容器端口并保留公网端口和口令时，订阅 URL 不变，但宿主机转发目标仍需更新。

保存前校验端口范围、监听端口冲突、新端口是否占用，以及 UUID、ShortId 等输入；SNI 变更会探测目标可达性，随后执行 Xray 配置测试。通过后生成新的分享链接、Clash / Xray 客户端配置和原生订阅，确认保存时备份到 `/etc/xray/config-backup-*`。重启或订阅自检失败时恢复原配置文件，并尝试重启原服务。

每次修改独立保存，完成或失败后返回配置菜单。UUID、ShortId、公网地址或公网端口变化需要客户端更新节点；重置订阅口令后旧订阅 URL 失效，须替换客户端订阅地址。SOCKS5 密码隐藏输入，启用后该端口也需要单独映射和放行。

「订阅域名 / HTTPS / 证书」可接入 Cloudflare 自动签发、使用自己的公开证书，或保留访问方式只改域名。HTTPS 域名必须被证书覆盖；更换域名后请同步更新 DNS。导入 `.p12` 仍使用主菜单 **6**。

## 客户端与订阅

安装完成后会打印分享链接和两种订阅地址，也可以通过菜单 **7** 再次查看：

```text
https://sub.example.com:58472/<随机口令>/clash.yaml
https://sub.example.com:58472/<随机口令>/vless.txt
```

选择 HTTP 时使用脚本实际输出的 `http://...` 地址。随机口令限制访问，HTTP 不提供传输加密；只修改 URL 的协议不能启用 HTTPS。

| 客户端 | 推荐导入方式 |
|---|---|
| Clash Verge / mihomo | `clash.yaml`，模式选择「规则」 |
| v2rayN | `vless.txt` 原生订阅，节点内核选择 Xray，路由选择「绕过大陆」 |
| 其他支持 Reality 的客户端 | 导入 `vless://` 分享链接 |

订阅由自己的 VPS 提供，无需第三方转换站。Clash 配置包含 ACL4SSR 策略组、国内直连、广告拦截和国外代理；原生 VLESS 订阅仅包含节点，分流由客户端路由控制。

v2rayN 导入完整 Clash YAML 时可能使用 mihomo 自定义配置。若 VLESS 正常而 YAML 测速超时，先通过 **2** 更新服务器订阅，再检查客户端内核、规则加载、DNS 和实际选中的节点。单次 `-1ms` 只代表该次测速未成功。

手动填写节点时：

| 参数 | 值 |
|---|---|
| 协议 / 传输 / 安全 | `vless` / `tcp` / `reality` |
| 地址 | 脚本输出的公网 IPv4，不能填容器内网地址 |
| 端口 | 默认 `52300`，以本机输出为准 |
| UUID / SNI / PublicKey / ShortId | 以本机输出为准 |
| Flow / Fingerprint / 加密 | `xtls-rprx-vision` / `chrome` / `none` |

新版 `xray x25519` 输出中的 **Password 对应客户端 PublicKey / pbk**，不要使用 Hash32。PrivateKey 只留在服务端。

## HTTPS 订阅

新安装时在订阅向导中选择 Cloudflare 自动申请；已有节点选择主菜单 **3**：

1. 填写完整订阅域名，例如 `sub.example.com`，不带协议、端口和路径。
2. 在 Cloudflare 添加指向 **NAT 宿主机公网 IP** 的 A 记录，选择「仅 DNS（灰云）」。
3. 映射并放行公网订阅 TCP 端口，例如公网 `58472` → 容器 `58472`；两者不同时填写实际公网端口。
4. 创建仅针对该域名区域的 Cloudflare API Token，权限为「区域 / DNS / 编辑」和「区域 / 区域 / 读取」，按提示隐藏输入。

脚本使用官方 acme.sh 和 Let's Encrypt DNS-01 签发公开证书，校验证书后开启 HTTPS，并配置每日续期检查及服务重载。**无需开放入站 80/443**。Cloudflare 边缘证书不能下载部署，Origin CA 不能用于灰云后的客户端直接访问。

切换后用新的 HTTPS URL 替换客户端原 HTTP 订阅地址。原节点和订阅口令保持不变；同一监听端口启用 TLS 后旧 HTTP URL 不再适用。本机自检验证订阅和证书，从客户端访问才能进一步确认公网 DNS 与 NAT 映射。

签发失败时按错误提示修正 Token、DNS 或网络，再选 **3** 重试。不要为订阅签发问题反复重新安装节点。菜单 **2** 会保留现有证书；手动管理的证书可通过 **3** 接入自动续期。

| 系统 | 自动续期任务 | 检查方法 |
|---|---|---|
| Alpine | `/etc/periodic/daily/xray-sub-renew` | `rc-service crond status`；`tail /var/log/xray-sub-renew.log` |
| Debian | `xray-sub-renew.timer` | `systemctl list-timers xray-sub-renew.timer`；`journalctl -u xray-sub-renew.service` |

使用已有公开证书时，可在安装向导中选择该方式；已有节点可设置下文环境变量后选 **2**。此方式校验证书，不接管续期。原证书工具续期后需重启订阅服务，可选择主菜单 **8**。

## 证书备份与换机

1. 旧 VPS 选择 **5**，填写导出路径（默认 `/root/sub-cert.p12`），输入并确认备份密码。
2. 将 `.p12` 下载到自己的电脑，再通过 SSH / SFTP 上传到新 VPS。
3. 新 VPS 尚未安装时，选择主菜单 **1**，在订阅向导中选「导入加密证书备份」；已经安装时，选择主菜单 **6**，填写备份路径和密码。
4. 将 Cloudflare 灰云 A 记录更新为新公网 IP，检查新机器端口映射，使用新机器输出的订阅地址。
5. 新机器选择 **3** 并提供 Cloudflare Token，重新接入自动续期。

备份为加密 PKCS#12，包含完整证书链和私钥，使用 AES-256-CBC、SHA-256 MAC 和 200000 次密码迭代。密码至少 8 个字符；文件仅 root 可读写，已有同名文件拒绝覆盖。请使用独立的长密码，备份和密码分别保管。

**证书备份不包含 Cloudflare Token、ACME 续期账户、节点参数或订阅口令。** 导入只复用证书，不能恢复整台旧机器，也不会延长证书有效期。证书导出不要求 Xray 正在运行。

导入时校验证书链、公私钥、域名和有效期（剩余须超过 24 小时），使用独立目录保存通过校验的证书。错误密码、损坏文件、不受信任证书、域名不匹配或即将过期时停止导入。

## 诊断与日常维护

连接超时或测速一直 `-1ms` 时，先选 **4**。诊断检查进程、监听、配置、SNI / dest 可达性、防火墙、时间和日志。它会访问公网 IP 检测与 SNI 目标，通常需要一些时间；诊断不会重新安装节点。

优先检查：

1. 云安全组与宿主机是否放行、映射 **节点 TCP 端口**。
2. 客户端是否使用公网地址，节点参数是否与菜单 **7** 一致。
3. 服务是否监听 `0.0.0.0`，服务器时间与 SNI / dest 是否正常。

从客户端电脑验证端口，例如 Windows PowerShell：

```powershell
Test-NetConnection -ComputerName <公网IP> -Port 52300
Test-NetConnection -ComputerName <订阅域名> -Port 58472
```

菜单 **8** 重启 Xray 与订阅服务，**9** 查看最近日志；修改端口、SNI、UUID、ShortId 等参数统一使用 **10**，脚本同步生成客户端文件和链接。

菜单 **2** 只重建订阅文件并重启订阅服务，保留节点参数、端口、口令和现有 HTTPS 配置；更新前将原订阅相关文件备份到 `/etc/xray/subscription-backup-*`。它不会升级 Xray-core。选项 **1** 会下载最新内核并重新安装节点。

SOCKS5 默认关闭，可在安装时开启。用户名为 1–64 个字母、数字或 `._@+-`，密码必须非空；脚本不强制密码长度或复杂度，公网使用请设置强密码，并单独映射、放行 SOCKS 端口。

## 高级参数

通常直接使用菜单即可。自动化场景可以用环境变量配合同一菜单编号：

| 变量 | 用途 / 默认值 |
|---|---|
| `PORT` | Reality 节点监听端口，默认 `52300`，安装时使用 |
| `NODE_PUBLIC_PORT` | Reality NAT 公网端口，默认与 `PORT` 相同，写入客户端链接与配置 |
| `CLASH_SUB_PORT` | 订阅监听端口，默认 `58472` |
| `CLASH_SUB_PUBLIC_PORT` | NAT 公网订阅端口，默认与监听端口相同 |
| `CLASH_SUB_HTTPS` | `auto` / `cloudflare` / `existing` / `import` / `off`；新安装默认 `auto`，普通更新保留原访问方式 |
| `CLASH_SUB_HOST` | 完整订阅域名 |
| `CLASH_SUB_TLS_CERT` / `CLASH_SUB_TLS_KEY` | 已有公开证书的 PEM 完整链和私钥路径 |
| `CF_Token` | Cloudflare Token；未设置时隐藏输入 |
| `CLASH_SUB_CERT_BUNDLE` | 安装时要导入的 `.p12` 路径 |
| `CERT_BUNDLE_PASSWORD` | 自动化证书导入 / 导出的密码；交互时隐藏输入 |
| `ENABLE_SOCKS` | `1` 启用 SOCKS5，默认 `0` |
| `SOCKS_PORT` / `SOCKS_USER` / `SOCKS_PASS` | SOCKS5 端口、账号、密码 |

已有节点使用自己管理的公开证书：

```sh
CLASH_SUB_HTTPS=existing \
CLASH_SUB_HOST=sub.example.com \
CLASH_SUB_TLS_CERT=/etc/xray/tls/fullchain.pem \
CLASH_SUB_TLS_KEY=/etc/xray/tls/key.pem \
sh xray.sh 2
```

新机器无交互安装为 HTTP 订阅：

```sh
CLASH_SUB_HTTPS=off sh xray.sh 1
```

通过安全环境预先提供 `CF_Token` 后，已有节点无交互接入 HTTPS：

```sh
CLASH_SUB_HOST=sub.example.com CLASH_SUB_PUBLIC_PORT=58472 sh xray.sh 3
```

不要把真实 Token、密码、私钥或订阅 URL 提交到仓库。已有 TLS 配置时拒绝通过 `off` 静默降级为 HTTP。

## 文件说明

仓库只保留统一入口和说明文件，不需要额外下载安装器、订阅更新工具或诊断工具。客户端模板由脚本直接生成。

| 服务器路径 | 内容 |
|---|---|
| `/etc/xray/config.json` | 服务端节点配置 |
| `/etc/xray/client-link.txt` | 节点参数、分享链接与订阅地址 |
| `/etc/xray/clash-meta.yaml` | Clash / mihomo 分流配置 |
| `/etc/xray/xray-client.json` | Xray 客户端分流配置 |
| `/etc/xray/v2rayn.txt` | Base64 编码的原生 VLESS 订阅 |
| `/etc/xray/clash-sub.env` | Reality 公网端口、订阅端口、随机口令与 TLS 路径 |
| `/etc/xray/tls/` | 订阅证书和私钥 |
| `/var/log/xray.log` | 节点文件日志 |

上述文件可能含敏感信息，请勿公开。ACL4SSR 规则来源：[ACL4SSR/ACL4SSR](https://github.com/ACL4SSR/ACL4SSR)。

License：MIT。
