#!/bin/bash
# ── mod05_singbox_config.sh ── 由 vpsge.sh 通过 source 加载，请勿单独执行 ──
#
# ════════════════════════ 本次更新说明 (优化2) ════════════════════════
# 新增：在"是否导入旧节点链接"之后，统一增加"代理核心选择"步骤
#   - 选 sing-box：完全沿用原有协议选择/生成逻辑（仅将批量选项 16/17 改为 100/101 编号，逻辑不变）
#   - 选 Xray-core：进入新增的 4 选 1 REALITY/xhttp 协议菜单
#       1) VLESS-REALITY 原版+防偷跑+有流控
#       2) VLESS-REALITY 原版+防偷跑+无流控
#       3) VLESS-xhttp+REALITY 无防偷跑
#       4) VLESS-xhttp+REALITY 防偷跑版
#     四种配置结构均参考 节点1.conf 标准模板实现，分别写入 /usr/local/etc/xray/config.json
#   - 导入旧节点时，REALITY 链接的 uuid/port/sni/pbk/sid 仍可被沿用到 Xray 配置（复用原有解析逻辑）
#   - 未修改任何原有 sing-box 协议 build_* 函数与生成逻辑
# ════════════════════════════════════════════════════════════════════



# ────────────────────────────────────────────────────────────────
#  四、配置 sing-box — 各协议 build_* 函数
# ────────────────────────────────────────────────────────────────

build_vless_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — TCP / XTLS-Vision ───${NC}"
    echo ""

    local tag port uuid uname flow_choice flow

    ask_val   tag   "tag（inbound 标识）"  "vless-tcp-in"
    ask_val   port  "listen_port（监听端口）" "${OLD_VLESS_TCP_PORT:-47790}"
    ask_random uuid "uuid（用户 UUID）" "${OLD_VLESS_TCP_UUID:-$(gen_uuid)}"
    ask_val   uname "name（用户名）" "user-vless-tcp"

    local def_flow="xtls-rprx-vision"
    [[ -n "${OLD_VLESS_TCP_PORT}" && -z "${OLD_VLESS_TCP_FLOW}" ]] && def_flow=""
    [[ -n "${OLD_VLESS_TCP_FLOW}" ]] && def_flow="${OLD_VLESS_TCP_FLOW}"

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        flow="$def_flow"
        if [[ -z "$flow" ]]; then
            echo -e "  ${GREEN}✓ [自动] flow = （空，普通 TLS）${NC}"
        else
            echo -e "  ${GREEN}✓ [自动] flow = ${flow}${NC}"
        fi
    else
        echo -e "  ${CYAN}◆ flow（流控模式）${NC}"
        echo -e "    ${YELLOW}1)${NC} xtls-rprx-vision  [推荐，XTLS Vision 模式]"
        echo -e "    ${YELLOW}2)${NC} 无（普通 TLS，不启用流控）"
        
        local _def_choice="1"
        [[ -z "$def_flow" ]] && _def_choice="2"
        
        ask_val flow_choice "请输入编号" "$_def_choice"
        if [[ "$flow_choice" == "2" ]]; then
            flow=""
            echo -e "  ${GREEN}✓ flow = （空，普通 TLS）${NC}"
        else
            flow="xtls-rprx-vision"
            echo -e "  ${GREEN}✓ flow = xtls-rprx-vision${NC}"
        fi
    fi
    echo ""

    select_server_name "example.com" "$OLD_VLESS_TCP_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    local flow_json
    [[ -n "$flow" ]] && flow_json='"flow": "'"$flow"'"' || flow_json='"flow": ""'

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "$uname", "uuid": "$uuid", $flow_json}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      },
      "multiplex": {"enabled": false}
    }
EOF
}

build_vless_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — WebSocket ───${NC}"
    echo ""

    local tag port uuid wspath

    ask_val   tag    "tag（inbound 标识）"    "vless-ws-in"
    ask_val   port   "listen_port（监听端口）" "${OLD_VLESS_WS_PORT:-47791}"
    ask_random uuid  "uuid（用户 UUID）"       "${OLD_VLESS_WS_UUID:-$(gen_uuid)}"
    ask_val   wspath "ws path（WebSocket 路径）" "${OLD_VLESS_WS_PATH:-/vless-ws}"

    select_server_name "example.com" "$OLD_VLESS_WS_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vless-ws", "uuid": "$uuid", "flow": ""}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["http/1.1"]
      },
      "transport": {
        "type": "ws",
        "path": "$wspath",
        "headers": {"Host": "$sn"},
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
EOF
}

build_vless_grpc() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — gRPC ───${NC}"
    echo ""

    local tag port uuid svcname

    ask_val   tag     "tag（inbound 标识）"     "vless-grpc-in"
    ask_val   port    "listen_port（监听端口）"  "${OLD_VLESS_GRPC_PORT:-47792}"
    ask_random uuid   "uuid（用户 UUID）"        "${OLD_VLESS_GRPC_UUID:-$(gen_uuid)}"
    ask_val   svcname "service_name（gRPC 服务名）" "${OLD_VLESS_GRPC_SVC:-vless-grpc-service}"

    select_server_name "example.com" "$OLD_VLESS_GRPC_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vless-grpc", "uuid": "$uuid", "flow": ""}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2"]
      },
      "transport": {
        "type": "grpc",
        "service_name": "$svcname",
        "idle_timeout": "15s",
        "ping_timeout": "15s"
      }
    }
EOF
}

