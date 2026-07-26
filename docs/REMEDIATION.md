# nginx-rp 质量整改工单

> 内部文档。面向维护者与接手会话，不面向脚本终端用户。
> 终端用户视角的说明一律只进 `README.md`。

立项日期：2026-07-26
基线提交：`21dc7a3`（fix: 站点列表显示真实反代目标而非内部 upstream 名）
基线规模：`nginx-rp.sh` 2127 行 / 111 KB，单文件

---

## 1. 立项（G0）

### 一句话灵魂

**任何一次操作，要么真正生效，要么明确失败并回到操作前状态——绝不出现「报告成功但没做到」。**

基线评审的结论不是「思路错了」，而是「收口没做完」。回滚模型、原子写、幂等设计都在，缺的是把它们贯彻到每一条写盘路径，以及用测试把它们钉死。

### Non-Goals（明确不做，本次不讨论）

> 执行中维护者要求「技术债一并修复」，其中两条 Non-Goal 被放开，下方已标注实际结论。
> 其余各条自始至终守住。

1. **不拆分单文件。** `bash <(curl -fsSL ...)` 一键分发是产品核心。主脚本必须保持单文件自包含，`tests/` 与 `.github/` 不参与分发。 —— **守住**
2. **不扩发行版支持。** `require_apt` 的硬阻断保留，不适配 RHEL / Alpine / OpenWrt。 —— **守住**
3. ~~**不改 meta 格式、不加 schema version。**~~ —— **已放开**。实际解法是拆开处理：内部换成具名字段契约、落盘格式一字节不动、版本号惰性升级。存量零操作的硬约束仍然满足，见 §5。
4. **不改交互流程与菜单结构。** —— **基本守住**：主菜单与各级菜单的编号、层级、操作路径全部未变。仅在运维子菜单末尾追加一项「查看本脚本操作记录」，并在卸载流程末尾追问一句是否移除脚本自身（技术债 T4 的落点，不新增菜单项）。
5. **不引入 bash 以外的运行时依赖。** 无 jq / python / perl。目标机可能是最小化安装。 —— **守住**
6. **不做多实例编排、不做权限分级。** 单机 root 工具的定位不变。 —— **守住**（`flock` 是并发防呆，不是编排）
7. **不做功能增补。** 不加新缓存档、不加新 DNS 服务商。 —— **守住**

### 准出度量（可量化，全部达标才算完成）

| # | 指标 | 目标值 | 验证方式 |
|---|---|---|---|
| M1 | 静默失败路径 | 0 | 集成测试注入写盘/软链失败，断言必须报错且回滚 |
| M2 | `shellcheck -S warning` 告警 | 0 | CI |
| M3 | 渲染矩阵通过率 | 5 缓存档 × 2 SSL 形态 = 10/10 `nginx -t` 通过 | 集成测试 |
| M4 | 回滚路径覆盖 | 3/3（渲染失败 / reload 失败 / 导入失败） | 集成测试断言文件内容回到原状 |
| M5 | 边界五类 | 空值 / 超长 / 非法字符 / 边界数值 / 并发，每类 ≥1 用例 | 单测 + 集成测试 |
| M6 | `purge_site_cache` 耗时 | 10 万文件 / 10 GB 缓存目录 ≤ 5 s | 集成测试计时 |
| M7 | 主配置修改可追溯 | 每次改 `/etc/nginx/nginx.conf` 均有对应备份，且 README 已披露 | 集成测试 + 文档评审 |
| M8 | 并发保护 | 第二个实例被拒绝并提示 | 集成测试 |
| M9 | CI 门禁 | push / PR 全绿方可合 main | GitHub Actions |

---

## 2. 已确认的范围决策

| 决策项 | 结论 | 影响 |
|---|---|---|
| 整改深度 | 全量 P0→P2，对齐 G0–G4 | 4 段推进，约 400–600 行改动 + 新增 `tests/`、`.github/`、`docs/` |
| 存量兼容 | 严格向后兼容，存量站点零操作 | 不动 meta 格式；`get_meta` 缺字段按默认值降级的现有行为保留 |
| 测试形态 | 纯函数单测 + Docker 集成测试 | 需新增 `tests/unit.sh`、`tests/integration/`，CI 三 job |

维护者自行拍板、不占用决策的项：

