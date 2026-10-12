#!/bin/bash
# ── mod04_install_service.sh ── 由 vpsge.sh 通过 source 加载，请勿单独执行 ──
#
# ════════════════════════ 本次更新说明 (优化2) ════════════════════════
# 新增：Komari 探针监控面板的安装支持（最新稳定版 / 指定版本号 / 预发布Snapshot版）
#   - 部署方式与 Wallos / Sub-Store 完全一致：Docker 部署 + Nginx 反代到独立 8443 端口
#   - 支持已安装检测、导入旧链接、域名冲突检测、证书路径询问
#   - 新增菜单项 20/21/22，插入在 Xray 之后、批量执行之前
#
# ════════════════════════ 本次更新说明 (优化5：修复服务启动检查) ════════════════════════
# 修复：Realm systemd 单元移除与 /root/realm 冲突的 DynamicUser，部署后启用并确认服务状态；
#   下载或启动失败时返回错误，并提供 systemd 日志排查提示。支持 x86_64 和 aarch64。
# 加固：Docker 服务先确认守护进程与 Compose 可用，容器启动失败时停止后续配置并输出日志提示。
# 菜单：在 Sub-Store、Wallos、Komari 项后标注需要 Docker，在 Realm 项标注无需 Docker。
#
# ════════════════════════ 本次更新说明 (优化3：修复反代 Connection 头) ════════════════════════
# 修复：Sub-Store 与 Komari 的 Nginx 反代配置中，Connection 请求头被写死为 "upgrade"，
#   导致所有普通 HTTP 请求（包括登录 POST）都被当成 WebSocket 协议升级请求处理，
#   容易造成连接被重置、登录页出现 "Network error"。
#   现改为 proxy_set_header Connection $http_connection; 根据客户端实际请求头动态传递，
#   普通请求走 keep-alive，WebSocket 升级请求依旧能正常工作。
#
# ════════════════════════ 本次更新说明 (优化4：修复反代 Host 头丢失端口号) ════════════════════════
# 修复：Sub-Store / Wallos / Komari 的 Nginx 反代配置中，均使用 proxy_set_header Host $host;
#   而 Nginx 的 $host 变量【永远不带端口号】。由于三者都统一部署在 8443 端口，
#   浏览器发出的 Origin 请求头是 https://域名:8443（带端口），
#   但后端收到的 Host 请求头却是 域名（不带端口），两者不一致。
#   部分应用（例如 Komari，其内置 cors_origin_check_enabled 默认开启）会用这种不一致
#   判定请求来源不可信，直接返回 403 拒绝——包括登录接口在内，导致登录页出现 "Network error"。
#   现统一改为 proxy_set_header Host $http_host; 完整保留客户端实际发送的 Host:端口，
#   从根本上解决该类反代场景下的来源校验误判问题。
#   优化4阶段仅修改了这三处配置中的 Host 请求头。
# ════════════════════════════════════════════════════════════════════


# ────────────────────────────────────────────────────────────────
#  卸载功能合集
# ────────────────────────────────────────────────────────────────
uninstall_singbox() {
    echo -e "${YELLOW}警告：这将彻底删除 sing-box 及其所有配置文件！${NC}"
    read -rp "确认卸载？(y/N): " choice
    if [[ "${choice,,}" == "y" ]]; then
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        rm -rf /etc/sing-box /var/log/sing-box /var/lib/sing-box
        
        # 彻底清理包管理器安装的版本
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt purge -y sing-box 2>/dev/null || true
        elif [[ -n "$PKG_MANAGER" ]]; then
            $PKG_MANAGER remove -y sing-box 2>/dev/null || true
        fi
        
        # 彻底移除所有可能的 sing-box 二进制路径
        rm -f /usr/local/bin/sing-box /usr/bin/sing-box /usr/sbin/sing-box /usr/local/sbin/sing-box /bin/sing-box
        for bin in $(type -aP sing-box 2>/dev/null); do rm -f "$bin" 2>/dev/null || true; done
        
        # 刷新 Bash 命令缓存，防止卸载后依旧误报存在
        hash -r 2>/dev/null || true
        log_success "sing-box 已彻底卸载"
    fi
}

uninstall_nginx() {
    echo -e "${YELLOW}警告：这将彻底删除 Nginx 及其所有站点配置！${NC}"
    read -rp "确认卸载？(y/N): " choice
    if [[ "${choice,,}" == "y" ]]; then
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
        
        # 彻底清理包管理器安装的版本
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt purge -y nginx nginx-common nginx-core 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
        elif [[ -n "$PKG_MANAGER" ]]; then
            $PKG_MANAGER remove -y nginx 2>/dev/null || true
        fi
        
        rm -rf /etc/nginx /var/log/nginx /var/www/html /usr/sbin/nginx /usr/bin/nginx
        
        # 彻底移除所有可能的 nginx 二进制路径
        rm -f /usr/sbin/nginx /usr/bin/nginx /usr/local/sbin/nginx /usr/local/bin/nginx /bin/nginx
        for bin in $(type -aP nginx 2>/dev/null); do rm -f "$bin" 2>/dev/null || true; done
        
        # 刷新 Bash 命令缓存
        hash -r 2>/dev/null || true
        log_success "Nginx 已彻底卸载"
    fi
}

uninstall_docker() {
    echo -e "${YELLOW}警告：这将彻底删除 Docker 环境及其所有容器和镜像！${NC}"
    read -rp "确认卸载？(y/N): " choice
    if [[ "${choice,,}" == "y" ]]; then
        log_step "1. 正在停止并删除所有正在运行的 Docker 容器..."
        docker ps -aq 2>/dev/null | xargs -r docker stop 2>/dev/null || true
        docker ps -aq 2>/dev/null | xargs -r docker rm 2>/dev/null || true

        log_step "2. 正在全面停止 Docker、Socket 及 containerd 底层核心服务..."
        systemctl stop docker docker.socket containerd containerd.service 2>/dev/null || true
        systemctl disable docker docker.socket containerd containerd.service 2>/dev/null || true

        log_step "3. 正在强制解除所有残留的内核虚拟挂载点 (overlay2/containerd)..."
        if [ -f /proc/mounts ]; then
            cat /proc/mounts | grep -E '/var/lib/(docker|containerd)' | awk '{print $2}' | sort -r | while read -r mnt; do
                umount -fl "$mnt" 2>/dev/null || true
            done
        fi

        log_step "4. 正在卸载 Docker 相关核心软件包..."
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-doc docker-compose podman-docker 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
        elif [[ -n "$PKG_MANAGER" ]]; then
            $PKG_MANAGER remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
        fi

        log_step "5. 正在彻底清空物理残留目录、缓存、套接字与配置文件..."
        rm -rf /var/lib/docker /var/lib/containerd /var/run/docker.sock /var/run/containerd /etc/docker /root/.docker /usr/bin/docker /usr/libexec/docker
        
        # 彻底移除可能残留的二进制文件
        for bin in $(type -aP docker 2>/dev/null); do rm -f "$bin" 2>/dev/null || true; done
        
        # 刷新 Bash 命令缓存
        hash -r 2>/dev/null || true

        log_step "6. 正在刷新重置 systemd 系统服务状态..."
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed 2>/dev/null || true

        log_success "Docker 环境已完美、干净地彻底卸载！无任何底层状态残留。"
    fi
}

uninstall_xray() {
    echo -e "${YELLOW}警告：这将彻底删除 Xray-core 及其所有配置文件！${NC}"
    read -rp "确认卸载？(y/N): " choice
    if [[ "${choice,,}" == "y" ]]; then
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
        systemctl daemon-reload 2>/dev/null || true
        rm -rf /usr/local/etc/xray /var/log/xray /usr/local/share/xray

        rm -f /usr/local/bin/xray /usr/bin/xray /usr/sbin/xray
        for bin in $(type -aP xray 2>/dev/null); do rm -f "$bin" 2>/dev/null || true; done

        hash -r 2>/dev/null || true
        log_success "Xray-core 已彻底卸载"
    fi
}