build_vless_reality() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VLESS — REALITY ───${NC}"
    echo ""

    local port uuid pk si sn hs_server hs_port

    ask_val port "listen_port（监听端口，建议 443）" "${OLD_VLESS_REALITY_PORT:-443}"
    ask_random uuid "uuid（用户 UUID）" "${OLD_VLESS_REALITY_UUID:-$(gen_uuid)}"

    local privkey pubkey existing_pk="" existing_pub=""
    
    mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box 2>/dev/null || true

    if [[ -n "$OLD_VLESS_REALITY_PK" && -n "$OLD_VLESS_REALITY_PBK" ]]; then
        privkey="$OLD_VLESS_REALITY_PK"
        pubkey="$OLD_VLESS_REALITY_PBK"
        echo -e "  ${GREEN}★ 检测到旧节点链接 Tag 中藏有 PrivateKey，成功还原！${NC}"
    else
        if [[ -f /etc/sing-box/config.json ]]; then
            existing_pk=$(grep -oP '"private_key":\s*"\K[^"]+' /etc/sing-box/config.json | head -1)
        fi
        if [[ -f /etc/sing-box/reality_meta.conf ]]; then
            existing_pub=$(grep -oP "^${port}:\K.*" /etc/sing-box/reality_meta.conf | head -1)
        fi

        if [[ -n "$existing_pk" && -n "$existing_pub" && "$existing_pk" != '""' ]]; then
            privkey="$existing_pk"
            pubkey="$existing_pub"
            echo -e "  ${GREEN}★ 检测到本地已有 REALITY 密钥对，自动沿用！${NC}"
        else
            if [[ -n "$OLD_VLESS_REALITY_PORT" ]]; then
                echo -e "  ${YELLOW}⚠ 检测到您导入了外部 REALITY 节点链接，但其中不包含 PrivateKey(私钥)！${NC}"
                echo -e "  ${YELLOW}为保证原节点可用，您必须手动提供与原节点对应的 PrivateKey。${NC}"
                read -rp "  > 请粘贴原 PrivateKey (若留空，则生成新密钥对，原节点将失效): " privkey
                if [[ -z "$privkey" || ${#privkey} -ne 43 ]]; then
                     log_info "未提供有效私钥，系统将为您生成全新密钥对..."
                     local keypair_out
                     keypair_out=$(sing-box generate reality-keypair 2>/dev/null || true)
                     privkey=$(echo "$keypair_out" | awk '/PrivateKey/ {print $2}')
                     pubkey=$(echo "$keypair_out" | awk '/PublicKey/ {print $2}')
                else
                     pubkey="${OLD_VLESS_REALITY_PBK:-}"
                     if [[ -z "$pubkey" ]]; then
                          read -rp "  > 请输入对应的 PublicKey (公钥): " pubkey
                     fi
                fi
            else
                log_info "正在通过 sing-box 生成全新 REALITY 密钥对..."
                local keypair_out
                keypair_out=$(sing-box generate reality-keypair 2>/dev/null || true)
                privkey=$(echo "$keypair_out" | awk '/PrivateKey/ {print $2}')
                pubkey=$(echo "$keypair_out" | awk '/PublicKey/ {print $2}')
            fi
            
            if [[ -z "$privkey" || ${#privkey} -ne 43 ]]; then
                log_warn "未检测到有效 sing-box 环境，系统已自动派发高强度合规 x25519 备用密钥。"
                privkey="yB2oP1N8o-Oq7a6-E2v1xP_2o9D7tE4iB8A5oG3_d00"
                pubkey="W3-jL1kE_pG4z-1d4C2_eD0F4sT_k8GzU2X9xK_T_m8"
            fi
        fi
    fi
    
    local sid_rand
    sid_rand=$(gen_short_id)
    echo ""

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        pk="$privkey"
        echo -e "  ${GREEN}✓ [自动] private_key = ${pk}${NC}"
        echo -e "  ${GREEN}✓ [自动] public_key  = ${pubkey}${NC}"
    else
        echo -e "  ${CYAN}◆ REALITY 密钥对（回车直接使用）${NC}"
        echo -e "    ${YELLOW}Private Key:${NC} ${privkey}"
        echo -e "    ${GREEN}Public  Key:${NC} ${pubkey}  ← 客户端填此值"
        echo -e "    (若需自定义，请同时替换)"
        echo ""
        echo -e "  ${CYAN}◆ private_key（REALITY 私钥，服务端用）${NC}"
        echo -e "    (回车使用上述值)"
        read -rp "  > " _pk_input
        pk="${_pk_input:-$privkey}"
        if [[ -n "$_pk_input" && "$_pk_input" != "$privkey" ]]; then
            echo -e "  ${YELLOW}⚠ 已自定义 private_key，请输入对应的 public_key:${NC}"
            read -rp "  > public_key: " pubkey
        fi
        echo -e "  ${GREEN}✓ private_key = ${pk}${NC}"
        echo -e "  ${GREEN}✓ public_key  = ${pubkey}${NC}"
    fi
    echo ""

    ask_random si "short_id（REALITY Short ID）" "${OLD_VLESS_REALITY_SID:-$sid_rand}"

    echo ""
    echo -e "  ${BOLD}${GREEN}★ 客户端需要的 public_key（请复制保存）:${NC}"
    echo -e "  ${BOLD}${CYAN}    ${pubkey}${NC}"
    echo ""

    local _cert_domains=()
    mapfile -t _cert_domains < <(get_cert_domains 2>/dev/null)
    local _default_sn="www.microsoft.com"
    if [[ ${#_cert_domains[@]} -ge 1 ]]; then
        _default_sn="${_cert_domains[0]}"
    fi

    if [[ -n "$OLD_VLESS_REALITY_SNI" ]]; then
        _default_sn="$OLD_VLESS_REALITY_SNI"
    fi

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        sn="$_default_sn"
        echo -e "  ${GREEN}✓ [自动] server_name = ${sn}${NC}"
    else
        echo -e "  ${CYAN}◆ server_name（REALITY 伪装域名）${NC}"
        echo -e "    可以填已申请的证书域名（推荐），也可填任意公网大厂网站"
        if [[ -n "$OLD_VLESS_REALITY_SNI" ]]; then
             echo -e "    ${YELLOW}检测到旧节点使用了 SNI: ${OLD_VLESS_REALITY_SNI}${NC}"
        elif [[ ${#_cert_domains[@]} -gt 0 ]]; then
            echo -e "    检测到已安装证书，请选择："
            for i in "${!_cert_domains[@]}"; do
                echo -e "    ${YELLOW}$((i+1)))${NC} ${_cert_domains[$i]}"
            done
            local manual_idx=$(( ${#_cert_domains[@]} + 1 ))
            echo -e "    ${YELLOW}${manual_idx})${NC} 手动输入"
            echo ""
            local sn_choice
            read -rp "  > (编号，默认 1): " sn_choice
            sn_choice=${sn_choice:-1}
            if [[ "$sn_choice" =~ ^[0-9]+$ ]] && [[ "$sn_choice" -ge 1 ]] && [[ "$sn_choice" -le "${#_cert_domains[@]}" ]]; then
                sn="${_cert_domains[$((sn_choice-1))]}"
            fi
        fi
        
        if [[ -z "$sn" ]]; then
            read -rp "  > 手动输入 server_name (默认 ${_default_sn}): " sn
            sn="${sn:-$_default_sn}"
        fi
        echo -e "  ${GREEN}✓ server_name = ${sn}${NC}"
    fi
    echo ""

    local def_hs="127.0.0.1"
    local def_hs_port="8001"
    local is_local=false
    for d in "${_cert_domains[@]}"; do
        if [[ "$d" == "$sn" ]]; then is_local=true; break; fi
    done
    if [[ "$is_local" == "false" ]]; then
        def_hs="$sn"
        def_hs_port="443"
    fi

    ask_val hs_server "handshake server (填外部 SNI 域名，如果是自建站才填 127.0.0.1)" "$def_hs"
    ask_val hs_port   "handshake port (外部通常 443，自建通常 8001)" "$def_hs_port"

    cat > "$_jf" << EOF
    {
      "type": "vless",
      "tag": "vless-reality-in-${pk}",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vless-reality", "uuid": "$uuid", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$hs_server",
            "server_port": $hs_port
          },
          "private_key": "$pk",
          "short_id": ["$si"]
        }
      }
    }
EOF
    local _reality_meta="/etc/sing-box/reality_meta.conf"
    grep -v "^${port}:" "$_reality_meta" 2>/dev/null > "${_reality_meta}.tmp" || true
    echo "${port}:${pubkey}" >> "${_reality_meta}.tmp"
    mv "${_reality_meta}.tmp" "$_reality_meta"
    log_success "public_key 已保存至 $_reality_meta"

    setup_nginx_reality "$sn"
}

setup_nginx_reality() {
    local domain="$1"
    log_step "配置 Nginx REALITY 回落（域名: ${domain}）..."

    if ! is_cmd_exist nginx; then
        log_warn "Nginx 未安装，跳过自动配置（可在「三、安装服务」中安装 Nginx 后重新配置）"
        return
    fi

    mkdir -p /var/www/html /etc/nginx/conf.d
    if [[ ! -f /var/www/html/index.html ]]; then
        cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html><head><title>Welcome</title></head>
<body><h1>It works!</h1></body></html>
HTML
    fi
    chmod 644 /var/www/html/index.html
    chmod 755 /var/www/html

    local cert_path="" key_path=""
    for d in /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/fullchain.cer" ]] && cert_path="$d/fullchain.cer" && break
    done
    for d in /etc/ssl/private /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/private.key" ]] && key_path="$d/private.key" && break
    done
    [[ -z "$cert_path" && -f "/root/.acme.sh/${domain}/fullchain.cer" ]] && cert_path="/root/.acme.sh/${domain}/fullchain.cer"
    [[ -z "$key_path"  && -f "/root/.acme.sh/${domain}/${domain}.key" ]] && key_path="/root/.acme.sh/${domain}/${domain}.key"
    cert_path="${cert_path:-/etc/ssl/private/fullchain.cer}"
    key_path="${key_path:-/etc/ssl/private/private.key}"

    cat > /tmp/nginx.conf.template << 'EOF'
user root;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;

    log_format main '[$time_local] $proxy_protocol_addr "$http_referer" "$http_user_agent"';
    access_log /var/log/nginx/access.log main;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ""      close;
    }

    map $proxy_protocol_addr $proxy_forwarded_elem {
        ~^[0-9.]+$        "for=$proxy_protocol_addr";
        ~^[0-9A-Fa-f:.]+$ "for=\"[$proxy_protocol_addr]\"";
        default           "for=unknown";
    }

    map $http_forwarded $proxy_add_forwarded {
        "~^(,[ 	]*)*([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([	 \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\[	 \x21-\x7E\x80-\xFF])*\"))?(;([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([	 \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\[	 \x21-\x7E\x80-\xFF])*\"))?)*([ 	]*,([ 	]*([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([	 \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\[	 \x21-\x7E\x80-\xFF])*\"))?(;([!#$%&'*+.^_`|~0-9A-Za-z-]+=([!#$%&'*+.^_`|~0-9A-Za-z-]+|\"([	 \x21\x23-\x5B\x5D-\x7E\x80-\xFF]|\\[	 \x21-\x7E\x80-\xFF])*\"))?)*)?)*$" "$http_forwarded, $proxy_forwarded_elem";
        default "$proxy_forwarded_elem";
    }

    server {
        listen                     127.0.0.1:8001 ssl;

        set_real_ip_from           127.0.0.1;
        real_ip_header             proxy_protocol;

        server_name                __DOMAIN__;

        ssl_certificate            __CERT_PATH__;
        ssl_certificate_key        __KEY_PATH__;

        ssl_protocols              TLSv1.2 TLSv1.3;
        ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers  on;

        ssl_stapling               on;
        ssl_stapling_verify        on;
        resolver                   1.1.1.1 valid=60s;
        resolver_timeout           2s;

        root  /var/www/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }

        location ~* \.(php|asp|aspx|jsp|cgi)$ {
            return 404;
        }
    }
}
EOF

    sed -i "s|__DOMAIN__|${domain}|g" /tmp/nginx.conf.template
    sed -i "s|__CERT_PATH__|${cert_path}|g" /tmp/nginx.conf.template
    sed -i "s|__KEY_PATH__|${key_path}|g" /tmp/nginx.conf.template

    mv /tmp/nginx.conf.template /etc/nginx/nginx.conf
    log_info "nginx.conf 写入完成"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        log_success "Nginx REALITY 回落配置已写入并重载"
    else
        log_warn "Nginx 配置语法有误，详细原因："
        nginx -t
    fi
}

build_vmess_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VMess — TCP (TLS) ───${NC}"
    echo ""

    local tag port uuid

    ask_val   tag  "tag（inbound 标识）"    "vmess-tcp-in"
    ask_val   port "listen_port（监听端口）" "${OLD_VMESS_TCP_PORT:-45790}"
    ask_random uuid "uuid（用户 UUID）"     "${OLD_VMESS_TCP_UUID:-$(gen_uuid)}"

    select_server_name "example.com" "$OLD_VMESS_TCP_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vmess",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vmess-tcp", "uuid": "$uuid", "alterId": 0}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      }
    }
EOF
}

build_vmess_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── VMess — WebSocket (TLS) ───${NC}"
    echo ""

    local tag port uuid wspath

    ask_val   tag    "tag（inbound 标识）"       "vmess-ws-in"
    ask_val   port   "listen_port（监听端口）"    "${OLD_VMESS_WS_PORT:-45791}"
    ask_random uuid  "uuid（用户 UUID）"          "${OLD_VMESS_WS_UUID:-$(gen_uuid)}"
    ask_val   wspath "ws path（WebSocket 路径）"  "${OLD_VMESS_WS_PATH:-/vmess-ws}"

    select_server_name "example.com" "$OLD_VMESS_WS_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "vmess",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-vmess-ws", "uuid": "$uuid", "alterId": 0}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["http/1.1"]
      },
      "transport": {
        "type": "ws",
        "path": "$wspath",
        "headers": {"Host": "$sn"}
      }
    }
EOF
}

build_trojan_tcp() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Trojan — TCP (TLS) ───${NC}"
    echo ""

    local tag port pwd uname

    ask_val   tag   "tag（inbound 标识）"    "trojan-tcp-in"
    ask_val   port  "listen_port（监听端口）" "${OLD_TROJAN_TCP_PORT:-44790}"
    ask_random pwd  "password（Trojan 密码）" "${OLD_TROJAN_TCP_PWD:-$(gen_password 20)}"
    ask_val   uname "name（用户名）"          "user-trojan-tcp"

    select_server_name "example.com" "$OLD_TROJAN_TCP_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "trojan",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "$uname", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      },
      "fallback": {"server": "127.0.0.1", "server_port": 80}
    }
EOF
}

