#!/bin/bash
# ============================================================================
#  Nginx 反向代理一键脚本（增强版）
#  作者：J606y · 代码由 Claude Code 编写（https://claude.com/claude-code）
#  主要功能：
#    - acme.sh 自动申请证书（HTTP-01 webroot / DNS API 泛域名）
#    - acme.sh 自动续签（内置 cron，签发即托管，附续签管理菜单）
#    - 针对不同站点的 Nginx 缓存开关（无缓存 / 普通缓存 / 视频分片缓存）
#
#  目标环境：Debian / Ubuntu + 系统 nginx（apt / systemd），nginx >= 1.25
#  适用场景：边缘 nginx 反代到源站（如某后端 origin:8080 视频流）
#
#  一键安装/运行（root，用进程替换 <(...) 避免管道把脚本当 stdin 导致菜单卡住）：
#    bash <(curl -fsSL https://raw.githubusercontent.com/J606y/nginx-rp/main/nginx-rp.sh)
#  非 root 先下载再运行（sudo 配进程替换可能因关闭文件描述符失败）：
#    curl -fsSL .../nginx-rp.sh -o nginx-rp.sh && sudo bash nginx-rp.sh
#  装好后以后直接输入快捷命令： n
# ============================================================================

set -o pipefail

# ----------------------------- 全局变量 -------------------------------------
SITES_AVAIL="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
GLOBAL_CONF="/etc/nginx/conf.d/00-nginx-rp.conf"
DENY_IP_CONF="/etc/nginx/conf.d/00-deny-direct-ip.conf"   # 禁止用 IP 直连的兜底 server
CERT_DIR="/etc/nginx/certs"
ACME_WEBROOT="/var/www/acme"
CACHE_DIR="/var/cache/nginx/nginx_rp"
ACME_HOME="$HOME/.acme.sh"
ACME="$ACME_HOME/acme.sh"
REQUIRED_PORTS=(80 443)

# 快捷命令：安装到固定路径后，输入 SHORTCUT_CMD 即可打开本菜单
INSTALL_PATH="/usr/local/bin/nginx-rp.sh"
SHORTCUT_CMD="n"
SHORTCUT_PATH="/usr/local/bin/$SHORTCUT_CMD"
# 自更新地址（菜单「更新本脚本」用）。
# 优先用 GitHub API contents 端点：基本无 CDN 缓存，秒级反映最新提交。
# 失败再回退 raw（raw 有约 5 分钟 CDN 缓存，加随机 query 尽量绕过）。
RAW_API_URL="https://api.github.com/repos/J606y/nginx-rp/contents/nginx-rp.sh?ref=main"
RAW_URL="https://raw.githubusercontent.com/J606y/nginx-rp/main/nginx-rp.sh"

# ----------------------------- 颜色输出 -------------------------------------
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_blue()  { printf '\033[36m%s\033[0m\n' "$*"; }
info()  { c_blue  "[*] $*"; }
ok()    { c_green "[✓] $*"; }
warn()  { c_yellow "[!] $*"; }
err()   { c_red   "[✗] $*"; }

pause() { read -rp "按回车键继续..." _; }

# ----------------------------- 前置检查 -------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请用 root 运行： sudo bash $0"
        exit 1
    fi
}

require_apt() {
    if ! command -v apt-get >/dev/null 2>&1; then
        err "本脚本面向 Debian / Ubuntu（apt）。当前系统不支持，请手动适配。"
        exit 1
    fi
}

# 通过 curl|bash 运行时 stdin 是管道而非键盘：read -rp 不显示提示、且会卡住/读到 EOF
# （表现为“输入后直接卡死”）。把交互输入接回控制终端即可。
ensure_tty() { [ -t 0 ] || { [ -r /dev/tty ] && exec </dev/tty; }; return 0; }

# 拉取本脚本最新版到指定文件（无缓存优先）。返回 0 成功 / 1 失败。
# ① GitHub API contents 端点：基本无缓存；② 回退 raw + 随机 query 尽量绕过缓存。
fetch_latest_self() {
    local out="$1"
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsSL -H 'Accept: application/vnd.github.raw' "$RAW_API_URL" -o "$out" 2>/dev/null && return 0
    curl -fsSL "$RAW_URL?nocache=$(date +%s 2>/dev/null)" -o "$out" 2>/dev/null
}

# 安装快捷命令：把脚本拷到 /usr/local/bin，并创建命令 n。
# 每次启动调用：已安装则静默（顺便更新脚本本体/刷新启动器），首次安装则提示。
setup_shortcut() {
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"

    # 把脚本本体安装/更新到固定路径：
    #  - 正常以文件运行（self 是真实文件）→ 直接拷贝；
    #  - 通过 curl|bash 运行（self 不是真实文件）且本体还不存在 → 从 GitHub 拉一份，
    #    避免装出一个指向不存在文件的悬空快捷命令（曾导致 n: No such file or directory）。
    if [ -n "$self" ] && [ -f "$self" ] && [ "$self" != "$INSTALL_PATH" ]; then
        cp -f "$self" "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH"
    elif [ ! -f "$INSTALL_PATH" ]; then
        if fetch_latest_self "$INSTALL_PATH" && bash -n "$INSTALL_PATH" 2>/dev/null; then
            chmod +x "$INSTALL_PATH"
        else
            rm -f "$INSTALL_PATH" 2>/dev/null   # 没拉成功就别留半截文件
        fi
    fi

    # 没有可用的脚本本体就不创建快捷命令，否则又会装出悬空的 n
    [ -f "$INSTALL_PATH" ] || return 0

    # 快捷命令被别的程序占用则跳过（只认我们自己写的）
    if [ -e "$SHORTCUT_PATH" ] && ! grep -q "nginx-rp" "$SHORTCUT_PATH" 2>/dev/null; then
        warn "命令「$SHORTCUT_CMD」已被占用（非本脚本），跳过创建。可改名（编辑脚本顶部 SHORTCUT_CMD）。"
        return 0
    fi

    # 创建/刷新启动器（每次重写，确保旧版启动器也能用上最新逻辑，并自愈悬空 n）。
    # 非 root 调用时自动 sudo 提权——脚本需要 root，否则会被 require_root 直接挡掉。
    local first=1; [ -e "$SHORTCUT_PATH" ] && first=0
    cat > "$SHORTCUT_PATH" <<EOF
#!/bin/bash
# nginx-rp 快捷启动器（非 root 自动 sudo 提权）
if [ "\$(id -u)" -ne 0 ]; then exec sudo bash "$INSTALL_PATH" "\$@"; fi
exec bash "$INSTALL_PATH" "\$@"
EOF
    chmod +x "$SHORTCUT_PATH"
    if [ "$first" = 1 ]; then
        clear
        ok "快捷命令安装成功！以后在任意目录输入  $SHORTCUT_CMD  即可打开本菜单。"
        echo "  脚本已安装到：$INSTALL_PATH"
        pause
    fi
}