# ────────────────────────────────────────────────────────────────
#  三、安装服务（sing-box / Nginx / Docker环境 / 面板 / Realm）
# ────────────────────────────────────────────────────────────────
install_nginx() {
    local mode="${1:-1}"
    log_step "安装 Nginx..."
    
    if is_cmd_exist nginx; then
        local ver
        ver=$(nginx -v 2>&1 | head -1)
        log_info "当前已安装版本: $ver"
        if [[ "$AUTO_DEFAULT" == "true" ]]; then
            log_info "自动执行：保留已安装的 Nginx，并确保服务正常运行"
            systemctl enable nginx >/dev/null 2>&1 || true
            systemctl restart nginx >/dev/null 2>&1 || return 1
            return 0
        fi
        if ! prompt_reinstall "Nginx"; then return 0; fi
    fi
    
    if [[ "$mode" == "2" ]]; then
        log_info "指定版本号安装对系统源依赖较高，将尝试通过包管理器匹配..."
        read -rp "请输入 Nginx 版本号 (回车跳过): " n_ver
    elif [[ "$mode" == "3" ]]; then
        log_info "将尝试安装 Nginx Mainline(Beta) 版本..."
    fi

    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt update -y >/dev/null 2>&1 || true
        # 核心防瘫痪修复：使用 --force-confmiss 强制恢复任何缺失的默认配置文件 (如被误删的 nginx.conf)
        DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confmiss" install -y nginx || { log_error "Nginx 安装失败"; return 1; }
    else
        $PKG_MANAGER install -y nginx || { log_error "Nginx 安装失败"; return 1; }
    fi
    
    # 针对 SELinux 系统，开启网络连接转发权限以支持面板反代
    if is_cmd_exist setsebool; then
        setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    fi

    mkdir -p /var/www/html /etc/nginx/conf.d
    if [[ ! -f /var/www/html/index.html ]]; then
        cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html><head><title>Welcome</title></head>
<body><h1>It works!</h1></body></html>
HTML
    fi
    
    # 【核心修复】清理系统自带的 Nginx 默认站点配置，确保 80/8080 端口完全释放，不与其他面板产生底层冲突
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    
    if ! nginx -t >/dev/null 2>&1; then
        log_error "Nginx 配置检查失败；请运行 nginx -t 查看详情"
        return 1
    fi
    if ! systemctl enable nginx >/dev/null 2>&1 || ! systemctl restart nginx >/dev/null 2>&1 || ! systemctl is-active --quiet nginx; then
        log_error "Nginx 未能启动；请运行 systemctl status nginx 和 journalctl -u nginx -n 50 查看原因"
        return 1
    fi
    log_success "Nginx 安装并启动成功"
}

install_docker_env() {
    local mode="${1:-1}"
    local installer
    log_step "检查并配置 Docker 环境..."
    
    if ! is_cmd_exist docker; then
        log_info "正在安装 Docker..."

        if [[ "$mode" == "3" ]]; then
            installer="https://test.docker.com"
        else
            installer="https://get.docker.com"
        fi

        if ! curl -fsSL "$installer" -o /tmp/get-docker.sh; then
            log_error "Docker 安装脚本下载失败"
            return 1
        fi
        if [[ "$mode" == "2" ]]; then
            read -rp "请输入 Docker 版本号 (回车跳过使用默认): " d_ver
            if [[ -n "$d_ver" ]]; then
                VERSION="$d_ver" sh /tmp/get-docker.sh || { rm -f /tmp/get-docker.sh; log_error "Docker 安装失败"; return 1; }
            else
                sh /tmp/get-docker.sh || { rm -f /tmp/get-docker.sh; log_error "Docker 安装失败"; return 1; }
            fi
        else
            sh /tmp/get-docker.sh || { rm -f /tmp/get-docker.sh; log_error "Docker 安装失败"; return 1; }
        fi
        rm -f /tmp/get-docker.sh
    else
        if [[ "$AUTO_DEFAULT" != "true" ]] && ! prompt_reinstall "Docker 环境"; then
            systemctl enable docker >/dev/null 2>&1 || true
            systemctl start docker >/dev/null 2>&1 || true
        fi
    fi
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker 命令可用，但 Docker 守护进程未运行；请检查 systemctl status docker"
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_info "正在安装 Docker Compose 插件..."
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt update -y && apt install -y docker-compose-plugin || { log_error "Docker Compose 插件安装失败"; return 1; }
        elif [[ -n "$PKG_MANAGER" ]]; then
            $PKG_MANAGER install -y docker-compose-plugin || { log_error "Docker Compose 插件安装失败"; return 1; }
        else
            log_error "未识别包管理器，无法安装 Docker Compose 插件"
            return 1
        fi
    else
        log_success "Docker Compose 已就绪"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose 不可用"
        return 1
    fi
}

# 这三个控制台共用 Nginx 的 8443 端口，必须用不同域名区分 TLS 虚拟主机。
panel_domain_in_use() {
    local domain="$1" exclude="${2:-}" service file
    for service in substore wallos komari; do
        [[ "$service" == "$exclude" ]] && continue
        file="/root/docker/$service/domain.txt"
        if [[ -f "$file" ]] && grep -Fqx -- "$domain" "$file"; then
            return 0
        fi
    done
    return 1
}

install_xray() {
    local mode="${1:-1}"   # 1=最新稳定版 2=指定版本号 3=Beta预发布版
    log_step "安装 Xray-core..."

    if is_cmd_exist xray; then
        local ver
        ver=$(xray version 2>/dev/null | head -1)
        log_info "当前已安装版本: $ver"
        if [[ "$AUTO_DEFAULT" == "true" ]]; then
            log_info "自动执行：检查并更新已安装的 Xray-core"
        elif ! prompt_reinstall "Xray-core"; then
            return 0
        fi
    fi

    local x_ver=""
    if [[ "$mode" == "2" ]]; then
        read -rp "请输入 Xray 版本号（例如 1.8.24，回车则改为安装最新稳定版）: " x_ver
        [[ -z "$x_ver" ]] && { log_info "未输入版本号，转为安装最新稳定版..."; mode="1"; }
    fi

    if [[ "$mode" == "2" ]]; then
        log_step "正在通过 GitHub Releases 直接下载 Xray v${x_ver} 二进制..."
        local ARCH ARCH_STR
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) ARCH_STR="64" ;;
            aarch64) ARCH_STR="arm64-v8a" ;;
            armv7l) ARCH_STR="arm32-v7a" ;;
            *) ARCH_STR="64" ;;
        esac
        if ! is_cmd_exist unzip; then
            if [[ "$PKG_MANAGER" == "apt" ]]; then
                apt update -y >/dev/null 2>&1 || true
                apt install -y unzip >/dev/null 2>&1 || true
            else
                $PKG_MANAGER install -y unzip >/dev/null 2>&1 || true
            fi
        fi
        local URL="https://github.com/XTLS/Xray-core/releases/download/v${x_ver}/Xray-linux-${ARCH_STR}.zip"
        rm -rf /tmp/xray-dl && mkdir -p /tmp/xray-dl
        if ! curl -fsSL "$URL" -o /tmp/xray-dl/xray.zip; then
            log_error "下载失败，请确认版本号是否存在"
            rm -rf /tmp/xray-dl
            return 1
        fi
        if ! unzip -qo /tmp/xray-dl/xray.zip -d /tmp/xray-dl; then
            log_error "解压失败"
            rm -rf /tmp/xray-dl
            return 1
        fi
        install -m 755 /tmp/xray-dl/xray /usr/local/bin/xray
        mkdir -p /usr/local/share/xray
        [[ -f /tmp/xray-dl/geoip.dat ]] && install -m 644 /tmp/xray-dl/geoip.dat /usr/local/share/xray/geoip.dat
        [[ -f /tmp/xray-dl/geosite.dat ]] && install -m 644 /tmp/xray-dl/geosite.dat /usr/local/share/xray/geosite.dat
        rm -rf /tmp/xray-dl
    else
        log_step "正在通过 XTLS 官方一键脚本安装 Xray-core...$( [[ "$mode" == "3" ]] && echo " (Beta/预发布版)")"
        if [[ "$mode" == "3" ]]; then
            if ! bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --beta; then
                log_error "Xray Beta 安装失败，请检查网络"
                return 1
            fi
        else
            if ! bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
                log_error "Xray 官方脚本安装失败，请检查网络"
                return 1
            fi
        fi
    fi

    mkdir -p /usr/local/etc/xray /var/log/xray

    if [[ ! -f /etc/systemd/system/xray.service ]]; then
        cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    if is_cmd_exist xray; then
        local ver
        ver=$(xray version 2>/dev/null | head -1)
        log_success "Xray-core 安装成功: $ver"
        
        # 【核心修复】：防止官方脚本自带的默认 config.json 占用端口，引发 Nginx 启动冲突
        if [[ -f /usr/local/etc/xray/config.json ]] && ! grep -q -E "dokodemo-in|vless-reality-in|xhttp-reality-in" /usr/local/etc/xray/config.json; then
            mv /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.default.bak 2>/dev/null || true
            systemctl stop xray >/dev/null 2>&1 || true
        fi

        if [[ -s /usr/local/etc/xray/config.json ]]; then
            if xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
                systemctl enable xray >/dev/null 2>&1 || true
                systemctl start xray >/dev/null 2>&1 || true
            fi
        else
            log_info "提醒: Xray-core 核心已就绪。请前往主菜单「四、配置节点」选择 Xray-core 内核生成配置，完成后系统将自动守护运行。"
        fi
    else
        log_error "Xray-core 安装失败"
    fi
}