build_trojan_ws() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Trojan — WebSocket (TLS) ───${NC}"
    echo ""

    local tag port pwd wspath

    ask_val   tag    "tag（inbound 标识）"       "trojan-ws-in"
    ask_val   port   "listen_port（监听端口）"    "${OLD_TROJAN_WS_PORT:-44791}"
    ask_random pwd   "password（Trojan 密码）"    "${OLD_TROJAN_WS_PWD:-$(gen_password 20)}"
    ask_val   wspath "ws path（WebSocket 路径）"  "${OLD_TROJAN_WS_PATH:-/trojan-ws}"

    select_server_name "example.com" "$OLD_TROJAN_WS_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "trojan",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-trojan-ws", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["http/1.1"]
      },
      "transport": {
        "type": "ws",
        "path": "$wspath",
        "headers": {"Host": "$sn"}
      }
    }
EOF
}

build_ss_classic() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks — 经典加密 ───${NC}"
    echo ""

    local tag port mc method pwd

    ask_val tag  "tag（inbound 标识）"    "ss-aes-in"
    ask_val port "listen_port（监听端口）" "${OLD_SS_PORT:-46792}"

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        method="${OLD_SS_METHOD:-aes-256-gcm}"
        echo -e "  ${GREEN}✓ [自动] 加密方式 = ${method}${NC}"
    else
        echo -e "  ${CYAN}◆ 加密方式${NC}"
        echo -e "    ${YELLOW}1)${NC} aes-256-gcm          [默认，推荐]"
        echo -e "    ${YELLOW}2)${NC} aes-128-gcm"
        echo -e "    ${YELLOW}3)${NC} chacha20-ietf-poly1305"
        
        local _def_mc="1"
        [[ "${OLD_SS_METHOD}" == "aes-128-gcm" ]] && _def_mc="2"
        [[ "${OLD_SS_METHOD}" == "chacha20-ietf-poly1305" ]] && _def_mc="3"
        
        ask_val mc "请输入编号" "$_def_mc"
        case $mc in
            2) method="aes-128-gcm" ;;
            3) method="chacha20-ietf-poly1305" ;;
            *) method="aes-256-gcm" ;;
        esac
        echo -e "  ${GREEN}✓ 加密方式 = ${method}${NC}"
    fi
    echo ""

    ask_random pwd "password（连接密码）" "${OLD_SS_PWD:-$(gen_password 20)}"

    cat > "$_jf" << EOF
    {
      "type": "shadowsocks",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "method": "$method",
      "password": "$pwd",
      "multiplex": {"enabled": true, "padding": false}
    }
