#!/bin/bash
# ── mod06_service_mgmt.sh ── 由 vpsge.sh 通过 source 加载，请勿单独执行 ──


# ────────────────────────────────────────────────────────────────
#  管理菜单及更新功能
# ────────────────────────────────────────────────────────────────
update_script() {
    clear
    echo -e "${BOLD}${CYAN}══ 更新脚本 ══${NC}"
    echo ""
    log_step "正在检查更新..."

    local target="/tmp/vpsge_update.sh"
    
    # 直接使用全局直链拉取更新
    if curl -fsSL --connect-timeout 10 --max-time 30 "$VPSGE_REMOTE_URL" -o "$target"; then
        if grep -q "vpsge" "$target"; then
            mv -f "$target" /usr/bin/vpsge
            chmod 755 /usr/bin/vpsge
            log_success "脚本已成功从 GitHub 拉取并更新至最新版本！"
            echo -e "${YELLOW}请重新输入命令 ${BOLD}${GREEN}vpsge${NC}${YELLOW} 以启动最新版。${NC}"
            exit 0
        else
            log_error "下载的文件验证失败，更新中止。"
        fi
    else
        log_error "下载脚本失败，请检查网络或 URL 是否正确。"
    fi
    rm -f "$target"
    press_enter
}

menu_manage_singbox() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 sing-box ══${NC}"
        echo ""
        
        local is_installed=false
        if is_cmd_exist sing-box || systemctl cat sing-box.service >/dev/null 2>&1; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if systemctl is-active --quiet sing-box 2>/dev/null; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 启动 sing-box"
        echo "  2) 停止 sing-box"
        echo "  3) 重启 sing-box 并查看状态"
        echo "  4) 查看完整状态 (systemctl status)"
        echo "  5) 设为开机自启"
        echo "  6) 取消开机自启"
        echo "  7) 查看是否开机自启"
        echo "  8) 实时查看日志"
        echo "  9) 验证配置文件"
        echo " 10) 一键修复配置（移除旧 dns/route 段）"
        echo " 11) 卸载 sing-box"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl start sing-box && log_success "sing-box 已启动"
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            2) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl stop sing-box && log_success "sing-box 已停止"
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            3)
                if [[ "$is_installed" == "true" ]]; then
                    systemctl restart sing-box
                    echo ""
                    systemctl status sing-box --no-pager || true
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            4) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl status sing-box --no-pager || true
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            5) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl enable sing-box && log_success "已设为开机自启"
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            6) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl disable sing-box && log_success "已取消开机自启"
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            7)
                if [[ "$is_installed" == "true" ]]; then
                    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
                        log_success "sing-box 已设为开机自启"
                    else
                        log_warn "sing-box 未设为开机自启"
                    fi
                else log_error "未安装 sing-box"; fi
                press_enter ;;
            8) 
                if [[ "$is_installed" == "true" ]]; then
                    journalctl -u sing-box -f --no-pager
                else log_error "未安装 sing-box"; press_enter; fi
                ;;
            9)
                if is_cmd_exist sing-box; then
                    local _sc_out
                    _sc_out=$(ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true sing-box check -c /etc/sing-box/config.json 2>&1)
                    local _sc_rc=$?
                    if [[ $_sc_rc -eq 0 ]]; then
                        log_success "配置验证通过"
                    else
                        local _sc_real
                        _sc_real=$(echo "$_sc_out" | grep -v "legacy DNS\|ENABLE_DEPRECATED" || true)
                        if [[ -z "$_sc_real" ]]; then
                            log_success "配置验证通过"
                        else
                            log_error "配置验证失败，详细原因："
                            echo "$_sc_real"
                        fi
                    fi
                else
                    log_error "sing-box 未安装"
                fi
                press_enter ;;
            10) fix_dns_format; press_enter ;;
            11) uninstall_singbox; press_enter ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_manage_nginx() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Nginx ══${NC}"
        echo ""
        
        local is_installed=false
        if is_cmd_exist nginx || systemctl cat nginx.service >/dev/null 2>&1; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if systemctl is-active --quiet nginx 2>/dev/null; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 启动 Nginx"
        echo "  2) 停止 Nginx"
        echo "  3) 重启 Nginx 并查看状态"
        echo "  4) 验证 Nginx 配置 (nginx -t)"
        echo "  5) 设为开机自启"
        echo "  6) 实时查看错误日志"
        echo "  7) 卸载 Nginx"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl start nginx && log_success "Nginx 已启动"
                else log_error "Nginx 未安装"; fi
                press_enter ;;
            2) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl stop nginx && log_success "Nginx 已停止"
                else log_error "Nginx 未安装"; fi
                press_enter ;;
            3)
                if [[ "$is_installed" == "true" ]]; then
                    systemctl restart nginx
                    echo ""
                    systemctl status nginx --no-pager || true
                else
                    log_error "Nginx 未安装"
                fi
                press_enter ;;
            4)
                if [[ "$is_installed" == "true" ]]; then
                    nginx -t && log_success "Nginx 配置验证通过" || log_error "Nginx 配置有误"
                else
                    log_error "Nginx 未安装"
                fi
                press_enter ;;
            5) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl enable nginx && log_success "Nginx 已设为开机自启"
                else log_error "Nginx 未安装"; fi
                press_enter ;;
            6) 
                if [[ -f /var/log/nginx/error.log ]]; then
                    tail -f /var/log/nginx/error.log
                else log_error "日志文件不存在或 Nginx 未安装"; press_enter; fi
                ;;
            7) uninstall_nginx; press_enter ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_manage_docker() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Docker 环境 ══${NC}"
        echo ""
        
        local is_installed=false
        if is_cmd_exist docker || systemctl cat docker.service >/dev/null 2>&1; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if systemctl is-active --quiet docker 2>/dev/null; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 启动 Docker"
        echo "  2) 停止 Docker"
        echo "  3) 重启 Docker"
        echo "  4) 查看 Docker 状态"
        echo "  5) 卸载 Docker"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl start docker && log_success "Docker 已启动"
                else log_error "Docker 未安装"; fi
                press_enter ;;
            2) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl stop docker && log_success "Docker 已停止"
                else log_error "Docker 未安装"; fi
                press_enter ;;
            3) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl restart docker && log_success "Docker 已重启"
                else log_error "Docker 未安装"; fi
                press_enter ;;
            4) 
                if [[ "$is_installed" == "true" ]]; then
                    systemctl status docker --no-pager || true
                else log_error "Docker 未安装"; fi
                press_enter ;;
            5) uninstall_docker; press_enter ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_manage_substore() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Sub-Store ══${NC}"
        echo ""
        
        local is_installed=false
        if is_cmd_exist docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^substore$"; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^substore$"; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 启动 Sub-Store"
        echo "  2) 停止 Sub-Store"
        echo "  3) 重启 Sub-Store"
        echo "  4) 查看实时日志"
        echo "  5) 找回面板访问地址"
        echo "  6) 卸载 Sub-Store"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) docker start substore 2>/dev/null && log_success "已启动" || log_error "操作失败/未安装"; press_enter ;;
            2) docker stop substore 2>/dev/null && log_success "已停止" || log_error "操作失败/未安装"; press_enter ;;
            3) docker restart substore 2>/dev/null && log_success "已重启" || log_error "操作失败/未安装"; press_enter ;;
            4) docker logs -f substore 2>/dev/null || log_error "操作失败/未安装"; press_enter ;;
            5)
                if [[ -f /root/docker/substore/domain.txt && -f /root/docker/substore/api_path.txt ]]; then
                    local p_sn=$(cat /root/docker/substore/domain.txt)
                    local p_api=$(cat /root/docker/substore/api_path.txt)
                    echo -e "  🌐 面板访问地址: ${GREEN}https://$p_sn:8443/?api=https://$p_sn:8443/$p_api${NC}"
                else
                    log_error "未找到配置信息，可能尚未安装。"
                fi
                press_enter
                ;;
            6)
                echo -e "${YELLOW}警告：这将彻底删除 Sub-Store 及其所有数据！${NC}"
                read -rp "确认卸载？(y/N): " choice
                if [[ "${choice,,}" == "y" ]]; then
                    docker stop substore 2>/dev/null || true
                    docker rm substore 2>/dev/null || true
                    rm -rf /root/docker/substore
                    log_success "Sub-Store 已彻底卸载"
                fi
                press_enter
                ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_manage_wallos() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Wallos ══${NC}"
        echo ""
        
        local is_installed=false
        if is_cmd_exist docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^wallos$"; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^wallos$"; then
                status_str="${GREEN}● 运行中${NC}"
            else
                status_str="${YELLOW}○ 已停止${NC}"
            fi
        fi

        echo -e "  服务状态: $status_str"
        echo ""
        echo "  1) 启动 Wallos"
        echo "  2) 停止 Wallos"
        echo "  3) 重启 Wallos"
        echo "  4) 查看实时日志"
        echo "  5) 找回面板访问地址"
        echo "  6) 卸载 Wallos"
        echo ""
        echo "  0) 返回上一级"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) docker start wallos 2>/dev/null && log_success "已启动" || log_error "操作失败/未安装"; press_enter ;;
            2) docker stop wallos 2>/dev/null && log_success "已停止" || log_error "操作失败/未安装"; press_enter ;;
            3) docker restart wallos 2>/dev/null && log_success "已重启" || log_error "操作失败/未安装"; press_enter ;;
            4) docker logs -f wallos 2>/dev/null || log_error "操作失败/未安装"; press_enter ;;
            5)
                if [[ -f /root/docker/wallos/domain.txt ]]; then
                    local w_sn=$(cat /root/docker/wallos/domain.txt)
                    echo -e "  🌐 面板访问地址: ${GREEN}https://$w_sn:8443${NC}"
                else
                    log_error "未找到配置信息，可能尚未安装。"
                fi
                press_enter
                ;;
            6)
                echo -e "${YELLOW}警告：这将彻底删除 Wallos 及其所有数据！${NC}"
                read -rp "确认卸载？(y/N): " choice
                if [[ "${choice,,}" == "y" ]]; then
                    docker stop wallos 2>/dev/null || true
                    docker rm wallos 2>/dev/null || true
                    rm -rf /root/docker/wallos
                    log_success "Wallos 已彻底卸载"
                fi
                press_enter
                ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_service() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 五、服务管理 ══${NC}"
        echo ""
        echo "  1) 管理 sing-box"
        echo "  2) 管理 Nginx"
        echo "  3) 管理 Docker"
        echo "  4) 管理 Sub-Store"
        echo "  5) 管理 Wallos"
        echo "  6) 管理 Realm (端口转发)"
        echo ""
        echo " 100) 更新脚本"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) menu_manage_singbox ;;
            2) menu_manage_nginx ;;
            3) menu_manage_docker ;;
            4) menu_manage_substore ;;
            5) menu_manage_wallos ;;
            6) menu_manage_realm ;;
            100) update_script ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