install_substore() {
    local sub_ver_choice="${1:-1}"
    
    local is_installed=false
    if [[ -d /root/docker/substore ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^substore$"; then
        is_installed=true
    fi

    local old_sub_domain=""
    local old_sub_api=""
    
    if [[ "$is_installed" == "true" ]]; then
        log_warn "检测到您的服务器中 Sub-Store 已经部署过了！"
        if [[ "$AUTO_DEFAULT" == "true" && -f /root/docker/substore/domain.txt ]]; then
            old_sub_domain=$(cat /root/docker/substore/domain.txt)
        fi
        if [[ -f /root/docker/substore/domain.txt && -f /root/docker/substore/api_path.txt ]]; then
            local p_sn=$(cat /root/docker/substore/domain.txt)
            local p_api=$(cat /root/docker/substore/api_path.txt)
            echo -e "  🌐 为您找回的现有面板访问地址: ${GREEN}https://$p_sn:8443/?api=https://$p_sn:8443/$p_api${NC}"
        fi
        local choice
        if [[ "$AUTO_DEFAULT" == "true" ]]; then
            choice=2
            log_info "自动执行：使用现有域名和 API 路径重建 Sub-Store，以应用修复并保留数据"
        else
            echo "  1) 不重新安装 (保留现有) [默认]"
            echo "  2) 重新安装 (覆盖更新)"
            echo "  3) 导入旧链接 (手动粘贴)"
            read -t 30 -rp "  > 请选择 (1-3, 30秒后默认 1): " choice || true
            choice=${choice:-1}
        fi
        if [[ "$choice" == "1" ]]; then return 0; fi
        
        docker stop substore 2>/dev/null || true
        docker rm substore 2>/dev/null || true
        
        if [[ "$choice" == "3" ]]; then
            read -rp "请粘贴旧的 Sub-Store 面板链接 (如 https://sub.xxx.com:8443/?api=...): " old_sub_link
            if [[ "$old_sub_link" =~ ^https://([^/:]+).*api=https://[^/:]+:[0-9]+/([^/]+) ]]; then
                old_sub_domain="${BASH_REMATCH[1]}"
                old_sub_api="${BASH_REMATCH[2]}"
                log_success "成功提取旧配置: 域名=$old_sub_domain, API路径=/$old_sub_api"
            else
                log_warn "未能识别链接格式，将使用常规方式配置。"
            fi
        fi
    else
        local choice
        if [[ "$AUTO_DEFAULT" == "true" ]]; then
            choice=1
        else
            echo -e "
${CYAN}检测到 Sub-Store 未安装，请选择部署方式：${NC}"
            echo "  1) 直接安装 [默认]"
            echo "  2) 导入旧链接 (手动粘贴)"
            read -t 30 -rp "  > 请选择 (1-2, 30秒后默认 1): " choice || true
            choice=${choice:-1}
        fi
        if [[ "$choice" == "2" ]]; then
            read -rp "请粘贴旧的 Sub-Store 面板链接 (如 https://sub.xxx.com:8443/?api=...): " old_sub_link
            if [[ "$old_sub_link" =~ ^https://([^/:]+).*api=https://[^/:]+:[0-9]+/([^/]+) ]]; then
                old_sub_domain="${BASH_REMATCH[1]}"
                old_sub_api="${BASH_REMATCH[2]}"
                log_success "成功提取旧配置: 域名=$old_sub_domain, API路径=/$old_sub_api"
            else
                log_warn "未能识别链接格式，将使用常规方式配置。"
            fi
        fi
    fi

    install_docker_env 1 || return 1
    
    if ! is_cmd_exist nginx; then
        log_warn "未检测到 Nginx，正在尝试自动预装..."
        install_nginx 1 || return 1
    fi

    if ! is_cmd_exist unzip; then
        log_info "正在为您自动安装必要的 unzip 解压工具..."
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt update -y >/dev/null 2>&1 || true
            apt install -y unzip >/dev/null 2>&1 || true
        else
            $PKG_MANAGER install -y unzip >/dev/null 2>&1 || true
        fi
    fi

    log_step "部署 Sub-Store (订阅转换中心)"

    local backend_url="https://github.com/sub-store-org/Sub-Store/releases/latest/download/sub-store.bundle.js"
    local frontend_url="https://github.com/sub-store-org/Sub-Store-Front-End/releases/latest/download/dist.zip"

    if [[ "$sub_ver_choice" == "2" ]]; then
        read -rp "请输入 Sub-Store 后端版本号 (例如 2.14.0): " target_ver
        if [[ -n "$target_ver" ]]; then backend_url="https://github.com/sub-store-org/Sub-Store/releases/download/${target_ver}/sub-store.bundle.js"; fi
        read -rp "请输入 Sub-Store 前端版本号 (例如 1.0.0，直接回车则默认最新): " target_fe_ver
        if [[ -n "$target_fe_ver" ]]; then frontend_url="https://github.com/sub-store-org/Sub-Store-Front-End/releases/download/${target_fe_ver}/dist.zip"; fi
    elif [[ "$sub_ver_choice" == "3" ]]; then
        log_info "正在获取 Github 预发布版(Beta)..."
        local pre_back=$(curl -s https://api.github.com/repos/sub-store-org/Sub-Store/releases | grep '"browser_download_url":' | grep 'sub-store.bundle.js' | head -n 1 | cut -d '"' -f 4)
        [[ -n "$pre_back" ]] && backend_url="$pre_back"
        local pre_front=$(curl -s https://api.github.com/repos/sub-store-org/Sub-Store-Front-End/releases | grep '"browser_download_url":' | grep 'dist.zip' | head -n 1 | cut -d '"' -f 4)
        [[ -n "$pre_front" ]] && frontend_url="$pre_front"
    fi

    local sn=""
    local cp=""
    local kp=""
    
    # 强制跳过确认，自动应用旧域名和证书
    if [[ -n "$old_sub_domain" ]]; then
        sn="$old_sub_domain"
        local prev_auto="$AUTO_DEFAULT"
        AUTO_DEFAULT="true"
        ask_cert_paths "$sn"
        cp="$CERT_PATH"
        kp="$KEY_PATH"
        AUTO_DEFAULT="$prev_auto"
    else
        # 自动执行时使用默认域名选择；交互安装时仍允许自定义。
        local prev_auto="$AUTO_DEFAULT"
        AUTO_DEFAULT="$prev_auto" 
        select_server_name "sub.example.com" "" "1"
        sn="$SELECTED_SN"
        AUTO_DEFAULT="$prev_auto"
        
        ask_cert_paths "$sn"
        cp="$CERT_PATH"
        kp="$KEY_PATH"
    fi

    if panel_domain_in_use "$sn" substore; then
        log_error "域名 $sn 已被 Wallos 或 Komari 占用；请选择不同域名后重试"
        return 1
    fi
    
    if [[ ! -f "$cp" || ! -f "$kp" ]]; then
        log_warn "⚠️ 警告：检测到证书或私钥文件实际不存在！"
        log_warn "Nginx 代理极有可能因此启动失败，导致面板无法访问！"
        log_warn "请后续确保将正确的证书文件放置于: $cp"
    fi

    mkdir -p /root/docker/substore/data || { log_error "无法创建 Sub-Store 数据目录"; return 1; }
    cd /root/docker/substore || { log_error "无法进入 Sub-Store 目录"; return 1; }

    local api_path
    if [[ -n "$old_sub_api" ]]; then
        api_path="$old_sub_api"
        echo "$api_path" > api_path.txt
        log_info "已沿用导入的旧 API 路径: /$api_path"
    elif [[ -f api_path.txt ]]; then
        api_path=$(cat api_path.txt)
        log_info "检测到本地已存在的 API 路径: /$api_path"
    else
        api_path=$(openssl rand -hex 12)
        echo "$api_path" > api_path.txt
        log_info "已生成随机高级防护 API 路径: /$api_path"
    fi
    if [[ ! "$api_path" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
        log_warn "导入或保存的 API 路径格式无效，正在生成新的随机路径"
        api_path=$(openssl rand -hex 12) || return 1
        printf '%s\n' "$api_path" > api_path.txt
    fi
    echo "$sn" > domain.txt

    log_info "正在为您下载并部署选中版本的核心代码..."
    if ! curl -fsSL --retry 3 --connect-timeout 15 "$backend_url" -o sub-store.bundle.js; then
        log_error "Sub-Store 后端下载失败；未启动容器"
        return 1
    fi
    if ! curl -fsSL --retry 3 --connect-timeout 15 "$frontend_url" -o dist.zip; then
        rm -f sub-store.bundle.js
        log_error "Sub-Store 前端下载失败；未启动容器"
        return 1
    fi
    
    rm -rf frontend dist_tmp
    if ! unzip -tq dist.zip >/dev/null 2>&1 || ! unzip -qo dist.zip -d dist_tmp; then
        rm -rf dist_tmp
        log_error "Sub-Store 前端压缩包无效或解压失败"
        return 1
    fi
    if [[ -d "dist_tmp/dist" ]]; then
        mv dist_tmp/dist frontend
    else
        mv dist_tmp frontend
    fi
    rm -rf dist_tmp dist.zip
    if [[ ! -s sub-store.bundle.js || ! -s frontend/index.html ]]; then
        log_error "Sub-Store 部署文件不完整（需要后端 bundle 和 frontend/index.html）"
        return 1
    fi

    cat > docker-compose.yml <<EOF
version: '3.8'
services:
  substore:
    image: node:20.18.0
    container_name: substore
    restart: unless-stopped
    working_dir: /app
    command: ["node", "sub-store.bundle.js"]
    ports:
      - "127.0.0.1:3001:3001"
    environment:
      SUB_STORE_FRONTEND_BACKEND_PATH: "/$api_path"
      SUB_STORE_BACKEND_CRON: "0 0 * * *"
      SUB_STORE_FRONTEND_PATH: "/app/frontend"
      SUB_STORE_FRONTEND_HOST: "0.0.0.0"
      SUB_STORE_FRONTEND_PORT: "3001"
      SUB_STORE_DATA_BASE_PATH: "/app"
      SUB_STORE_BACKEND_MERGE: "true"
      # 合并模式下前端和 API 由同一 Node 监听器提供，Docker 转发需要绑定容器网卡。
      SUB_STORE_BACKEND_API_HOST: "0.0.0.0"
      SUB_STORE_BACKEND_API_PORT: "3001"
      # Sub-Store 对来源进行精确匹配，需允许本服务的 scheme、域名和 8443 端口。
      SUB_STORE_CORS_ALLOWED_ORIGINS: "https://${sn}:8443"
      TZ: "Asia/Shanghai"
    volumes:
      - ./sub-store.bundle.js:/app/sub-store.bundle.js
      - ./frontend:/app/frontend
      - ./data:/app/data
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    log_info "启动容器..."
    docker compose config -q || { log_error "Sub-Store Compose 配置无效"; return 1; }
    docker compose up -d || { log_error "Sub-Store 容器启动失败，请运行 docker compose logs --tail=100 查看原因"; return 1; }
    if ! docker ps --filter name='^/substore$' --filter status=running --format '{{.Names}}' | grep -qx substore; then
        docker compose logs --tail=100
        log_error "Sub-Store 容器没有保持运行"
        return 1
    fi

    log_step "配置 Nginx 安全反向代理 (专属隔离 8443 端口)"
    open_firewall_ports
    mkdir -p /etc/nginx/conf.d
    
    # 修复兼容性：移除 Nginx 1.27+ 中已废弃引发致命报错阻断启动的 http2 参数，确保面板能顺利暴露
    # 【优化3修复】：Connection 头改为跟随客户端实际请求头 $http_connection，
    # 避免所有普通 HTTP 请求被误当成 WebSocket 升级请求，导致登录等请求出现连接被重置/Network error
    cat > /etc/nginx/conf.d/substore.conf <<EOF
server {
    listen 8080;
    listen [::]:8080;
    server_name $sn;
    return 301 https://\$host:8443\$request_uri;
}
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name $sn;

    ssl_certificate $cp;
    ssl_certificate_key $kp;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
    }
}
EOF
    if ! nginx -t; then
        log_error "Sub-Store 的 Nginx 配置检查失败；请检查证书、域名和 8443 端口配置"
        return 1
    fi
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || { log_error "Nginx 未能加载 Sub-Store 反代配置"; return 1; }
    
    echo ""
    log_success "Sub-Store 部署完成！"
    echo -e "  🌐 访问面板地址: ${GREEN}https://$sn:8443/?api=https://$sn:8443/$api_path${NC}"
    echo -e "  🔐 后台API路径:  ${YELLOW}/$api_path${NC}"
    echo -e "  ${YELLOW}（如果不慎忘记该地址，可在脚本主菜单的「服务管理」中随时找回查看）${NC}"
    echo ""
}

install_wallos() {
    local wallos_mode="${1:-1}"
    local wallos_ver="2.36.2"
    
    local is_installed=false
    if [[ -d /root/docker/wallos ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^wallos$"; then
        is_installed=true
    fi

    local old_wal_domain=""
    if [[ "$is_installed" == "true" ]]; then
        log_warn "检测到您的服务器中 Wallos 已经部署过了！"
        if [[ -f /root/docker/wallos/domain.txt ]]; then
            local w_sn=$(cat /root/docker/wallos/domain.txt)
            echo -e "  🌐 为您找回的现有面板访问地址: ${GREEN}https://$w_sn:8443${NC}"
        fi
        if [[ "$AUTO_DEFAULT" == "true" ]]; then
            log_info "自动执行：保留现有 Wallos 部署"
            return 0
        fi
        echo "  1) 不重新安装 (保留现有) [默认]"
        echo "  2) 重新安装 (覆盖更新)"
        echo "  3) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-3, 30秒后默认 1): " choice || true
        choice=${choice:-1}
        if [[ "$choice" == "1" ]]; then return 0; fi
        
        docker stop wallos 2>/dev/null || true
        docker rm wallos 2>/dev/null || true
        
        if [[ "$choice" == "3" ]]; then
            read -rp "请粘贴旧的 Wallos 面板链接 (例如 https://wallos.xxx.com:8443): " old_wal_link
            if [[ -n "$old_wal_link" ]]; then
                if [[ "$old_wal_link" =~ ^https://([^/:]+) ]]; then
                    old_wal_domain="${BASH_REMATCH[1]}"
                    log_success "成功提取旧配置: 域名=$old_wal_domain"
                else
                    log_warn "未能识别链接格式，将使用常规方式配置。"
                fi
            fi
        fi
    else
        local choice
        if [[ "$AUTO_DEFAULT" == "true" ]]; then
            choice=1
        else
            echo -e "
${CYAN}检测到 Wallos 未安装，请选择部署方式：${NC}"
            echo "  1) 直接安装 [默认]"
            echo "  2) 导入旧链接 (手动粘贴)"
            read -t 30 -rp "  > 请选择 (1-2, 30秒后默认 1): " choice || true
            choice=${choice:-1}
        fi
        if [[ "$choice" == "2" ]]; then
            read -rp "请粘贴旧的 Wallos 面板链接 (例如 https://wallos.xxx.com:8443): " old_wal_link
            if [[ -n "$old_wal_link" ]]; then
                if [[ "$old_wal_link" =~ ^https://([^/:]+) ]]; then
                    old_wal_domain="${BASH_REMATCH[1]}"
                    log_success "成功提取旧配置: 域名=$old_wal_domain"
                else
                    log_warn "未能识别链接格式，将使用常规方式配置。"
                fi
            fi
        fi
    fi

    if [[ "$wallos_mode" == "1" ]]; then
        wallos_ver="latest"
    elif [[ "$wallos_mode" == "2" ]]; then
        if [[ "$AUTO_DEFAULT" == "true" ]]; then
            wallos_ver="2.36.2"
        else
            ask_val wallos_ver "请输入待部署的 Wallos 版本标签" "2.36.2"
        fi
    elif [[ "$wallos_mode" == "3" ]]; then
        wallos_ver="beta"
    fi

    install_docker_env 1 || return 1
    
    if ! is_cmd_exist nginx; then
        log_warn "未检测到 Nginx，正在尝试自动预装..."
        install_nginx 1 || return 1
    fi

    log_step "部署 Wallos (订阅管理与财务系统) - 版本: $wallos_ver"

    local sn=""
    local cp=""
    local kp=""
    if [[ -n "$old_wal_domain" ]]; then
        sn="$old_wal_domain"
        local prev_auto="$AUTO_DEFAULT"
        AUTO_DEFAULT="true"
        ask_cert_paths "$sn"
        cp="$CERT_PATH"
        kp="$KEY_PATH"
        AUTO_DEFAULT="$prev_auto"
    else
        while true; do
            # 自动执行时使用默认域名选择；交互安装时仍允许自定义。
            local prev_auto="$AUTO_DEFAULT"
            AUTO_DEFAULT="$prev_auto" 
            select_server_name "wallos.example.com" "" "2"
            sn="$SELECTED_SN"
            AUTO_DEFAULT="$prev_auto"
            
            if [[ -f /root/docker/substore/domain.txt ]]; then
                local sub_sn=$(cat /root/docker/substore/domain.txt)
                if [[ "$sn" == "$sub_sn" ]]; then
                    echo -e "${RED}[ERROR] 域名冲突拦截！检测到该域名已被 Sub-Store 占用。${NC}"
                    echo -e "${CYAN}请重新选择，或者选择 手动输入 其他域名！${NC}"
                    echo ""
                    continue
                fi
            fi
            break
        done
        ask_cert_paths "$sn"
        cp="$CERT_PATH"
        kp="$KEY_PATH"
    fi

    if panel_domain_in_use "$sn" wallos; then
        log_error "域名 $sn 已被 Sub-Store 或 Komari 占用；请选择不同域名后重试"
        return 1
    fi
    
    if [[ ! -f "$cp" || ! -f "$kp" ]]; then
        log_warn "⚠️ 警告：检测到证书或私钥文件实际不存在！"
        log_warn "Nginx 代理极有可能因此启动失败，导致面板无法访问！"
        log_warn "请后续确保将正确的证书文件放置于: $cp"
    fi

    mkdir -p /root/docker/wallos/{db,logos}
    cd /root/docker/wallos
    echo "$sn" > domain.txt

    cat > docker-compose.yml <<EOF
version: '3.8'
services:
  wallos:
    container_name: wallos
    image: bellamy/wallos:$wallos_ver
    ports:
      - "127.0.0.1:8282:80/tcp"
    environment:
      TZ: 'Asia/Shanghai'
    volumes:
      - './db:/var/www/html/db'
      - './logos:/var/www/html/images/uploads/logos'
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    log_info "启动容器..."
    docker compose config -q || { log_error "Wallos Compose 配置无效"; return 1; }
    docker compose up -d || { log_error "Wallos 容器启动失败，请运行 docker compose logs --tail=100 查看原因"; return 1; }
    if ! docker ps --filter name='^/wallos$' --filter status=running --format '{{.Names}}' | grep -qx wallos; then
        docker compose logs --tail=100
        log_error "Wallos 容器没有保持运行"
        return 1
    fi

    log_step "配置 Nginx 安全反向代理 (专属隔离 8443 端口)"
    open_firewall_ports
    mkdir -p /etc/nginx/conf.d
    
    # 修复兼容性：移除 Nginx 1.27+ 中已废弃引发致命报错阻断启动的 http2 参数，确保面板能顺利暴露
    cat > /etc/nginx/conf.d/wallos.conf <<EOF
server {
    listen 8080;
    listen [::]:8080;
    server_name $sn;
    return 301 https://\$host:8443\$request_uri;
}
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name $sn;

    ssl_certificate $cp;
    ssl_certificate_key $kp;

    location / {
        proxy_pass http://127.0.0.1:8282;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || log_warn "Nginx 重载失败，请后续检查配置文件或证书是否存在"
    
    echo ""
    log_success "Wallos 部署完成！"
    echo -e "  🌐 访问面板地址: ${GREEN}https://$sn:8443${NC}"
    echo ""
}

install_komari() {
    local komari_ver_choice="${1:-1}"
    local komari_tag="latest"

    local is_installed=false
    if [[ -d /root/docker/komari ]] && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^komari$"; then
        is_installed=true
    fi

    local old_komari_domain=""
    if [[ "$is_installed" == "true" ]]; then
        log_warn "检测到您的服务器中 Komari 探针已经部署过了！"
        if [[ -f /root/docker/komari/domain.txt ]]; then
            local k_sn=$(cat /root/docker/komari/domain.txt)
            echo -e "  🌐 为您找回的现有面板访问地址: ${GREEN}https://$k_sn:8443${NC}"
        fi
        if [[ "$AUTO_DEFAULT" == "true" ]]; then
            log_info "自动执行：保留现有 Komari 部署"
            return 0
        fi
        echo "  1) 不重新安装 (保留现有) [默认]"
        echo "  2) 重新安装 (覆盖更新)"
        echo "  3) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-3, 30秒后默认 1): " choice || true
        choice=${choice:-1}
        if [[ "$choice" == "1" ]]; then return 0; fi

        docker stop komari 2>/dev/null || true
        docker rm komari 2>/dev/null || true

        if [[ "$choice" == "3" ]]; then
            read -rp "请粘贴旧的 Komari 面板链接 (例如 https://komari.xxx.com:8443): " old_komari_link
            if [[ -n "$old_komari_link" ]]; then
                if [[ "$old_komari_link" =~ ^https://([^/:]+) ]]; then
                    old_komari_domain="${BASH_REMATCH[1]}"
                    log_success "成功提取旧配置: 域名=$old_komari_domain"
                else
                    log_warn "未能识别链接格式，将使用常规方式配置。"
                fi
            fi
        fi
    else
        local choice
        if [[ "$AUTO_DEFAULT" == "true" ]]; then
            choice=1
        else
            echo -e "
${CYAN}检测到 Komari 探针未安装，请选择部署方式：${NC}"
            echo "  1) 直接安装 [默认]"
            echo "  2) 导入旧链接 (手动粘贴)"
            read -t 30 -rp "  > 请选择 (1-2, 30秒后默认 1): " choice || true
            choice=${choice:-1}
        fi
        if [[ "$choice" == "2" ]]; then
            read -rp "请粘贴旧的 Komari 面板链接 (例如 https://komari.xxx.com:8443): " old_komari_link
            if [[ -n "$old_komari_link" ]]; then
                if [[ "$old_komari_link" =~ ^https://([^/:]+) ]]; then
                    old_komari_domain="${BASH_REMATCH[1]}"
                    log_success "成功提取旧配置: 域名=$old_komari_domain"
                else
                    log_warn "未能识别链接格式，将使用常规方式配置。"
                fi
            fi
        fi
    fi

    if [[ "$komari_ver_choice" == "1" ]]; then
        komari_tag="latest"
    elif [[ "$komari_ver_choice" == "2" ]]; then
        ask_val komari_tag "请输入待部署的 Komari 镜像版本号 (例如 1.3.2)" "latest"
    elif [[ "$komari_ver_choice" == "3" ]]; then
        log_info "正在获取 Github 预发布版(Snapshot)标签..."
        local pre_tag=$(curl -s https://api.github.com/repos/komari-monitor/komari/releases | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4)
        if [[ -n "$pre_tag" ]]; then
            komari_tag="$pre_tag"
        else
            log_warn "未能获取预发布版标签，回退为 latest"
            komari_tag="latest"
        fi
    fi

    install_docker_env 1 || return 1

    if ! is_cmd_exist nginx; then
        log_warn "未检测到 Nginx，正在尝试自动预装..."
        install_nginx 1 || return 1
    fi

    log_step "部署 Komari (轻量级服务器监控探针) - 镜像版本: $komari_tag"

    local sn=""
    local cp=""
    local kp=""
    if [[ -n "$old_komari_domain" ]]; then
        sn="$old_komari_domain"
        local prev_auto="$AUTO_DEFAULT"
        AUTO_DEFAULT="true"
        ask_cert_paths "$sn"
        cp="$CERT_PATH"
        kp="$KEY_PATH"
        AUTO_DEFAULT="$prev_auto"
    else
        while true; do
            # 自动执行时使用默认域名选择；交互安装时仍允许自定义。
            local prev_auto="$AUTO_DEFAULT"
            AUTO_DEFAULT="$prev_auto"
            select_server_name "komari.example.com" "" "3"
            sn="$SELECTED_SN"
            AUTO_DEFAULT="$prev_auto"

            local conflict=false
            if [[ -f /root/docker/substore/domain.txt ]]; then
                local sub_sn=$(cat /root/docker/substore/domain.txt)
                [[ "$sn" == "$sub_sn" ]] && conflict=true
            fi
            if [[ -f /root/docker/wallos/domain.txt ]]; then
                local wal_sn=$(cat /root/docker/wallos/domain.txt)
                [[ "$sn" == "$wal_sn" ]] && conflict=true
            fi

            if [[ "$conflict" == "true" ]]; then
                echo -e "${RED}[ERROR] 域名冲突拦截！检测到该域名已被其他面板占用。${NC}"
                echo -e "${CYAN}请重新选择，或者选择 手动输入 其他域名！${NC}"
                echo ""
                continue
            fi
            break
        done
        ask_cert_paths "$sn"
        cp="$CERT_PATH"
        kp="$KEY_PATH"
    fi

    if panel_domain_in_use "$sn" komari; then
        log_error "域名 $sn 已被 Sub-Store 或 Wallos 占用；请选择不同域名后重试"
        return 1
    fi

    if [[ ! -f "$cp" || ! -f "$kp" ]]; then
        log_warn "⚠️ 警告：检测到证书或私钥文件实际不存在！"
        log_warn "Nginx 代理极有可能因此启动失败，导致面板无法访问！"
        log_warn "请后续确保将正确的证书文件放置于: $cp"
    fi

    mkdir -p /root/docker/komari/data
    cd /root/docker/komari
    echo "$sn" > domain.txt

    local admin_user=""
    local admin_pass=""
    if [[ "$AUTO_DEFAULT" != "true" ]]; then
        read -rp "请输入 Komari 初始管理员用户名 (回车则由系统随机生成): " admin_user
        read -rp "请输入 Komari 初始管理员密码 (回车则由系统随机生成): " admin_pass
    else
        log_info "自动执行：由 Komari 首次启动生成管理员凭据，可通过容器日志查看"
    fi

    cat > docker-compose.yml <<EOF
version: '3.8'
services:
  komari:
    image: ghcr.io/komari-monitor/komari:$komari_tag
    container_name: komari
    restart: unless-stopped
    ports:
      - "127.0.0.1:25774:25774"
    environment:
      TZ: "Asia/Shanghai"
EOF
    if [[ -n "$admin_user" ]]; then
        echo "      ADMIN_USERNAME: \"$admin_user\"" >> docker-compose.yml
    fi
    if [[ -n "$admin_pass" ]]; then
        echo "      ADMIN_PASSWORD: \"$admin_pass\"" >> docker-compose.yml
    fi
    cat >> docker-compose.yml <<EOF
    volumes:
      - ./data:/app/data
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    log_info "启动容器..."
    docker compose config -q || { log_error "Komari Compose 配置无效"; return 1; }
    docker compose up -d || { log_error "Komari 容器启动失败，请运行 docker compose logs --tail=100 查看原因"; return 1; }
    if ! docker ps --filter name='^/komari$' --filter status=running --format '{{.Names}}' | grep -qx komari; then
        docker compose logs --tail=100
        log_error "Komari 容器没有保持运行"
        return 1
    fi

    log_step "配置 Nginx 安全反向代理 (专属隔离 8443 端口)"
    open_firewall_ports
    mkdir -p /etc/nginx/conf.d

    # 修复兼容性：移除 Nginx 1.27+ 中已废弃引发致命报错阻断启动的 http2 参数，确保面板能顺利暴露
    # 【优化3修复】：Connection 头改为跟随客户端实际请求头 $http_connection，
    # 避免所有普通 HTTP 请求被误当成 WebSocket 升级请求，导致登录页出现 Network error
    cat > /etc/nginx/conf.d/komari.conf <<EOF
server {
    listen 8080;
    listen [::]:8080;
    server_name $sn;
    return 301 https://\$host:8443\$request_uri;
}
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name $sn;

    ssl_certificate $cp;
    ssl_certificate_key $kp;

    location / {
        proxy_pass http://127.0.0.1:25774;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
    }
}
EOF
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || log_warn "Nginx 重载失败，请后续检查配置文件或证书是否存在"

    echo ""
    log_success "Komari 探针部署完成！"
    echo -e "  🌐 访问面板地址: ${GREEN}https://$sn:8443${NC}"
    echo -e "  ${YELLOW}（如未设置管理员账号密码，请使用 docker logs komari 查看系统自动生成的初始账号密码）${NC}"
    echo -e "  ${YELLOW}（如果不慎忘记该地址，可在脚本主菜单的「服务管理」中随时找回查看）${NC}"
    echo ""
}

# ----------------- Realm 端口转发功能模块 -----------------
deploy_realm() {
    local arch asset_url
    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) log_error "当前架构 $(uname -m) 暂不支持 Realm"; return 1 ;;
    esac

    if [[ -x "/root/realm/realm" ]]; then
        if [[ "$AUTO_DEFAULT" == "true" ]]; then
            log_info "自动执行：Realm 已安装，保留现有版本"
            systemctl enable --now realm.service >/dev/null 2>&1 || return 1
            return 0
        fi
        if ! prompt_reinstall "Realm"; then return 0; fi
        systemctl stop realm 2>/dev/null || true
    fi

    log_step "部署 Realm 端口转发环境"
    mkdir -p /root/realm || { log_error "无法创建 /root/realm"; return 1; }
    asset_url="https://github.com/github19999/fork-realm/releases/download/v2.6.0/realm-${arch}-unknown-linux-gnu.tar.gz"
    if ! curl -fL --retry 3 --connect-timeout 15 "$asset_url" -o /tmp/realm.tar.gz; then
        log_error "Realm 下载失败，请检查网络或该架构的 Release 资源"
        return 1
    fi
    if ! tar -xzf /tmp/realm.tar.gz -C /root/realm realm; then
        rm -f /tmp/realm.tar.gz
        log_error "Realm 安装包解压失败"
        return 1
    fi
    rm -f /tmp/realm.tar.gz
    chmod 755 /root/realm/realm || { log_error "设置 Realm 执行权限失败"; return 1; }
    if [[ ! -f /root/realm/config.toml ]]; then
        install -m 600 /dev/null /root/realm/config.toml
    fi
    cat > /etc/systemd/system/realm.service << 'EOF'
[Unit]
Description=Realm port forwarder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=/root/realm
ExecStart=/root/realm/realm -c /root/realm/config.toml
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || { log_error "systemd 配置重载失败"; return 1; }
    if ! systemctl enable --now realm.service; then
        log_error "Realm 服务启动失败；请运行 systemctl status realm 和 journalctl -u realm -n 50 查看原因"
        return 1
    fi
    if ! systemctl is-active --quiet realm.service; then
        log_error "Realm 服务未进入运行状态；请运行 journalctl -u realm -n 50 查看原因"
        return 1
    fi
    log_success "Realm 已安装并启动，且已设置为开机自启。"
}

add_forward_realm() {
    if [[ ! -x "/root/realm/realm" ]]; then
        log_error "请先安装 Realm"
        return 1
    fi
    log_step "添加 Realm 转发规则"
    if [ ! -f "/root/realm/config.toml" ]; then
        touch /root/realm/config.toml
    fi
    while true; do
        read -p "请输入目标 IP: " ip
        read -p "请输入本地/目标端口 (同端口): " port
        echo "[[endpoints]]" >> /root/realm/config.toml
        echo "listen = \"0.0.0.0:$port\"" >> /root/realm/config.toml
        echo "remote = \"$ip:$port\"" >> /root/realm/config.toml
        
        read -p "是否继续添加(Y/N)? " answer
        if [[ "${answer,,}" != "y" ]]; then
            break
        fi
    done
    if systemctl restart realm.service; then
        log_success "转发规则已添加并生效。"
    else
        log_error "Realm 重启失败；请运行 journalctl -u realm -n 50 查看原因"
        return 1
    fi
}

delete_forward_realm() {
    log_step "删除 Realm 转发规则"
    if [ ! -f "/root/realm/config.toml" ]; then
        log_warn "未找到配置文件 /root/realm/config.toml"
        return
    fi
    echo "当前转发规则："
    local IFS=$'
'
    local lines=($(grep -n 'remote =' /root/realm/config.toml))
    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi
    local index=1
    for line in "${lines[@]}"; do
        echo "${index}. $(echo $line | cut -d '"' -f 2)"
        let index+=1
    done

    echo "请输入要删除的转发规则序号，直接按回车返回主菜单。"
    read -p "选择: " choice
    if [ -z "$choice" ]; then
        echo "返回。"
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入数字。"
        return
    fi

    if [ $choice -lt 1 ] || [ $choice -gt ${#lines[@]} ]; then
        echo "选择超出范围，请输入有效序号。"
        return
    fi

    local chosen_line=${lines[$((choice-1))]}
    local line_number=$(echo $chosen_line | cut -d ':' -f 1)

    local start_line=$((line_number - 2))
    local end_line=$line_number

    sed -i "${start_line},${end_line}d" /root/realm/config.toml

    log_success "转发规则已删除。"
    if ! systemctl restart realm.service; then
        log_error "规则已从配置中删除，但 Realm 重启失败；请检查 journalctl -u realm -n 50"
        return 1
    fi
    log_success "转发规则已删除并生效。"
}

start_service_realm() {
    if [[ ! -x "/root/realm/realm" || ! -f /etc/systemd/system/realm.service ]]; then
        log_error "Realm 未完整安装，请重新部署"
        return 1
    fi
    if ! systemctl daemon-reload || ! systemctl enable --now realm.service || ! systemctl is-active --quiet realm.service; then
        log_error "Realm 启动失败；请运行 systemctl status realm 和 journalctl -u realm -n 50 查看原因"
        return 1
    fi
    log_success "Realm 服务已启动并设置为开机自启。"
}

stop_service_realm() {
    systemctl stop realm 2>/dev/null || true
    log_success "realm 服务已停止。"
}

uninstall_realm() {
    log_step "卸载 Realm"
    systemctl stop realm 2>/dev/null || true
    systemctl disable realm 2>/dev/null || true
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf /root/realm
    hash -r 2>/dev/null || true
    log_success "realm 已被彻底卸载。"
    press_enter
}

menu_manage_realm() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Realm (端口转发) ══${NC}"
        echo ""
        
        local is_installed=false
        if [[ -f "/root/realm/realm" ]]; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if systemctl is-active --quiet realm 2>/dev/null; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 部署环境 (安装 Realm)"
        echo "  2) 添加转发"
        echo "  3) 删除转发"
        echo "  4) 启动服务"
        echo "  5) 停止服务"
        echo "  6) 一键卸载"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) deploy_realm; press_enter ;;
            2) add_forward_realm; press_enter ;;
            3) delete_forward_realm; press_enter ;;
            4) 
                if [[ "$is_installed" == "true" ]]; then start_service_realm; else log_error "未安装 Realm"; fi
                press_enter ;;
            5) 
                if [[ "$is_installed" == "true" ]]; then stop_service_realm; else log_error "未安装 Realm"; fi
                press_enter ;;
            6) uninstall_realm ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}
# ----------------------------------------------------------

menu_install_service() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 三、安装服务 (包含 Docker/拓展) ══${NC}"
        echo ""
        echo -e "  ${CYAN}── 核心代理 (sing-box) ──${NC}"
        echo "  1) 安装 sing-box 最新稳定版"
        echo "  2) 安装 sing-box 指定版本号"
        echo "  3) 安装 sing-box Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Nginx (用于反代和回落) ──${NC}"
        echo "  4) 安装 Nginx 最新稳定版"
        echo "  5) 安装 Nginx 指定版本号"
        echo "  6) 安装 Nginx Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── 安装/修复 Docker 环境 ──${NC}"
        echo "  7) 安装 Docker 最新稳定版"
        echo "  8) 安装 Docker 指定版本号"
        echo "  9) 安装 Docker Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Sub-Store (订阅转换中心) ──${NC}"
        echo " 10) 安装 Sub-Store 最新稳定版 [需要 Docker]"
        echo " 11) 安装 Sub-Store 指定版本号 [需要 Docker]"
        echo " 12) 安装 Sub-Store / 预发布版 [需要 Docker]"
        echo ""
        echo -e "  ${CYAN}── Wallos (个人财务与订阅追踪) ──${NC}"
        echo " 13) 安装 Wallos 最新稳定版 [需要 Docker]"
        echo " 14) 安装 Wallos 指定版本号 (默认: 2.36.2，回车确认) [需要 Docker]"
        echo " 15) 安装 Wallos Beta / 预发布版 [需要 Docker]"
        echo ""
        echo -e "  ${CYAN}── Realm (端口转发工具) ──${NC}"
        echo " 16) 进入 Realm 管理面板 (部署/转发/卸载；无需 Docker)"
        echo ""
        echo -e "  ${CYAN}── 核心代理 (Xray) ──${NC}"
        echo " 17) 安装 Xray 最新稳定版"
        echo " 18) 安装 Xray 指定版本号"
        echo " 19) 安装 Xray Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Komari (轻量级服务器监控探针) ──${NC}"
        echo " 20) 安装 Komari 最新稳定版 [需要 Docker]"
        echo " 21) 安装 Komari 指定版本号 [需要 Docker]"
        echo " 22) 安装 Komari Snapshot / 预发布版 [需要 Docker]"
        echo ""
        echo -e "  ${CYAN}── 批量执行 ──${NC}"
        echo -e " ${GREEN}100) 全部自动执行 (所有服务)${NC}"
        echo -e " ${YELLOW}101) 全部手动执行 (所有服务)${NC}"
        echo -e " ${PURPLE}102) 请输入服务（例如 1 4 7 10 14 16 17 20，默认 0）${NC}"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " vc_raw
        vc_raw=${vc_raw:-0}

        local SVC_CHOICES=()
        if [[ "$vc_raw" == "100" ]]; then
            SVC_CHOICES=(1 4 7 10 14 160 17 20)
            AUTO_DEFAULT=true
        elif [[ "$vc_raw" == "101" ]]; then
            SVC_CHOICES=(1 4 7 10 14 160 17 20)
            AUTO_DEFAULT=false
        elif [[ "$vc_raw" == "102" ]]; then
            read -rp "请输入服务编号（例如 1 4 7，以空格隔开）: " -a SVC_CHOICES
            AUTO_DEFAULT=false
        else
            read -ra SVC_CHOICES <<< "$vc_raw"
            AUTO_DEFAULT=false
        fi

        if [[ ${#SVC_CHOICES[@]} -eq 0 || "${SVC_CHOICES[0]}" == "0" ]]; then
            return
        fi

        local is_batch=false
        if [[ ${#SVC_CHOICES[@]} -gt 1 ]]; then
            is_batch=true
            log_info "即将进行批量执行操作..."
            sleep 1
        fi

        for vc in "${SVC_CHOICES[@]}"; do
            case $vc in
                0) return ;;
                1|2|3)
                    if is_cmd_exist sing-box; then
                        local ver
                        ver=$(sing-box version 2>/dev/null | head -1)
                        log_info "当前已安装版本: $ver"
                        if [[ "$AUTO_DEFAULT" == "true" ]]; then
                            log_info "自动执行：检查并更新已安装的 sing-box"
                        elif ! prompt_reinstall "sing-box"; then
                            [[ "$is_batch" == "false" ]] && press_enter
                            continue
                        fi
                    fi

                    if [[ "$vc" == "1" ]]; then
                        log_step "安装 sing-box 最新稳定版..."
                        if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh); then
                            if ! bash <(curl -fsSL https://sing-box.app/rpm-install.sh); then
                                log_error "安装失败，请检查网络或手动安装"
                                [[ "$is_batch" == "false" ]] && press_enter
                                continue
                            fi
                        fi
                    elif [[ "$vc" == "2" ]]; then
                        echo -n "请输入版本号（例如 1.9.0）: "
                        read -r SB_VER
                        [[ -z "$SB_VER" ]] && { log_error "版本号不能为空"; [[ "$is_batch" == "false" ]] && press_enter; continue; }
                        log_step "安装 sing-box v${SB_VER}..."
                        local ARCH
                        ARCH=$(uname -m)
                        case "$ARCH" in
                            x86_64) ARCH_STR="amd64" ;;
                            aarch64) ARCH_STR="arm64" ;;
                            armv7l) ARCH_STR="armv7" ;;
                            *) ARCH_STR="amd64" ;;
                        esac
                        local URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${ARCH_STR}.tar.gz"
                        if ! curl -fsSL "$URL" -o /tmp/sing-box.tar.gz; then
                            log_error "下载失败"
                            [[ "$is_batch" == "false" ]] && press_enter
                            continue
                        fi
                        tar -xzf /tmp/sing-box.tar.gz -C /tmp/
                        install -m 755 "/tmp/sing-box-${SB_VER}-linux-${ARCH_STR}/sing-box" /usr/local/bin/sing-box
                        rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${SB_VER}-linux-${ARCH_STR}"
                    elif [[ "$vc" == "3" ]]; then
                        log_step "安装 sing-box Beta 版..."
                        if ! bash <(curl -fsSL https://sing-box.app/deb-install.sh) beta; then
                            log_error "Beta 安装失败"
                            [[ "$is_batch" == "false" ]] && press_enter
                            continue
                        fi
                    fi

                    mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box

                    if [[ ! -f /etc/systemd/system/sing-box.service ]]; then
                        cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/bin/env sing-box -D /var/lib/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
                        systemctl daemon-reload
                    fi

                    if is_cmd_exist sing-box; then
                        local ver
                        ver=$(sing-box version 2>/dev/null | head -1)
                        log_success "sing-box 安装成功: $ver"
                        
                        # 【核心修复】：防止官方安装包自带的默认 config.json 占用 8080 等端口引发 Nginx/Substore 启动冲突
                        if [[ -f /etc/sing-box/config.json ]] && ! grep -q -E "vless-|vmess-|trojan-|shadowsocks-|hysteria2-|tuic-|anytls-|naive-" /etc/sing-box/config.json; then
                            mv /etc/sing-box/config.json /etc/sing-box/config.json.default.bak 2>/dev/null || true
                            systemctl stop sing-box >/dev/null 2>&1 || true
                        fi
                        
                        # 尝试自动启动 (若已存在有效配置)
                        if [[ -s /etc/sing-box/config.json ]]; then
                            if ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
                                systemctl enable sing-box >/dev/null 2>&1 || true
                                systemctl start sing-box >/dev/null 2>&1 || true
                            fi
                        else
                            log_info "提醒: sing-box 核心已就绪。请前往主菜单「4. 配置 sing-box」生成配置，完成后系统将自动守护运行。"
                        fi
                    else
                        log_error "sing-box 安装失败"
                    fi
                    [[ "$is_batch" == "false" ]] && press_enter
                    ;;
                4) install_nginx 1; [[ "$is_batch" == "false" ]] && press_enter ;;
                5) install_nginx 2; [[ "$is_batch" == "false" ]] && press_enter ;;
                6) install_nginx 3; [[ "$is_batch" == "false" ]] && press_enter ;;
                7) install_docker_env 1; [[ "$is_batch" == "false" ]] && press_enter ;;
                8) install_docker_env 2; [[ "$is_batch" == "false" ]] && press_enter ;;
                9) install_docker_env 3; [[ "$is_batch" == "false" ]] && press_enter ;;
                10) install_substore 1; [[ "$is_batch" == "false" ]] && press_enter ;;
                11) install_substore 2; [[ "$is_batch" == "false" ]] && press_enter ;;
                12) install_substore 3; [[ "$is_batch" == "false" ]] && press_enter ;;
                13) install_wallos 1; [[ "$is_batch" == "false" ]] && press_enter ;;
                14) install_wallos 2; [[ "$is_batch" == "false" ]] && press_enter ;;
                15) install_wallos 3; [[ "$is_batch" == "false" ]] && press_enter ;;
                16) menu_manage_realm ;;
                160) deploy_realm; [[ "$is_batch" == "false" ]] && press_enter ;;
                17) install_xray 1; [[ "$is_batch" == "false" ]] && press_enter ;;
                18) install_xray 2; [[ "$is_batch" == "false" ]] && press_enter ;;
                19) install_xray 3; [[ "$is_batch" == "false" ]] && press_enter ;;
                20) install_komari 1; [[ "$is_batch" == "false" ]] && press_enter ;;
                21) install_komari 2; [[ "$is_batch" == "false" ]] && press_enter ;;
                22) install_komari 3; [[ "$is_batch" == "false" ]] && press_enter ;;
                *) log_warn "未知选项或服务: $vc，跳过"; sleep 1 ;;
            esac
        done

        if [[ "$is_batch" == "true" ]]; then
            log_info "批量安装步骤已全部执行；请根据各步骤的错误提示处理未成功项。"
            [[ "$AUTO_DEFAULT" != "true" ]] && press_enter
        fi
    done
}