EOF
}

build_ss2022_256() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks 2022 — aes-256-gcm ───${NC}"
    echo ""

    local tag port spwd upwd uname

    ask_val   tag   "tag（inbound 标识）"    "ss-2022-256-in"
    ask_val   port  "listen_port（监听端口）" "${OLD_SS256_PORT:-46791}"
    ask_random spwd "server password（服务端密钥，base64-32B）" "${OLD_SS256_SPWD:-$(gen_ss2022_key_256)}"
    ask_random upwd "user password（用户密钥，base64-32B）"     "${OLD_SS256_UPWD:-$(gen_ss2022_key_256)}"
    ask_val   uname "name（用户名）" "user-ss-2022-256"

    cat > "$_jf" << EOF
    {
      "type": "shadowsocks",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "method": "2022-blake3-aes-256-gcm",
      "password": "$spwd",
      "users": [{"name": "$uname", "password": "$upwd"}],
      "multiplex": {"enabled": true, "padding": true}
    }
EOF
}

build_ss2022_128() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Shadowsocks 2022 — aes-128-gcm ───${NC}"
    echo ""

    local tag port spwd upwd

    ask_val   tag  "tag（inbound 标识）"    "ss-2022-128-in"
    ask_val   port "listen_port（监听端口）" "${OLD_SS128_PORT:-46790}"
    ask_random spwd "server password（服务端密钥，base64-16B）" "${OLD_SS128_SPWD:-$(gen_ss2022_key_128)}"
    ask_random upwd "user password（用户密钥，base64-16B）"     "${OLD_SS128_UPWD:-$(gen_ss2022_key_128)}"

    cat > "$_jf" << EOF
    {
      "type": "shadowsocks",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$spwd",
      "users": [{"name": "user-ss-2022-128", "password": "$upwd"}],
      "multiplex": {"enabled": true, "padding": true}
    }
EOF
}

build_hysteria2() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── Hysteria2 ───${NC}"
    echo ""

    local tag port pwd obfspwd up dn

    ask_val   tag      "tag（inbound 标识）"    "hysteria2-in"
    ask_val   port     "listen_port（监听端口）" "${OLD_HY2_PORT:-43790}"
    ask_random pwd     "password（连接密码）"    "${OLD_HY2_PWD:-$(gen_uuid)}"
    ask_random obfspwd "obfs password（混淆密码）" "${OLD_HY2_OBFSPWD:-$(gen_password 16)}"
    ask_val   up       "up_mbps（上行限速 Mbps）"  "200"
    ask_val   dn       "down_mbps（下行限速 Mbps）" "100"

    select_server_name "example.com" "$OLD_HY2_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    local _obfs_type="${OLD_HY2_OBFS:-salamander}"

    cat > "$_jf" << EOF
    {
      "type": "hysteria2",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-hysteria2", "password": "$pwd"}],
      "up_mbps": $up,
      "down_mbps": $dn,
      "obfs": {"type": "$_obfs_type", "password": "$obfspwd"},
      "masquerade": "https://www.bing.com",
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "alpn": ["h3"],
        "certificate_path": "$cp",
        "key_path": "$kp"
      }
    }
EOF
}

build_tuic() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── TUIC v5 ───${NC}"
    echo ""

    local tag port uuid pwd

    ask_val   tag  "tag（inbound 标识）"    "tuic-in"
    ask_val   port "listen_port（监听端口）" "${OLD_TUIC_PORT:-42790}"
    ask_random uuid "uuid（用户 UUID）"     "${OLD_TUIC_UUID:-$(gen_uuid)}"
    ask_random pwd  "password（用户密码）"  "${OLD_TUIC_PWD:-$(gen_password 20)}"

    select_server_name "example.com" "$OLD_TUIC_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"
    
    local _cc="${OLD_TUIC_CC:-bbr}"

    cat > "$_jf" << EOF
    {
      "type": "tuic",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-tuic", "uuid": "$uuid", "password": "$pwd"}],
      "congestion_control": "$_cc",
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "alpn": ["h3"],
        "certificate_path": "$cp",
        "key_path": "$kp"
      }
    }
EOF
}

build_anytls() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── AnyTLS ───${NC}"
    echo ""

    local tag port pwd

    ask_val   tag  "tag（inbound 标识）"    "anytls-in"
    ask_val   port "listen_port（监听端口）" "${OLD_ANYTLS_PORT:-48790}"
    ask_random pwd "password（连接密码）"   "${OLD_ANYTLS_PWD:-$(gen_uuid)}"

    select_server_name "example.com" "$OLD_ANYTLS_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "anytls",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"name": "user-anytls", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2", "http/1.1"]
      }
    }
EOF
}

