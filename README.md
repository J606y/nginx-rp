# nginx-rp

一个面向 **Debian / Ubuntu** 的 Nginx 反向代理一键脚本：交互式菜单完成「装 Nginx → 配反代 → 自动 HTTPS 证书 → 自动续签 → 缓存档位 → 安全收紧」整条链路，适合把边缘 Nginx 反代到源站（如某后端 `origin:8080` 的视频流）。

> 集成 acme.sh 自动签发 / 续签、按站点的缓存档位、HTTPS 回源、禁 IP 直连、后端端口封锁与脚本自更新，开箱即用。

## 功能

- **安装 Nginx**：自动补 `nginx.conf` 对 `sites-enabled` 的 include、放行 80/443 防火墙（ufw / firewalld / iptables 自适应）；已有 Nginx（含 Docker / 手动启动）不重复安装、不抢端口，只平滑重载。
- **配置反向代理**：按域名生成站点配置，支持 `http://127.0.0.1:8080` 本机后端，也支持 `https://源站域名` 回源（自动补 SNI 与源站 Host，避免串站）。
- **自动 HTTPS 证书**（acme.sh，默认 Let's Encrypt）：
  - HTTP-01（webroot，需 80 可达）
  - DNS API（Cloudflare / 阿里云 / 腾讯云 DNSPod，支持泛域名 `*.domain`）
  - 使用已有本地证书文件
  - 签发即托管自动续签（内置 cron，续签后自动 reload）
- **三种缓存档位**：无缓存（纯流媒体/上传，关闭缓冲）、普通缓存（网页/静态，Range 与视频自动绕过）、视频分片缓存（slice 切片缓存 Range 响应）。
- **安全收紧**：
  - 禁止用 IP / 未知域名直接访问（default_server 兜底，HTTP 444、HTTPS `ssl_reject_handshake`，老版本回落自签证书）。
  - 封锁后端端口公网直连（iptables，同时处理 `DOCKER-USER` 链，保留本机回环给 Nginx）。
- **快捷命令 `n`**：首次运行后安装到 `/usr/local/bin`，以后任意目录输入 `n` 即可打开菜单（非 root 自动 `sudo` 提权）。
- **脚本自更新**：菜单「更新本脚本」从 GitHub 拉最新版（优先 API 端点避开 CDN 缓存，失败回退 raw），语法校验通过才覆盖。

## 一键安装 / 运行

root 用户（推荐，脚本本就要求 root）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/J606y/nginx-rp/main/nginx-rp.sh)
```

> 用进程替换 `<(...)` 而不是 `curl | bash`：管道形式会把脚本本身当成标准输入，
> 菜单的 `read` 读不到你的键盘输入，表现为「卡住 / 没反应」。

非 root 用户先下载再用 sudo 运行（`sudo` 配进程替换可能因关闭文件描述符而失败，故分两步）：

```bash
curl -fsSL https://raw.githubusercontent.com/J606y/nginx-rp/main/nginx-rp.sh -o nginx-rp.sh
sudo bash nginx-rp.sh
```

首次运行会把脚本安装到 `/usr/local/bin/nginx-rp.sh` 并创建快捷命令 `n`，之后直接：

```bash
n
```

## 环境要求

- Debian / Ubuntu（使用 `apt`）
- root 权限（`sudo`）
- 推荐 nginx ≥ 1.25；`ssl_reject_handshake`（禁 IP 直连的 HTTPS 兜底）需要 nginx ≥ 1.19.4，更老版本会自动回落到自签证书 + 444

## 菜单一览

```
1. 安装 Nginx
2. 配置反向代理
3. 管理反向代理
   ├─ 管理已配置站点（改目标 / 改缓存 / 换证书 / 删除）
   ├─ 证书 / 自动续签管理
   ├─ 后端端口直连封锁（开 / 关）
   └─ 禁止用 IP 直接访问（开 / 关，仅域名可访问）
4. 卸载 Nginx
5. 更新本脚本（拉 GitHub 最新）
0. 退出
```

## 文件落点

| 路径 | 说明 |
| --- | --- |
| `/etc/nginx/sites-available/<域名>.conf` | 各站点配置（含本脚本元信息注释，用于回读管理） |
| `/etc/nginx/conf.d/00-nginx-rp.conf` | 公共配置：缓存区、WebSocket map、媒体跳过缓存 map |
| `/etc/nginx/conf.d/00-deny-direct-ip.conf` | 「禁止 IP 直连」兜底 server（开启后存在） |
| `/etc/nginx/certs/<域名>/` | 安装到 Nginx 的证书（fullchain.pem / key.pem） |
| `/var/cache/nginx/nginx_rp` | 反代缓存目录 |
| `~/.acme.sh/` | acme.sh 与自动续签 cron |

## 注意

- 云厂商安全组 / 安全列表（Oracle、阿里云等）需另在控制台收紧；本脚本只改本机 iptables。
- 「禁止 IP 直连」会停用系统自带的 `sites-enabled/default`（它也占 `default_server`，否则冲突）。
- DNS API 泛域名需要对应服务商的 API 凭据，按提示输入。

## 致谢

由 [Claude Code](https://claude.com/claude-code) 编写。

## License

[MIT](LICENSE)