# 从 GitHub 拉最新脚本覆盖安装路径并重启自身。
# 解决「n 快捷命令永远跑旧版」的问题（脚本本体不会自更新）。
self_update() {
    command -v curl >/dev/null 2>&1 || { err "需要 curl"; pause; return; }
    local tmp; tmp="$(mktemp)"
    info "从 GitHub 拉取最新脚本（API 端点，无缓存）..."
    if ! fetch_latest_self "$tmp"; then
        err "下载失败，检查网络。"; rm -f "$tmp"; pause; return
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        err "下载到的脚本语法不通过，已放弃（可能拉到旧缓存/半截文件）。"; rm -f "$tmp"; pause; return
    fi
    if cp -f "$tmp" "$INSTALL_PATH" 2>/dev/null && chmod +x "$INSTALL_PATH"; then
        rm -f "$tmp"
        ok "已更新到最新版，正在重启脚本..."; sleep 1
        exec bash "$INSTALL_PATH"
    else
        err "写入 $INSTALL_PATH 失败（需 root）。"; rm -f "$tmp"; pause
    fi
}

# 重载 nginx：兼容三种情况——① systemd 托管；② 手动/其它方式起的「野」nginx；
# ③ 当前没运行。不依赖 /run/nginx.pid（野进程常常没写它，导致 nginx -s reload
# 报 invalid PID），而是直接定位正在运行的 master 进程发 HUP 重载（零停机）。
reload_nginx() {
    if ! nginx -t 2>/tmp/nginx_test.log; then
        err "Nginx 配置测试失败，未重载。错误如下："
        cat /tmp/nginx_test.log
        return 1
    fi

    # 找到正在运行的 master（pid 文件优先，陈旧则回退到进程扫描）
    local mpid
    mpid="$(cat /run/nginx.pid 2>/dev/null)"
    [ -n "$mpid" ] && ! kill -0 "$mpid" 2>/dev/null && mpid=""
    [ -z "$mpid" ] && mpid="$(pgrep -o -x nginx 2>/dev/null)"

    # ① systemd 正好管着这个 master → 用 systemd reload（状态最干净）
    if [ -n "$mpid" ] && systemctl is-active --quiet nginx 2>/dev/null \
       && [ "$(systemctl show -p MainPID --value nginx 2>/dev/null)" = "$mpid" ]; then
        systemctl reload nginx && { ok "Nginx 已重载（systemd）"; return 0; }
    fi

    # ② 有在跑的 master 但不归 systemd 管 → 直接 HUP 它重载，不碰 pid 文件
    if [ -n "$mpid" ] && kill -0 "$mpid" 2>/dev/null; then
        kill -HUP "$mpid" && { ok "Nginx 已重载（HUP master $mpid）"; return 0; }
    fi

    # ③ 当前没运行 → 启动（优先 systemd，回退裸命令）
    if systemctl start nginx 2>/dev/null || nginx 2>/dev/null; then
        ok "Nginx 已启动"
        return 0
    fi

    err "Nginx 重载/启动失败。"
    return 1
}

# ----------------------------- 防火墙 ---------------------------------------
open_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in "${REQUIRED_PORTS[@]}"; do ufw allow "$p"/tcp >/dev/null 2>&1; done
        ok "ufw 已放行 ${REQUIRED_PORTS[*]}"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        for p in "${REQUIRED_PORTS[@]}"; do firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1; done
        firewall-cmd --reload >/dev/null 2>&1
        ok "firewalld 已放行 ${REQUIRED_PORTS[*]}"
    elif command -v iptables >/dev/null 2>&1; then
        for p in "${REQUIRED_PORTS[@]}"; do
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
        done
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
        ok "iptables 已放行 ${REQUIRED_PORTS[*]}（如需持久化请确认 netfilter-persistent）"
    else
        warn "未检测到受支持的防火墙，跳过。请自行确认 80/443 已放行。"
    fi
}

# ------------------- 后端端口直连封锁（仅经域名/Nginx 访问） -----------------
# 反代建好后，常希望禁止公网再用 http://IP:端口 直连后端（如后端 8080）。
# 做法：iptables 丢弃「非回环」入站到该端口的流量，保留 lo 让 Nginx(127.0.0.1) 仍可访问。
# 注意：Docker 发布的端口（compose 里 8080:8080）走 DOCKER-USER 链，绕过 INPUT/ufw，
#       所以必须同时在 DOCKER-USER 链下规则，否则封不住。

# 需要操作的链：DOCKER-USER（存在则优先，管 Docker 发布端口）+ INPUT（管本机服务）
_iptables_block_chains() {
    iptables -nL DOCKER-USER >/dev/null 2>&1 && echo DOCKER-USER
    echo INPUT
}

# 任一链已存在 DROP 规则即视为已封锁
backend_port_blocked() {
    local port="$1" ch
    for ch in $(_iptables_block_chains); do
        iptables -C "$ch" -p tcp --dport "$port" ! -i lo -j DROP 2>/dev/null && return 0
    done
    return 1
}

restrict_port() {
    local port="$1" ch
    command -v iptables >/dev/null 2>&1 || {
        warn "未找到 iptables，跳过。请用云安全组/防火墙封锁端口 $port 的公网入站。"; return 0; }
    for ch in $(_iptables_block_chains); do
        iptables -C "$ch" -p tcp --dport "$port" ! -i lo -j DROP 2>/dev/null || \
            iptables -I "$ch" 1 -p tcp --dport "$port" ! -i lo -j DROP
    done
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    ok "已封锁公网直连 :$port（保留本机回环，Nginx 反代不受影响）"
    warn "云厂商安全组/安全列表（Oracle / 阿里云等）需另在控制台收紧，本脚本只改本机 iptables。"
}