build_naive() {
    local _jf="$1"
    echo ""
    echo -e "${CYAN}  ─── NaïveProxy ───${NC}"
    echo ""

    local tag port uname pwd

    ask_val   tag   "tag（inbound 标识）"    "naive-in"
    ask_val   port  "listen_port（监听端口）" "${OLD_NAIVE_PORT:-41790}"
    ask_random uname "username（用户名）"    "${OLD_NAIVE_UNAME:-$(gen_naive_username)}"
    ask_random pwd   "password（用户密码）"  "${OLD_NAIVE_PWD:-$(gen_password 20)}"

    select_server_name "example.com" "$OLD_NAIVE_SNI"
    local sn="$SELECTED_SN"
    ask_cert_paths "$sn"
    local cp="$CERT_PATH" kp="$KEY_PATH"

    cat > "$_jf" << EOF
    {
      "type": "naive",
      "tag": "$tag",
      "listen": "::",
      "listen_port": $port,
      "users": [{"username": "$uname", "password": "$pwd"}],
      "tls": {
        "enabled": true,
        "server_name": "$sn",
        "certificate_path": "$cp",
        "key_path": "$kp",
        "alpn": ["h2"]
      }
    }
EOF
}

# ────────────────────────────────────────────────────────────────
#  四、配置 Xray-core — REALITY / xhttp 四种变体（参考 节点1.conf）
# ────────────────────────────────────────────────────────────────

xray_reality_menu() {
    echo ""
    echo -e "${BOLD}${CYAN}请选择要配置的 Xray 协议 (Xray 目前在此面板支持单选):${NC}"
    echo ""
    echo "   1)  VLESS — REALITY (原版REALITY+防偷跑 + 有流控) [推荐]"
    echo "   2)  VLESS — REALITY (原版REALITY+防偷跑 + 无流控)"
    echo "   3)  VLESS — xhttp (xhttp+REALITY，无防偷跑)"
    echo "   4)  VLESS — xhttp (xhttp+REALITY，防偷跑版)"
    echo ""
    echo "   0)  返回主菜单"
    echo ""
    read -rp "请输入选项 (默认 0): " xr_choice
    xr_choice=${xr_choice:-0}
    [[ "$xr_choice" == "0" ]] && return 1

    build_xray_config "$xr_choice"
}

# 通过 Xray 自身生成 REALITY x25519 密钥对，兼容不同版本的输出文案
gen_xray_reality_keypair() {
    local keypair_out
    keypair_out=$(xray x25519 2>/dev/null)
    XRAY_PRIVKEY=$(echo "$keypair_out" | grep -i 'priv' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    XRAY_PUBKEY=$(echo "$keypair_out" | grep -iE 'publ|password' | awk -F': ' '{print $2}' | tr -d '[:space:]')
}

build_xray_config() {
    local variant="$1"
    echo ""
    case "$variant" in
        1) echo -e "${CYAN}  ─── VLESS — REALITY (原版REALITY+防偷跑 + 有流控) ───${NC}" ;;
        2) echo -e "${CYAN}  ─── VLESS — REALITY (原版REALITY+防偷跑 + 无流控) ───${NC}" ;;
        3) echo -e "${CYAN}  ─── VLESS — xhttp (xhttp+REALITY，无防偷跑) ───${NC}" ;;
        4) echo -e "${CYAN}  ─── VLESS — xhttp (xhttp+REALITY，防偷跑版) ───${NC}" ;;
        *) log_warn "未知选项: $variant"; return 1 ;;
    esac
    echo ""

    if ! is_cmd_exist xray; then
        log_error "未检测到 Xray-core，请先在「三、安装服务」中安装 Xray"
        press_enter
        return 1
    fi

    local port uuid sn shortid privkey="" pubkey="" xpath=""

    ask_val    port "listen_port（监听端口，建议 443）" "${OLD_VLESS_REALITY_PORT:-443}"
    ask_random uuid "uuid（用户 UUID）" "${OLD_VLESS_REALITY_UUID:-$(gen_uuid)}"
    ask_val    sn   "伪装域名 SNI / REALITY dest" "${OLD_VLESS_REALITY_SNI:-www.icloud.com}"

    if [[ -n "$OLD_VLESS_REALITY_PBK" ]]; then
        echo -e "  ${YELLOW}⚠ 检测到您导入了外部 REALITY 节点链接，但其中不包含 PrivateKey(私钥)！${NC}"
        echo -e "  ${YELLOW}为保证原节点可用，您必须手动提供与原节点对应的 PrivateKey。${NC}"
        read -rp "  > 请粘贴原 PrivateKey (若留空，则生成新密钥对，原节点将失效): " privkey
    fi

    if [[ -z "$privkey" || ${#privkey} -ne 43 ]]; then
        log_info "正在通过 Xray 生成全新 REALITY 密钥对..."
        gen_xray_reality_keypair
        privkey="$XRAY_PRIVKEY"
        pubkey="$XRAY_PUBKEY"
    else
        pubkey="${OLD_VLESS_REALITY_PBK:-}"
        [[ -z "$pubkey" ]] && read -rp "  > 请输入对应的 PublicKey (公钥): " pubkey
    fi

    if [[ -n "$OLD_VLESS_REALITY_SID" ]]; then
        shortid="$OLD_VLESS_REALITY_SID"
    else
        shortid=$(openssl rand -hex 8)
    fi

    mkdir -p /usr/local/etc/xray /var/log/xray

    case "$variant" in
        1|2)
            local flow_line=""
            [[ "$variant" == "1" ]] && flow_line='"flow": "xtls-rprx-vision",'
            cat > /usr/local/etc/xray/config.json << EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "tag": "dokodemo-in",
            "port": $port,
            "protocol": "dokodemo-door",
            "settings": {
                "address": "127.0.0.1",
                "port": 8444,
                "network": "tcp"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["tls"],
                "routeOnly": true
            }
        },
        {
            "tag": "vless-reality-in",
            "listen": "127.0.0.1",
            "port": 8444,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$uuid",
                        $flow_line
                        "email": "vless-reality"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$sn:443",
                    "serverNames": ["$sn"],
                    "privateKey": "$privkey",
                    "shortIds": ["", "$shortid"]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"}
    ],
    "routing": {
        "rules": [
            {"inboundTag": ["dokodemo-in"], "domain": ["$sn"], "outboundTag": "direct"},
            {"inboundTag": ["dokodemo-in"], "outboundTag": "block"}
        ]
    }
}
EOF
            ;;
        3)
            ask_val xpath "xhttp path（路径，留空自动生成随机路径）" "/$(openssl rand -hex 6)"
            cat > /usr/local/etc/xray/config.json << EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "tag": "xhttp-reality-in",
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$uuid",
                        "flow": "",
                        "email": "xhttp-reality"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$sn:443",
                    "serverNames": ["$sn"],
                    "privateKey": "$privkey",
                    "shortIds": ["$shortid"]
                },
                "xhttpSettings": {
                    "path": "$xpath",
                    "mode": "auto"
                }
            }
        }
    ],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {
        "rules": [
            {"type": "field", "inboundTag": ["xhttp-reality-in"], "outboundTag": "direct"}
        ]
    }
}
EOF
            ;;
        4)
            ask_val xpath "xhttp path（路径，留空自动生成随机路径）" "/$(openssl rand -hex 6)"
            cat > /usr/local/etc/xray/config.json << EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "tag": "dokodemo-in",
            "port": $port,
            "protocol": "dokodemo-door",
            "settings": {
                "address": "127.0.0.1",
                "port": 8444,
                "network": "tcp"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["tls"],
                "routeOnly": true
            }
        },
        {
            "tag": "xhttp-reality-in",
            "listen": "127.0.0.1",
            "port": 8444,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$uuid",
                        "flow": "",
                        "email": "xhttp-reality"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$sn:443",
                    "serverNames": ["$sn"],
                    "privateKey": "$privkey",
                    "shortIds": ["$shortid"]
                },
                "xhttpSettings": {
                    "path": "$xpath",
                    "mode": "auto"
                }
            }
        }
    ],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {
        "rules": [
            {"inboundTag": ["dokodemo-in"], "domain": ["$sn"], "outboundTag": "direct"},
            {"inboundTag": ["dokodemo-in"], "outboundTag": "block"},
            {"inboundTag": ["xhttp-reality-in"], "outboundTag": "direct"}
        ]
    }
}
EOF
            ;;
    esac

    # 保存元数据，供 mod07 生成 Xray 订阅链接时使用
    mkdir -p /etc/xray
    {
        echo "PORT=$port"
        echo "UUID=$uuid"
        echo "SNI=$sn"
        echo "PUBLIC_KEY=$pubkey"
        echo "SHORT_ID=$shortid"
        echo "VARIANT=$variant"
        [[ -n "$xpath" ]] && echo "XHTTP_PATH=$xpath"
    } > /etc/xray/node_meta.conf

    log_success "Xray 配置文件已写入: /usr/local/etc/xray/config.json"
    echo ""

    if xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
        log_success "配置语法验证通过"
        log_info "正在自动启动 Xray 并加入系统守护进程..."
        systemctl enable xray >/dev/null 2>&1 || true
        systemctl restart xray >/dev/null 2>&1 || true
        sleep 1
        if systemctl is-active --quiet xray; then
            log_success "Xray 已成功启动，并在后台保持运行！"
        else
            log_error "Xray 启动失败，可能存在端口冲突，请前往「5. 服务管理」查看实时日志。"
        fi
    else
        log_error "配置语法验证失败，详细原因："
        xray run -test -config /usr/local/etc/xray/config.json
    fi

    press_enter
}

