#!/bin/bash
# nginx-rp 集成测试。必须在容器内以 root 运行（见同目录 Dockerfile）：
#   docker build -f tests/integration/Dockerfile -t nginx-rp-it . && docker run --rm nginx-rp-it
#
# 覆盖单测够不着的部分：真实 nginx -t、渲染管线、三条回滚路径、缓存清理精度与性能、
# 单实例锁、入口守卫的分发路径、主配置备份。
# 刻意不用 set -e：本测试的核心就是驱动各种失败路径，需要自己判定返回码。

# SC2154：SITE 是被测脚本里的关联数组（declare -A），shellcheck 跨文件看不到声明，
#          会把 SITE[domain] 的下标当成未赋值变量引用。
# SC2034：SITE / NGINX_CONF_BACKED_UP 由被 source 的脚本消费，这里赋值即是驱动被测逻辑。
# 文件级指令必须紧跟 shebang、位于任何命令之前，否则不生效。
# shellcheck disable=SC2154,SC2034

set -uo pipefail

WORK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$WORK/nginx-rp.sh"

PASS=0; FAIL=0
sec() { printf '\n\033[36m── %s\033[0m\n' "$1"; }
_ok() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
_no() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
# assert <说明> <命令...>：命令返回 0 即通过。
# 统一用它而不是「[ cond ]; chk $?」——后者的 $? 取自 test，中间插入任何语句都会被
# 覆盖，是极易写错的模式（shellcheck SC2319 专门告警）。
assert() { local msg="$1"; shift; if "$@"; then _ok "$msg"; else _no "$msg"; fi; }

[ "$(id -u)" = 0 ] || { echo "集成测试需要 root（请在容器内运行）"; exit 1; }

# nginx 起来，让 reload_nginx 走「HUP 正在运行的 master」这条真实路径
nginx -g 'daemon on;' 2>/dev/null || true
sleep 1

# 自签证书，供 ssl=file 的渲染矩阵使用
mkdir -p /etc/nginx/certs/testcert
openssl req -x509 -nodes -newkey rsa:2048 -days 2 -subj "/CN=it.example.com" \
    -keyout /etc/nginx/certs/testcert/key.pem \
    -out    /etc/nginx/certs/testcert/fullchain.pem >/dev/null 2>&1
CRT=/etc/nginx/certs/testcert/fullchain.pem
KEY=/etc/nginx/certs/testcert/key.pem

# shellcheck source=../../nginx-rp.sh
source "$SCRIPT"
ensure_sites_enabled_include >/dev/null 2>&1
ensure_global_conf >/dev/null 2>&1

# ============================================================ 入口守卫
sec "入口守卫：分发路径行为不变"
_ok "source 时不进入交互菜单（已执行到此处即为证据）"

# 框架自检。被测脚本定义了自己的 ok() / info() / warn()，source 会覆盖同名函数——
# 第一版测试的计数函数就叫 ok()，被覆盖后全部用例通过却报告「0 项成功」，
# 绿色勾照常打印，失败被完全掩盖。计数函数一律用 _ 前缀，并在此确认它真的在计数。
if [ "$PASS" -lt 1 ]; then
    echo "致命：计数函数未生效（疑似被被测脚本的同名函数覆盖），中止。" >&2
    exit 1
fi

if command -v setpriv >/dev/null 2>&1; then
    guard_out="$(timeout 10 setpriv --reuid=1000 --regid=1000 --clear-groups \
                 bash "$SCRIPT" 2>&1 </dev/null | head -1)"
    case "$guard_out" in
        *root*) _ok "直接执行时触发 require_root" ;;
        *)      _no "直接执行未触发 require_root：$guard_out" ;;
    esac
else
    _ok "跳过降权检查（无 setpriv）"
fi

