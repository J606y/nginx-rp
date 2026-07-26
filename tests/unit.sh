#!/bin/bash
# nginx-rp 纯函数单测。零环境依赖，任意 bash 4.3+ 可跑，不需要 root / nginx / Docker。
#   用法： bash tests/unit.sh
# 覆盖边界五类：空值 / 超长 / 非法字符 / 边界数值 / 状态复位。
# 依赖被测脚本可被 source（入口守卫保证 source 时不进交互）。

# SC2154：SITE 是被测脚本里的关联数组（declare -A），shellcheck 跨文件看不到声明，
#          会把 SITE[domain] 的下标当成未赋值变量引用。
# SC2034：AUDIT_MAX_BYTES 等由被 source 的脚本消费，这里赋值就是「注入测试配置」。
# 文件级指令必须紧跟 shebang、位于任何命令之前，否则不生效。
# shellcheck disable=SC2154,SC2034

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../nginx-rp.sh"

# 沙箱化所有路径：单测不写盘，但要杜绝任何一处意外碰到系统配置
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export SITES_AVAIL="$SANDBOX/sites-available"
export SITES_ENABLED="$SANDBOX/sites-enabled"
export NGINX_CONF_D="$SANDBOX/conf.d"
export NGINX_CONF="$SANDBOX/nginx.conf"
export CERT_DIR="$SANDBOX/certs"
export BACKUP_DIR="$SANDBOX/backups"
export CACHE_DIR="$SANDBOX/cache"
export LOG_DIR="$SANDBOX/log"
export AUDIT_LOG="$SANDBOX/audit.log"
export LOCK_FILE="$SANDBOX/lock"
export BLOCKED_PORTS_FILE="$SANDBOX/blocked-ports"
export ACME_HOME="$SANDBOX/acme"
mkdir -p "$SITES_AVAIL" "$SITES_ENABLED" "$NGINX_CONF_D" "$LOG_DIR"

# shellcheck source=../nginx-rp.sh
source "$SCRIPT"

PASS=0; FAIL=0; CURRENT=""
group() { CURRENT="$1"; }
_ok()   { PASS=$((PASS + 1)); }
_no()   { FAIL=$((FAIL + 1)); printf '  FAIL [%s] %s\n' "$CURRENT" "$1"; }

# rc <期望返回码> <函数> <参数...>
rc() {
    local want="$1"; shift
    "$@" >/dev/null 2>&1
    local got=$?
    [ "$got" = "$want" ] && _ok || _no "$(printf '%q ' "$@")→ rc=$got 期望 $want"
}
# out <期望stdout> <函数> <参数...>
out() {
    local want="$1"; shift
    local got; got="$("$@" 2>/dev/null)"
    [ "$got" = "$want" ] && _ok || _no "$(printf '%q ' "$@")→ [$got] 期望 [$want]"
}
eq() { # eq <实际> <期望> <说明>
    [ "$1" = "$2" ] && _ok || _no "$3: 得到 [$1] 期望 [$2]"
}

# ---------------------------------------------------------------- valid_ipv4
group valid_ipv4
for v in 0.0.0.0 1.2.3.4 255.255.255.255 192.168.1.1 10.0.0.1; do rc 0 valid_ipv4 "$v"; done
for v in "" 256.1.1.1 1.2.3 1.2.3.4.5 a.b.c.d 1.2.3.300 " 1.2.3.4" "1.2.3.4 " 1..2.3 -1.2.3.4; do
    rc 1 valid_ipv4 "$v"
done

# ---------------------------------------------------------------- valid_ipv6
group valid_ipv6
for v in ::1 :: 2001:db8::1 fe80::1 2001:0db8:0000:0000:0000:0000:0000:0001 \
         ::ffff:192.0.2.1 2001:db8::ffff:192.0.2.1 abcd:ef01:2345:6789:abcd:ef01:2345:6789 \
         1::8 1:2:3:4:5:6:7:8 ::8 1:: fe80::1%0 2001:db8:0:0:1::1; do
    case "$v" in *%*) continue ;; esac   # zone id 不在支持范围，跳过
    rc 0 valid_ipv6 "$v"
