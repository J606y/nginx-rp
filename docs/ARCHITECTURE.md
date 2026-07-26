# nginx-rp 内部设计

> 内部文档，面向维护者与接手会话。终端用户视角的说明只进 `README.md`。

## 形态约束

单文件 bash 脚本，必须能 `bash <(curl -fsSL ...)` 直接运行。这条约束决定了几乎所有设计取舍：

- 不能拆模块、不能有运行时依赖（无 jq / python / perl），只用 Debian 基础系统必有的工具。
- `tests/`、`.github/`、`docs/` 不参与分发，删掉也不影响脚本运行。
- 脚本末尾用 `[ "${BASH_SOURCE[0]}" = "$0" ]` 守卫，使其既能直接执行又能被 `source` 进测试。三条分发路径下两个变量均相等，行为不变；`source` 时不等，只加载函数。

## 核心契约：站点属性 SITE

站点的全部可配置属性放在全局关联数组 `SITE`，它是渲染的唯一输入。

```
site_reset      置为默认值
site_load <f>   从站点文件的 meta 注释块读入（缺字段沿用默认值）
site_validate   渲染前统一校验，返回 1 即拒绝渲染
render_site_file   按 SITE 渲染并落盘（无参数）
render_site_safe   快照 → 渲染 → nginx -t → 失败回滚（无参数）
```

字段：`domain target maxbody cache skipcookie sslverify ssl crt key allow_ips realip metaver`

**新增字段只需改两处**：`site_reset` 的默认值表、`render_site_file` 的使用处。调用点不用动。

> 历史：这套契约原本是 11 个位置参数贯穿 10 处调用点，加一个字段要同步改 10 行，
> 漏一处、错一位都不报错，只会静默渲染出错误配置。

### 落盘格式与版本

meta 是站点 `.conf` 头部的 `# key=value` 注释块，`get_meta` 是唯一读取入口。

格式**刻意保持不变**，存量机器上的站点无需任何迁移即可继续被读取和管理。`metaver` 采用惰性升级：旧文件读出来是空（视为 v1），下次保存时自动写上当前版本，不做一次性全量重写。

## 失败与回滚模型

**核心不变量：任何一次操作，要么真正生效，要么明确失败并回到操作前状态。**

`render_site_safe` 的完整流程：

```
1. 快照     cp 旧文件 → .rollback.$$   ← 快照失败立刻中止，没有退路就不动手
2. 渲染     render_site_file           ← 写盘/软链每步检查返回值
3. 验证     reload_nginx → nginx -t
4a. 成功    删除快照，写审计日志
4b. 失败    _rollback_site 恢复文件与软链 → reload → 返回 1
```

写盘用 `tmp + mv` 原子换位，避免中途被打断留下半截文件。

其他有回滚的路径：`enable_deny_ip`、`enable_realip`、`import_external_site`、`toggle_external_site`。新增会写盘的路径时，对照上面的模型实现，不要裸写 `render_site_file + reload`。

## 输入校验

所有会被拼进 nginx 配置的用户输入都必须先过校验，否则等于允许注入任意指令：

