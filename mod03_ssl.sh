#!/bin/bash
# ── mod03_ssl.sh ── 由 vpsge.sh 通过 source 加载，请勿单独执行 ──


# ────────────────────────────────────────────────────────────────
#  二、SSL 证书
# ────────────────────────────────────────────────────────────────
STOPPED_SERVICES_SSL=()

manage_web_services_ssl() {
    local action="$1"
    if [[ "$action" == "stop" ]]; then
        for svc in nginx apache2 httpd lighttpd caddy; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                systemctl stop "$svc" 2>/dev/null || true
                STOPPED_SERVICES_SSL+=("$svc")
                log_info "已停止冲突服务: $svc"
            fi
        done
    elif [[ "$action" == "start" ]]; then
        for svc in "${STOPPED_SERVICES_SSL[@]:-}"; do
            if [[ -n "$svc" ]]; then
                systemctl start "$svc" 2>/dev/null || true
                log_info "已重新启动: $svc"
            fi
        done
        STOPPED_SERVICES_SSL=()
    fi
}

open_firewall_ports() {
    log_step "检查并自动放行本地防火墙端口 (80/443/8080/8443)..."
    
    # 增加 iptables 原生兜底机制，无视上层拦截
    if is_cmd_exist iptables; then
        iptables -I INPUT -p tcp -m multiport --dports 80,443,8080,8443,3001,8282 -j ACCEPT 2>/dev/null || true
        is_cmd_exist iptables-save && iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
    fi
    if is_cmd_exist ip6tables; then
        ip6tables -I INPUT -p tcp -m multiport --dports 80,443,8080,8443,3001,8282 -j ACCEPT 2>/dev/null || true
        is_cmd_exist ip6tables-save && ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true
    fi
    
    if is_cmd_exist ufw && ufw status | grep -q "Status: active"; then
        log_info "检测到 UFW 防火墙处于开启状态，正在放行端口..."
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw allow 8080/tcp >/dev/null 2>&1 || true
        ufw allow 8443/tcp >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1
        log_success "UFW 防火墙放行成功"
    fi

    if is_cmd_exist firewall-cmd && systemctl is-active --quiet firewalld; then
        log_info "检测到 Firewalld 防火墙处于开启状态，正在放行端口..."
        firewall-cmd --zone=public --add-port=80/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port=443/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port=8080/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port=8443/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1
        log_success "Firewalld 防火墙放行成功"
    fi
}