# 进程替换 bash <(...)：$0 与 BASH_SOURCE[0] 同为 /dev/fd/N，必须仍进入交互入口。
# timeout 兜底：入口守卫若写错导致卡死，测试要失败而不是把 CI 挂死。
subst_out="$(timeout 10 bash <(cat "$SCRIPT") 2>&1 </dev/null | head -40)"
subst_rc=$?
assert "进程替换路径未卡死" [ "$subst_rc" != 124 ]
case "$subst_out" in
    *Nginx*|*nginx*) _ok "bash <(...) 进程替换路径仍进入主流程" ;;
    *)               _no "进程替换路径行为异常：$subst_out" ;;
esac
# 主菜单编号契约：老用户靠肌肉记忆按数字，新增项不得挤占既有编号。
# 契约锁的是「编号 → 做哪件事」，不是逐字文案：v1.0.1 把 6 号从 reload 改成 restart
# （reload 认不到回源域名的新 IP），编号与语义归属未变，只更了标题。
for entry in "1. 配置反向代理" "2. 管理反向代理" "3. 安装 Nginx" "4. 更新 Nginx" \
             "5. 更新本脚本" "6. 应用配置并强制生效" "9. 卸载 Nginx" "0. 退出"; do
    case "$subst_out" in
        *"$entry"*) _ok "主菜单保留「$entry」" ;;
        *)          _no "主菜单缺少或改动了「$entry」" ;;
    esac
done

# ============================================================ 渲染矩阵
sec "渲染矩阵：5 缓存档 × 2 SSL 形态，nginx -t 全通过"
i=0
for cache in none static normal micro slice; do
    for ssl in none file; do
        i=$((i + 1))
        site_reset
        SITE[domain]="m${i}.example.com"
        SITE[target]="http://127.0.0.1:8080"
        SITE[cache]="$cache"
        SITE[ssl]="$ssl"
        if [ "$ssl" = file ]; then SITE[crt]="$CRT"; SITE[key]="$KEY"; fi
        if render_site_file >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
            _ok "cache=$cache ssl=$ssl 渲染并通过 nginx -t"
        else
            _no "cache=$cache ssl=$ssl 渲染或 nginx -t 失败"
            nginx -t 2>&1 | sed 's/^/       /'
        fi
        # 每例必须独立：render_site_file 不带回滚，失败的配置会留在 sites-enabled 里，
        # 把后面每一次 nginx -t 全部带崩，最终只能看到一片红而找不到首因。
        rm -f "/etc/nginx/sites-available/m${i}.example.com.conf" \
              "/etc/nginx/sites-enabled/m${i}.example.com.conf"
    done
done
assert "矩阵用例清理干净，nginx -t 回到基线" nginx -t

sec "白名单与 real_ip 同站共存"
site_reset
SITE[domain]="coexist.example.com"
SITE[target]="http://127.0.0.1:8080"
SITE[allow_ips]="203.0.113.10 10.0.0.0/8"
SITE[realip]="203.0.113.10"
render_site_file >/dev/null 2>&1 && nginx -t >/dev/null 2>&1
coex_rc=$?
assert "白名单 + real_ip 同站渲染并通过 nginx -t" [ "$coex_rc" = 0 ]
COEX=/etc/nginx/sites-available/coexist.example.com.conf
assert "白名单用 geo \$realip_remote_addr 判定（不受 real_ip 改写影响）" \
    grep -q 'geo \$realip_remote_addr' "$COEX"
assert "real_ip 可信上游已写入" grep -q 'set_real_ip_from 203.0.113.10;' "$COEX"
if grep -qE '^\s*allow\s' "$COEX"; then
    _no "仍在使用会被 real_ip 破坏的 allow/deny"
else
    _ok "未使用 allow/deny（改用 geo）"
fi