unrestrict_port() {
    local port="$1" ch
    command -v iptables >/dev/null 2>&1 || return 0
    for ch in $(_iptables_block_chains); do
        while iptables -C "$ch" -p tcp --dport "$port" ! -i lo -j DROP 2>/dev/null; do
            iptables -D "$ch" -p tcp --dport "$port" ! -i lo -j DROP
        done
    done
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    ok "已解除端口 $port 的公网直连封锁"
}

# 从反代目标解析端口并校验是否本机，再封锁
restrict_backend_port() {
    local target="$1" hp host port
    hp="${target#*://}"; hp="${hp%%/*}"     # 去掉 scheme 和路径 -> host[:port]
    host="${hp%%:*}"; port="${hp##*:}"
    [ "$host" = "$port" ] && port=""        # 没写端口
    case "$target" in https://*) port="${port:-443}" ;; *) port="${port:-80}" ;; esac
    case "$host" in
        127.0.0.1|localhost|::1|0.0.0.0) ;;
        *) warn "反代目标 $host 不在本机，无法在此封锁端口 $port。"
           warn "请到后端所在主机上操作，或把后端端口仅绑定 127.0.0.1。"; return 0 ;;
    esac
    restrict_port "$port"
}

# ------------------- 禁止用 IP 直接访问（仅允许域名） -----------------------
# 加一个 default_server 兜底：Host/SNI 不是已配置域名（即用 IP 或未知域名访问）时，
# HTTP 直接 444、HTTPS 拒绝握手。真实站点都带 server_name，只有 IP/未知域名会落到这里。
deny_ip_enabled() { [ -f "$DENY_IP_CONF" ]; }

# nginx >= 1.19.4 才有 ssl_reject_handshake（可不带证书直接拒绝未知 SNI）
nginx_supports_reject_handshake() {
    local v
    v=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$v" ] && [ "$(printf '%s\n1.19.4\n' "$v" | sort -V | head -1)" = "1.19.4" ]
}

# 老版本 nginx 回落：生成一张自签证书占位（只给兜底 server 用，真实域名各走各的证书）
ensure_snakeoil_cert() {
    local d="$CERT_DIR/_snakeoil"
    [ -f "$d/crt.pem" ] && [ -f "$d/key.pem" ] && return 0
    command -v openssl >/dev/null 2>&1 || return 1
    mkdir -p "$d"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=invalid" \
        -keyout "$d/key.pem" -out "$d/crt.pem" >/dev/null 2>&1
}

enable_deny_ip() {
    command -v nginx >/dev/null 2>&1 || { err "请先安装 Nginx（菜单 1）"; return 1; }
    # 系统自带默认站点也占 default_server，会冲突，先停用
    if [ -e "$SITES_ENABLED/default" ]; then
        rm -f "$SITES_ENABLED/default"
        warn "已停用系统默认站点 sites-enabled/default（避免 default_server 冲突）"
    fi

    # 443 兜底块：优先 ssl_reject_handshake；老版本回落自签证书 + 444
    local https_block=""
    if nginx_supports_reject_handshake; then
        https_block="    ssl_reject_handshake on;"
    elif ensure_snakeoil_cert; then
        https_block="    ssl_certificate     $CERT_DIR/_snakeoil/crt.pem;
    ssl_certificate_key $CERT_DIR/_snakeoil/key.pem;
    return 444;"
    else
        warn "nginx 太旧且无 openssl，HTTPS 用 IP 访问无法封，仅封 HTTP。"
    fi

    {
        echo "# 由 nginx-rp.sh 管理：禁止用 IP / 未知域名直接访问，只有配置过的域名能访问。"
        echo "server {"
        echo "    listen 80 default_server;"
        echo "    listen [::]:80 default_server;"
        echo "    server_name _;"
        echo "    return 444;"
        echo "}"
        if [ -n "$https_block" ]; then
            echo "server {"
            echo "    listen 443 ssl default_server;"
            echo "    listen [::]:443 ssl default_server;"
            echo "    server_name _;"
            echo "$https_block"
            echo "}"
        fi
    } > "$DENY_IP_CONF"

    if reload_nginx; then
        ok "已开启：用 IP 直接访问将被拒绝，只有域名能打开。"
    else
        err "配置测试失败，已回滚（可能与已有 default_server 冲突）。"
        rm -f "$DENY_IP_CONF"; reload_nginx
        return 1
    fi
}

disable_deny_ip() {
    [ -f "$DENY_IP_CONF" ] || { info "未开启「禁止 IP 直连」"; return 0; }
    rm -f "$DENY_IP_CONF"
    reload_nginx && ok "已关闭「禁止 IP 直连」（IP 访问恢复默认行为）。"
}

# ----------------------------- 全局配置 -------------------------------------
# 写入 http 上下文的公共配置：缓存区、websocket upgrade map、媒体类型跳过缓存 map
ensure_global_conf() {
    # 兼容旧版（曾用 1keji 命名）：删掉遗留的全局配置，否则它与新文件重复定义
    # rpcache 缓存区 / map，会让 nginx -t 因重复声明失败。待各机迁移完可移除本行。
    rm -f /etc/nginx/conf.d/00-1keji-rp.conf 2>/dev/null
    mkdir -p "$ACME_WEBROOT" "$CACHE_DIR" "$CERT_DIR"
    id www-data >/dev/null 2>&1 && chown -R www-data:www-data "$CACHE_DIR" 2>/dev/null
    cat > "$GLOBAL_CONF" <<'EOF'
# 由 nginx-rp.sh 管理，请勿手动编辑。
# 反代缓存区（普通缓存 / 视频分片缓存共用）
proxy_cache_path /var/cache/nginx/nginx_rp levels=1:2 keys_zone=rpcache:100m max_size=10g inactive=7d use_temp_path=off;

# WebSocket: 根据 Upgrade 头决定 Connection
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# 普通缓存模式下：命中这些响应类型时不写入缓存（视频/音频/大文件流/m3u8/dash）
map $upstream_http_content_type $rp_skip_media {
    default                    0;
    ~*^video/                  1;
    ~*^audio/                  1;
    application/octet-stream   1;
    ~*mpegurl                  1;
    ~*dash\+xml                1;
}
EOF
    ok "公共配置已写入 $GLOBAL_CONF"
}