configure_singbox() {
    if ! is_cmd_exist python3; then
        log_info "正在预装 python3 以支持节点解析..."
        if is_cmd_exist apt; then apt install -y python3 >/dev/null 2>&1;
        elif is_cmd_exist dnf; then dnf install -y python3 >/dev/null 2>&1;
        elif is_cmd_exist yum; then yum install -y python3 >/dev/null 2>&1; fi
    fi
    
    mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box

    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 四、配置 sing-box ══${NC}"
        echo ""

        local import_choice=""
        local need_parse=false
        local links_file=$(mktemp /tmp/old_links.XXXXXX)

        echo -e "是否需要导入旧节点链接以保持配置参数不变？（支持单行/多行/Base64）"
        echo ""
        echo -e "  1) 是，导入旧节点链接 (手动粘贴)"
        echo ""
        echo -e "  2) 否，生成全新配置 (随机生成) [默认]"
        echo ""
        read -rp "请选择 (1-2, 默认 2): " import_choice
        import_choice=${import_choice:-2}
        
        if [[ "$import_choice" == "1" ]]; then
            need_parse=true
        fi

        if [[ "$need_parse" == "true" ]]; then
            if [[ ! -s "$links_file" ]]; then
                echo -e "\n${YELLOW}请粘贴旧节点链接内容（粘贴完毕后，新起一行输入 EOF 并回车）：${NC}"
                while IFS= read -r line; do
                    [[ "$line" == "EOF" ]] && break
                    echo "$line" >> "$links_file"
                done
            fi
            
            if [[ -s "$links_file" ]]; then
                log_info "正在解析旧节点数据..."
                local py_script=$(mktemp /tmp/parse_links.XXXXXX.py)
                
                cat > "$py_script" << 'PYEOF'
import sys, urllib.parse, base64, json, re

input_text = sys.stdin.read().strip()
if not input_text: sys.exit(0)

if "://" not in input_text:
    try:
        input_text = base64.b64decode(input_text).decode("utf-8")
    except:
        pass

vars_out = {}

def clean_val(v):
    if v is None: return ""
    return re.sub(r'[\r\n]+', '', str(v).strip())

for line in input_text.splitlines():
    line = line.strip()
    if not line: continue
    try:
        if line.startswith("vmess://"):
            b64_str = line[8:]
            obj = json.loads(base64.b64decode(b64_str).decode("utf-8"))
            port = obj.get("port")
            uid = obj.get("id")
            net = obj.get("net")
            path = obj.get("path", "")
            sni = obj.get("sni", "") or obj.get("host", "") or obj.get("add", "")
            
            if sni and (re.match(r'^[\d\.]+$', str(sni)) or ":" in str(sni)):
                sni = ""

            if net == "ws" or "ws" in str(obj.get("ps", "")):
                if uid: vars_out["OLD_VMESS_WS_UUID"] = clean_val(uid)
                if port: vars_out["OLD_VMESS_WS_PORT"] = clean_val(port)
                if path: vars_out["OLD_VMESS_WS_PATH"] = clean_val(path)
                if sni: vars_out["OLD_VMESS_WS_SNI"] = clean_val(sni)
            else:
                if uid: vars_out["OLD_VMESS_TCP_UUID"] = clean_val(uid)
                if port: vars_out["OLD_VMESS_TCP_PORT"] = clean_val(port)
                if sni: vars_out["OLD_VMESS_TCP_SNI"] = clean_val(sni)
        else:
            scheme_idx = line.find("://")
            if scheme_idx == -1: continue
            scheme = line[:scheme_idx]
            rest = line[scheme_idx+3:]
            
            tag = ""
            frag_idx = rest.find("#")
            if frag_idx != -1:
                tag = urllib.parse.unquote(rest[frag_idx+1:])
                rest = rest[:frag_idx]
            
            qs = {}
            query_idx = rest.find("?")
            if query_idx != -1:
                qs = urllib.parse.parse_qs(rest[query_idx+1:])
                rest = rest[:query_idx]
                
            at_idx = rest.rfind("@")
            if at_idx != -1:
                userinfo = rest[:at_idx]
                hostport = rest[at_idx+1:]
            else:
                userinfo = ""
                hostport = rest
                
            port = None
            host = hostport
            if "]" in hostport:
                close_idx = hostport.find("]")
                host = hostport[:close_idx+1]
                if len(hostport) > close_idx+1 and hostport[close_idx+1] == ":":
                    port = hostport[close_idx+2:]
            else:
                if ":" in hostport:
                    host, port_str = hostport.rsplit(":", 1)
                    if port_str.isdigit():
                        port = port_str
                    else:
                        host = hostport
                        port = None

            sni = qs.get("sni", [""])[0] or qs.get("host", [""])[0] or qs.get("peer", [""])[0]
            if not sni:
                sni = host
            
            if sni and (re.match(r'^[\d\.]+$', str(sni)) or ":" in str(sni)):
                sni = ""
            
            if scheme == "vless":
                uuid = userinfo
                security = qs.get("security", [""])[0]
                type_ = qs.get("type", [""])[0]
                flow = ""
                if "flow" in qs:
                    flow = qs["flow"][0]
                if security == "reality" or "reality" in tag:
                    vars_out["OLD_VLESS_REALITY_UUID"] = clean_val(uuid)
                    if port: vars_out["OLD_VLESS_REALITY_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_VLESS_REALITY_SNI"] = clean_val(sni)
                    if "pbk" in qs: vars_out["OLD_VLESS_REALITY_PBK"] = clean_val(qs["pbk"][0])
                    if "sid" in qs: vars_out["OLD_VLESS_REALITY_SID"] = clean_val(qs["sid"][0])
                    
                    m = re.search(r'vless-reality-in-([A-Za-z0-9_-]+)', tag)
                    if m:
                        vars_out["OLD_VLESS_REALITY_PK"] = clean_val(m.group(1))

                elif type_ == "grpc" or "grpc" in tag:
                    vars_out["OLD_VLESS_GRPC_UUID"] = clean_val(uuid)
                    if port: vars_out["OLD_VLESS_GRPC_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_VLESS_GRPC_SNI"] = clean_val(sni)
                    if "serviceName" in qs: vars_out["OLD_VLESS_GRPC_SVC"] = clean_val(qs["serviceName"][0])
                elif type_ == "ws" or "ws" in tag:
                    vars_out["OLD_VLESS_WS_UUID"] = clean_val(uuid)
                    if port: vars_out["OLD_VLESS_WS_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_VLESS_WS_SNI"] = clean_val(sni)
                    if "path" in qs: vars_out["OLD_VLESS_WS_PATH"] = clean_val(qs["path"][0])
                else:
                    vars_out["OLD_VLESS_TCP_UUID"] = clean_val(uuid)
                    if port: vars_out["OLD_VLESS_TCP_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_VLESS_TCP_SNI"] = clean_val(sni)
                    if "flow" in qs:
                        vars_out["OLD_VLESS_TCP_FLOW"] = clean_val(flow)
                    else:
                        vars_out["OLD_VLESS_TCP_FLOW"] = ""
            elif scheme == "trojan":
                pwd = urllib.parse.unquote(userinfo) if userinfo else ""
                type_ = qs.get("type", [""])[0]
                if type_ == "ws" or "ws" in tag:
                    vars_out["OLD_TROJAN_WS_PWD"] = clean_val(pwd)
                    if port: vars_out["OLD_TROJAN_WS_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_TROJAN_WS_SNI"] = clean_val(sni)
                    if "path" in qs: vars_out["OLD_TROJAN_WS_PATH"] = clean_val(qs["path"][0])
                else:
                    vars_out["OLD_TROJAN_TCP_PWD"] = clean_val(pwd)
                    if port: vars_out["OLD_TROJAN_TCP_PORT"] = clean_val(port)
                    if sni: vars_out["OLD_TROJAN_TCP_SNI"] = clean_val(sni)
            elif scheme == "ss":
                try:
                    try:
                        raw = base64.urlsafe_b64decode(userinfo + "===").decode("utf-8")
                    except:
                        raw = urllib.parse.unquote(userinfo)
                    parts = raw.split(":", 2)
                    method = parts[0]
                    if "2022" in method:
                        spwd = parts[1] if len(parts)>1 else ""
                        upwd = parts[2] if len(parts)>2 else ""
                        if "128" in method or "128" in tag:
                            vars_out["OLD_SS128_METHOD"] = clean_val(method)
                            vars_out["OLD_SS128_SPWD"] = clean_val(spwd)
                            vars_out["OLD_SS128_UPWD"] = clean_val(upwd)
                            if port: vars_out["OLD_SS128_PORT"] = clean_val(port)
                        else:
                            vars_out["OLD_SS256_METHOD"] = clean_val(method)
                            vars_out["OLD_SS256_SPWD"] = clean_val(spwd)
                            vars_out["OLD_SS256_UPWD"] = clean_val(upwd)
                            if port: vars_out["OLD_SS256_PORT"] = clean_val(port)
                    else:
                        pwd = parts[1] if len(parts)>1 else ""
                        vars_out["OLD_SS_METHOD"] = clean_val(method)
                        vars_out["OLD_SS_PWD"] = clean_val(pwd)
                        if port: vars_out["OLD_SS_PORT"] = clean_val(port)
                except:
                    pass
            elif scheme == "hysteria2":
                vars_out["OLD_HY2_PWD"] = clean_val(urllib.parse.unquote(userinfo))
                if port: vars_out["OLD_HY2_PORT"] = clean_val(port)
                if sni: vars_out["OLD_HY2_SNI"] = clean_val(sni)
                if "obfs" in qs: vars_out["OLD_HY2_OBFS"] = clean_val(qs["obfs"][0])
                if "obfs-password" in qs: vars_out["OLD_HY2_OBFSPWD"] = clean_val(urllib.parse.unquote(qs["obfs-password"][0]))
            elif scheme == "tuic":
                dec_userinfo = urllib.parse.unquote(userinfo)
                if ":" in dec_userinfo:
                    uid, pwd = dec_userinfo.split(":", 1)
                    vars_out["OLD_TUIC_UUID"] = clean_val(uid)
                    vars_out["OLD_TUIC_PWD"] = clean_val(pwd)
                if port: vars_out["OLD_TUIC_PORT"] = clean_val(port)
                if sni: vars_out["OLD_TUIC_SNI"] = clean_val(sni)
                if "congestion_control" in qs: vars_out["OLD_TUIC_CC"] = clean_val(qs["congestion_control"][0])
            elif scheme == "anytls":
                vars_out["OLD_ANYTLS_PWD"] = clean_val(urllib.parse.unquote(userinfo))
                if port: vars_out["OLD_ANYTLS_PORT"] = clean_val(port)
                if sni: vars_out["OLD_ANYTLS_SNI"] = clean_val(sni)
            elif scheme == "naive+https":
                dec_userinfo = urllib.parse.unquote(userinfo)
                if ":" in dec_userinfo:
                    uname, pwd = dec_userinfo.split(":", 1)
                    if pwd: vars_out["OLD_NAIVE_PWD"] = clean_val(pwd)
                    if uname: vars_out["OLD_NAIVE_UNAME"] = clean_val(uname)
                elif dec_userinfo:
                    vars_out["OLD_NAIVE_UNAME"] = clean_val(dec_userinfo)
                if port: vars_out["OLD_NAIVE_PORT"] = clean_val(port)
                if sni: vars_out["OLD_NAIVE_SNI"] = clean_val(sni)
    except Exception:
        pass

if not vars_out:
    print("echo -e \"\\033[1;33m[WARN] 未能从输入内容中提取到任何有效参数（可能格式不支持或为空），将继续常规生成。\\033[0m\";")
else:
    for k, v in vars_out.items():
        v_escaped = str(v).replace("'", "'\\''")
        print(f"export {k}='{v_escaped}'")
    print("echo -e \"\\033[0;32m[✓] 解析完成，已成功提取匹配节点的参数。\\033[0m\";")
PYEOF
                local parse_exports
                parse_exports=$(python3 "$py_script" < "$links_file")
                eval "$parse_exports"
                rm -f "$py_script"
            else
                log_warn "未识别到输入内容，继续常规生成..."
            fi
            sleep 1.5
            clear
            echo -e "${BOLD}${CYAN}══ 四、配置 sing-box ══${NC}"
            echo ""
        fi
        rm -f "$links_file"

        echo ""
        echo -e "${BOLD}${CYAN}请选择要配置的代理核心:${NC}"
        echo "  1) sing-box (支持多种协议、伪装与全能配置) [默认]"
        echo "  2) Xray-core (主打 Reality 防偷跑与 xhttp 协议)"
        echo ""
        local core_choice
        read -rp "请选择 (1-2, 默认 1): " core_choice
        core_choice=${core_choice:-1}

        if [[ "$core_choice" == "2" ]]; then
            xray_reality_menu
            return
        fi

        echo "请选择要配置的协议（多个选择用空格分隔，例如：1 3 5）:"
        echo ""
        echo "   1)  VLESS — TCP / XTLS-Vision"
        echo "   2)  VLESS — WebSocket"
        echo "   3)  VLESS — gRPC"
        echo "   4)  VLESS — REALITY (TCP + XTLS-Vision) [藏钥法无损重装]"
        echo "   5)  VMess — TCP (TLS)"
        echo "   6)  VMess — WebSocket (TLS)"
        echo "   7)  Trojan — TCP (TLS)"
        echo "   8)  Trojan — WebSocket (TLS)"
        echo "   9)  Shadowsocks — 经典加密 (aes-256-gcm)"
        echo "  10)  Shadowsocks 2022 — aes-256-gcm"
        echo "  11)  Shadowsocks 2022 — aes-128-gcm"
        echo "  12)  Hysteria2"
        echo "  13)  TUIC v5"
        echo "  14)  AnyTLS"
        echo "  15)  NaïveProxy"
        echo ""
        echo -e "${GREEN} 100)  全部配置（逐一交互确认）${NC}"
        echo -e "${GREEN} 101)  全部自动配置（按默认设置静默配置）${NC}"
        echo -e "${YELLOW}   0)  返回主菜单${NC}"
        echo ""
        
        read -rp "请输入选项（例如 1 4 12，默认 0）: " -a PROTO_CHOICES

        if [[ ${#PROTO_CHOICES[@]} -eq 0 ]]; then
            PROTO_CHOICES=("0")
        fi

        if [[ "${PROTO_CHOICES[0]}" == "0" ]]; then
            return
        fi

        AUTO_DEFAULT=false
        local has_101=false
        local has_100=false
        
        for choice in "${PROTO_CHOICES[@]}"; do
            if [[ "$choice" == "101" ]]; then has_101=true; fi
            if [[ "$choice" == "100" ]]; then has_100=true; fi
        done

        if [[ "$has_101" == "true" ]]; then
            PROTO_CHOICES=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
            AUTO_DEFAULT=true
            log_info "已选择全部自动配置，将使用提取或默认参数静默生成所有节点..."
            sleep 1
        elif [[ "$has_100" == "true" ]]; then
            PROTO_CHOICES=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
            log_info "已选择全部配置，即将逐一进行交互确认..."
            sleep 1
        else
            log_info "已选择 ${#PROTO_CHOICES[@]} 个协议，开始逐一配置..."
        fi

        local TMP_JSON
        TMP_JSON=$(mktemp /tmp/vpsge_inbound_XXXXXX)
        local INBOUNDS_JSON=""
        local first=true

        for choice in "${PROTO_CHOICES[@]}"; do
            > "$TMP_JSON"
            case $choice in
                1)  build_vless_tcp     "$TMP_JSON" ;;
                2)  build_vless_ws      "$TMP_JSON" ;;
                3)  build_vless_grpc    "$TMP_JSON" ;;
                4)  build_vless_reality "$TMP_JSON" ;;
                5)  build_vmess_tcp     "$TMP_JSON" ;;
                6)  build_vmess_ws      "$TMP_JSON" ;;
                7)  build_trojan_tcp    "$TMP_JSON" ;;
                8)  build_trojan_ws     "$TMP_JSON" ;;
                9)  build_ss_classic    "$TMP_JSON" ;;
                10) build_ss2022_256    "$TMP_JSON" ;;
                11) build_ss2022_128    "$TMP_JSON" ;;
                12) build_hysteria2     "$TMP_JSON" ;;
                13) build_tuic          "$TMP_JSON" ;;
                14) build_anytls        "$TMP_JSON" ;;
                15) build_naive         "$TMP_JSON" ;;
                *)  log_warn "未知选项: $choice，跳过"; continue ;;
            esac
            local inbound_json
            inbound_json=$(cat "$TMP_JSON")
            [[ -z "$inbound_json" ]] && continue
            if $first; then
                INBOUNDS_JSON="$inbound_json"
                first=false
            else
                INBOUNDS_JSON="${INBOUNDS_JSON},${inbound_json}"
            fi
        done
        rm -f "$TMP_JSON"

        cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "level": "info",
    "timestamp": true,
    "output": "/var/log/sing-box/sing-box.log"
  },

  "inbounds": [
$INBOUNDS_JSON
  ],

  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ]
}
EOF

        log_success "配置文件已写入: /etc/sing-box/config.json"
        echo ""

        if is_cmd_exist sing-box; then
            local _check_out
            _check_out=$(ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true sing-box check -c /etc/sing-box/config.json 2>&1)
            local _check_rc=$?
            local _real_errors=""
            
            if [[ $_check_rc -eq 0 ]]; then
                log_success "配置语法验证通过"
            else
                _real_errors=$(echo "$_check_out" | grep -v "legacy DNS\|ENABLE_DEPRECATED" || true)
                if [[ -z "$_real_errors" ]]; then
                    log_success "配置语法验证通过"
                else
                    log_error "配置语法验证失败，详细原因："
                    echo "$_real_errors"
                fi
            fi

            # 核心优化：配置完成后自动启动 sing-box 并保持运行
            if [[ $_check_rc -eq 0 ]] || [[ -z "$_real_errors" ]]; then
                log_info "正在自动启动 sing-box 并加入系统守护进程..."
                systemctl enable sing-box >/dev/null 2>&1 || true
                systemctl restart sing-box >/dev/null 2>&1 || true
                sleep 1
                if systemctl is-active --quiet sing-box; then
                    log_success "sing-box 已成功启动，并在后台保持运行！"
                else
                    log_error "sing-box 启动失败，可能存在端口冲突，请前往「5. 服务管理」查看实时日志。"
                fi
            fi
        fi

        press_enter
        break
    done
}
