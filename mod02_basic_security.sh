#!/bin/bash
# ── mod02_basic_security.sh ── 由 vpsge.sh 通过 source 加载，请勿单独执行 ──

# ────────────────────────────────────────────────────────────────
#  一、基础安全设置
# ────────────────────────────────────────────────────────────────
bootstrap_packages() {
    log_step "预装基础组件"
    if is_cmd_exist apt; then
        apt update -y && apt install -y curl sudo wget git unzip nano vim openssl python3
    elif is_cmd_exist dnf; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y curl sudo wget git unzip nano vim openssl python3
    elif is_cmd_exist yum; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y curl sudo wget git unzip nano vim openssl python3
    fi
    log_success "基础组件已就绪"
}

setup_ssh_key() {
    echo ""
    log_step "配置 SSH 密钥登录"
    echo "请输入你的 SSH 公钥（以 ssh-rsa / ssh-ed25519 / ecdsa-sha2 开头）:"
    read -r PUBLIC_KEY

    if [[ -z "$PUBLIC_KEY" ]]; then
        log_error "公钥不能为空"; return 1
    fi
    if [[ ! "$PUBLIC_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|sk-ssh-ed25519) ]]; then
        log_warn "公钥格式可能不正确，但继续执行..."
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    chown root:root /root/.ssh

    if ! grep -qF "$PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
        log_success "公钥已添加"
    else
        log_info "公钥已存在，跳过"
    fi

    chmod 600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh/authorized_keys

    is_cmd_exist restorecon && { restorecon -Rv /root/.ssh/ >/dev/null 2>&1 && log_info "SELinux 上下文已修复"; } || true
    log_success "SSH 密钥登录配置完成"
}

disable_password_login() {
    log_step "禁用 SSH 密码登录"
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"

    sshd_set() {
        local key="$1" val="$2"
        if grep -qE "^#?\s*${key}\s" "$SSHD_CONFIG"; then
            sed -i "s|^#\?\s*${key}\s.*|${key} ${val}|" "$SSHD_CONFIG"
        else
            echo "${key} ${val}" >> "$SSHD_CONFIG"
        fi
    }

    sshd_set "PasswordAuthentication" "no"
    sshd_set "ChallengeResponseAuthentication" "no"
    sshd_set "KbdInteractiveAuthentication" "no"
    sshd_set "PubkeyAuthentication" "yes"
    sshd_set "AuthorizedKeysFile" ".ssh/authorized_keys"
    sshd_set "PermitRootLogin" "prohibit-password"

    if sshd -t 2>&1; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        log_success "SSH 密码登录已禁用"
    else
        log_error "SSH 配置语法错误，请检查配置文件"
    fi
}

change_ssh_port() {
    log_step "修改 SSH 端口"
    local current_port
    current_port=$(grep -E "^Port\s" /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    current_port="${current_port:-22}"
    echo "当前 SSH 端口: $current_port"
    echo -n "请输入新端口（1024-65535，默认 43916）: "
    read -r SSH_PORT
    [[ -z "$SSH_PORT" ]] && SSH_PORT=43916

    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ $SSH_PORT -lt 1024 || $SSH_PORT -gt 65535 ]]; then
        log_error "端口范围应在 1024-65535"; return 1
    fi

    local SSHD_CONFIG="/etc/ssh/sshd_config"
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
    sed -i 's/^Port\s/#Port /' "$SSHD_CONFIG"
    grep -q "^Port $SSH_PORT" "$SSHD_CONFIG" || echo "Port $SSH_PORT" >> "$SSHD_CONFIG"

    if sshd -t 2>&1; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        log_success "SSH 端口已修改为: $SSH_PORT"
        log_warn "⚠  请确保防火墙已放行端口 $SSH_PORT"
    else
        log_error "SSH 配置语法错误，已还原备份"
    fi
}

enable_bbr() {
    log_step "启用 BBR 拥塞控制"
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current_cc" == "bbr" ]]; then
        log_success "BBR 已启用，跳过"; return
    fi

    local kv
    kv=$(uname -r | cut -d. -f1-2 | tr -d '.')
    if [[ "$kv" -lt 49 ]] 2>/dev/null; then
        log_warn "内核版本低于 4.9，BBR 不受支持"; return
    fi

    grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    log_success "BBR 启用成功"
}

configure_ip_protocol() {
    echo ""
    echo -e "${CYAN}── IP 协议优先级 ──${NC}"
    echo "1) IPv4 优先 [默认]"
    echo "2) IPv6 优先"
    echo "3) 保持不变"
    read -rp "请选择 (1-3): " c; c=${c:-1}
    case $c in
        1)
            if [[ -f /etc/gai.conf ]]; then
                cp /etc/gai.conf "/etc/gai.conf.backup.$(date +%Y%m%d_%H%M%S)"
                if grep -q "^#\s*precedence ::ffff:0:0/96" /etc/gai.conf; then
                    sed -i 's/^#\s*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
                elif ! grep -q "^precedence ::ffff:0:0/96" /etc/gai.conf; then
                    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
                fi
                log_success "IPv4 优先已设置"
            fi ;;
        2)
            [[ -f /etc/gai.conf ]] && sed -i 's/^precedence ::ffff:0:0\/96/#precedence ::ffff:0:0\/96/' /etc/gai.conf
            log_success "IPv6 优先已设置" ;;
        3) log_info "IP 协议优先级保持不变" ;;
    esac

    echo ""
    echo -e "${CYAN}── IP 协议禁用 ──${NC}"
    echo "1) 禁用 IPv6"
    echo "2) 禁用 IPv4（危险操作）"
    echo "3) 保持不变 [默认]"
    read -rp "请选择 (1-3): " d; d=${d:-3}
    local SYSCTL_D="/etc/sysctl.d"; mkdir -p "$SYSCTL_D"
    case $d in
        1)
            local f="$SYSCTL_D/99-disable-ipv6.conf"
            [[ ! -f "$f" ]] && cat > "$f" << 'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
            sysctl -p "$f" >/dev/null 2>&1
            log_success "IPv6 已禁用" ;;
        2)
            log_warn "警告：禁用 IPv4 可能导致服务器断联！"
            read -rp "确认禁用 IPv4？(y/N): " confirm
            if [[ "${confirm,,}" == "y" ]]; then
                cat > "$SYSCTL_D/99-disable-ipv4.conf" << 'EOF'