# ----------------------------- 安装 Nginx -----------------------------------
install_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        warn "检测到本机已有 Nginx：$(nginx -v 2>&1)，不再重复安装。"
    else
        info "更新软件源并安装 Nginx..."
        apt-get update -y && apt-get install -y nginx
        ok "Nginx 安装完成"
    fi

    mkdir -p "$SITES_AVAIL" "$SITES_ENABLED"
    # 确保 nginx.conf 引入 sites-enabled（部分精简安装没有）
    if ! grep -qE "include\s+/etc/nginx/sites-enabled/\*" /etc/nginx/nginx.conf; then
        sed -i '/include \/etc\/nginx\/conf.d\/\*.conf;/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
        warn "已向 nginx.conf 补充 sites-enabled 引入"
    fi

    ensure_global_conf
    open_firewall

    # 关键：已有正在运行的 nginx（含 Docker / 手动起的）就【绝不再起第二个】，
    # 否则会抢 80/443 导致 systemd 启动失败。只平滑重载让新配置生效。
    if pgrep -x nginx >/dev/null 2>&1; then
        warn "已有正在运行的 Nginx，跳过启动（避免抢占 80/443），仅重载使配置生效。"
        reload_nginx
    else
        systemctl enable nginx >/dev/null 2>&1
        systemctl start nginx 2>/dev/null || nginx
        reload_nginx
    fi
    ok "Nginx 就绪"
    pause
}

# ----------------------------- 更新 Nginx -----------------------------------
# 升级 apt 安装的系统 Nginx 到软件源最新版本（仅升级 nginx 相关包，不动其它软件）。
# 说明：HUP 重载只换配置不换二进制；apt 升级 nginx 时其 postinst 通常会自动重启
#       systemd 托管的 nginx 让新版本生效，这里再 reload 一次确保配置无误并在线。
update_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        err "未检测到 Nginx，请先安装（菜单 1）"; pause; return
    fi
    local old; old=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    info "当前 Nginx 版本：${old:-未知}，更新软件源并检查升级..."
    apt-get update -y
    # 同时升级 nginx 元包与实际承载二进制的 nginx-core / nginx-common（与卸载逻辑对应）
    if ! apt-get install -y --only-upgrade nginx nginx-common nginx-core; then
        err "升级失败，请检查软件源 / 网络后重试。"; pause; return
    fi
    local new; new=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$new" ] && [ "$old" = "$new" ]; then
        ok "已是软件源最新版本（${new}），无需升级。"
    else
        ok "Nginx 已升级：${old:-?} -> ${new:-?}"
        warn "若运行中的进程仍是旧版本（非 systemd / Docker 自管的 nginx），请手动重启使新二进制生效。"
    fi
    reload_nginx
    pause
}

# ----------------------------- 确保 acme.sh ---------------------------------
# 邮箱格式校验：local@domain.tld，且排除保留/不可投递域名（localhost/.local/.test...）。
# Let's Encrypt 会对 contact 邮箱做解析校验，非法地址会以 invalidContact 拒绝注册。
valid_email() {
    local e="$1"
    local re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    [[ "$e" =~ $re ]] || return 1
    case "${e##*@}" in
        localhost|*.local|*.localhost|*.internal|*.example|*.test|*.invalid) return 1 ;;
    esac
    return 0
}

# 是否已成功注册过 Let's Encrypt 账户（ca.conf 里存有真实 ACCOUNT_URL 才算数）。
le_account_registered() {
    grep -rqs "ACCOUNT_URL='http" "$ACME_HOME/ca/acme-v02.api.letsencrypt.org" 2>/dev/null
}

# 注册 Let's Encrypt 账户。邮箱可选：
#  - 传入合法邮箱 → 带 -m 注册；失败（如 invalidContact）则自动回退到「无邮箱」重试。
#  - 无邮箱 → 先清掉 account.conf 里可能残留的脏邮箱，再匿名注册（LE 已停发到期邮件，完全 OK）。
# 返回 0 成功 / 1 失败。
register_le_account() {
    local email="$1"
    if [ -n "$email" ] && "$ACME" --register-account -m "$email" --server letsencrypt; then
        return 0
    fi
    [ -n "$email" ] && warn "用邮箱注册失败，改用「无邮箱」方式重试..."
    # 清掉残留脏邮箱：account.conf 与各 CA 的 ca.conf(CA_EMAIL) 都要清——
    # acme.sh 注册前会把邮箱写进 ca.conf，只清 account.conf 会被它反复捞回来用，
    # 导致 invalidContact 一直复现。
    sed -i '/EMAIL=/d' "$ACME_HOME/account.conf" 2>/dev/null
    find "$ACME_HOME/ca" -name ca.conf -exec sed -i '/EMAIL=/d' {} + 2>/dev/null
    "$ACME" --register-account --server letsencrypt
}

# 证书功能首次使用时自动安装 acme.sh（含自动续签 cron）。返回 0 成功 / 1 失败。
ensure_acme() {
    if [ -f "$ACME" ]; then
        "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1
        # acme.sh 已装但账户没注册成功（例如上次填了坏邮箱）→ 在这里补注册，
        # 否则会等到 --issue 时才报 invalidContact。
        if ! le_account_registered; then
            register_le_account "" >/dev/null 2>&1 || \
                { err "Let's Encrypt 账户注册失败，请检查网络后重试。"; return 1; }
        fi
        return 0
    fi
    info "首次使用证书功能，自动安装 acme.sh..."
    apt-get install -y curl socat >/dev/null 2>&1
    local email
    read -rp "接收证书到期提醒的邮箱（Let's Encrypt 已停发提醒邮件，可直接回车跳过）: " email
    if [ -n "$email" ] && ! valid_email "$email"; then
        warn "邮箱格式无效或为保留域名，将以「无邮箱」方式注册。"
        email=""
    fi
    if [ -n "$email" ]; then
        curl -fsSL https://get.acme.sh | sh -s email="$email"
    else
        curl -fsSL https://get.acme.sh | sh
    fi
    if [ ! -f "$ACME" ]; then
        err "acme.sh 安装失败，请检查网络。"
        return 1
    fi
    # 默认 CA 用 Let's Encrypt（避免 ZeroSSL 需要 EAB 注册）；安装即自带续签 cron
    "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1
    "$ACME" --upgrade --auto-upgrade >/dev/null 2>&1
    # 显式注册账户：把 invalidContact 之类问题在这里就暴露/兜底，而不是拖到签发时才炸
    if ! register_le_account "$email"; then
        err "Let's Encrypt 账户注册失败，请检查网络后重试。"
        return 1
    fi
    ok "acme.sh 就绪；Let's Encrypt 账户已注册；自动续签 cron 已安装"
    return 0
}