fix_dns_format() {
    local cfg="/etc/sing-box/config.json"
    [[ ! -f "$cfg" ]] && { log_error "配置文件不存在: $cfg"; return 1; }

    log_step "修复旧版 config.json（移除 geoip/dns/route，兼容 sing-box 1.12+）..."
    cp "$cfg" "${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
    log_info "已备份原文件"

    python3 << 'INNEREOF'
import json, re, sys

cfg_path = "/etc/sing-box/config.json"
with open(cfg_path) as f:
    raw = f.read()

clean = re.sub(r'(?<![:/])//[^
]*', '', raw)
try:
    obj = json.loads(clean)
except Exception as e:
    print(f"[ERROR] 解析配置失败: {e}")
    sys.exit(1)

changed = []

if "dns" in obj:
    del obj["dns"]
    changed.append("移除 dns 段")

if "route" in obj:
    del obj["route"]
    changed.append("移除 route 段（含 geoip 规则）")

if "outbounds" not in obj:
    obj["outbounds"] = [
        {"type": "direct", "tag": "direct"},
        {"type": "block",  "tag": "block"}
    ]
    changed.append("补充 outbounds")

if changed:
    with open(cfg_path, "w") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    print("[✓] 修复内容: " + " / ".join(changed))
else:
    print("[INFO] 配置已是最新格式，无需修复")
INNEREOF

    echo ""
    log_step "修复后验证..."
    hash -r 2>/dev/null || true
    if is_cmd_exist sing-box; then
        local _out _rc
        _out=$(sing-box check -c "$cfg" 2>&1)
        _rc=$?
        if [[ $_rc -eq 0 ]]; then
            log_success "配置验证通过"
            log_info "正在自动重启 sing-box 使配置生效..."
            systemctl restart sing-box >/dev/null 2>&1 || true
            if systemctl is-active --quiet sing-box; then
                log_success "sing-box 已成功重启并稳定运行！"
            else
                log_warn "sing-box 重启失败，请检查服务状态。"
            fi
        else
            log_warn "验证结果："
            echo "$_out"
            log_info "修复完成，但验证有警告，请手动检查配置。"
        fi
    fi
}