- **保持单文件分发**（见 Non-Goal 1）。
- **`nginx.conf` 修改策略**：继续自动修改，但改前备份 + README 披露 + 收窄作用域。不改成「每次询问」——`neutralize_conf_gzip` 在每次 reload/restart 前都跑，询问会毁掉交互体验。
- **不引入外部依赖**（见 Non-Goal 5）。缓存清理的性能优化用 `awk`（Debian 基础系统自带 mawk）而非 Python。

---

## 3. 缺陷清单（评审结论，按整改段归位）

### P0 — 静默失败与安全（第 1 段）

**D1｜渲染失败被当成功上报** · `nginx-rp.sh:1207-1208`

```bash
mv -f "$tmp" "$file"
ln -sf "$file" "$SITES_ENABLED/$primary.conf"
```

两处均无返回值检查，`render_site_file` 整体无 return 语义。磁盘满 / 只读挂载时：新配置没落盘 → `render_site_safe` 照常 reload → `nginx -t` 拿旧配置通过 → 打印「目标已更新」。**用户被告知改动生效，实际没有。** 上游的 `{ ... } > "$tmp"` 与 `cat >> "$tmp"` 同样未检查。

**D2｜root 写固定 `/tmp` 路径** · `nginx-rp.sh:161,163,199,200`

```bash
nginx -t 2>/tmp/nginx_test.log
```

`/tmp` world-writable，本地非特权用户可预置 `ln -s /etc/shadow /tmp/nginx_test.log`，root 运行时重定向跟随符号链接覆盖任意文件（CWE-59）。同文件 `846` 行 `acme_issue` 已用 `mktemp`，属漏网而非认知缺失。`846` 行的 `|| echo "/tmp/acme_issue.$$"` 兜底同样是可预测路径，一并处理。

**D3｜输入校验不对称** · `nginx-rp.sh:1329`

同一个 `render_site_file` 的三个用户输入：`allow_ips` 有字符白名单（`534`）、`realip` 有 `valid_ip_cidr`（`385`），唯独 `skipcookie` 只做了 `${var//\"/}` 删双引号，`;` `{` `}` 全部放行，直接拼进 nginx `map` 块。语法合法的注入能通过 `nginx -t` 回滚闸门。本地 root 场景危害有限，但破坏了脚本自身的一致性。

**D4｜反代目标 host/path 未做字符校验** · `nginx-rp.sh:1250-1261`

`normalize_target` 只检查 scheme 与 host 非空，host 与 path 的字符不校验，直接拼进 `upstream server` 与 `proxy_pass`。与 D3 同源，一并修。

### P1 — 不可逆修改与性能（第 2、3 段）

**D5｜三处 `sed -i` 直改 `/etc/nginx/nginx.conf`，零备份** · `559` / `575` / `675,681`

`ensure_worker_shutdown_timeout`、`neutralize_conf_gzip`、`ensure_sites_enabled_include` 均直接修改用户主配置且无备份。README「文件落点」表未列 `nginx.conf`，用户不知情。

**D6｜gzip 注释正则无上下文判断** · `nginx-rp.sh:575`

```bash
sed -i -E 's/^([[:space:]]*)(gzip([[:space:]_]).*)$/\1# \2 .../' "$conf"
```

作用于全文件任意行。用户若在 `nginx.conf` 的 `server{}` 或 `location{}` 内写了 gzip 指令，会被一并注释，静默改变行为。且该函数在每次 reload/restart 前都跑。

**D7｜缓存清理是全盘全文扫描** · `nginx-rp.sh:653-667`

```bash
grep -rlsE "KEY: https?${host_re}/" "$CACHE_DIR"
```

`proxy_cache_path` 声明 `max_size=10g`，而 `KEY` 只在文件头部。当前实现对每个文件读到尾。删站 / 换缓存档时分钟级阻塞，无进度、无超时、无中断。代码注释里的「文件多时可能稍慢」低估了一个数量级。

### P2 — 工程规范（第 3、4 段）

| ID | 项 | 现状 |
|---|---|---|
| D8 | 测试 | 零。`.claude/settings.local.json` 显示手工跑过 `shellcheck -S error` 与 `bash -n`，未固化 |
| D9 | CI | 无 `.github/` |
| D10 | 清理 | 无 `trap`。Ctrl-C 残留 `.tmp.$$` / `.rollback.$$`（列表有跳过兜底，但文件永久堆积） |
| D11 | 可观测 | 无操作日志。改 iptables、改主配置、删证书、删缓存全部无痕，事后无法追溯 |
| D12 | 并发 | 无锁。两个终端同时操作同一站点直接竞态 |
| D13 | 文档 | 无 CHANGELOG、无内部交接文档、无 Non-Goals、无回滚演练记录 |