# ----------------------------- 证书签发 -------------------------------------
# 通过 webroot(HTTP-01) 签发；要求该域名已 A 记录指向本机且 80 端口可达，
# 且本机已存在监听该域名 80 端口、serving /var/www/acme 的 server（add_site 会先建）。
issue_cert_http() {
    local domain="$1"
    ensure_acme || return 1
    info "通过 HTTP-01(webroot) 为 $domain 申请证书..."
    "$ACME" --issue -d "$domain" --webroot "$ACME_WEBROOT" --keylength ec-256 --server letsencrypt
}

# 通过 DNS API 签发（支持泛域名 *.domain）
issue_cert_dns() {
    local domain="$1" provider="$2"
    ensure_acme || return 1
    local dnsapi=""
    case "$provider" in
        cloudflare)
            read -rp "Cloudflare API Token (CF_Token): " CF_Token
            export CF_Token; dnsapi="dns_cf" ;;
        aliyun)
            read -rp "阿里云 Ali_Key: "    Ali_Key
            read -rp "阿里云 Ali_Secret: " Ali_Secret
            export Ali_Key Ali_Secret; dnsapi="dns_ali" ;;
        tencent)
            read -rp "DNSPod DP_Id: "  DP_Id
            read -rp "DNSPod DP_Key: " DP_Key
            export DP_Id DP_Key; dnsapi="dns_dp" ;;
        *) err "未知 DNS 服务商"; return 1 ;;
    esac
    info "通过 DNS API($dnsapi) 为 $domain 及 *.$domain 申请证书..."
    "$ACME" --issue --dns "$dnsapi" -d "$domain" -d "*.$domain" --keylength ec-256 --server letsencrypt
}

# 把已签发证书安装到 nginx 目录，并登记 reloadcmd（续签后自动 reload）
install_cert_to_nginx() {
    local domain="$1"
    mkdir -p "$CERT_DIR/$domain"
    "$ACME" --install-cert -d "$domain" --ecc \
        --key-file       "$CERT_DIR/$domain/key.pem" \
        --fullchain-file "$CERT_DIR/$domain/fullchain.pem" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || kill -HUP \"\$(pgrep -o -x nginx)\" 2>/dev/null || systemctl start nginx 2>/dev/null || nginx"
}

# ----------------------------- 渲染站点配置 ---------------------------------
# 参数: domain target maxbody(MB) cache(none|normal|slice) ssl(none|le|dns|file) crt key
render_site_file() {
    local domain="$1" target="$2" maxbody="$3" cache="$4" ssl="$5" crt="$6" key="$7" allow_ips="$8"
    local file="$SITES_AVAIL/$domain.conf"

    # IP 访问白名单块：仅允许 allow_ips 里的 IP/网段访问 location /（其余 403）。
    # 用途：回源域名只放行边缘 Nginx 的出口 IP。基于直连来源 $remote_addr 判断——
    # 源站直接面向边缘机时有效；源站前若再套 CDN/代理则看不到真实边缘 IP。
    # 只加在 location /，不动 acme-challenge，证书签发/续签不受影响。
    local access_block="" _aip
    if [ -n "$allow_ips" ]; then
        for _aip in $allow_ips; do
            access_block+="        allow ${_aip};"$'\n'
        done
        access_block+="        deny all;"$'\n'
    fi

    # 缓存指令块（$'' 内 nginx 变量保持字面量，\n 为真实换行）
    local cache_block
    case "$cache" in
        none)
            cache_block=$'        # 无缓存：关闭缓冲，适合纯流媒体/上传\n        proxy_buffering off;\n        proxy_request_buffering off;' ;;
        normal)
            cache_block=$'        # 普通缓存：缓存网页/静态；Range 请求或视频/音频/大文件自动绕过\n        proxy_cache rpcache;\n        proxy_cache_key $scheme$host$request_uri;\n        proxy_cache_valid 200 301 302 10m;\n        proxy_cache_valid 404 1m;\n        proxy_cache_bypass $http_range $arg_nocache;\n        proxy_no_cache $http_range $rp_skip_media;\n        add_header X-Cache-Status $upstream_cache_status always;' ;;
        slice)
            cache_block=$'        # 视频分片缓存：按 1MB 切片缓存 Range 响应（206）\n        slice 1m;\n        proxy_cache rpcache;\n        proxy_cache_key $scheme$host$uri$is_args$args$slice_range;\n        proxy_set_header Range $slice_range;\n        proxy_cache_valid 200 206 1d;\n        proxy_cache_valid 404 1m;\n        add_header X-Cache-Status $upstream_cache_status always;' ;;
    esac

    # HTTPS 回源（target 为 https://域名）：必须补发 SNI、且把 Host 改成源站域名——
    # 否则源站握手缺 SNI 会拿到默认证书，按 server_name 又匹配不到边缘域名 → 失败/串站。
    # http:// 本机后端则保持 Host $host（部分后端靠它生成对外链接）。
    local host_hdr='$host' ssl_block='' up_hostport up_host
    case "$target" in
        https://*)
            up_hostport="${target#*://}"; up_hostport="${up_hostport%%/*}"   # host[:port]
            up_host="${up_hostport%%:*}"                                      # host（去端口）
            host_hdr="$up_hostport"
            ssl_block=$'\n        proxy_ssl_server_name on;\n        proxy_ssl_name '"$up_host;"
            ;;
    esac

    # 元信息（manage 解析用）
    {
        echo "# ===== nginx-rp BEGIN ====="
        echo "# domain=$domain"
        echo "# target=$target"
        echo "# maxbody=$maxbody"
        echo "# cache=$cache"
        echo "# ssl=$ssl"
        echo "# crt=$crt"
        echo "# key=$key"
        echo "# allow_ips=$allow_ips"
        echo "# ===== nginx-rp END ====="
    } > "$file"

    if [ "$ssl" = "none" ]; then
        cat >> "$file" <<EOF

