#!/bin/bash
# X-Panel 生成「Cloudflare 中转」节点：VLESS + WebSocket（源站明文，TLS 由 CF 提供）
#   bash cdnsetup.sh <CDN域名> [--port 80] [--remark 名称]
set -uo pipefail
XUI_HOME=/usr/local/x-ui
DB=/etc/x-ui/x-ui.db
OK="\033[32m[OK]\033[0m"; ERR="\033[31m[FAIL]\033[0m"; INFO="\033[36m[INFO]\033[0m"; WARN="\033[33m[WARN]\033[0m"
ok(){ printf "$OK %s\n" "$*"; }; err(){ printf "$ERR %s\n" "$*"; }; info(){ printf "$INFO %s\n" "$*"; }; warn(){ printf "$WARN %s\n" "$*"; }

DOMAIN="${1:-}"; shift || true
ORIGIN_PORT=80; REMARK=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) ORIGIN_PORT="$2"; shift 2 ;;
        --remark) REMARK="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done
[[ -z "$DOMAIN" ]] && { echo "用法: bash cdnsetup.sh <CDN域名> [--port 80] [--remark 名称]"; exit 1; }
[[ -f "$DB" ]] || { echo "找不到 $DB"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3"; exit 1; }

PUBIP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "")
[[ -z "$PUBIP" ]] && warn "无法获取公网 IP，配置 CF 时请自行填服务器 IP"

if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$ORIGIN_PORT$"; then
    err "源站端口 $ORIGIN_PORT 已被占用，请用 --port 指定其它端口"; exit 1
fi

info "创建 VLESS + WebSocket 入站（源站端口 $ORIGIN_PORT）..."
RES=$(python3 - "$DB" "$ORIGIN_PORT" "$REMARK" <<'PY'
import json, sqlite3, sys, uuid, secrets
db, port, remark = sys.argv[1], int(sys.argv[2]), sys.argv[3]
con = sqlite3.connect(db)
uid = str(uuid.uuid4())
path = "/" + secrets.token_hex(6)
name = remark or ("cdn-" + secrets.token_hex(2))
settings = json.dumps({
    "clients": [{"id": uid, "flow": "", "email": name, "enable": True, "limitIp": 0,
                 "totalGB": 0, "expiryTime": 0, "tgId": 0, "subId": "", "comment": "", "reset": 0}],
    "decryption": "none", "fallbacks": []
}, ensure_ascii=False)
stream = json.dumps({
    "network": "ws", "security": "none",
    "wsSettings": {"path": path, "headers": {}},
    "tcpSettings": {"acceptProxyProtocol": False, "header": {"type": "none"}}
}, ensure_ascii=False)
sniffing = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": False, "routeOnly": False})
con.execute("""INSERT INTO inbounds
  (user_id, up, down, total, all_time, remark, enable, expiry_time, device_limit, listen, port, protocol, settings, stream_settings, tag, sniffing)
  VALUES (1, 0, 0, 0, 0, ?, 1, 0, 0, '', ?, 'vless', ?, ?, ?, ?)""",
  (name, port, settings, stream, f"inbound-{port}", sniffing))
con.commit(); con.close()
print(f"{uid}|{path}|{name}")
PY
)
[[ -z "$RES" ]] && { err "写入数据库失败"; exit 1; }
UUID=$(echo "$RES" | cut -d'|' -f1)
WSPATH=$(echo "$RES" | cut -d'|' -f2)
NAME=$(echo "$RES" | cut -d'|' -f3)
ok "入站已创建：备注 $NAME  UUID $UUID  WS 路径 $WSPATH"

info "重启面板以加载新入站..."
if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then systemctl restart x-ui; sleep 4
else pkill -f "$XUI_HOME/x-ui"; ( cd "$XUI_HOME" && nohup "$XUI_HOME/x-ui" >/var/log/x-ui.out 2>&1 & ); sleep 4; fi

if ss -lnt 2>/dev/null | grep -qE "[:.]$ORIGIN_PORT "; then ok "xray 已在 $ORIGIN_PORT 监听（源站就绪）"
else err "源站端口未监听，请检查 journalctl -u x-ui"; fi

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then ufw allow "$ORIGIN_PORT" >/dev/null 2>&1 && ok "ufw 放行 $ORIGIN_PORT"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-port="$ORIGIN_PORT"/tcp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; ok "firewalld 放行 $ORIGIN_PORT"
else info "无活动防火墙"; fi

ENCPATH=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$WSPATH")
LINK="vless://${UUID}@${DOMAIN}:443?type=ws&encryption=none&security=tls&sni=${DOMAIN}&host=${DOMAIN}&path=${ENCPATH}&fp=chrome#${NAME}-cdn"
SUBDOMAIN=$(echo "$DOMAIN" | cut -d. -f1)

cat <<EOF

================ Cloudflare 配置（必须做） ================
1) DNS 记录
   类型 A    名称 ${SUBDOMAIN}    内容 ${PUBIP:-<服务器IP>}
   代理状态：已代理（橙色云朵）← 必须是橙云

2) SSL/TLS → 概述 → 加密模式：灵活（Flexible）
   源站是明文 WS，由 CF 提供 HTTPS

3) 等待 1~2 分钟，在任意机器验证：
   curl -sI "https://${DOMAIN}${WSPATH}" | head -1
   期望 4xx（来自 xray 的响应）；若 52x/5xx 说明回源不通

================================ 客户端链接 ================================
${LINK}

CF 也支持这些端口（443 不通可换）：8443 / 2053 / 2083 / 2087 / 2096 / 8880 / 2052 / 2082 / 2086 / 2095
把链接里的 :443 换成上面任意端口即可。

提示：CF 免费版国内速度一般 10~50Mbps；追求速度优先考虑「换 IP + 直连 Reality」。
EOF