---

## 4. 分段规划

排序原则：**风险自兜底**——高风险改动必须落在测试就位之后。故 D6（改用户主配置的正则重写）从直觉上的第 2 段挪到第 3 段。

每段完成即提交 `main`（脚本自更新只从 main 拉，生产机通过菜单「5 更新本脚本」获取）。段与段之间向维护者汇报，确认后再进下一段。

### 第 1 段 · P0 止血

**改动性质**：纯加固，把原本被忽略的返回值检查起来。不改控制流，不改交互。风险低，`bash -n` + 手工验证足够。

1. **D1** — `render_site_file` 全链路返回状态
   - `{ ... } > "$tmp"`、`cat >> "$tmp"`、`mv -f`、`ln -sf` 四处逐一检查，任一失败即 `rm -f "$tmp"` 并 `return 1`
   - `render_site_safe` 把现有的回滚块抽成内部函数 `_rollback_site`，渲染失败与 reload 失败共用
   - `render_site_safe` 改为 `if ! render_site_file "$@"; then _rollback_site; return 1; fi`
2. **D2** — 新增 `nginx_test()` 统一封装，内部用 `mktemp`；`reload_nginx` / `restart_nginx` / `ops_menu` 的配置测试全部改走它。`acme_issue` 的 `mktemp` 兜底改为失败即返回，删除可预测路径分支
3. **D3** — `skipcookie` 加字符白名单 `[A-Za-z0-9_.:|-]`（覆盖 `nh:at`、`_app_session`、`a|b` 多选一场景），拒绝时给明确提示。`choose_cache_mode` 入口与 `set_site_*` 读 meta 回来的值都要过（防手工改坏 meta）
4. **D4** — `normalize_target` 补 host 字符校验（`A-Za-z0-9.:_-` 与 IPv6 方括号）与 path 校验（拒 `;` `{` `}` 空白与换行）

**验收**：`bash -n` 通过；手工在测试机造只读 `sites-available`，断言报错且不打印成功文案；非法 cookie / target 被拒。

### 第 2 段 · 不可逆修改可追溯 + 缓存性能

**改动性质**：新增备份行为与算法替换，不改既有语义。风险低。

1. **D5** — 新增 `backup_nginx_conf()`，在三个 `sed -i` 实际要改之前调用。单次运行内幂等（用标志位），避免每次 reload 堆备份。备份落 `$BACKUP_DIR`
2. **D7** — `purge_site_cache` 改为单 `awk` 进程批量处理，每文件只读前 16 行（`nextfile` 提前退出，mawk / gawk 均支持），配合 `find -print0 | xargs -0`。补文件总数提示
3. **README** — 「文件落点」表补 `/etc/nginx/nginx.conf` 行，写明会被修改的三处与备份位置

**验收**：测试机上确认改 `nginx.conf` 前生成备份；10 万小文件缓存目录计时 ≤ 5 s。

### 第 3 段 · 测试与 CI（G3 主体）

**改动性质**：新增测试资产 + 一处结构性改动（入口守卫）+ D6 正则重写。**入口守卫是本次整改唯一有回归风险的改动，必须优先验证两条分发路径。**

1. **入口守卫** — 脚本末尾改为
   ```bash
   if [ "${BASH_SOURCE[0]}" = "$0" ]; then
       require_root; require_apt; ensure_tty; setup_shortcut; main_menu
   fi
   ```
   使脚本可被 `source` 进测试而不进入交互。**必须验证**：`bash <(curl ...)`（`$0` 与 `BASH_SOURCE[0]` 同为 `/dev/fd/N`）、`n` 快捷命令、`sudo bash nginx-rp.sh` 三条路径行为不变
2. **`tests/unit.sh`** — 纯函数单测，任意 bash 可跑：`valid_ip_cidr`（合法 v4/v6/CIDR、越界 256、前缀 33/129、空、垃圾串）、`normalize_target`、`valid_domain`、`valid_email`、`get_meta`（缺字段、值含 `=`）、cookie 白名单、micro TTL 钳制（`00000` → 5，超长数字）
3. **`tests/integration/`** — Docker（`debian:bookworm` + nginx），用例：
   - 渲染矩阵：5 缓存档 × (仅 HTTP / 本地证书 HTTPS) = 10 例 `nginx -t` 全通过（M3）
   - 白名单 + real_ip 同站共存，断言 `geo $realip_remote_addr` 块正确生成
   - 回滚三连（M4）：渲染失败（只读目录）/ reload 失败（坏证书路径）/ 导入接管失败，各自断言文件内容回到原状
   - `neutralize_conf_gzip` 只动 `http{}` 顶层：造一个 `server{}` 内含 gzip 的 `nginx.conf`，断言未被注释
   - `purge_site_cache` 只删本站：造两站缓存条目，断言另一站不受影响 + 计时（M6）
   - 边界五类（M5）