server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type "text/plain";
    }

    location / {
$access_block        proxy_pass $target;
        proxy_http_version 1.1;
        proxy_set_header Host $host_hdr;$ssl_block
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        client_max_body_size ${maxbody}m;
        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
$cache_block
    }
}
EOF
    else
        cat >> "$file" <<EOF

server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type "text/plain";
    }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $domain;

    ssl_certificate     $crt;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type "text/plain";
    }

    location / {
$access_block        proxy_pass $target;
        proxy_http_version 1.1;
        proxy_set_header Host $host_hdr;$ssl_block
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        client_max_body_size ${maxbody}m;
        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
$cache_block
    }
}
EOF
    fi

    ln -sf "$file" "$SITES_ENABLED/$domain.conf"
}

# ----------------------------- 元信息读取 -----------------------------------
get_meta() {  # get_meta <key> <file>
    grep -m1 "^# $1=" "$2" 2>/dev/null | cut -d= -f2-
}

# ----------------------------- 缓存模式选择 ---------------------------------
choose_cache_mode() {
    # 结果写入全局变量 CACHE_MODE
    echo "  请选择该站点的缓存模式：" >&2
    echo "    1) 无缓存      —— 关闭缓冲，纯流媒体/直连源站（推荐）" >&2
    echo "    2) 普通缓存    —— 缓存网页/静态，Range 与视频自动绕过" >&2
    echo "    3) 视频分片缓存 —— slice 切片缓存 Range 响应（源站直链带签名时命中率低，慎用）" >&2
    local c; read -rp "  输入 [1-3]（默认1）: " c
    case "$c" in
        2) CACHE_MODE="normal" ;;
        3) CACHE_MODE="slice" ;;
        *) CACHE_MODE="none" ;;
    esac
}

# ----------------------------- 选择并应用 HTTPS 证书 ------------------------
# 弹证书方式菜单并落地（渲染站点 + reload）。新建/管理换证书共用，所以「申请失败」
# 后进管理也能改选别的方式（HTTP-01 / DNS / 本地证书 / 仅 HTTP）。
# 用法: apply_https_cert <domain> <target> <maxbody> <cache>
# 返回: 0=已写入并启用了可用站点配置（HTTP 或 HTTPS）；1=失败/取消，未写可用配置
apply_https_cert() {
    local domain="$1" target="$2" maxbody="$3" cache="$4" allow_ips="$5"
    echo "  请选择 HTTPS 证书方式："
    echo "    1) acme.sh 自动申请（HTTP-01，需 80 端口可达，推荐）"
    echo "    2) acme.sh 自动申请（DNS API，支持泛域名）"
    echo "    3) 使用已有证书文件（本地证书，输入路径）"
    echo "    4) 不启用 HTTPS（仅 80）"
    local s; read -rp "  输入 [1-4]（默认1）: " s
    case "$s" in
        4)
            render_site_file "$domain" "$target" "$maxbody" "$cache" "none" "" "" "$allow_ips"
            reload_nginx && { ok "已设为仅 HTTP：http://$domain"; return 0; }
            return 1 ;;
        3)
            local crt key
            read -rp "  证书 fullchain 路径: " crt
            read -rp "  私钥 key 路径: " key
            if [ ! -f "$crt" ] || [ ! -f "$key" ]; then err "证书文件不存在"; return 1; fi
            render_site_file "$domain" "$target" "$maxbody" "$cache" "file" "$crt" "$key" "$allow_ips"
            reload_nginx && { ok "已启用（本地证书）：https://$domain"; return 0; }
            return 1 ;;
        2)
            echo "    DNS 服务商： 1) Cloudflare  2) 阿里云  3) 腾讯云(DNSPod)"
            local dp; read -rp "    选择 [1-3]: " dp
            local prov; case "$dp" in 1) prov=cloudflare;; 2) prov=aliyun;; 3) prov=tencent;; *) err "无效"; return 1;; esac
            if issue_cert_dns "$domain" "$prov" && install_cert_to_nginx "$domain"; then
                render_site_file "$domain" "$target" "$maxbody" "$cache" "dns" \
                    "$CERT_DIR/$domain/fullchain.pem" "$CERT_DIR/$domain/key.pem" "$allow_ips"
                reload_nginx && { ok "已启用（HTTPS + 泛域名证书）：https://$domain"; return 0; }
            fi
            err "证书申请失败。"; return 1 ;;
        *)
            # 先建/保留 HTTP 站点承载 acme challenge，再签发，最后换成 HTTPS
            render_site_file "$domain" "$target" "$maxbody" "$cache" "none" "" "" "$allow_ips"
            reload_nginx || { err "初始 HTTP 配置失败"; return 1; }
            if issue_cert_http "$domain" && install_cert_to_nginx "$domain"; then
                render_site_file "$domain" "$target" "$maxbody" "$cache" "le" \
                    "$CERT_DIR/$domain/fullchain.pem" "$CERT_DIR/$domain/key.pem" "$allow_ips"
                reload_nginx && ok "已启用（HTTPS + 自动证书）：https://$domain"
            else
                err "证书申请失败，已保留仅 HTTP 站点。请检查域名解析 / 80 端口可达性，或改用 DNS API / 本地证书。"
            fi
            return 0 ;;   # HTTP 站点仍在，算"已写可用配置"
    esac
}