| 输入 | 校验函数 |
| --- | --- |
| 域名 | `valid_domain` |
| 反代目标 | `normalize_target`（host 用正则白名单，path 拒绝 `; { } " ' \` 与空白） |
| IP / CIDR | `valid_ip_cidr` → `valid_ipv4` / `valid_ipv6` |
| 登录 cookie | `valid_cookie_pattern`（只放行 `[A-Za-z0-9_.:|-]`） |

`site_validate` 在渲染前把这些再过一遍，覆盖「meta 被手工改坏」与「外部配置导入的解析结果」两种来源。

两个易踩的坑，都已被单测钉死：

- `case` 的模式里 `|` 是分支分隔符，写进 `[!...]` 否定字符类会把模式从中间截断，导致**所有**输入被放行。校验用 `[[ =~ ]]`，不用 `case`。
- `awk -v` 会对值做转义序列处理，把正则里的 `\.` 降级成 `.`（匹配任意字符）。传正则一律走 `ENVIRON`。

## nginx 版本适配

渲染出的配置必须匹配**本机** nginx 版本，不能假设用户跑的是新版：

| 特性 | 分界 | 处理 |
| --- | --- | --- |
| HTTP/2 | 1.25.1 | ≥ 用 `http2 on;`；< 用 `listen ... http2`。探测失败时按老语法走——新版对老语法只是弃用警告，反过来会直接 `unknown directive` |
| `ssl_reject_handshake` | 1.19.4 | ≥ 直接拒绝未知 SNI；< 回落到自签证书 + 444 |

统一走 `nginx_version_ge <版本>`。

> 这不是理论风险：Debian 12(bookworm) 官方源的 nginx 是 1.22.1，而脚本一度固定渲染
> `http2 on;`，结果在最主流的目标环境上**所有 HTTPS 站点都建不起来**。文档当时写的是
> 「推荐 nginx ≥ 1.25」，实际是硬依赖。集成测试首次运行就抓到了它——这也是为什么
> 集成环境必须用发行版默认的 nginx，而不是最新版。

## 缓存清理

`purge_site_cache` 逐条挑出属于本站的缓存文件——缓存区 `rpcache` 是多站点共用的，不能整目录删。

匹配缓存文件头部的 `KEY: <scheme><host>/...` 行，host 里的点必须转义（否则 `a.b.com` 的正则会连 `aXbYcom` 一起误删）。

只读每个文件的**前 16 行**（`awk` + `nextfile`）。缓存区上限 10GB，全文匹配会把未命中的文件整个读到尾，删一次站点等于全盘扫描十几 GB。老 awk 无 `nextfile` 时退回全文扫描并明确告知。

并发数取 `nproc` 但**钳在 4–8**，不完全跟随核数：耗时几乎全在等 IO，CPU 基本闲着，并发低于 4 时（2 核小机器、CI runner）压不满盘队列。同一份代码 10 万文件的实测：开发机约 2.5–4.6 s，2 核 CI runner 约 6.3 s，而优化前的全文扫描是 25.1 s。集成测试的阈值按「防退化到全文扫描量级」设为 10 s，不卡具体数字——绝对耗时跟机器差太多，卡死就成了环境彩票。

## 对主配置的修改

三处（见 README「对主配置的改动」）。统一经 `backup_nginx_conf` 备份，单次运行内只备份一次（`NGINX_CONF_BACKED_UP` 标志位），否则每次 reload 都会堆一份。备份失败时**跳过修改**——宁可不改，也不在没有退路的情况下动用户主配置。

`neutralize_conf_gzip` 用 awk 跟踪花括号深度，只处理 `http{}` 直接子级的 gzip 行。用户写在 `server{}` / `location{}` 里的 gzip 是合法的局部覆盖，与公共配置不冲突，注释掉等于静默改变站点行为。

## 可观测与并发

- `audit()` 写 `/var/log/nginx-rp.log`，只记变更类操作。写入失败一律静默且不返回错误——审计是旁路，不能阻断运维操作本身。注意错误重定向要包住整个复合命令（`{ ...; } 2>/dev/null`），路径不可写时报错来自 shell 建立重定向的那一刻，挂在 `printf` 上的 `2>/dev/null` 拦不住。
- `acquire_lock()` 用 `flock -n` 独占 fd 9。无 `flock` 时不阻断，只提醒——锁是防呆，不该成为可用性单点。
- `read_choice()`：所有 `while true` 菜单必须走它。`read` 读到 EOF 时返回非 0 且不赋值，按「无效选项」处理会瞬间无限刷屏。

## 端口封锁的持久性

iptables 规则写在 `DOCKER-USER`（管 Docker 发布端口）与 `INPUT`（管本机服务）两条链。Docker 重启会重建 `DOCKER-USER` 并清掉规则，主机重启在没有 netfilter-persistent 时同样会丢。

对策：封锁的端口记进 `/etc/nginx/nginx-rp-blocked-ports`，脚本每次启动调用 `restore_port_blocks` **逐链**检查并补齐。

`backend_port_blocked` 必须要求**所有**链都有规则才算已封锁。早先是「任一链有即算」，Docker 重启后 `INPUT` 还在而 `DOCKER-USER` 没了，菜单显示「已封锁」而端口实际裸奔。

## 测试

| 层 | 位置 | 覆盖 |
| --- | --- | --- |
| 单测 | `tests/unit.sh` | 纯函数：校验器、meta 读写、SITE 契约、gzip awk 作用域、audit、菜单 EOF。零依赖 |
| 集成 | `tests/integration/` | 真实 Debian + nginx：渲染矩阵、回滚三连、缓存精度与性能、单实例锁、入口守卫 |
| 静态 | CI | `shellcheck -S warning` 零告警 + `bash -n` + LF 行尾检查 |

单测覆盖不到渲染/回滚路径——P0 缺陷恰恰全在那里，所以集成测试不是可选项。

## 已知技术债

| 项 | 说明 | 状态 |
| --- | --- | --- |
| IPv6 zone id | `valid_ipv6` 不支持 `fe80::1%eth0` 形式 | 未支持。目标场景（可信上游 / 白名单）用不到链路本地地址 |
| meta 无强类型 | 字段值是自由字符串，靠 `site_validate` 逐条校验兜底 | 可接受。加 schema 会引入依赖，与单文件约束冲突 |
| 无 systemd 单元 | 端口封锁靠脚本启动时重放，主机重启后到下次运行脚本之间有窗口期 | 有意为之。装 unit 属于系统侵入，超出单机工具定位；已在 README 说明 |
| `discover_proxies` 全文 grep | 对每个候选配置文件做全文匹配找 `nginx-rp BEGIN` 标记 | 可接受。配置文件通常只有几 KB，与缓存目录不是一个量级 |

## 接手须知

- 改动后先 `bash -n`，再 `bash tests/unit.sh`，再 `shellcheck -S warning`。三者全绿才提交。
- 涉及渲染 / 回滚 / 主配置的改动，必须补集成测试用例并在容器里实跑。
- 发版即进 `main`：脚本自更新只从 `main` 拉，功能分支不会被生产机看到。
- 面向终端用户的文案只进 README；架构、取舍、技术债只进本文件。
