# 回滚演练手册

> 内部文档。G4 交付闸门要求「回滚演练通过」，本文件记录演练项、如何复现，以及哪些已被自动化覆盖。

脚本对系统的每一类改动都必须可回退。下表是全部改动面与对应的回退手段。

| 改动面 | 回退手段 | 自动化覆盖 |
| --- | --- | --- |
| 站点配置渲染 | `render_site_safe` 快照回滚 | ✅ 集成测试「回滚 1/3、2/3」 |
| 外部配置导入接管 | 备份 + 双向回滚（原文件恢复、受管文件清除） | ✅ 集成测试「回滚 3/3」 |
| 外部配置启停 | 失败即恢复软链 / 改回文件名 | ⬜ 手工 |
| 禁止 IP 直连 | 失败即删除 `00-deny-direct-ip.conf` 并 reload | ⬜ 手工 |
| 全局 real_ip | 失败即删除 `00-nginx-rp-realip.conf` 并 reload | ⬜ 手工 |
| `nginx.conf` 三处修改 | 改前备份到 `$BACKUP_DIR`，手工 `cp` 还原 | ✅ 集成测试验证备份生成 |
| 端口封锁 | 菜单解除封锁 / `iptables -D` | ⬜ 手工 |
| 证书签发与安装 | 删除证书菜单 + acme.sh `--remove` | ⬜ 手工 |
| 脚本自更新 | 从 GitHub 重拉，或用备份的旧版本覆盖 | ⬜ 手工 |

## 自动化演练

```bash
docker build -f tests/integration/Dockerfile -t nginx-rp-it .
docker run --rm nginx-rp-it
```

三条回滚路径的断言：

1. **渲染写盘失败** — 把 `sites-available` 设为只读后触发渲染。断言：返回失败、**不输出任何成功文案**、站点文件内容与操作前逐字节一致、`nginx -t` 仍通过。
2. **`nginx -t` 失败** — 指向不存在的证书路径。断言：返回失败、站点文件已恢复旧内容、`nginx -t` 仍通过。
3. **导入接管失败** — 用一份会导致 `nginx -t` 不过的外部配置执行导入。断言：原外部配置按原样恢复、`nginx -t` 仍通过。

第 1 条是本次整改的核心：此前那条路径会打印「已更新」，而磁盘上什么都没变。

## 手工演练步骤

在一台可弃用的 Debian/Ubuntu 测试机上执行。**不要在生产机上做。**

### 1. 站点配置回滚

```bash
n                                     # 建一个站点 rb.example.com → http://127.0.0.1:8080
cp /etc/nginx/sites-available/rb.example.com.conf /tmp/before.conf
chmod a-w /etc/nginx/sites-available  # 制造写盘失败
n                                     # 管理站点 → 1 修改反代目标 → 改成 :9999
```

预期：报「站点配置渲染失败，已回滚到修改前状态」，**没有**任何「已更新」字样。

```bash
chmod u+w /etc/nginx/sites-available
diff /tmp/before.conf /etc/nginx/sites-available/rb.example.com.conf   # 应无差异
nginx -t                                                              # 应通过
```

### 2. 主配置还原

```bash
ls -lt /etc/nginx/nginx-rp-backups/nginx.conf.*.bak | head -1
cp /etc/nginx/nginx-rp-backups/nginx.conf.<时间戳>.<pid>.bak /etc/nginx/nginx.conf
nginx -t && systemctl reload nginx
```

注意：还原后 `include sites-enabled` 与 gzip 去重会在下次运行脚本时重新写入，这是幂等设计的预期行为。

### 3. 端口封锁解除

```bash
iptables -L DOCKER-USER -n --line-numbers | grep DROP
iptables -L INPUT -n --line-numbers | grep DROP
n    # 管理反向代理 → 3 后端端口直连封锁 → 输入端口 → 解除
```

预期：两条链的规则都被删除，且 `/etc/nginx/nginx-rp-blocked-ports` 里对应行消失（否则下次启动会被自动补回）。

### 4. 脚本自身回退

```bash
cp /usr/local/bin/nginx-rp.sh /tmp/nginx-rp.prev    # 更新前先留一份
n                                                   # 5 更新本脚本
cp /tmp/nginx-rp.prev /usr/local/bin/nginx-rp.sh    # 需要回退时
```

自更新本身有语法校验闸门（`bash -n` 不通过就不覆盖），但不做版本回退，故需要自行留存。

## 演练记录

| 日期 | 环境 | 范围 | 结果 |
| --- | --- | --- | --- |
| 2026-07-26 | debian:bookworm + nginx 1.22.1（容器） | 自动化三条回滚路径 + 新建失败不留半成品 | ✅ 全通过（集成测试 57/57） |

后续自动化部分随每次 CI 运行；手工部分在发版前按需执行。

### 首次演练发现的问题

- `chmod a-w` 无法在 root 下制造写盘失败（root 无视权限位），用例形同虚设。改用「目标临时文件名被非空目录占位」，对 root 同样有效。
- 渲染矩阵用例未清理失败产物，一个失败配置留在 `sites-enabled` 会把后续每次 `nginx -t` 全部带崩，导致只能看到一片红而找不到首因。每例结束即清理。