sec "长域名白名单：geo 变量名撞哈希桶的回归"
# 实锤：origin-openclaw.20051212.xyz（28 字符）一开白名单，nginx -t 直接
# emerg「could not build variables_hash, you should increase
# variables_hash_bucket_size: 64」。根因是 geo 变量名 rp_<域名去符号>_<cksum>_deny
# 恰好 47 字符，而默认 64 字节的桶只容得下 46 字符——域名少一个字符都不触发，
# 所以上面 coexist.example.com（19 字符）这类短域名用例永远测不出来。
site_reset
SITE[domain]="origin-longname.20051212.example.com"   # 36 字符，稳过 46 字符阈值
SITE[target]="http://127.0.0.1:8080"
SITE[allow_ips]="203.0.113.10"
render_site_file >/dev/null 2>&1 && nginx -t >/dev/null 2>&1
long_rc=$?
assert "长域名 + 白名单渲染并通过 nginx -t" [ "$long_rc" = 0 ]
LONG=/etc/nginx/sites-available/origin-longname.20051212.example.com.conf
# 防退化：这条用例的全部价值在于变量名确实越过了默认桶的容量。若将来命名规则变短，
# 用例会变成一句空断言——这里把前提本身钉死。
LONGVAR="$(grep -oE 'rp_[A-Za-z0-9_]+_deny' "$LONG" 2>/dev/null | head -n1)"
assert "geo 变量名确实超出默认 64 字节桶的上限（${#LONGVAR} ≥ 47）" [ "${#LONGVAR}" -ge 47 ]
assert "公共配置已抬高 variables_hash_bucket_size" \
    grep -q '^variables_hash_bucket_size 128;' /etc/nginx/conf.d/00-nginx-rp.conf
rm -f "$LONG" /etc/nginx/sites-enabled/origin-longname.20051212.example.com.conf
assert "长域名用例清理干净，nginx -t 回到基线" nginx -t

sec "micro 自定义 TTL 与登录 cookie"
site_reset
SITE[domain]="micro2.example.com"; SITE[target]="http://127.0.0.1:8080"
SITE[cache]="micro:120"; SITE[skipcookie]="xf_user|xf_session"
render_site_file >/dev/null 2>&1 && nginx -t >/dev/null 2>&1
micro_rc=$?
assert "micro:120 + 自定义 cookie 渲染通过" [ "$micro_rc" = 0 ]
MICRO=/etc/nginx/sites-available/micro2.example.com.conf
assert "自定义 TTL 写入正确" grep -q 'proxy_cache_valid 200 120s;' "$MICRO"
assert "自定义登录 cookie 写入 map" grep -q 'xf_user|xf_session' "$MICRO"

# HTTPS 监听语法必须匹配本机 nginx 版本：1.25.1 前没有独立的 http2 指令，
# 渲染出 `http2 on;` 会让所有 HTTPS 站点 nginx -t 直接失败。
site_reset
SITE[domain]="h2.example.com"; SITE[target]="http://127.0.0.1:8080"
SITE[ssl]="file"; SITE[crt]="$CRT"; SITE[key]="$KEY"
render_site_file >/dev/null 2>&1
H2=/etc/nginx/sites-available/h2.example.com.conf
nginx_ver="$(nginx_version)"
if nginx_supports_http2_directive; then
    assert "nginx $nginx_ver：用独立 http2 指令" grep -qE '^\s*http2 on;' "$H2"
else
    assert "nginx $nginx_ver：用 listen ... http2 老语法" grep -qE 'listen 443 ssl http2;' "$H2"
    if grep -qE '^\s*http2 on;' "$H2"; then
        _no "对 <1.25.1 的 nginx 渲染了 http2 指令（会导致所有 HTTPS 站点失效）"
    else
        _ok "未对老版本 nginx 渲染 http2 指令"
    fi
fi
assert "HTTPS 站点在本机 nginx 版本下通过 nginx -t" nginx -t
rm -f "$H2" /etc/nginx/sites-enabled/h2.example.com.conf