4. **D6** — `neutralize_conf_gzip` 用 `awk` 跟踪花括号深度与 `http{}` 上下文重写，只注释 http 顶层的 gzip 行。**在上一条集成用例就位之后再改**
5. **`.github/workflows/ci.yml`** — 三 job：`lint`（`shellcheck -S warning` + `bash -n`）、`unit`、`integration`
6. **M2** — 清零 shellcheck warning（预计会暴露一批 SC2086 / SC2155 之类，逐条判断修还是加 `# shellcheck disable` 并注明理由）

**验收**：CI 三 job 全绿；M2–M6 达标。

### 第 4 段 · 可观测与交付文档（G4）

1. **D11** — `audit()` 写 `/var/log/nginx-rp.log`：时间、`${SUDO_USER:-root}`、操作、目标、结果。只记变更类操作（建站 / 改配置 / 删站 / 改 iptables / 改主配置 / 签发删除证书 / 卸载），不记菜单浏览。超 10 MB 自截断保留后半（不引入 logrotate 依赖）
2. **D12** — `flock -n` 单实例锁（util-linux，Debian 基础系统自带），置于 `require_root` 之后，被拒时给明确提示
3. **D10** — `trap` 清理本进程残留的 `.tmp.$$` / `.rollback.$$`
4. **D13** — 文档补齐：
   - `docs/ARCHITECTURE.md`（内部）：meta 11 字段语义与位置参数契约、渲染管线、回滚模型、已知技术债
   - `docs/ROLLBACK-DRILL.md`：回滚演练步骤与结果，标注哪些项已被集成测试自动覆盖
   - `CHANGELOG.md`
   - README 补：操作日志位置、单实例锁行为
5. **闸门复核** — 逐条核对 M1–M9，出具准出结论

**验收**：M1–M9 全绿，G0–G4 逐条判定为 YES。

---

## 4.5 执行结果

范围在执行中扩大：维护者要求技术债一并修复，故原「不修」的 5 项全部纳入并完成。
执行过程中另外发现并修复了 3 个基线评审未抓到的缺陷（见下表 ★）。

| 编号 | 项 | 状态 |
| --- | --- | --- |
| D1 | 渲染失败被当成功上报 | ✅ 已修 |
| D2 | root 写固定 `/tmp` 路径 | ✅ 已修（含 `acme_issue` 的可预测路径兜底） |
| D3 | `skipcookie` 校验缺失 | ✅ 已修 |
| D4 | 反代目标 host/path 未校验 | ✅ 已修 |
| D5 | 主配置修改无备份 | ✅ 已修（三处统一经 `backup_nginx_conf`） |
| D6 | gzip 正则无上下文判断 | ✅ 已修（awk 跟踪花括号深度） |
| D7 | 缓存清理全盘全文扫描 | ✅ 已修（awk + `nextfile` 只读前 16 行） |
| D8/D9 | 无测试 / 无 CI | ✅ 已建（单测 174 项 + Docker 集成 + 三 job CI） |
| D10 | 无 trap 清理 | ✅ 已修 |
| D11 | 无操作日志 | ✅ 已修（`audit()` + 菜单查看入口） |
| D12 | 无并发锁 | ✅ 已修（`flock -n`） |
| D13 | 文档缺失 | ✅ 已补（ARCHITECTURE / ROLLBACK-DRILL / CHANGELOG / README 披露） |
| T1 | 位置参数契约脆弱 | ✅ 已重构为 `SITE` 关联数组，落盘格式不变、存量零操作 |
| T2 | meta 无 schema version | ✅ 已加 `metaver`，惰性升级 |
| T3 | iptables 规则不持久 | ✅ 已修（状态文件 + 启动逐链自愈） |
| T4 | 无卸载本脚本入口 | ✅ 已加（挂在卸载流程末尾，不新增菜单项） |
| T5 | IPv6 校验偏宽 | ✅ 已收紧（`valid_ipv6` 完整实现，含 `::` 压缩与 IPv4 映射） |
| ★N1 | `backend_port_blocked` 「任一链有即算已封」 | ✅ 已修。Docker 重启清掉 `DOCKER-USER` 后状态显示「已封锁」而端口实际裸奔 |
| ★N2 | 菜单在 EOF 下无限刷屏 | ✅ 已修（`read_choice` 统一处理，7 处菜单） |
| ★N3 | 删证书时 `rm -rf` 路径可能退化 | ✅ 已修（域名合法性校验 + `${var:?}`），由 shellcheck SC2115 抓到 |
| ★N4 | **Debian 12 上所有 HTTPS 站点建不起来** | ✅ 已修。固定渲染 `http2 on;`（nginx 1.25.1+ 语法），而 Debian 12 官方源是 1.22.1 → `unknown directive`。README 原写「推荐 ≥1.25」，实为硬依赖。现按版本自动选语法。**由集成测试首跑抓到** |

