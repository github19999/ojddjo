#!/bin/bash
# ================================================================
#   服务器一键管理脚本 (vpsge)
#   版本号：vpsge-v9.2
#   主程序入口 — 加载所有模块后启动主菜单
# ================================================================

set -e

# ── 模块加载 ──
# 脚本所在目录（兼容直接运行和 source 运行）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/mod01_globals.sh"
source "$SCRIPT_DIR/mod02_basic_security.sh"
source "$SCRIPT_DIR/mod03_ssl.sh"
source "$SCRIPT_DIR/mod04_install_service.sh"
source "$SCRIPT_DIR/mod05_singbox_config.sh"
source "$SCRIPT_DIR/mod06_service_mgmt.sh"
source "$SCRIPT_DIR/mod07_gen_links.sh"


# ────────────────────────────────────────────────────────────────
#  全部执行 1→6
# ────────────────────────────────────────────────────────────────
run_all() {
    clear
    echo -e "${BOLD}${YELLOW}══ 全部执行 1→6 ══${NC}"
    echo ""
    echo "将依次执行："
    echo "  1. 基础安全设置（SSH/BBR/fail2ban）"
    echo "  2. SSL 证书申请"
    echo "  3. 安装 sing-box"
    echo "  4. 配置 sing-box 协议"
    echo "  5. 启动 sing-box 服务"
    echo "  6. 生成节点链接"
    echo ""
    read -rp "确认继续？(y/N): " c
    [[ "${c,,}" != "y" ]] && return

    detect_distro
    bootstrap_packages

    echo ""
    echo -e "${BLUE}── 步骤 1：基础安全设置 ──${NC}"
    setup_ssh_key
    disable_password_login
    change_ssh_port
    enable_bbr
    configure_ip_protocol
    setup_fail2ban

    echo ""
    echo -e "${BLUE}── 步骤 2：SSL 证书 ──${NC}"
    deploy_ssl

    echo ""
    echo -e "${BLUE}── 步骤 3：安装 sing-box ──${NC}"
    bash <(curl -fsSL https://sing-box.app/deb-install.sh) 2>/dev/null || true
    mkdir -p /etc/sing-box /var/log/sing-box /var/lib/sing-box

    echo ""
    echo -e "${BLUE}── 步骤 4：配置 sing-box ──${NC}"
    configure_singbox

    echo ""
    echo -e "${BLUE}── 步骤 5：sing-box 服务 ──${NC}"
    systemctl enable sing-box
    systemctl restart sing-box
    systemctl is-active --quiet sing-box && log_success "sing-box 运行中" || log_warn "sing-box 启动失败，请检查配置"

    echo ""
    echo -e "${BLUE}── 步骤 6：生成节点链接 ──${NC}"
    generate_links

    press_enter
}

# ────────────────────────────────────────────────────────────────
#  主菜单
# ────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}"
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║          服务器一键管理脚本  ($SCRIPT_VERSION)            ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo "  部署流程:"
        echo -e "   ${GREEN}1.${NC} 基础设置（SSH/fail2ban/BBR）       ${GREEN}2.${NC} SSL 证书申请与安装"
        echo -e "   ${GREEN}3.${NC} 安装服务 (包含 Docker/拓展)        ${GREEN}4.${NC} 配置 sing-box 节点"
        echo -e "   ${GREEN}5.${NC} 服务管理 (启停/日志/面板维护)      ${GREEN}6.${NC} 生成节点订阅链接"
        echo ""
        echo -e "   ${YELLOW}7.${NC} ── 全部执行（1→6）──"
        echo ""
        echo "══════════════════════════════════════════════════════"
        echo "   0. 退出"
        echo ""
        read -rp "请选择: " opt
        case $opt in
            1) detect_distro; menu_basic ;;
            2) menu_ssl ;;
            3) detect_distro; menu_install_service ;;
            4) configure_singbox ;;
            5) menu_service ;;
            6) menu_links ;;
            7) detect_distro; run_all ;;
            0)
                echo ""
                echo -e "${GREEN}感谢使用，再见！${NC}"
                echo -e "${YELLOW}提示：退出脚本后，随时可以输入快捷命令 ${BOLD}${GREEN}vpsge${NC}${YELLOW} 重新进入主菜单。${NC}"
                echo ""
                exit 0 ;;
            *)
                log_warn "无效选项，请重新选择"
                sleep 1 ;;
        esac
    done
}

# ────────────────────────────────────────────────────────────────
#  安装 vpsge 快捷命令
# ────────────────────────────────────────────────────────────────
install_self() {
    local target="/usr/bin/vpsge"
    
    # 如果当前正在 /usr/bin/vpsge 执行，则无需安装
    [[ "$0" == "$target" ]] && return 0

    # 判断是否为本地文件正常运行，若是则直接复制
    if [[ -f "$0" && "$0" != *"bash"* && "$0" != *"/dev/fd/"* ]]; then
        cp -f "$0" "$target"
        chmod 755 "$target"
    else
        # 否则判定为通过 bash <(curl ...) 执行流，强制从直链拉取文件创建快捷命令
        curl -fsSL --connect-timeout 10 "$https://raw.githubusercontent.com/github19999/ojddjo/main/vpsge.sh" -o "$target" 2>/dev/null || \
        wget -qO "$target" "$https://raw.githubusercontent.com/github19999/ojddjo/main/vpsge.sh" 2>/dev/null
        
        if [[ -f "$target" ]]; then
            chmod 755 "$target"
        fi
    fi

    # 验证是否安装成功并刷新 hash
    if is_cmd_exist vpsge; then
        log_success "已安装快捷命令: vpsge"
    fi
}

# ────────────────────────────────────────────────────────────────
#  入口
# ────────────────────────────────────────────────────────────────
check_root
detect_distro
install_self