deploy_ssl() {
    log_step "SSL 证书申请与安装"

    log_info "安装必要依赖..."
    local packages=""
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        packages="curl wget socat cron openssl ca-certificates git dnsutils"
    else
        packages="curl wget socat cronie openssl ca-certificates git bind-utils"
    fi
    $PKG_MANAGER install -y $packages >/dev/null 2>&1 || true

    local cron_svc="cron"
    [[ "$PKG_MANAGER" != "apt" ]] && cron_svc="crond"
    systemctl enable "$cron_svc" >/dev/null 2>&1 || true
    systemctl start  "$cron_svc" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$cron_svc" 2>/dev/null; then
        log_success "cron 服务已运行"
    else
        log_warn "cron 服务未能启动，自动续期 crontab 将在证书安装后手动补充"
    fi

    echo ""
    echo -e "${CYAN}请配置要申请SSL证书的域名:${NC}"
    echo -e "${YELLOW}注意事项:${NC}"
    echo "  • 支持单个或多个域名"
    echo "  • 多个域名请用空格分隔"
    echo "  • 确保域名已正确解析到本服务器"
    echo "  • 示例: example.com www.example.com"
    echo ""

    local DOMAINS=()
    local MAIN_DOMAIN=""
    
    while true; do
        read -rp "请输入域名: " DOMAINS_INPUT
        if [[ -z "$DOMAINS_INPUT" ]]; then
            log_error "域名不能为空，请重新输入"
            continue
        fi

        read -ra DOMAINS <<< "$DOMAINS_INPUT"

        for domain in "${DOMAINS[@]}"; do
            if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
                log_warn "域名格式可能不正确: $domain"
            fi
            echo -n "检查域名解析: $domain ... "
            if nslookup "$domain" >/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${YELLOW}!${NC} (解析失败，但将继续)"
            fi
        done

        MAIN_DOMAIN=${DOMAINS[0]}

        echo ""
        echo -e "${GREEN}域名配置:${NC}"
        echo "  主域名: $MAIN_DOMAIN"
        echo "  所有域名: ${DOMAINS[*]}"
        echo "  域名数量: ${#DOMAINS[@]}"
        echo ""

        echo -e "确认域名配置正确? :"
        echo "  1) Y/y [默认]"
        echo "  2) N/n"
        read -rp "请选择 (1-2) [默认 1]: " confirm_choice
        confirm_choice=${confirm_choice:-1}
        if [[ "$confirm_choice" == "1" || "${confirm_choice,,}" == "y" ]]; then
            break
        fi
        echo ""
    done

    echo ""
    echo -e "${CYAN}请选择证书安装位置:${NC}"
    echo "  1) 标准路径 (/etc/ssl/private/) [默认]"
    echo "  2) Nginx专用 (/etc/nginx/ssl/)"
    echo "  3) Apache专用 (/etc/apache2/ssl/)"
    echo "  4) 用户目录 (/home/ssl/)"
    echo "  5) 自定义路径"
    echo ""
    
    local CERT_DIR=""
    while true; do
        read -rp "请选择 (1-5) [默认 1]: " path_choice
        path_choice=${path_choice:-1}
        case $path_choice in
            1) CERT_DIR="/etc/ssl/private"; break ;;
            2) CERT_DIR="/etc/nginx/ssl"; break ;;
            3) CERT_DIR="/etc/apache2/ssl"; break ;;
            4) CERT_DIR="/home/ssl"; break ;;
            5)
                while true; do
                    read -rp "请输入自定义路径: " custom_path
                    if [[ -n "$custom_path" ]]; then
                        CERT_DIR="$custom_path"
                        break
                    else
                        log_warn "路径不能为空，请重新输入"
                    fi
                done
                break
                ;;
            *) log_warn "无效选择，请输入 1-5"; continue ;;
        esac
    done
    mkdir -p "$CERT_DIR" && chmod 755 "$CERT_DIR"

    if [[ ! -f /root/.acme.sh/acme.sh ]]; then
        log_step "安装 acme.sh..."
        rm -rf /tmp/acme_sh_install
        if git clone https://github.com/acmesh-official/acme.sh.git /tmp/acme_sh_install >/dev/null 2>&1; then
            cd /tmp/acme_sh_install || return 1
            ./acme.sh --install --force >/dev/null 2>&1
            cd - >/dev/null || true
            rm -rf /tmp/acme_sh_install
        else
            local _acme_tar="/tmp/acme.tar.gz"
            if curl -fsSL https://github.com/acmesh-official/acme.sh/archive/master.tar.gz -o "$_acme_tar" 2>/dev/null || \
               wget -qO "$_acme_tar" https://github.com/acmesh-official/acme.sh/archive/master.tar.gz 2>/dev/null; then
                tar -xzf "$_acme_tar" -C /tmp/
                cd /tmp/acme.sh-master || return 1
                ./acme.sh --install --force >/dev/null 2>&1
                cd - >/dev/null || true
                rm -rf /tmp/acme.sh-master "$_acme_tar"
            else
                log_error "acme.sh 源码下载失败，请检查网络"
                return 1
            fi
        fi

        if [[ ! -f /root/.acme.sh/acme.sh ]]; then
            log_error "acme.sh 安装失败，未找到 /root/.acme.sh/acme.sh"
            return 1
        fi
    else
        log_info "acme.sh 已存在，检查更新..."
        /root/.acme.sh/acme.sh --upgrade >/dev/null 2>&1 || true
    fi

    ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh 2>/dev/null || true
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    log_success "acme.sh 已就绪"

    manage_web_services_ssl "stop"
    open_firewall_ports
    
    log_info "配置智能续期 Hook，确保未来 Web 服务的无缝证书自动续期..."
    cat > /root/.acme.sh/vpsge_hook.sh << 'EOF'
#!/bin/bash
ACTION=$1
SERVICES="nginx apache2 httpd lighttpd caddy"

if [ "$ACTION" == "pre" ]; then
    for svc in $SERVICES; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            touch "/tmp/.vpsge_${svc}_stopped"
        fi
    done
elif [ "$ACTION" == "post" ]; then
    for svc in $SERVICES; do
        if [ -f "/tmp/.vpsge_${svc}_stopped" ]; then
            systemctl start "$svc" 2>/dev/null || true
            rm -f "/tmp/.vpsge_${svc}_stopped"
        fi
    done