# ============================================================ 回滚三连
sec "回滚 1/3：渲染写盘失败"
# 注意：脚本以 root 运行，而 root 无视文件权限位——chmod a-w 造不出写盘失败（第一版
# 测试就是这么写的，结果渲染照常成功，用例形同虚设）。
# 改用「目标路径被一个非空目录占位」：render_site_file 先写 $file.tmp.$$，重定向到
# 目录必然失败（Is a directory），精准命中写盘失败分支，且对 root 同样有效。
# $$ 在命令替换的子 shell 中与父进程一致，占位名算得准。
site_reset
SITE[domain]="rb1.example.com"; SITE[target]="http://127.0.0.1:8080"
render_site_safe >/dev/null 2>&1
RB1=/etc/nginx/sites-available/rb1.example.com.conf
rb1_orig="$(cat "$RB1" 2>/dev/null)"
assert "前置：基准站点已建立" [ -n "$rb1_orig" ]

mkdir -p "$RB1.tmp.$$/blocker"
site_reset
SITE[domain]="rb1.example.com"; SITE[target]="http://127.0.0.1:9999"
rb1_out="$(render_site_safe 2>&1)"; rb1_rc=$?
rm -rf "$RB1.tmp.$$"
assert "写盘失败时 render_site_safe 返回失败（不再谎报成功）" [ "$rb1_rc" != 0 ]
case "$rb1_out" in
    *已更新*|*已启用*) _no "失败路径却输出了成功文案" ;;
    *)                 _ok "失败路径未输出任何成功文案" ;;
esac
assert "站点文件内容保持为修改前状态" [ "$(cat "$RB1" 2>/dev/null)" = "$rb1_orig" ]
assert "旧目标仍然生效（新目标未被写入）" grep -q '127.0.0.1:8080' "$RB1"
assert "回滚后 nginx 配置仍然有效" nginx -t

# 新建站点时写盘失败：不能留下任何半成品（文件或软链）
site_reset
SITE[domain]="rb1b.example.com"; SITE[target]="http://127.0.0.1:8080"
RB1B=/etc/nginx/sites-available/rb1b.example.com.conf
mkdir -p "$RB1B.tmp.$$/blocker"
render_site_safe >/dev/null 2>&1; rb1b_rc=$?
rm -rf "$RB1B.tmp.$$"
assert "新建站点写盘失败时返回失败"     [ "$rb1b_rc" != 0 ]
assert "写盘失败后未留下站点文件"       [ ! -f "$RB1B" ]
assert "写盘失败后未留下 enabled 软链" [ ! -e /etc/nginx/sites-enabled/rb1b.example.com.conf ]

sec "回滚 2/3：nginx -t 失败（证书路径不存在）"
site_reset
SITE[domain]="rb2.example.com"; SITE[target]="http://127.0.0.1:8080"
render_site_safe >/dev/null 2>&1
RB2=/etc/nginx/sites-available/rb2.example.com.conf
rb2_orig="$(cat "$RB2")"
site_reset
SITE[domain]="rb2.example.com"; SITE[target]="http://127.0.0.1:8080"
SITE[ssl]="file"; SITE[crt]="/nonexistent/fullchain.pem"; SITE[key]="/nonexistent/key.pem"
render_site_safe >/dev/null 2>&1; rb2_rc=$?
assert "坏证书导致 nginx -t 失败时返回失败" [ "$rb2_rc" != 0 ]
assert "站点文件已回滚到旧内容" [ "$(cat "$RB2")" = "$rb2_orig" ]
assert "回滚后 nginx 配置仍然有效" nginx -t

