#!/bin/bash
# X-Panel 在线一键安装（从 GitHub Release 下载）
#   bash <(curl -fsSL https://raw.githubusercontent.com/tianyou-lab/3-xui-dist/main/install.sh)
# 私有仓库：TOKEN=ghp_xxx bash <(curl -fsSL -H "Authorization: Bearer ghp_xxx" <同上URL>)
# 可选环境变量：PANEL_PORT WEB_PATH USERNAME PASSWORD DOMAIN
#               SKIP_HARDEN=1 SKIP_BBR=1 GH_OWNER GH_REPO GH_TAG TOKEN BASE_URL MIRROR
set -uo pipefail

# 默认从 GitHub Release 下载（可通过环境变量覆盖）
GH_OWNER="${GH_OWNER:-tianyou-lab}"
GH_REPO="${GH_REPO:-3-xui-dist}"
GH_TAG="${GH_TAG:-v25.10.13.1}"
PKG_NAME="${PKG_NAME:-x-panel-v25.10.13-precompiled.tar.gz}"
# 私有仓库需提供 token：TOKEN=ghp_xxx
GH_TOKEN="${TOKEN:-${GH_TOKEN:-}}"
BASE_URL="${BASE_URL:-https://github.com/$GH_OWNER/$GH_REPO/releases/download/$GH_TAG}"
XUI_HOME=/usr/local/x-ui
XUI_DB=/etc/x-ui
SERVICE_FILE=/etc/systemd/system/x-ui.service
CRED_FILE=/root/x-panel-credentials.txt