elif [ "$ACTION" == "reload" ]; then
    for svc in $SERVICES; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
        fi
    done
fi
EOF
    chmod +x /root/.acme.sh/vpsge_hook.sh

    log_step "申请证书（Standalone 模式）..."
    local domain_args=""
    for d in "${DOMAINS[@]}"; do domain_args="$domain_args -d $d"; done

    echo "正在申请证书，请耐心等待..."
    if /root/.acme.sh/acme.sh --issue $domain_args --standalone --force \
        --pre-hook "/root/.acme.sh/vpsge_hook.sh pre" \
        --post-hook "/root/.acme.sh/vpsge_hook.sh post"; then
        log_success "SSL 证书申请成功"
    else
        log_error "SSL 证书申请失败"
        echo -e "${YELLOW}可能的原因:${NC}"
        echo "  • 防火墙/云服务商安全组阻止了外网对 80 端口的访问 (Timeout)"
        echo "  • 域名未正确解析到本服务器的公网 IP"
        echo "  • Let's Encrypt 服务暂时不可用"
        echo -e "${PURPLE}【重要提示】如果您的 VPS (如 YXVM、Oracle 等) 存在外部控制台安全组，请务必登录控制台手动放行 80/443 端口！${NC}"
        manage_web_services_ssl "start"
        return 1
    fi

    log_step "安装SSL证书到指定目录..."
    local KEY_FILE="$CERT_DIR/private.key"
    local CERT_FILE="$CERT_DIR/fullchain.cer"
    local CA_FILE="$CERT_DIR/ca.cer"
    local RELOAD_CMD="/root/.acme.sh/vpsge_hook.sh reload"

    if /root/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
        --key-file  "$KEY_FILE"  \
        --fullchain-file "$CERT_FILE" \
        --ca-file   "$CA_FILE"   \
        --reloadcmd "$RELOAD_CMD"; then
        
        chmod 600 "$KEY_FILE"  2>/dev/null || true
        chmod 644 "$CERT_FILE" "$CA_FILE" 2>/dev/null || true
        chown root:root "$KEY_FILE" "$CERT_FILE" "$CA_FILE" 2>/dev/null || true
        log_success "证书已成功安装至: $CERT_DIR"
    else
        log_error "证书安装失败"
        manage_web_services_ssl "start"
        return 1
    fi

    log_success "智能续期 Hook 注册完成。未来无论您何时安装 Nginx 等服务，续期程序均会自动感知并智能避让防冲突。"

    log_step "设置证书自动续期..."
    local LOG_FILE="/var/log/acme-renew.log"
    local CRON_JOB="0 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> $LOG_FILE 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab - 2>/dev/null
        log_success "自动续期任务已设置（每天 02:00，日志: $LOG_FILE）"
    else
        log_info "自动续期任务已存在，跳过"
    fi

    manage_web_services_ssl "start"

    echo ""
    echo -e "${CYAN}=============================================="
    echo "           SSL证书部署完成！"
    echo "=============================================="
    echo -e "${NC}"
    echo -e "${GREEN}证书信息:${NC}"
    echo "  主域名: $MAIN_DOMAIN"
    echo "  所有域名: ${DOMAINS[*]}"
    echo "  证书目录: $CERT_DIR"
    echo "  私钥文件: $KEY_FILE"
    echo "  证书文件: $CERT_FILE"
    if [[ -f "$CERT_FILE" ]]; then
        local expire_date=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
        if [[ -n "$expire_date" ]]; then
            echo "  有效期至: $expire_date"
        fi
    fi
    echo ""
}

menu_ssl() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 二、SSL 证书 ══${NC}"
        echo ""
        echo "  1) 申请并安装 SSL 证书"
        echo "  2) 查看已安装证书"
        echo "  3) 手动续期证书"
        echo "  4) 查看续期日志"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) deploy_ssl; press_enter ;;
            2) /root/.acme.sh/acme.sh --list 2>/dev/null || log_warn "acme.sh 未安装"; press_enter ;;
            3)
                echo "输入要续期的域名:"
                read -r rd
                /root/.acme.sh/acme.sh --renew -d "$rd" --force 2>/dev/null || log_warn "续期失败"
                press_enter ;;
            4) tail -f /var/log/acme-renew.log 2>/dev/null || log_warn "日志文件不存在"; press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}