# ----------------------------- 新增反代站点 ---------------------------------
configure_reverse_proxy() {
    command -v nginx >/dev/null 2>&1 || { err "请先安装 Nginx（菜单 1）"; pause; return; }
    ensure_global_conf

    local domain target maxbody created=0
    read -rp "请输入域名（如 v.example.com）: " domain
    [ -z "$domain" ] && { err "域名不能为空"; pause; return; }
    read -rp "请输入反代目标（如 http://127.0.0.1:8080，也支持 https://源站域名 回源）: " target
    [ -z "$target" ] && { err "目标不能为空"; pause; return; }
    read -rp "客户端最大请求体大小 MB（上传用，默认 1024）: " maxbody
    [ -z "$maxbody" ] && maxbody=1024

    choose_cache_mode

    if apply_https_cert "$domain" "$target" "$maxbody" "$CACHE_MODE" ""; then created=1; fi

    # 反代建好后的两个收尾询问：
    if [ "$created" = 1 ]; then
        # (a) 后端在本机时：是否封后端端口(如 8080)的公网直连
        local _hp _host
        _hp="${target#*://}"; _hp="${_hp%%/*}"; _host="${_hp%%:*}"
        case "$_host" in
            127.0.0.1|localhost|::1|0.0.0.0)
                echo
                local _yn
                read -rp "是否封锁后端端口的公网直连(如 IP:8080)，仅允许经 Nginx？(y/N): " _yn
                case "$_yn" in y|Y) restrict_backend_port "$target" ;; esac
                ;;
        esac
        # (b) 是否禁止用 IP 直接打开网站(80/443)，仅允许域名访问（未开启时才问）
        if ! deny_ip_enabled; then
            echo
            local _yn2
            read -rp "是否禁止用 IP 直接访问网站，仅允许域名访问？(y/N): " _yn2
            case "$_yn2" in y|Y) enable_deny_ip ;; esac
        fi
    fi
    pause
}

