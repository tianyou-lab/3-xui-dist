# 3-xui-dist

X-Panel（3x-ui 定制版）二进制分发仓库。

## 一键安装（含域名与免费证书）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tianyou-lab/3-xui-dist/main/install.sh)
```

安装过程会询问**是否使用域名并自动签发 Let's Encrypt 证书**；安装完成后自动开启证书续期（acme.sh cron，续期后自动重启面板）。


## 已装面板，只想补证书

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tianyou-lab/3-xui-dist/main/cert.sh)
# 或非交互：DOMAIN=panel.example.com bash <(curl -fsSL .../cert.sh)
```

不会改动端口/路径/密码，只申请证书 → 写入面板 → 重启 → 输出 https 地址。

## 安装内容

- 静态编译的 `x-ui`（musl 静态链接，无 glibc 依赖，linux/amd64）
- `bin/`：xray 内核 + geoip/geosite 数据
- 自动生成随机端口 / 随机访问路径 / 随机密码
- systemd 服务、防火墙端口放行、日志轮转（logrotate + journald 限额 + 每小时守卫）、BBR
- 可选：Let's Encrypt 证书（acme.sh，80 空闲用 standalone，否则用 443 ALPN）

凭据写入 `/root/x-panel-credentials.txt`。

## 版本

| 版本 | 说明 |
|---|---|
<<<<<<< HEAD
| v25.10.13.1 | 基于 X-Panel 25.10.13；日志治理；批量生成出站/路由；多防火墙端口放行 |
=======
| v25.10.13.1 | 基于 X-Panel 25.10.13；移除实用导航与 TG 群链接；日志治理；批量生成出站/路由；多防火墙端口放行；交互式域名与证书 |
>>>>>>> 53487cf (fix(install): acme.sh 多源安装（get.acme.sh 不可达时走 GitHub 源码包）+ 新增 cert.sh)

## 环境变量

`PANEL_PORT` `WEB_PATH` `USERNAME` `PASSWORD` `DOMAIN` `SKIP_CERT=1` `SKIP_HARDEN=1` `SKIP_BBR=1` `GH_TAG` 