net.ipv4.conf.all.disable_ipv4=1
net.ipv4.conf.default.disable_ipv4=1
EOF
                log_warn "IPv4 禁用配置已写入，重启后生效"
            else
                log_info "已取消"
            fi ;;
        3) log_info "IP 协议状态保持不变" ;;
    esac
}

setup_fail2ban() {
    log_step "安装并配置 fail2ban"
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt install -y fail2ban || { log_warn "fail2ban 安装失败"; return; }
    else
        $PKG_MANAGER install -y fail2ban || { log_warn "fail2ban 安装失败"; return; }
    fi

    local SSH_PORT_CURRENT
    SSH_PORT_CURRENT=$(grep -E "^Port\s" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    SSH_PORT_CURRENT="${SSH_PORT_CURRENT:-22}"

    local BACKEND LOGPATH=""
    if systemctl is-active --quiet systemd-journald 2>/dev/null; then
        BACKEND="systemd"
    else
        BACKEND="auto"
        for lp in /var/log/auth.log /var/log/secure; do
            [[ -f "$lp" ]] && LOGPATH="logpath = $lp" && break
        done
        [[ -z "$LOGPATH" ]] && LOGPATH="logpath = /var/log/auth.log"
    fi

    systemctl stop fail2ban 2>/dev/null || true
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = -1
findtime = 300
maxretry = 1

[sshd]
enabled  = true
port     = $SSH_PORT_CURRENT
backend  = $BACKEND
${LOGPATH}
maxretry = 1
findtime = 300
bantime  = -1
EOF
    sleep 1
    systemctl enable fail2ban && systemctl start fail2ban
    systemctl is-active --quiet fail2ban && log_success "fail2ban 启动成功" || log_warn "fail2ban 启动失败，请检查日志"
}

menu_basic() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 一、基础安全设置 ══${NC}"
        echo ""
        echo "  1) SSH 密钥登录"
        echo "  2) 禁用密码登录"
        echo "  3) 修改 SSH 端口"
        echo "  4) 启用 BBR 拥塞控制"
        echo "  5) IP 协议优先级 & 禁用"
        echo "  6) 安装配置 fail2ban"
        echo "  7) 全部执行 (1→6)"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) setup_ssh_key; press_enter ;;
            2) disable_password_login; press_enter ;;
            3) change_ssh_port; press_enter ;;
            4) enable_bbr; press_enter ;;
            5) configure_ip_protocol; press_enter ;;
            6) setup_fail2ban; press_enter ;;
            7)
                bootstrap_packages
                setup_ssh_key
                disable_password_login
                change_ssh_port
                enable_bbr
                configure_ip_protocol
                setup_fail2ban
                press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}
