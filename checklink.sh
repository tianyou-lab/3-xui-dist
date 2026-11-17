#!/bin/bash
# X-Panel 分享链接校验器：把 vless 链接与服务端入站配置逐项比对
#   bash <(curl -fsSL ".../checklink.sh") "vless://..."
set -uo pipefail
XUI_HOME=/usr/local/x-ui
DB=/etc/x-ui/x-ui.db
OK="\033[32m[OK]\033[0m"; ERR="\033[31m[FAIL]\033[0m"; INFO="\033[36m[INFO]\033[0m"
ok(){ printf "$OK %s\n" "$*"; }; err(){ printf "$ERR %s\n" "$*"; }; info(){ printf "$INFO %s\n" "$*"; }

LINK="${1:-}"
[[ -z "$LINK" ]] && { echo "用法: bash checklink.sh \"vless://...\""; exit 1; }
[[ "$LINK" == vless://* ]] || { echo "只支持 vless:// 链接"; exit 1; }
[[ -f "$DB" ]] || { echo "找不到 $DB"; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3"; exit 1; }

PUBIP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "")

python3 - "$LINK" "$DB" "${XUI_HOME}/bin/xray-linux-amd64" "$PUBIP" <<'PY'
import json, sqlite3, subprocess, sys
from urllib.parse import urlparse, parse_qs, unquote

link, db, xray, pubip = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
u = urlparse(link)
uuid = unquote(u.username or '')
host = u.hostname or ''
port = u.port or 0
q = {k: v[0] for k, v in parse_qs(u.query).items()}
fails = []

def ok(m): print("\033[32m[OK]\033[0m   " + m)
def bad(m):
    print("\033[31m[FAIL]\033[0m " + m); fails.append(m)
def info(m): print("\033[36m[INFO]\033[0m " + m)

print(f"链接: uuid={uuid} host={host} port={port}")
print(f"      type={q.get('type')} security={q.get('security')} sni={q.get('sni')} sid={q.get('sid')} pbk={q.get('pbk','')[:16]}… flow={q.get('flow')}")
print("")

con = sqlite3.connect(db)
row = con.execute("select id, settings, stream_settings from inbounds where port=?", (port,)).fetchone()
if not row:
    bad(f"服务器上没有任何入站使用端口 {port}")
    sys.exit(1)
iid, settings, ss = row
s = json.loads(settings or '{}'); d = json.loads(ss or '{}')
rs = d.get('realitySettings') or {}

info(f"匹配到入站 #{iid}（端口 {port}）")

# 1 网络/安全
if q.get('type') == d.get('network'): ok(f"网络类型一致: {d.get('network')}")
else: bad(f"网络类型不一致: 链接={q.get('type')} 服务器={d.get('network')}")
if q.get('security') == d.get('security'): ok(f"安全类型一致: {d.get('security')}")
else: bad(f"安全类型不一致: 链接={q.get('security')} 服务器={d.get('security')}")

# 2 UUID
clients = s.get('clients') or []
ids = [c.get('id') for c in clients]
if uuid in ids:
    c = clients[ids.index(uuid)]
    ok(f"UUID 匹配客户端: {c.get('email')}")
    lf = q.get('flow') or ''
    sf = c.get('flow') or ''
    if lf == sf: ok(f"flow 一致: '{sf}'" if sf else "flow 一致: 均为空")
    else: bad(f"flow 不一致: 链接='{lf}' 服务器='{sf}'")
else:
    bad(f"UUID 不在该入站的客户端里（服务器有 {len(ids)} 个客户端）")

# 3 SNI / shortId
snis = rs.get('serverNames') or []
if q.get('sni') in snis: ok(f"SNI 在 serverNames 中: {q.get('sni')}")
else: bad(f"SNI '{q.get('sni')}' 不在 serverNames {snis} 中")
sids = rs.get('shortIds') or []
if (q.get('sid') or '') in sids: ok(f"shortId 在列表中: '{q.get('sid')}'")
else: bad(f"shortId '{q.get('sid')}' 不在 {sids} 中")

# 4 pbk
priv = rs.get('privateKey') or ''
derived = ''
if priv:
    try:
        out = subprocess.run([xray, 'x25519', '-i', priv], capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines():
            low = line.lower()
            if low.startswith('password:') or low.startswith('public key'):
                derived = line.split(':', 1)[1].strip()
    except Exception:
        pass
if derived and q.get('pbk') == derived: ok("pbk 与服务端公钥一致")
elif derived: bad(f"pbk 不一致: 链接={q.get('pbk')} 服务端={derived}（链接可能是旧的，请重新生成）")
else: info("无法推导服务端公钥，跳过 pbk 校验")

# 5 目标与端口可达
if pubip and host:
    try:
        import socket
        rip = socket.gethostbyname(host)
        if rip == pubip: ok(f"域名解析正确: {host} → {rip}")
        else: bad(f"域名解析异常: {host} → {rip}，本机公网 IP 是 {pubip}")
    except Exception as e:
        bad(f"域名解析失败: {e}")

print("")
if fails:
    print(f"\033[31m结果: 发现 {len(fails)} 处不匹配，这就是连不上的原因\033[0m")
    sys.exit(2)
print("\033[32m结果: 链接与服务端配置完全匹配 —— 服务端无问题，问题在客户端或线路\033[0m")
PY