### 验证状态（全部实跑，非纸面）

| 项 | 方式 | 结果 |
| --- | --- | --- |
| 语法 | `bash -n`（三个文件） | ✅ 通过 |
| 静态检查 | `shellcheck -S warning`（三个文件） | ✅ 零告警 |
| 单测 | `bash tests/unit.sh` | ✅ 174/174 |
| 集成测试 | Docker（debian:bookworm + nginx 1.22.1） | ✅ 57/57 |
| CI | GitHub Actions | ⬜ 待推送后触发 |

### 度量达标情况

| # | 指标 | 目标 | 实测 |
| --- | --- | --- | --- |
| M1 | 静默失败路径 | 0 | ✅ 写盘失败返回 1、不输出成功文案、旧配置逐字节不变 |
| M2 | shellcheck warning | 0 | ✅ 0 |
| M3 | 渲染矩阵 | 10/10 | ✅ 10/10 |
| M4 | 回滚路径 | 3/3 | ✅ 3/3（另加「新建失败不留半成品」2 项） |
| M5 | 边界五类 | 每类 ≥1 | ✅ 空值/超长/非法字符/边界数值在单测，并发在集成 |
| M6 | 10 万文件缓存清理 | ≤ 5000ms | ✅ 3626ms（优化前同数据集 25138ms） |
| M7 | 主配置改动可追溯 | 有备份 + 已披露 | ✅ 备份生成 + 单次运行只备份一次 + README 列出三处改动 |
| M8 | 并发保护 | 第二实例被拒 | ✅ |
| M9 | CI 门禁 | 全绿方可合 main | ⬜ 待首次推送验证 |

### 测试自身的两个教训

1. **`chmod a-w` 对 root 无效**，第一版「只读目录」用例形同虚设——渲染照常成功。改用「临时文件名被非空目录占位」，对 root 同样有效且精准命中写盘失败分支。
2. **`source` 被测脚本会覆盖同名函数**。第一版计数函数叫 `ok()`，被脚本自己的 `ok()` 覆盖后，全部用例通过却报告「0 项成功」，绿色勾照常打印而失败被完全掩盖。计数函数改用 `_` 前缀，并加了框架自检。

## 5. 技术债处置

立项时列出的 5 项技术债，维护者要求一并修复，已全部完成（见 §4.5 的 T1–T5）。

其中 T1（位置参数契约）与 T2（meta 无 schema version）原判定为「与存量零操作冲突，
本次不修」。实际解法是把两者拆开看：**内部**换成具名字段的关联数组契约，**落盘格式**
一个字节都不动，版本号走惰性升级（旧文件读出来是空即视为 v1，下次保存自动写上）。
两个目标并不互斥——原判定过于保守。

修复后新产生的、有意保留的取舍记录在 `docs/ARCHITECTURE.md` 的「已知技术债」一节。

---

## 6. 接手须知

- 主脚本必须保持单文件、可 `bash <(curl ...)` 直接运行。改动后先跑 `bash -n`，再跑 `tests/unit.sh`（第 3 段起可用）。
- 站点配置的唯一真相是 `sites-available/<主域名>.conf` 头部的 meta 注释块，`get_meta` 是唯一读取入口。任何新增字段必须同时改 `render_site_file` 的写入与全部 10 处调用点。
- 所有写盘操作必须能回滚。新增路径时对照 `render_site_safe` 的快照—渲染—验证—回滚模型。
- 发版即进 `main`：脚本自更新只从 `main` 拉，功能分支不会被生产机看到。