sec "回滚 3/3：外部配置导入失败"
cat > /etc/nginx/conf.d/ext.conf <<'EOF'
server {
    listen 80;
    server_name ext.example.com;
    ssl_certificate /nonexistent/c.pem;
    ssl_certificate_key /nonexistent/k.pem;
    location / { proxy_pass http://127.0.0.1:8081; }
}
EOF
ext_orig="$(cat /etc/nginx/conf.d/ext.conf)"
# 该文件本身就让 nginx -t 不过；导入会用模板重写并 reload，必然失败 → 应完整回滚
printf 'y\n' | import_external_site /etc/nginx/conf.d/ext.conf >/dev/null 2>&1
if [ -f /etc/nginx/conf.d/ext.conf ] && [ "$(cat /etc/nginx/conf.d/ext.conf)" = "$ext_orig" ]; then
    _ok "导入失败后原外部配置已按原样恢复"
else
    _no "导入失败后原外部配置未恢复"
fi
rm -f /etc/nginx/conf.d/ext.conf \
      /etc/nginx/sites-available/ext.example.com.conf \
      /etc/nginx/sites-enabled/ext.example.com.conf 2>/dev/null
assert "导入回滚后 nginx 配置仍然有效" nginx -t

# ============================================================ 输入拒绝
sec "非法输入在渲染前被拒（不写出可疑配置）"
site_reset; SITE[domain]="inj.example.com"; SITE[target]="http://127.0.0.1:8080"
SITE[skipcookie]='a) 1;} server { listen 9999;'
render_site_file >/dev/null 2>&1; inj_rc=$?
assert "注入型 skipcookie 被拒绝渲染" [ "$inj_rc" != 0 ]
assert "被拒后未留下站点文件" [ ! -f /etc/nginx/sites-available/inj.example.com.conf ]

site_reset; SITE[domain]="inj2.example.com"; SITE[target]="http://127.0.0.1:8080"
SITE[allow_ips]=":::::::"
render_site_file >/dev/null 2>&1; inj2_rc=$?
assert "畸形 IPv6 白名单被拒绝渲染" [ "$inj2_rc" != 0 ]

site_reset; SITE[domain]="inj3.example.com"
SITE[target]='http://127.0.0.1:8080;}server{listen 9999;'
render_site_file >/dev/null 2>&1; inj3_rc=$?
assert "注入型反代目标被拒绝渲染" [ "$inj3_rc" != 0 ]

# ============================================================ 主配置备份
sec "主配置修改可追溯"
cp /etc/nginx/nginx.conf /tmp/nginx.conf.keep
rm -rf /etc/nginx/nginx-rp-backups
NGINX_CONF_BACKED_UP=0
# 确保 http 顶层存在 gzip（Debian 默认就有，这里保证测试确定性），
# 同时在 server{} 内也放一条，验证作用域精度
grep -qE '^[[:space:]]*gzip[[:space:]_]' /etc/nginx/nginx.conf \
    || sed -i '0,/^http {/s//http {\n\tgzip on;/' /etc/nginx/nginx.conf
neutralize_conf_gzip >/dev/null 2>&1
assert "修改 nginx.conf 前生成了备份" \
    bash -c 'ls /etc/nginx/nginx-rp-backups/nginx.conf.*.bak >/dev/null 2>&1'
assert "gzip 去重后 nginx -t 仍通过" nginx -t
bk1=$(find /etc/nginx/nginx-rp-backups -type f 2>/dev/null | wc -l)
neutralize_conf_gzip >/dev/null 2>&1
neutralize_conf_gzip >/dev/null 2>&1
bk2=$(find /etc/nginx/nginx-rp-backups -type f 2>/dev/null | wc -l)
assert "重复调用不再堆积备份（单次运行只备份一次）" [ "$bk1" = "$bk2" ]

# ============================================================ 缓存清理
sec "缓存清理：精度"
CACHE_DIR=/var/cache/nginx/it_cache
rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR/1/2"
mkkey() { printf '\x03\x00\x00\x00HDR\nKEY: %s\nHTTP/1.1 200 OK\n' "$1" > "$2"; head -c 4096 /dev/zero >> "$2"; }
mkkey "httpa.example.com/index"    "$CACHE_DIR/1/2/f1"
mkkey "httpsa.example.com/v.mp4"   "$CACHE_DIR/1/2/f2"
mkkey "httpswww.example.com/l.png" "$CACHE_DIR/1/f3"
mkkey "httpother.com/x"            "$CACHE_DIR/1/f4"
mkkey "httpaXexampleYcom/evil"     "$CACHE_DIR/f5"
purge_site_cache "a.example.com www.example.com" >/dev/null 2>&1
assert "本站条目 f1 已清理" [ ! -f "$CACHE_DIR/1/2/f1" ]
assert "本站条目 f2 已清理" [ ! -f "$CACHE_DIR/1/2/f2" ]
assert "本站条目 f3 已清理" [ ! -f "$CACHE_DIR/1/f3" ]
assert "无关站点条目保留"   [ -f "$CACHE_DIR/1/f4" ]
assert "形近域名条目保留（正则里的点已转义）" [ -f "$CACHE_DIR/f5" ]

sec "缓存清理：性能（10 万文件 / 约 10GB 逻辑体积）"
rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
for d in $(seq 0 99); do
    mkdir -p "$CACHE_DIR/$d"
    for n in $(seq 0 999); do
        printf '\x03\x00\x00\x00HDR\nKEY: httpbulk%s.example.com/%s\nHTTP/1.1 200 OK\n' "$d" "$n" \
            > "$CACHE_DIR/$d/f$n"
        truncate -s 100K "$CACHE_DIR/$d/f$n"
    done
done
bulk_total=$(find "$CACHE_DIR" -type f | wc -l)
bulk_start=$(date +%s%N)
purge_site_cache "target.example.com" >/dev/null 2>&1
bulk_ms=$(( ($(date +%s%N) - bulk_start) / 1000000 ))
printf '  文件数=%s 逻辑体积≈%sMB 耗时=%sms\n' "$bulk_total" "$((bulk_total * 100 / 1024))" "$bulk_ms"
# 这是【防退化】阈值，不是性能目标。绝对耗时跟机器差太多——同一份代码在开发机
# 约 2.5s、在 2 核 CI runner 上 6.3s，卡死某个具体数字只会变成环境彩票。
# 真正要挡住的是「退回全文扫描」这个量级的错误：那条路径在同数据集上要 25s+。
# 实测值始终打印出来，趋势由人看。
assert "10 万文件 / 10GB 缓存目录清理未退化到全文扫描量级（≤10s，实测 ${bulk_ms}ms）" \
    [ "$bulk_ms" -le 10000 ]
rm -rf "$CACHE_DIR"

# ============================================================ 单实例锁
sec "单实例锁"
LOCK_FILE=/var/lock/nginx-rp-it.lock
(
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 1
    sleep 5
) &
lock_holder=$!
sleep 1
lock_out="$(LOCK_FILE=$LOCK_FILE timeout 10 bash "$SCRIPT" 2>&1 </dev/null | head -5)"
case "$lock_out" in
    *另一个*|*实例*) _ok "第二个实例被锁拒绝并给出提示" ;;
    *)               _no "第二个实例未被拒绝：$lock_out" ;;
esac
wait "$lock_holder" 2>/dev/null
rm -f "$LOCK_FILE"

# ============================================================ 审计日志
sec "操作审计"
assert "审计日志已记录操作"     [ -s /var/log/nginx-rp.log ]
assert "渲染操作有记录"         grep -q 'RENDER' /var/log/nginx-rp.log
assert "失败或回滚有记录"       grep -qE 'RENDER-ROLLBACK|RENDER-FAIL' /var/log/nginx-rp.log
assert "主配置备份有记录"       grep -q 'BACKUP nginx.conf' /var/log/nginx-rp.log

# ============================================================ 汇总
cp -f /tmp/nginx.conf.keep /etc/nginx/nginx.conf 2>/dev/null
echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m集成测试通过：%d 项全部成功\033[0m\n' "$PASS"
    exit 0
fi
printf '\033[31m集成测试失败：%d 项通过，%d 项失败\033[0m\n' "$PASS" "$FAIL"
exit 1
