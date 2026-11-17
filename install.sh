#!/bin/bash
# X-Panel 在线一键安装（从 GitHub Release 下载）
#   bash <(curl -fsSL https://raw.githubusercontent.com/tianyou-lab/3-xui-dist/main/install.sh)
# 私有仓库：TOKEN=ghp_xxx bash <(curl -fsSL -H "Authorization: Bearer ghp_xxx" <同上URL>)
# 交互式：安装过程中会询问「是否使用域名并自动签发免费证书」
# 可选环境变量：PANEL_PORT WEB_PATH USERNAME PASSWORD DOMAIN（给了域名则自动申请证书）
#               SKIP_CERT=1 跳过证书  SKIP_HARDEN=1 SKIP_BBR=1
#               GH_OWNER GH_REPO GH_TAG TOKEN BASE_URL MIRROR
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

# ============ 域名与证书相关函数 ============
validate_domain() {
    local d="${1:-}"
    [[ -n "$d" && ${#d} -le 253 ]] || return 1
    [[ "$d" == *.* ]] || return 1
    [[ "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

check_domain_dns() {
    local domain="$1" server_ip="" domain_ip=""
    server_ip=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null)
    if [[ -z "$server_ip" ]]; then warn "无法获取本机公网 IP，跳过 DNS 校验"; return 0; fi
    info "本机公网 IP: $server_ip"
    if command -v dig >/dev/null; then
        domain_ip=$(dig +short A "$domain" @8.8.8.8 2>/dev/null | tail -n1)
    fi
    if [[ -z "$domain_ip" ]] && command -v nslookup >/dev/null; then
        domain_ip=$(nslookup "$domain" 8.8.8.8 2>/dev/null | awk '/^Address: /{print $2}' | tail -n1)
    fi
    if [[ -z "$domain_ip" ]] && command -v getent >/dev/null; then
        domain_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -n1)
    fi
    if [[ -z "$domain_ip" ]]; then
        warn "无法解析 $domain，请确认 DNS 已添加 A 记录"
        return 1
    fi
    info "域名解析 IP: $domain_ip"
    if [[ "$server_ip" == "$domain_ip" ]]; then ok "DNS 解析正确"; return 0; fi
    warn "域名解析 IP ($domain_ip) 与本机 IP ($server_ip) 不一致，证书申请大概率失败"
    if [[ -t 0 ]]; then
        local ans=""
        read -r -p "是否仍然继续申请证书？[y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] && return 0
    fi
    return 1
}

port_busy() {
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"
}

restart_panel() {
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
        systemctl restart x-ui
        sleep 3
    else
        pkill -f "$XUI_HOME/x-ui" 2>/dev/null
        ( cd "$XUI_HOME" && nohup "$XUI_HOME/x-ui" >/var/log/x-ui.out 2>&1 & )
        sleep 2
    fi
}

# 多源安装 acme.sh（get.acme.sh 在部分网络下不可用，故提供 GitHub 源码包 / git clone 兜底）
install_acme() {
    local domain="$1"
    local acme="$HOME/.acme.sh/acme.sh"
    local log=/tmp/acme-install.log
    local ok=0

    if [[ -x "$acme" ]]; then
        ok "acme.sh 已存在: $acme"
        return 0
    fi

    info "安装 acme.sh（日志: $log）..."
    : > "$log"

    # 方式 1：官方一键脚本
    if curl -fsSL --max-time 60 https://get.acme.sh -o /tmp/get-acme.sh 2>>"$log"; then
        if sh /tmp/get-acme.sh email="admin@$domain" >>"$log" 2>&1 && [[ -x "$acme" ]]; then ok=1; fi
    else
        echo "[WARN] 无法下载 https://get.acme.sh" >>"$log"
    fi

    # 方式 2：GitHub 源码包（官方脚本自身的兜底方式）
    if [[ $ok -ne 1 ]]; then
        info "改用 GitHub 源码包安装 acme.sh ..."
        if curl -fsSL --max-time 180 https://github.com/acmesh-official/acme.sh/archive/master.tar.gz -o /tmp/acme-master.tar.gz 2>>"$log"; then
            rm -rf /tmp/acme.sh-master
            tar xzf /tmp/acme-master.tar.gz -C /tmp >>"$log" 2>&1
            if [[ -d /tmp/acme.sh-master ]]; then
                if ( cd /tmp/acme.sh-master && ./acme.sh --install --home "$HOME/.acme.sh" --accountemail "admin@$domain" >>"$log" 2>&1 ) && [[ -x "$acme" ]]; then ok=1; fi
            fi
        else
            echo "[WARN] 无法下载 acme.sh 源码包（github.com 不可达）" >>"$log"
        fi
    fi

    # 方式 3：git clone
    if [[ $ok -ne 1 ]] && command -v git >/dev/null; then
        info "改用 git clone 安装 acme.sh ..."
        rm -rf /tmp/acme-git
        if git clone --depth=1 https://github.com/acmesh-official/acme.sh.git /tmp/acme-git >>"$log" 2>&1; then
            if ( cd /tmp/acme-git && ./acme.sh --install --home "$HOME/.acme.sh" --accountemail "admin@$domain" >>"$log" 2>&1 ) && [[ -x "$acme" ]]; then ok=1; fi
        fi
    fi

    if [[ $ok -ne 1 ]]; then
        err "acme.sh 安装失败：无法访问 get.acme.sh / github.com"
        echo "----- 安装日志（末尾 20 行）-----"
        tail -n 20 "$log" 2>/dev/null
        echo "------------------------------"
        warn "可手动安装后重试本脚本，或手动签发证书后执行:"
        warn "  x-ui cert -webCert /root/cert/<域名>/fullchain.pem -webCertKey /root/cert/<域名>/privkey.pem"
        return 1
    fi
    ok "acme.sh 安装成功"
    return 0
}

setup_certificate() {
    local domain="$1"
    local acme="$HOME/.acme.sh/acme.sh"
    local dir="/root/cert/$domain"
    local mode="" rc=0

    install_acme "$domain" || return 1
    "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1

    if ! port_busy 80; then
        mode="standalone"
    elif ! port_busy 443; then
        mode="alpn"
    else
        err "80 与 443 端口均被占用，无法自动签发证书（面板仍可用 HTTP 访问）"
        warn "请释放 80 端口后重新运行本脚本，或手动签发后执行: x-ui cert -webCert $dir/fullchain.pem -webCertKey $dir/privkey.pem"
        return 1
    fi
    info "验证方式: $mode"
    if [[ "$mode" == "standalone" ]] && ! command -v socat >/dev/null; then
        warn "缺少 socat（standalone 模式必需），尝试安装..."
        if command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null; then dnf install -y -q socat >/dev/null 2>&1 || true
        elif command -v yum >/dev/null; then yum install -y -q socat >/dev/null 2>&1 || true
        fi
        command -v socat >/dev/null || warn "socat 仍不可用，standalone 可能失败"
    fi

    info "正在向 Let's Encrypt 申请证书（约 10~60 秒）..."
    if [[ "$mode" == "standalone" ]]; then
        "$acme" --issue -d "$domain" --standalone --httpport 80 --force
    else
        "$acme" --issue -d "$domain" --alpn --tlsport 443 --force
    fi
    rc=$?
    if [[ $rc -ne 0 ]]; then
        err "证书签发失败（常见原因：DNS 未生效 / 80、443 被占用 / Let's Encrypt 频率限制）"
        rm -rf "$HOME/.acme.sh/$domain" 2>/dev/null
        return 1
    fi
    ok "证书签发成功"

    mkdir -p "$dir"
    "$acme" --installcert -d "$domain" \
        --key-file "$dir/privkey.pem" \
        --fullchain-file "$dir/fullchain.pem" \
        --reloadcmd "systemctl restart x-ui" >/dev/null 2>&1
    if [[ ! -f "$dir/fullchain.pem" || ! -f "$dir/privkey.pem" ]]; then
        err "证书文件安装失败"
        return 1
    fi
    chmod 600 "$dir/privkey.pem"; chmod 644 "$dir/fullchain.pem"
    "$acme" --upgrade --auto-upgrade >/dev/null 2>&1
    ok "证书已安装: $dir（acme.sh 已开启自动续期 + 续期后自动重启面板）"

    cd "$XUI_HOME" || return 1
    if ! "$XUI_HOME/x-ui" cert -webCert "$dir/fullchain.pem" -webCertKey "$dir/privkey.pem" >/dev/null 2>&1; then
        err "写入面板证书失败"
        return 1
    fi
    restart_panel
    ok "面板已启用 HTTPS"
    return 0
}

info "步骤 1/10: 检查依赖..."
DEPS="curl tar ca-certificates socat openssl cron git"
if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $DEPS >/dev/null 2>&1 || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl tar ca-certificates >/dev/null 2>&1 || true
elif command -v dnf >/dev/null; then
    dnf install -y -q $DEPS >/dev/null 2>&1 || dnf install -y -q curl tar ca-certificates >/dev/null 2>&1 || true
elif command -v yum >/dev/null; then
    yum install -y -q $DEPS >/dev/null 2>&1 || yum install -y -q curl tar ca-certificates >/dev/null 2>&1 || true
fi
command -v curl >/dev/null || die "缺少 curl"
command -v tar  >/dev/null || die "缺少 tar"

info "步骤 2/10: 下载安装包..."
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

info "步骤 3/10: 安装文件到 $XUI_HOME ..."
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

info "步骤 4/10: 生成端口/路径/凭据..."
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
USERNAME="${USERNAME:-$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 10)}"
PASSWORD="${PASSWORD:-$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)}"
cd "$XUI_HOME" || die "无法进入 $XUI_HOME"
"$XUI_HOME/x-ui" setting -port "$PANEL_PORT" -webBasePath "$WEB_PATH" -username "$USERNAME" -password "$PASSWORD" >/dev/null 2>&1 \
    || warn "初始设置写入失败（数据库可能已存在），可用 x-ui setting 手动修改"
ok "端口 $PANEL_PORT | 路径 $WEB_PATH | 用户 $USERNAME"

info "步骤 5/10: 配置并启动服务..."
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

info "步骤 6/10: 防火墙端口..."
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PANEL_PORT" >/dev/null 2>&1 && ok "ufw 已放行 $PANEL_PORT"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PANEL_PORT"/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 $PANEL_PORT"
else
    warn "未检测到活动防火墙；云服务器请在安全组放行 $PANEL_PORT"
fi

# ---------- 7. 域名与 HTTPS 证书 ----------
CERT_OK=0
DOMAIN="${DOMAIN:-}"
if [[ "${SKIP_CERT:-0}" != "1" ]]; then
    info "步骤 7/10: 域名与 HTTPS 证书..."
    if [[ -z "$DOMAIN" && -t 0 ]]; then
        printf '\033[33m是否使用域名并自动签发免费证书（Let\x27s Encrypt）？[y/N]: \033[0m'
        read -r USE_DOMAIN
        if [[ "$USE_DOMAIN" =~ ^[Yy]$ ]]; then
            tries=0
            while (( tries < 3 )); do
                tries=$((tries + 1))
                printf '\033[33m请输入已解析到本机的域名（如 panel.example.com）: \033[0m'
                read -r DOMAIN || { DOMAIN=""; break; }
                if [[ -z "$DOMAIN" ]]; then DOMAIN=""; break; fi
                if ! validate_domain "$DOMAIN"; then err "域名格式不正确（第 $tries/3 次）"; DOMAIN=""; continue; fi
                if ! check_domain_dns "$DOMAIN"; then err "DNS 检查未通过（第 $tries/3 次）"; DOMAIN=""; continue; fi
                break
            done
            if [[ -z "$DOMAIN" ]]; then
                warn "未获得有效域名，跳过证书配置，面板将使用 HTTP 访问"
            fi
        fi
    elif [[ -n "$DOMAIN" ]]; then
        info "使用指定域名: $DOMAIN"
        validate_domain "$DOMAIN" || { err "域名格式不正确: $DOMAIN"; DOMAIN=""; }
    fi

    if [[ -n "$DOMAIN" ]]; then
        setup_certificate "$DOMAIN" && CERT_OK=1
    else
        info "未使用域名：面板将通过 http://IP:$PANEL_PORT$WEB_PATH 访问"
        warn "如需 HTTPS，可在面板「面板设置」中上传证书，或重跑本脚本选择域名"
    fi
else
    info "步骤 7/10: 已跳过证书配置"
fi

if [[ "${SKIP_HARDEN:-0}" != "1" ]]; then
    info "步骤 8/10: 日志治理（内置配置，无需额外下载）..."
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
    info "步骤 8/10: 已跳过日志治理"
fi

if [[ "${SKIP_BBR:-0}" != "1" ]]; then
    info "步骤 9/10: 启用 BBR..."
    modprobe tcp_bbr 2>/dev/null || true
    grep -q '^net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    ok "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
else
    info "步骤 9/10: 已跳过 BBR"
fi

info "步骤 10/10: 汇总..."
IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 5 ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")
if [[ "$CERT_OK" == "1" && -n "$DOMAIN" ]]; then
    SCHEME=https
    URL="https://$DOMAIN:$PANEL_PORT$WEB_PATH"
    CERT_HINT="（HTTPS 已启用，证书自动续期）"
else
    SCHEME=http
    URL="http://$IP:$PANEL_PORT$WEB_PATH"
    CERT_HINT="（HTTP，未配置证书）"
fi
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

# 版权信息
echo ""
echo "============================================="
echo " 版权声明:"
echo " 1. 允许自由使用和修改"
echo " 2. 禁止用于非法活动"
echo " 3. 二次发布需保留此声明"
echo "============================================="
echo "感谢使用 X-Panel自动化安装工具"
echo "版权声明: 禁止用于商业用途"

# 开发者信息
echo "============================================="
echo "脚本名称: X-Panel自动化安装工具"
echo "贡献者: 天道酬勤  欢迎TG交流vx：wzhr000"
echo "版本: v2026117.0"
echo "============================================="
echo "安装完成！请访问面板进行配置"

