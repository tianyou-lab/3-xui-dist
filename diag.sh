#!/bin/bash
# X-Panel 连接诊断（在面板所在服务器上以 root 运行）
#   bash <(curl -fsSL https://raw.githubusercontent.com/tianyou-lab/3-xui-dist/main/diag.sh)
set -uo pipefail

XUI_HOME=/usr/local/x-ui
DB=/etc/x-ui/x-ui.db
OK="\033[32m[OK]\033[0m"; WARN="\033[33m[WARN]\033[0m"; ERR="\033[31m[FAIL]\033[0m"; INFO="\033[36m[INFO]\033[0m"
ok()   { printf "$OK %s\n" "$*"; }
warn() { printf "$WARN %s\n" "$*"; }
err()  { printf "$ERR %s\n" "$*"; }
info() { printf "$INFO %s\n" "$*"; }

[[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
[[ -x "$XUI_HOME/x-ui" ]] || { echo "未找到 $XUI_HOME/x-ui"; exit 1; }

echo "==================== X-Panel 连接诊断 ===================="
date '+时间: %F %T %Z'

echo ""
echo "---- 1. 面板服务 ----"
if command -v systemctl >/dev/null; then
    systemctl is-active x-ui >/dev/null 2>&1 && ok "x-ui 服务运行中" || err "x-ui 服务未运行（systemctl status x-ui 查看）"
fi
"$XUI_HOME/x-ui" -v 2>/dev/null | sed 's/^/    版本: /'
PANEL_PORT=$(ss -lntp 2>/dev/null | grep -o 'x-ui.*' >/dev/null; "$XUI_HOME/x-ui" setting -show true 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -Eo 'port（端口号）: *[0-9]+' | grep -Eo '[0-9]+' | head -n1)
[[ -n "${PANEL_PORT:-}" ]] && ok "面板端口: $PANEL_PORT"

echo ""
echo "---- 2. Xray 内核 ----"
if pgrep -f 'xray-linux' >/dev/null; then
    ok "xray 进程在运行 (PID $(pgrep -f 'xray-linux' | head -n1))"
else
    err "xray 进程未运行 —— 面板无法启动 xray（查看 journalctl -u x-ui -n 50）"
fi
if [[ -x "$XUI_HOME/bin/xray-linux-amd64" && -f "$XUI_HOME/bin/config.json" ]]; then
    if "$XUI_HOME/bin/xray-linux-amd64" -test -c "$XUI_HOME/bin/config.json" >/tmp/xray-test.log 2>&1; then
        ok "xray 配置校验通过"
    else
        err "xray 配置校验失败："; tail -n 5 /tmp/xray-test.log | sed 's/^/      /'
    fi
fi

echo ""
echo "---- 3. 监听端口 ----"
ss -lntp 2>/dev/null | awk 'NR==1 || /xray|x-ui/' | sed 's/^/    /'

echo ""
echo "---- 4. 入站配置（端口 / 协议 / Reality 目标）----"
if command -v sqlite3 >/dev/null && [[ -f "$DB" ]]; then
    sqlite3 -separator ' | ' "$DB" "SELECT id, port, protocol, remark, substr(stream_settings,1,0) FROM inbounds;" 2>/dev/null | sed 's/^/    ID|端口|协议|备注: /'
    info "Reality 目标（target）与 SNI 列表："
    sqlite3 "$DB" "SELECT id || ' -> target=' || json_extract(stream_settings,'\$.realitySettings.target') || '  sni=' || json_extract(stream_settings,'\$.realitySettings.serverNames') FROM inbounds WHERE protocol='vless';" 2>/dev/null | sed 's/^/    /'
else
    warn "缺少 sqlite3 或无数据库，跳过"
fi

echo ""
echo "---- 5. 防火墙 ----"
if command -v ufw >/dev/null; then
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
        ok "ufw 已启用"; ufw status 2>/dev/null | sed -n '3,20p' | sed 's/^/    /'
    else
        info "ufw 未启用（未启用=不拦截，端口默认放通）"
    fi
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    ok "firewalld 运行中"; firewall-cmd --list-ports 2>/dev/null | sed 's/^/    已放行: /'
fi
iptables -S INPUT 2>/dev/null | head -5 | sed 's/^/    iptables: /'

echo ""
echo "---- 6. 公网 IP 与域名 ----"
IP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "获取失败")
info "公网 IP: $IP"
CERT=$("$XUI_HOME/x-ui" setting -show true 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -Eo 'webDomain[^ ]*' | head -n1)
[[ -n "$CERT" ]] && info "面板证书: $CERT"

echo ""
echo "---- 7. Reality 伪装目标可达性（从本服务器测）----"
for t in tesla.com:443 sega.com:443 apple.com:443 icloud.com:443 lovelive-anime.jp:443 meta.com:443; do
    h=${t%%:*}; p=${t##*:}
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$h/$p" 2>/dev/null; then
        ok "$t 可达"
    else
        err "$t 不可达 ← 若你的节点用这个目标，必然连不上，请改用可达目标"
    fi
done

echo ""
echo "---- 8. 出网连通性 ----"
curl -fsS -o /dev/null --max-time 8 https://www.google.com 2>/dev/null && ok "访问 google.com 正常" || warn "访问 google.com 失败（可能被限制，影响 Reality 握手）"

echo ""
echo "---- 9. 最近日志（错误相关）----"
journalctl -u x-ui -n 100 --no-pager 2>/dev/null | grep -iE 'error|failed|panic|refused|timeout' | tail -n 8 | sed 's/^/    /' || info "无错误日志"

echo ""
echo "==================== 诊断结束 ===================="
echo "常见原因对照："
echo "  1) 云安全组未放行节点端口（服务器内 ufw 放行 ≠ 云厂商安全组放行）"
echo "  2) Reality 伪装目标在本机不可达（上面第 7 项）"
echo "  3) 客户端与服务器时间偏差过大（Reality 对时间敏感，用 date 对比）"
echo "  4) 客户端不支持 xtls-rprx-vision / 使用了错误的 SNI 或 shortId"
echo "  5) 面板创建入站后未重启 xray（面板会自动重启，可看第 2、3 项确认端口已监听）"
