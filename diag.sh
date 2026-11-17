#!/bin/bash
# X-Panel 连接诊断 v2（在面板所在服务器上以 root 运行）
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

# 统一的 sqlite 查询（sqlite3 优先，缺失时用 python3）
q() {
    if command -v sqlite3 >/dev/null; then
        sqlite3 -noheader "$DB" "$1" 2>/dev/null
    elif command -v python3 >/dev/null; then
        python3 - "$DB" "$1" <<'PY' 2>/dev/null
import sqlite3,sys
con=sqlite3.connect(sys.argv[1])
for row in con.execute(sys.argv[2]):
    print("|".join("" if v is None else str(v) for v in row))
PY
    fi
}

echo "==================== X-Panel 连接诊断 ===================="
date '+时间: %F %T %Z'

PUBIP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null || echo "")

echo ""
echo "---- 1. 面板服务 ----"
command -v systemctl >/dev/null && { systemctl is-active x-ui >/dev/null 2>&1 && ok "x-ui 服务运行中" || err "x-ui 服务未运行"; }
"$XUI_HOME/x-ui" -v 2>/dev/null | sed 's/^/    版本: /'
PANEL_PORT=$("$XUI_HOME/x-ui" setting -show true 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -Eo 'port（端口号）: *[0-9]+' | grep -Eo '[0-9]+' | head -n1)
[[ -n "${PANEL_PORT:-}" ]] && ok "面板端口: $PANEL_PORT"

echo ""
echo "---- 2. Xray 内核 ----"
pgrep -f 'xray-linux' >/dev/null && ok "xray 进程运行中 (PID $(pgrep -f 'xray-linux' | head -n1))" || err "xray 进程未运行"
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
echo "---- 4. 入站与 Reality 参数 ----"
INB=$(q "SELECT id||'|'||port||'|'||protocol||'|'||ifnull(remark,'')||'|'||ifnull(json_extract(stream_settings,'\$.network'),'')||'|'||ifnull(json_extract(stream_settings,'\$.security'),'')||'|'||ifnull(json_extract(stream_settings,'\$.realitySettings.target'),'')||'|'||ifnull(json_extract(stream_settings,'\$.realitySettings.serverNames'),'')||'|'||ifnull(json_extract(stream_settings,'\$.realitySettings.shortIds'),'') FROM inbounds;")
if [[ -z "$INB" ]]; then
    warn "未能读取入站配置（缺 sqlite3/python3 或数据库为空）"
else
    printf '    %-4s %-7s %-8s %-10s %-8s %-8s %s\n' ID 端口 协议 备注 网络 安全 伪装目标/SNI/shortIds
    echo "$INB" | while IFS='|' read -r id port proto remark net sec target snis sids; do
        printf '    %-4s %-7s %-8s %-10s %-8s %-8s %s\n' "$id" "$port" "$proto" "$remark" "$net" "$sec" "$target"
        [[ -n "${snis:-}" ]] && echo "         serverNames: $snis"
        [[ -n "${sids:-}" ]] && echo "         shortIds   : $sids"
    done
fi

echo ""
echo "---- 5. Reality 回退自测（从本机公网 IP 连自己的节点）----"
if [[ -n "$PUBIP" && -n "$INB" ]]; then
    echo "$INB" | while IFS='|' read -r id port proto remark net sec target snis sids; do
        [[ "$sec" != "reality" ]] && continue
        sni=$(echo "$snis" | tr -d '[]" ' | cut -d, -f1)
        [[ -z "$sni" ]] && continue
        out=$(timeout 15 openssl s_client -connect "$PUBIP:$port" -servername "$sni" </dev/null 2>&1 | grep -E 'subject=|Verify return code|alert' | head -2 | tr '\n' ' ')
        if echo "$out" | grep -q 'subject='; then
            ok "端口 $port (SNI $sni) Reality 回退正常 → $out"
        else
            err "端口 $port (SNI $sni) Reality 回退失败 → $out"
        fi
    done
else
    warn "缺少公网 IP 或入站信息，跳过"
fi

echo ""
echo "---- 6. 防火墙 ----"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ok "ufw 已启用"; ufw status 2>/dev/null | sed -n '3,15p' | sed 's/^/    /'
else
    info "ufw 未启用（未启用=不拦截）"
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    ok "firewalld 运行中"; firewall-cmd --list-ports 2>/dev/null | sed 's/^/    已放行: /'
fi
iptables -S INPUT 2>/dev/null | head -3 | sed 's/^/    iptables: /'

echo ""
echo "---- 7. Reality 伪装目标可达性（服务器侧）----"
BAD=0
for t in tesla.com:443 sega.com:443 apple.com:443 icloud.com:443 lovelive-anime.jp:443 meta.com:443; do
    h=${t%%:*}; p=${t##*:}
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$h/$p" 2>/dev/null; then
        ok "$t 可达"
    else
        err "$t 不可达"; BAD=$((BAD+1))
    fi
done

echo ""
echo "---- 8. 出网与系统 ----"
curl -fsS -o /dev/null --max-time 8 https://www.google.com 2>/dev/null && ok "google.com 可访问" || warn "google.com 不可访问"
info "服务器时间: $(date '+%F %T %Z')   公网 IP: ${PUBIP:-未知}"

echo ""
echo "---- 9. 最近错误日志 ----"
journalctl -u x-ui -n 150 --no-pager 2>/dev/null | grep -iE 'error|failed|panic|refused|timeout|reality' | tail -n 6 | sed 's/^/    /' || info "无错误日志"

echo ""
echo "==================== 结论 ===================="
if [[ $BAD -gt 0 ]]; then
    err "有 $BAD 个 Reality 目标不可达：请在一键配置时避开这些目标（新版面板会自动跳过不可达目标）"
else
    ok "服务器侧检查全部正常：xray 在跑、端口在听、Reality 回退正常、目标可达、无防火墙拦截"
    echo ""
    echo "如果客户端仍连不上，问题在「客户端」或「客户端到服务器的线路」，请依次排查："
    echo "  A. 客户端不支持 Reality/vision：换 v2rayN 6.x+ / v2rayNG 1.8+ / mihomo(Clash Meta) / sing-box"
    echo "  B. 从客户端所在网络测试端口是否可达："
    echo "       Windows: Test-NetConnection 64.178.127.30 -Port 41206"
    echo "       macOS/Linux: nc -zv 64.178.127.30 41206"
    echo "     不通 → 被墙/被运营商拦，请换端口(如 443)或换 IP"
    echo "  C. 客户端与服务器时间偏差 >1 分钟：校准系统时间"
    echo "  D. 导入链接时参数丢失：重新扫码，确保 flow=xtls-rprx-vision、sid、pbk、sni 与上面第 4 节一致"
fi
echo "=============================================="