done
# 回归重点：旧实现只查「含冒号且字符是十六进制」，下面这些畸形串全部被放行过
for v in ::::::: :::: ::: "" 1.2.3.4 12345::1 1:2:3:4:5:6:7 1:2:3:4:5:6:7:8:9 \
         2001:db8::1::2 :1:2:3:4:5:6:7 1:2:3:4:5:6:7: gggg::1 1::2::3 \
         192.0.2.1::1 ::ffff:999.0.2.1 ":" "1:" ":1" "1:2:3:4:5:6:7:8:"; do
    rc 1 valid_ipv6 "$v"
done

# ------------------------------------------------------------- valid_ip_cidr
group valid_ip_cidr
for v in 1.2.3.0/24 1.2.3.4 10.0.0.0/8 ::1 2001:db8::/32 fe80::/10 0.0.0.0/0 \
         1.2.3.4/32 ::/0 2001:db8::1/128; do
    rc 0 valid_ip_cidr "$v"
done
# 边界数值：v4 前缀 32 合法 / 33 非法；v6 前缀 128 合法 / 129 非法
for v in 1.2.3.0/33 1.2.3.0/abc 2001:db8::/129 "" "1.2.3.0/24/8" ":::::::" \
         "1.2.3.256/24" all "unix:" "1.2.3.0/-1" "1.2.3.0/999"; do
    rc 1 valid_ip_cidr "$v"
done

# ------------------------------------------------------ valid_cookie_pattern
group valid_cookie_pattern
for v in "" xf_user "xf_user|xf_session" "nh:at" _app_session "a-b.c" PHPSESSID; do
    rc 0 valid_cookie_pattern "$v"
done
# 注入向量：这些若被放行就能往 nginx map 块里塞任意指令
for v in 'a) 1;} server {' 'a;b' 'a"b' 'a$b' 'a b' 'a{b' 'a}b' 'a/b' 'a\b' "a'b" 'a
b'; do
    rc 1 valid_cookie_pattern "$v"
done

# ------------------------------------------------------------- valid_domain
group valid_domain
for v in example.com a.b.c.example.com xn--fiqs8s.com sub-domain.example.co.uk; do
    rc 0 valid_domain "$v"
done
for v in "" localhost "*.example.com" "-bad.com" "bad-.com" "a b.com" "example" \
         "ex ample.com" 'x.com;{' "192.168.1.1"; do
    rc 1 valid_domain "$v"
done

# --------------------------------------------------------------- valid_email
group valid_email
for v in a@b.com user.name+tag@example.co.uk; do rc 0 valid_email "$v"; done
for v in "" abc a@b a@localhost a@x.local a@x.test "a b@c.com"; do rc 1 valid_email "$v"; done

# ---------------------------------------------------------- normalize_target
group normalize_target
out "http://127.0.0.1:8080"      normalize_target "http://127.0.0.1:8080"
out "http://127.0.0.1:8080"      normalize_target "127.0.0.1:8080"
out "https://origin.example.com" normalize_target "https://origin.example.com"
out "http://example.com"         normalize_target "example.com"
out "http://[::1]:8080"          normalize_target "http://[::1]:8080"
out "https://a.b.c-d.com/path/x" normalize_target "https://a.b.c-d.com/path/x"
out "http://localhost:3000/"     normalize_target "http://localhost:3000/"
# 空值 / 协议 / 注入 / 超长端口
for v in "" "ftp://x.com" "http://" "http://x.com;}server{listen 8888;" "http://x.com /etc" \
         'http://x.com/a;b' 'http://x.com/a{b}' 'http://x.com/a"b' "http://-bad.com" \
         "http://x.com:99999999" "http://x y.com" 'http://x.com/a b'; do
    rc 1 normalize_target "$v"
