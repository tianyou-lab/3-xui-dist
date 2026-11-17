#!/bin/bash
# X-Panel 证书配置脚本（已安装面板的机器可单独运行）
#   bash <(curl -fsSL https://raw.githubusercontent.com/tianyou-lab/3-xui-dist/main/cert.sh)
# 作用：为已有面板申请 Let's Encrypt 证书、写入面板、开启自动续期
# 可选：DOMAIN=panel.example.com 直接指定域名（非交互）
set -uo pipefail

XUI_HOME=/usr/local/x-ui
PANEL_PORT=""
WEB_PATH=""

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


# ---------- 主流程 ----------
[[ $EUID -eq 0 ]] || die "请用 root 运行"
[[ -x "$XUI_HOME/x-ui" ]] || die "未找到 $XUI_HOME/x-ui，请先安装面板"

# 读取当前面板端口与访问路径
read_panel_conf() {
    local out
    out=$("$XUI_HOME/x-ui" setting -show true 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
    PANEL_PORT=$(echo "$out" | grep -Eo 'port（端口号）: *[0-9]+' | grep -Eo '[0-9]+' | head -n1)
    WEB_PATH=$(echo "$out" | grep -Eo 'webBasePath（访问路径）: *[^ ]+' | awk '{print $2}' | head -n1)
    [[ -z "$PANEL_PORT" ]] && PANEL_PORT=13688
    [[ -z "$WEB_PATH" ]] && WEB_PATH="/"
    info "当前面板: 端口 $PANEL_PORT，路径 $WEB_PATH"
}

read_panel_conf

DOMAIN="${DOMAIN:-}"
if [[ -z "$DOMAIN" ]]; then
    printf '\033[33m请输入已解析到本机的域名（如 panel.example.com）: \033[0m'
    read -r DOMAIN
fi
validate_domain "$DOMAIN" || die "域名格式不正确: $DOMAIN"

if ! check_domain_dns "$DOMAIN"; then
    warn "DNS 检查未通过，仍尝试申请（可能失败）"
fi

if setup_certificate "$DOMAIN"; then
    echo ""
    ok "证书配置完成"
    echo "  登录地址: https://$DOMAIN:$PANEL_PORT$WEB_PATH"
    echo "  证书路径: /root/cert/$DOMAIN/{fullchain.pem,privkey.pem}"
    echo "  自动续期: acme.sh cron 已启用（续期后自动重启面板）"
else
    err "证书配置失败，面板仍可通过 http://<服务器IP>:$PANEL_PORT$WEB_PATH 访问"
    exit 1
fi