# ----------------------------- 列出/管理站点 -------------------------------
list_sites() {
    local found=0 i=1
    SITE_FILES=()
    for f in "$SITES_AVAIL"/*.conf; do
        [ -e "$f" ] || continue
        grep -qE "(nginx-rp|1keji-rp) BEGIN" "$f" || continue   # 1keji-rp：兼容旧版站点，重渲染后自动迁移到新标记
        local d t c s
        d=$(get_meta domain "$f"); t=$(get_meta target "$f")
        c=$(get_meta cache "$f");  s=$(get_meta ssl "$f")
        printf "  %d) %-28s -> %-28s [缓存:%s 证书:%s]\n" "$i" "$d" "$t" "$c" "$s"
        SITE_FILES+=("$f"); i=$((i+1)); found=1
    done
    [ "$found" -eq 0 ] && { warn "没有由本脚本管理的反代站点"; return 1; }
    return 0
}

manage_reverse_proxy() {
    echo "已配置的反代站点："
    list_sites || { pause; return; }
    local idx; read -rp "选择要管理的站点序号（回车返回）: " idx
    [ -z "$idx" ] && return
    local f="${SITE_FILES[$((idx-1))]}"
    [ -z "$f" ] || [ ! -f "$f" ] && { err "无效序号"; pause; return; }

    local domain target maxbody cache ssl crt key allow_ips
    domain=$(get_meta domain "$f"); target=$(get_meta target "$f")
    maxbody=$(get_meta maxbody "$f"); cache=$(get_meta cache "$f")
    ssl=$(get_meta ssl "$f"); crt=$(get_meta crt "$f"); key=$(get_meta key "$f")
    allow_ips=$(get_meta allow_ips "$f")

    echo "  当前： $domain -> $target  [缓存:$cache 证书:$ssl 上限:${maxbody}m]"
    echo "         IP 白名单：${allow_ips:-未设置（任意 IP 可访问）}"
    echo "    1) 修改反代目标"
    echo "    2) 修改缓存模式"
    echo "    3) 申请/更换 HTTPS 证书（HTTP-01 / DNS / 本地证书 / 仅 HTTP）"
    echo "    4) 删除该站点"
    echo "    5) 设置 IP 访问白名单（仅允许指定 IP 访问，回源域名用）"
    echo "    0) 返回"
    local op; read -rp "  选择: " op
    case "$op" in
        1)
            read -rp "  新目标: " target
            [ -z "$target" ] && { err "不能为空"; pause; return; }
            render_site_file "$domain" "$target" "$maxbody" "$cache" "$ssl" "$crt" "$key" "$allow_ips"
            reload_nginx && ok "目标已更新"
            ;;
        2)
            choose_cache_mode
            render_site_file "$domain" "$target" "$maxbody" "$CACHE_MODE" "$ssl" "$crt" "$key" "$allow_ips"
            reload_nginx && ok "缓存模式已改为 $CACHE_MODE"
            ;;
        3)
            ensure_global_conf
            apply_https_cert "$domain" "$target" "$maxbody" "$cache" "$allow_ips"
            ;;
        4)
            read -rp "  确认删除 $domain ？(y/N): " yn
            if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
                rm -f "$f" "$SITES_ENABLED/$domain.conf"
                reload_nginx && ok "已删除（证书保留在 $CERT_DIR/$domain）"
            fi
            ;;
        5)
            echo "  仅允许下列 IP/网段访问 $domain（空格分隔，支持 CIDR 如 1.2.3.0/24 或 IPv6）。"
            echo "  直接回车留空 = 清除白名单，恢复任意 IP 可访问。"
            echo "  当前：${allow_ips:-（无，任意 IP 可访问）}"
            local newips; read -rp "  允许的 IP： " newips
            local -a _ips; read -ra _ips <<< "$newips"; newips="${_ips[*]}"   # 压缩多余空格
            local bad=0 ip
            for ip in $newips; do
                case "$ip" in *[!0-9a-fA-F:./]*) bad=1 ;; esac
            done
            if [ "$bad" = 1 ]; then
                err "含非法字符，IP/网段只能包含数字、字母(IPv6)、. : / ，已取消。"
            else
                render_site_file "$domain" "$target" "$maxbody" "$cache" "$ssl" "$crt" "$key" "$newips"
                if reload_nginx; then
                    if [ -n "$newips" ]; then ok "已设置白名单，仅允许：$newips（其它来源 403）"
                    else ok "已清除白名单，恢复任意 IP 可访问。"; fi
                else
                    err "配置测试失败，请检查输入的 IP 是否合法（可重新设置或清空）。"
                fi
            fi
            ;;
        *) return ;;
    esac
    pause
}

# ----------------------------- 证书 / 续签管理 -----------------------------
cert_menu() {
    ensure_acme || { pause; return; }
    echo "证书 / 自动续签管理："
    echo "    1) 查看已签发证书列表"
    echo "    2) 立即续签全部（强制）"
    echo "    3) 续签指定域名"
    echo "    4) 查看自动续签计划（cron）"
    echo "    0) 返回"
    local op; read -rp "  选择: " op
    case "$op" in
        1) "$ACME" --list ;;
        2) "$ACME" --cron --force; ok "已触发强制续签" ;;
        3) local d; read -rp "  域名: " d; "$ACME" --renew -d "$d" --ecc --force ;;
        4)
            if crontab -l 2>/dev/null | grep -q acme.sh; then
                ok "自动续签已启用："; crontab -l 2>/dev/null | grep acme.sh
            else
                warn "未发现 acme.sh 续签 cron。请重新申请一次证书以触发安装/修复。"
            fi
            ;;
        *) return ;;
    esac
    pause
}

# ----------------------------- 卸载 -----------------------------------------
uninstall_nginx() {
    read -rp "确认卸载 Nginx 并清理本脚本配置？(y/N): " yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ] || return
    systemctl stop nginx 2>/dev/null
    systemctl disable nginx 2>/dev/null
    apt-get purge -y nginx nginx-common nginx-core >/dev/null 2>&1
    rm -f "$GLOBAL_CONF" "$DENY_IP_CONF"
    rm -rf "$CACHE_DIR"
    warn "Nginx 已卸载。证书目录 $CERT_DIR 与 acme.sh($ACME_HOME) 保留，如需彻底清理请手动删除。"
    pause
}

# ------------------- 后端端口直连封锁开关 -----------------------------------
port_block_menu() {
    echo "后端端口直连封锁：禁止公网用 IP:端口 直连后端（保留本机回环给 Nginx）"
    local port; read -rp "  输入后端端口（如 8080，回车返回）: " port
    [ -z "$port" ] && return
    case "$port" in *[!0-9]*) err "端口需为数字"; pause; return ;; esac
    if backend_port_blocked "$port"; then
        warn "端口 $port 当前【已封锁】公网直连"
        local yn; read -rp "  解除封锁？(y/N): " yn
        case "$yn" in y|Y) unrestrict_port "$port" ;; esac
    else
        info "端口 $port 当前【未封锁】"
        local yn; read -rp "  现在封锁？(y/N): " yn
        case "$yn" in y|Y) restrict_port "$port" ;; esac
    fi
    pause
}

# ------------------- 禁止 IP 直接访问开关 -----------------------------------
deny_ip_menu() {
    if deny_ip_enabled; then
        warn "禁止 IP 直接访问：当前【已开启】（用 IP 打开网站会被拒绝）"
        local yn; read -rp "  关闭它？(y/N): " yn
        case "$yn" in y|Y) disable_deny_ip ;; esac
    else
        info "禁止 IP 直接访问：当前【未开启】"
        echo "  开启后：http://服务器IP 打不开，只有配置过的域名能访问。"
        local yn; read -rp "  现在开启？(y/N): " yn
        case "$yn" in y|Y) enable_deny_ip ;; esac
    fi
    pause
}

# ----------------------------- 管理子菜单 -----------------------------------
manage_menu() {
    while true; do
        clear
        c_green "------------- 管理反向代理 -------------"
        echo "  1. 管理已配置站点（改目标 / 改缓存 / 换证书 / 删除）"
        echo "  2. 证书 / 自动续签管理"
        echo "  3. 后端端口直连封锁（开 / 关）"
        echo "  4. 禁止用 IP 直接访问（开 / 关，仅域名可访问）"
        echo "  0. 返回上级"
        echo "----------------------------------------"
        local op; read -rp "请选择 [0-4]: " op
        case "$op" in
            1) manage_reverse_proxy ;;
            2) cert_menu ;;
            3) port_block_menu ;;
            4) deny_ip_menu ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ----------------------------- 顶部信息栏 -----------------------------------
banner() {
    local nstat ver sites
    if command -v nginx >/dev/null 2>&1; then
        ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        nstat="已安装${ver:+ ($ver)}"
    else
        nstat="未安装"
    fi
    sites=$(grep -lE "(nginx-rp|1keji-rp) BEGIN" "$SITES_AVAIL"/*.conf 2>/dev/null | wc -l | tr -d ' ')
    clear
    printf '\033[36m'
    cat <<'EOF'
 _ __   __ _ (_) _ __   __  __        _ __  _ __
| '_ \ / _` || || '_ \  \ \/ / _____ | '__|| '_ \
| | | | (_| || || | | |  >  < |_____|| |   | |_) |
|_| |_|\__, ||_||_| |_| /_/\_\       |_|   | .__/
       |___/                               |_|
EOF
    printf '\033[0m'
    echo "  Nginx 反向代理一键脚本 · acme 自动证书 / 续签 / 缓存"
    echo "  项目: https://github.com/J606y/nginx-rp"
    echo "  作者: J606y · 由 Claude Code 编写"
    printf "  Nginx: %s     已配置站点: %s 个\n" "$nstat" "$sites"
    echo "=================================================="
}

# ----------------------------- 主菜单 ---------------------------------------
main_menu() {
    while true; do
        banner
        echo "  1. 安装 Nginx"
        echo "  2. 配置反向代理"
        echo "  3. 管理反向代理"
        echo "  4. 卸载 Nginx"
        echo "  5. 更新本脚本（拉 GitHub 最新）"
        echo "  6. 更新 Nginx"
        echo "  0. 退出"
        echo "--------------------------------------------------"
        echo "  提示：下次直接输入  $SHORTCUT_CMD  即可打开本菜单"
        local opt; read -rp "请选择一个选项 [0-6]: " opt
        case "$opt" in
            1) install_nginx ;;
            2) configure_reverse_proxy ;;
            3) manage_menu ;;
            4) uninstall_nginx ;;
            5) self_update ;;
            6) update_nginx ;;
            0) exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

require_root
require_apt
ensure_tty
setup_shortcut
main_menu