info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
die()  { err "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行"

info "步骤 1/9: 检查依赖..."
if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl tar ca-certificates >/dev/null 2>&1 || true
elif command -v dnf >/dev/null; then
    dnf install -y -q curl tar ca-certificates >/dev/null 2>&1 || true
elif command -v yum >/dev/null; then
    yum install -y -q curl tar ca-certificates >/dev/null 2>&1 || true
fi
command -v curl >/dev/null || die "缺少 curl"
command -v tar  >/dev/null || die "缺少 tar"

info "步骤 2/9: 下载安装包..."
TMP_DIR=$(mktemp -d /tmp/x-panel-install.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
dl() { # dl <url> <输出文件>
    if [[ -n "$GH_TOKEN" ]]; then
        curl -fsSL --retry 3 -H "Authorization: Bearer $GH_TOKEN" -o "$2" "$1"
    else
        curl -fsSL --retry 3 -o "$2" "$1"
    fi
}
MIRROR="${MIRROR:-https://xui.keyucc.top/dl}"   # 备用镜像（可选）
if ! dl "$BASE_URL/$PKG_NAME" "$TMP_DIR/$PKG_NAME"; then
    warn "GitHub 下载失败，尝试备用镜像 $MIRROR ..."
    dl "$MIRROR/$PKG_NAME" "$TMP_DIR/$PKG_NAME" || die "下载安装包失败（GitHub 与镜像均不可用）"
fi
if dl "$BASE_URL/SHA256SUMS" "$TMP_DIR/SHA256SUMS" 2>/dev/null; then
    EXPECT=$(grep -F "$PKG_NAME" "$TMP_DIR/SHA256SUMS" | awk '{print $1}')
    if [[ -n "$EXPECT" ]]; then
        ACTUAL=$(sha256sum "$TMP_DIR/$PKG_NAME" | awk '{print $1}')
        [[ "$EXPECT" == "$ACTUAL" ]] || die "校验和不匹配"
        ok "安装包校验通过 ($(du -h "$TMP_DIR/$PKG_NAME" | cut -f1))"
    fi
fi

info "步骤 3/9: 安装文件到 $XUI_HOME ..."
mkdir -p "$XUI_HOME" "$XUI_DB"
if [[ -x "$XUI_HOME/x-ui" ]]; then
    cp -f "$XUI_HOME/x-ui" "$XUI_HOME/x-ui.bak.$(date +%Y%m%d%H%M%S)" && warn "已备份旧二进制"
fi
tar -xzf "$TMP_DIR/$PKG_NAME" -C "$TMP_DIR" || die "解压失败"
[[ -f "$TMP_DIR/x-ui" ]] || die "安装包内缺少 x-ui"
cp -f "$TMP_DIR/x-ui" "$XUI_HOME/x-ui"
chmod 755 "$XUI_HOME/x-ui"
if [[ -d "$TMP_DIR/bin" ]]; then
    rm -rf "$XUI_HOME/bin"
    cp -rf "$TMP_DIR/bin" "$XUI_HOME/bin"
    chmod 755 "$XUI_HOME/bin/"* 2>/dev/null
fi
ok "主程序与 xray 内核安装完成"

info "步骤 4/9: 生成端口/路径/凭据..."
pick_port() {
    local p
    for _ in $(seq 1 50); do
        p=$(( (RANDOM % 40000) + 20000 ))
        if ! ss -lnt 2>/dev/null | grep -q ":$p "; then echo "$p"; return 0; fi
    done
    echo 13688
}
PANEL_PORT="${PANEL_PORT:-$(pick_port)}"
WEB_PATH="${WEB_PATH:-/$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)/}"
[[ "$WEB_PATH" == /* ]] || WEB_PATH="/$WEB_PATH"
[[ "$WEB_PATH" == */ ]] || WEB_PATH="$WEB_PATH/"
USERNAME="${USERNAME:-admin}"
PASSWORD="${PASSWORD:-$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)}"
cd "$XUI_HOME" || die "无法进入 $XUI_HOME"
"$XUI_HOME/x-ui" setting -port "$PANEL_PORT" -webBasePath "$WEB_PATH" -username "$USERNAME" -password "$PASSWORD" >/dev/null 2>&1 \
    || warn "初始设置写入失败（数据库可能已存在），可用 x-ui setting 手动修改"
ok "端口 $PANEL_PORT | 路径 $WEB_PATH | 用户 $USERNAME"

info "步骤 5/9: 配置并启动服务..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=X-Panel Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$XUI_HOME
ExecStart=$XUI_HOME/x-ui
Restart=on-failure
RestartSec=5s
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl enable x-ui >/dev/null 2>&1
    systemctl restart x-ui
    sleep 4
    systemctl is-active x-ui >/dev/null && ok "x-ui 已启动（systemd）" || warn "服务异常，查看 journalctl -u x-ui"
else
    warn "未检测到 systemd，改用 nohup 后台启动"
    pkill -f "$XUI_HOME/x-ui" 2>/dev/null || true
    cd "$XUI_HOME" && nohup "$XUI_HOME/x-ui" >/var/log/x-ui.out 2>&1 &
    sleep 3
fi

info "步骤 6/9: 防火墙端口..."
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PANEL_PORT" >/dev/null 2>&1 && ok "ufw 已放行 $PANEL_PORT"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PANEL_PORT"/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 $PANEL_PORT"
else
    warn "未检测到活动防火墙；云服务器请在安全组放行 $PANEL_PORT"
fi

if [[ "${SKIP_HARDEN:-0}" != "1" ]]; then
    info "步骤 7/9: 日志治理（内置配置，无需额外下载）..."
    cat > /etc/logrotate.d/x-ui <<'XUILR'
# X-Panel / Xray 日志轮转
# 注意：xray 进程一直持有日志文件描述符且不会重开，必须用 copytruncate
/usr/local/x-ui/*.log /var/log/x-ui/*.log {
    size 50M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su root root
}
XUILR
    chmod 644 /etc/logrotate.d/x-ui
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-xui-limit.conf <<'XUIJD'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
SystemMaxFiles=10
XUIJD
    chmod 644 /etc/systemd/journald.conf.d/99-xui-limit.conf
    cat > /usr/local/bin/xui-log-guard.sh <<'XUIGUARD'
#!/bin/bash
# X-Panel / Xray 日志与磁盘守卫
# 用法: xui-log-guard.sh            正常巡检（cron 每小时）
#       xui-log-guard.sh --dry-run  只报告不处理
# 阈值可用环境变量覆盖
set -uo pipefail

WARN_MB=${WARN_MB:-600}          # 日志总量告警阈值
HARD_MB=${HARD_MB:-900}          # 日志总量强制清理阈值
FILE_MAX_MB=${FILE_MAX_MB:-100}  # 单个日志文件上限
DISK_PCT_MAX=${DISK_PCT_MAX:-85} # 磁盘使用率强制清理阈值
JOURNAL_MAX=${JOURNAL_MAX:-500M} # journald 回收目标
LOG_PATHS="/usr/local/x-ui /var/log/x-ui"
DB=/etc/x-ui/x-ui.db
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

# 通过面板已配置的 TG 机器人推送（未启用则静默跳过）
notify_tg() {
    local msg="$1" token chat enable
    [[ -f "$DB" ]] || return 0
    enable=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='tgBotEnable';" 2>/dev/null)
    [[ "$enable" == "true" ]] || return 0
    token=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='tgBotToken';" 2>/dev/null)
    chat=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='tgBotChatId';" 2>/dev/null)
    [[ -n "$token" && -n "$chat" ]] || return 0
    curl -s -m 10 "https://api.telegram.org/bot${token}/sendMessage" \
        -d "chat_id=${chat}" --data-urlencode "text=${msg}" >/dev/null 2>&1
}

alert() { # $1=级别(warning|err) $2=消息
    logger -p "user.${1}" -t xui-log-guard "$2"
    echo "[$(date '+%F %T')] $1 $2"
    notify_tg "[X-Panel 日志守卫] $2"
}

log_total_mb() {
    local kb=0
    for d in $LOG_PATHS; do
        [[ -d "$d" ]] || continue
        kb=$((kb + $(find "$d" -maxdepth 1 -type f -name '*.log*' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}') / 1024))
    done
    echo $((kb / 1024))
}

journal_mb() {
    local b
    b=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1)
    [[ -z "$b" ]] && { echo 0; return; }
    case "$b" in
        *G) awk -v v="${b%G}" 'BEGIN{print int(v*1024)}' ;;
        *M) echo "${b%M}" | cut -d. -f1 ;;
        *K) echo 0 ;;
        *) echo 0 ;;
    esac
}

# 清理动作
do_cleanup() {
    [[ $DRY -eq 1 ]] && { echo "(dry-run) 跳过实际清理"; return; }
    logrotate -f /etc/logrotate.d/x-ui 2>/dev/null
    # 轮转后仍超限的单个文件直接截断（truncate 对 xray 追加写是安全的）
    for d in $LOG_PATHS; do
        [[ -d "$d" ]] || continue
        find "$d" -maxdepth 1 -type f -name '*.log' -size "+${FILE_MAX_MB}M" -print0 2>/dev/null |
        while IFS= read -r -d '' f; do
            echo "  截断超大日志: $f ($(du -h "$f" | cut -f1))"
            truncate -s 0 "$f"
        done
    done
    # 只保留最近 2 份轮转归档
    for d in $LOG_PATHS; do
        [[ -d "$d" ]] || continue
        find "$d" -maxdepth 1 -type f -name '*.log.[0-9]*' 2>/dev/null | sort -V | head -n -2 | xargs -r rm -f
    done
    journalctl --vacuum-size="$JOURNAL_MAX" >/dev/null 2>&1
}

main() {
    local logs journals disk used_mb
    logs=$(log_total_mb)
    journals=$(journal_mb)
    disk=$(df --output=pcent / | tail -1 | tr -dc '0-9')
    used_mb=$((logs + journals))

    echo "日志文件: ${logs}MB   journal: ${journals}MB   合计: ${used_mb}MB   磁盘: ${disk}%  (阈值 warn=${WARN_MB} hard=${HARD_MB} disk=${DISK_PCT_MAX}%)"

    if (( used_mb >= HARD_MB )) || (( disk >= DISK_PCT_MAX )); then
        alert err "日志/磁盘超硬阈值（日志${used_mb}MB，磁盘${disk}%），已强制清理"
        do_cleanup
        local after; after=$(( $(log_total_mb) + $(journal_mb) ))
        echo "清理后合计: ${after}MB"
        alert warning "清理完成，当前日志合计 ${after}MB，磁盘 $(df --output=pcent / | tail -1 | tr -dc '0-9')%"
    elif (( used_mb >= WARN_MB )); then
        alert warning "日志总量 ${used_mb}MB 已超过告警阈值 ${WARN_MB}MB（journal ${journals}MB，磁盘 ${disk}%），建议检查"
    else
        echo "状态正常，无需处理"
    fi
}

main
XUIGUARD
    chmod 755 /usr/local/bin/xui-log-guard.sh
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
        systemctl restart systemd-journald 2>/dev/null
        journalctl --vacuum-size=500M >/dev/null 2>&1
    fi
    if command -v crontab >/dev/null; then
        (crontab -l 2>/dev/null | grep -v xui-log-guard; echo '7 * * * * /usr/local/bin/xui-log-guard.sh >/dev/null 2>&1') | crontab -
    fi
        ok "日志治理完成（logrotate + journald 500M + 每小时守卫）"
else
    info "步骤 7/9: 已跳过日志治理"
fi

if [[ "${SKIP_BBR:-0}" != "1" ]]; then
    info "步骤 8/9: 启用 BBR..."
    modprobe tcp_bbr 2>/dev/null || true
    grep -q '^net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    ok "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
else
    info "步骤 8/9: 已跳过 BBR"
fi

info "步骤 9/9: 汇总..."
IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 5 ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")
SCHEME=http
CERT_HINT=""
if [[ -n "${DOMAIN:-}" && -f "/root/cert/$DOMAIN/fullchain.pem" ]]; then
    "$XUI_HOME/x-ui" cert -webCert "/root/cert/$DOMAIN/fullchain.pem" -webCertKey "/root/cert/$DOMAIN/privkey.pem" >/dev/null 2>&1 \
        && { systemctl restart x-ui 2>/dev/null; SCHEME=https; CERT_HINT="（已绑定证书 $DOMAIN）"; }
fi
URL="${SCHEME}://${DOMAIN:-$IP}:${PANEL_PORT}${WEB_PATH}"
cat > "$CRED_FILE" <<EOF
========================================
X-Panel 安装信息  $(date '+%F %T')
========================================
登录地址: $URL
用户名:   $USERNAME
密码:     $PASSWORD
端口:     $PANEL_PORT
访问路径: $WEB_PATH
证书:     ${CERT_HINT:-未配置（HTTP）}

常用命令:
  systemctl status x-ui
  systemctl restart x-ui
  x-ui                      交互菜单
  journalctl -u x-ui -f
  /usr/local/bin/xui-log-guard.sh   日志/磁盘巡检
========================================
EOF
chmod 600 "$CRED_FILE"

echo ""
ok "安装完成 $CERT_HINT"
echo "  登录地址: $URL"
echo "  用户名:   $USERNAME"
echo "  密码:     $PASSWORD"
echo "  凭据文件: $CRED_FILE"
echo ""
warn "云服务器请在控制台安全组放行端口 $PANEL_PORT（TCP）"