done

# ------------------------------------------------------------------ get_meta
group get_meta
META_F="$SANDBOX/site.conf"
cat > "$META_F" <<'EOF'
# ===== nginx-rp BEGIN =====
# domain=a.example.com b.example.com
# target=http://127.0.0.1:8080/x=y
# maxbody=2048
# cache=micro:120
# allow_ips=
# ===== nginx-rp END =====
server { listen 80; }
EOF
out "a.example.com b.example.com" get_meta domain "$META_F"
out "http://127.0.0.1:8080/x=y"   get_meta target "$META_F"   # 值里含 = 必须完整保留
out "micro:120"                   get_meta cache "$META_F"
out ""                            get_meta allow_ips "$META_F"
out ""                            get_meta nonexistent "$META_F"

# ------------------------------------------------- site_reset / site_load
group site_load
site_reset
eq "${SITE[maxbody]}" "1024" "site_reset 默认上传上限"
eq "${SITE[cache]}"   "none" "site_reset 默认缓存档"
site_load "$META_F"
eq "${SITE[domain]}"  "a.example.com b.example.com" "site_load 多域名"
eq "${SITE[maxbody]}" "2048"      "site_load 覆盖默认值"
eq "${SITE[cache]}"   "micro:120" "site_load 缓存档"
# 旧版 meta 没有 skipcookie / sslverify / metaver —— 存量兼容的落点：必须降级为默认值
eq "${SITE[skipcookie]}" "" "旧版 meta 缺 skipcookie 时降级为空"
eq "${SITE[sslverify]}"  "" "旧版 meta 缺 sslverify 时降级为空"
eq "${SITE[metaver]}"    "" "旧版 meta 缺 metaver 时视为 v1"
eq "${SITE[ssl]}"        "none" "旧版 meta 缺 ssl 时用默认值"
# 复位后不能残留上一个站点的字段（全局可变状态的关键不变量）
site_reset
eq "${SITE[domain]}" "" "site_reset 清空 domain"
eq "${SITE[cache]}"  "none" "site_reset 复位 cache"

# --------------------------------------------------------------- site_validate
group site_validate
_mk() { site_reset; SITE[domain]="ok.example.com"; SITE[target]="http://127.0.0.1:8080"; }
_mk; rc 0 site_validate
_mk; SITE[domain]="";                    rc 1 site_validate      # 空域名
_mk; SITE[domain]='x.com;{';             rc 1 site_validate      # 非法域名
_mk; SITE[target]="";                    rc 1 site_validate      # 空目标
_mk; SITE[target]='http://x;}server{';   rc 1 site_validate      # 注入目标
_mk; SITE[maxbody]="abc";                rc 1 site_validate      # 非数字上限
_mk; SITE[maxbody]="";                   rc 1 site_validate
_mk; SITE[skipcookie]='a;b';             rc 1 site_validate      # 注入 cookie
_mk; SITE[skipcookie]='xf_user|xf_sess'; rc 0 site_validate
_mk; SITE[allow_ips]="1.2.3.4 bogus";    rc 1 site_validate      # 白名单混入非法条目
_mk; SITE[allow_ips]="1.2.3.0/24 ::1";   rc 0 site_validate
_mk; SITE[realip]=":::::::";             rc 1 site_validate      # 畸形 IPv6 不得入配置
_mk; SITE[domain]="a.example.com b.example.com"; rc 0 site_validate   # SAN 多域名
_mk; SITE[domain]="a.example.com bad_domain";    rc 1 site_validate   # 多域名里有一个非法

