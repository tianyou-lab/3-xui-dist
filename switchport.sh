#!/bin/bash
# X-Panel 节点换端口（含放行 + 重启 + 重新生成分享链接）
#   bash switchport.sh <新端口> [--inbound <ID>] [--domain <域名或IP>]
#   默认处理所有 vless+reality 入站
set -uo pipefail
XUI_HOME=/usr/local/x-ui
DB=/etc/x-ui/x-ui.db
OK="\033[32m[OK]\033[0m"; ERR="\033[31m[FAIL]\033[0m"; INFO="\033[36m[INFO]\033[0m"
ok(){ printf "$OK %s\n" "$*"; }; err(){ printf "$ERR %s\n" "$*"; }; info(){ printf "$INFO %s\n" "$*"; }

NEWPORT="${1:-}"; shift || true
INBOUND_ID=""; DOMAIN_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --inbound) INBOUND_ID="$2"; shift 2 ;;
        --domain)  DOMAIN_ARG="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done
[[ -z "$NEWPORT" ]] && { echo "用法: bash switchport.sh <新端口> [--inbound ID] [--domain 域名]"; exit 1; }
[[ "$NEWPORT" =~ ^[0-9]+$ ]] && (( NEWPORT >= 1 && NEWPORT <= 65535 )) || { echo "端口无效"; exit 1; }
[[ -f "$DB" ]] || { echo "找不到 $DB"; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }

PUBIP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "")
HOST="${DOMAIN_ARG:-$PUBIP}"

# 端口占用检查
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$NEWPORT$"; then
    err "端口 $NEWPORT 已被占用，请换一个"; exit 1
fi

info "把入站端口改为 $NEWPORT（--inbound ${INBOUND_ID:-全部 reality 入站}）..."
OUT=$(python3 - "$DB" "$NEWPORT" "$INBOUND_ID" "$XUI_HOME/bin/xray-linux-amd64" <<'PY'
import json, sqlite3, subprocess, sys
db, newport, target_id, xray = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
con = sqlite3.connect(db)
where = "protocol='vless'" + (" and id=" + target_id if target_id else "")
rows = con.execute(f"select id, port, remark, settings, stream_settings from inbounds where {where}").fetchall()
if not rows:
    print("EMPTY"); sys.exit(0)
for iid, oldport, remark, settings, ss in rows:
    d = json.loads(ss or '{}'); s = json.loads(settings or '{}')
    rs = d.get('realitySettings') or {}
    if d.get('security') != 'reality':
        continue
    con.execute("update inbounds set port=?, tag=? where id=?", (newport, f"inbound-{newport}", iid))
    priv = rs.get('privateKey') or ''
    pbk = ''
    if priv:
        out = subprocess.run([xray, 'x25519', '-i', priv], capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines():
            low = line.lower()
            if low.startswith('password:') or low.startswith('public key'):
                pbk = line.split(':', 1)[1].strip()
    snis = rs.get('serverNames') or ['']
    sids = rs.get('shortIds') or ['']
    print(f"INBOUND|{iid}|{oldport}|{remark}|{pbk}|{snis[0]}|{sids[0]}")
    for c in (s.get('clients') or []):
        print(f"CLIENT|{iid}|{c.get('id')}|{c.get('email')}|{c.get('flow','')}")
con.commit(); con.close()
PY
)
if [[ "$OUT" == "EMPTY" || -z "$OUT" ]]; then err "没有找到可修改的 vless+reality 入站"; exit 1; fi

info "重启面板使 xray 重新加载配置..."
if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl restart x-ui; sleep 4
else
    pkill -f "$XUI_HOME/x-ui"; ( cd "$XUI_HOME" && nohup "$XUI_HOME/x-ui" >/var/log/x-ui.out 2>&1 & ); sleep 4
fi

if ss -lnt 2>/dev/null | grep -qE "[:.]$NEWPORT "; then
    ok "xray 已在新端口 $NEWPORT 监听"
else
    err "新端口未监听，请检查 journalctl -u x-ui"
fi

# 防火墙放行
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$NEWPORT" >/dev/null 2>&1 && ok "ufw 已放行 $NEWPORT"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$NEWPORT"/tcp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; ok "firewalld 已放行 $NEWPORT"
elif iptables -S INPUT 2>/dev/null | grep -qE 'DROP|REJECT'; then
    iptables -C INPUT -p tcp --dport "$NEWPORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$NEWPORT" -j ACCEPT
    ok "iptables 已放行 $NEWPORT"
else
    info "无活动防火墙，无需放行（云服务器记得在安全组放行 $NEWPORT）"
fi

echo ""
echo "================ 新的分享链接 ================"
echo "$OUT" | grep '^INBOUND|' | while IFS='|' read -r _ iid oldport remark pbk sni sid; do
    echo ""
    echo "入站 #$iid 备注 $remark  （$oldport → $NEWPORT，SNI $sni，sid $sid）"
done
echo "$OUT" | grep '^CLIENT|' | while IFS='|' read -r _ iid uuid email flow; do
    meta=$(echo "$OUT" | grep "^INBOUND|$iid|" | head -n1)
    IFS='|' read -r _ _ _ remark pbk sni sid <<< "$meta"
    fparam=""
    [[ -n "${flow:-}" ]] && fparam="&flow=${flow}"
    echo ""
    echo "  [$email]"
    echo "  vless://${uuid}@${HOST}:${NEWPORT}?type=tcp&encryption=none&security=reality&pbk=${pbk}&fp=chrome&sni=${sni}&sid=${sid}&spx=%2F${fparam}#${remark}-${email}"
done
echo ""
echo "============================================="
warn_note="客户端只需把端口改成 $NEWPORT，其它参数不用动；如仍连不上说明该端口也被拦，请再换（推荐 443/8443/2053）"
info "$warn_note"
