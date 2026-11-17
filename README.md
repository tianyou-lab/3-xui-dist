# 3-xui-dist

X-Panel（3x-ui 定制版）二进制分发仓库。**源码不在此仓库**，仅存放安装脚本与编译产物。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tianyou-lab/3-xui-dist/main/install.sh)
```
## 安装内容

- 静态编译的 `x-ui`（musl 静态链接，无 glibc 依赖，linux/amd64）
- `bin/`：xray 内核 + geoip/geosite 数据
- 自动生成随机端口 / 随机访问路径 / 随机密码
- systemd 服务、防火墙端口放行、日志轮转（logrotate + journald 限额 + 每小时守卫）、BBR

安装完成后凭据写入 `/root/x-panel-credentials.txt`。

## 版本

| 版本 | 说明 |
|---|---|
| v25.10.13.1 | 基于 X-Panel 25.10.13；移除实用导航与 TG 群链接；日志治理；批量生成出站/路由；多防火墙端口放行 |

## 环境变量

`PANEL_PORT` `WEB_PATH` `USERNAME` `PASSWORD` `DOMAIN` `SKIP_HARDEN=1` `SKIP_BBR=1` `GH_TAG` `MIRROR`