# ------------------------------------------------------- gzip awk 作用域
group neutralize_gzip_awk
cat > "$SANDBOX/ngx.conf" <<'EOF'
events { worker_connections 768; }
http {
    gzip on;
    gzip_disable "msie6";
    # gzip_vary on;
    server {
        gzip off;
        location /a { gzip_comp_level 9; }
    }
}
EOF
awk "$_GZIP_AWK" "$SANDBOX/ngx.conf" > "$SANDBOX/ngx.out"; awk_rc=$?
eq "$awk_rc" "0" "有 http 顶层 gzip 时 awk 应返回 0"
grep -qE '^# +gzip on;'          "$SANDBOX/ngx.out" && _ok || _no "http 顶层 gzip on 未被注释"
grep -qE '^# +gzip_disable'      "$SANDBOX/ngx.out" && _ok || _no "http 顶层 gzip_disable 未被注释"
grep -qE '^ +gzip off;'          "$SANDBOX/ngx.out" && _ok || _no "server{} 内 gzip off 被误注释"
grep -qE 'gzip_comp_level 9;'    "$SANDBOX/ngx.out" && _ok || _no "location{} 内 gzip 被误注释"
eq "$(grep -c '# gzip_vary on;' "$SANDBOX/ngx.out")" "1" "已注释行被二次注释"
# 幂等：对已处理过的文件再跑一次不应有任何改动
awk "$_GZIP_AWK" "$SANDBOX/ngx.out" > "$SANDBOX/ngx.out2"; awk_rc2=$?
eq "$awk_rc2" "1" "无 http 顶层 gzip 时 awk 应返回 1"
if diff -q "$SANDBOX/ngx.out" "$SANDBOX/ngx.out2" >/dev/null; then _ok; else _no "gzip 处理非幂等"; fi

# ------------------------------------------------------------------- audit
group audit
AUDIT_LOG="$SANDBOX/a.log"; rm -f "$AUDIT_LOG"
audit "TEST line one"
grep -q "TEST line one" "$AUDIT_LOG" && _ok || _no "审计日志未写入"
# 日志不可写时必须完全静默且不返回错误（审计是旁路，不能阻断运维操作）
AUDIT_LOG="$SANDBOX/no/such/dir/a.log"
noise="$(audit "should be silent" 2>&1)"; arc=$?
eq "$noise" "" "日志不可写时有噪声输出"
eq "$arc"   "0" "日志不可写时返回了错误码"
# 超限自截断
AUDIT_LOG="$SANDBOX/a.log"; AUDIT_MAX_BYTES=200
head -c 5000 /dev/zero | tr '\0' 'x' > "$AUDIT_LOG"
audit "after trim"
sz=$(wc -c < "$AUDIT_LOG")
[ "$sz" -lt 500 ] && _ok || _no "超限未自截断（当前 $sz 字节）"

# ------------------------------------------------------- 菜单 EOF 行为
group menu_eof
# 回归：read 读到 EOF 时若被当成「无效选项」，while true 菜单会瞬间无限刷屏。
# 非交互环境（CI、curl|bash、stdin 被关闭）下必定触发。
menu_out="$(timeout 5 bash -c "source '$SCRIPT' 2>/dev/null; main_menu </dev/null" 2>&1)"
menu_rc=$?
[ "$menu_rc" != 124 ] && _ok || _no "main_menu 在 EOF 下无限循环（超时）"
case "$menu_out" in *EOF*) _ok ;; *) _no "EOF 退出时未给出提示" ;; esac
# 子菜单同样不能死循环
for fn in manage_menu ops_menu; do
    timeout 5 bash -c "source '$SCRIPT' 2>/dev/null; $fn </dev/null" >/dev/null 2>&1
    [ $? != 124 ] && _ok || _no "$fn 在 EOF 下无限循环（超时）"
done

# ------------------------------------------------------------------- 汇总
echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m单测通过：%d 项全部成功\033[0m\n' "$PASS"
    exit 0
fi
printf '\033[31m单测失败：%d 项通过，%d 项失败\033[0m\n' "$PASS" "$FAIL"
exit 1
