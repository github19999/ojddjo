#!/bin/bash
# ================================================================
#   服务器一键管理脚本 (vpsge)
#   版本号：vpsge
#   主程序入口 — 加载所有模块后启动主菜单
# ================================================================

set -e

# ────────────────────────────────────────────────────────────────
#  全局直链配置（GitHub raw 地址，改仓库名时只需改这里）
# ────────────────────────────────────────────────────────────────
VPSGE_BASE_URL="https://raw.githubusercontent.com/github19999/ojddjo/main"
VPSGE_REMOTE_URL="${VPSGE_BASE_URL}/vpsge.sh"
SCRIPT_VERSION="vpsge"

# ────────────────────────────────────────────────────────────────
#  模块本地安装目录
# ────────────────────────────────────────────────────────────────
VPSGE_MODULE_DIR="/usr/lib/vpsge"

MODULES=(
    mod01_globals.sh
    mod02_basic_security.sh
    mod03_ssl.sh
    mod04_install_service.sh
    mod05_singbox_config.sh
    mod06_service_mgmt.sh
    mod07_gen_links.sh
)

# ────────────────────────────────────────────────────────────────
#  下载并加载所有模块
#  支持两种运行方式：
#    1) bash <(curl ...) — 从 GitHub 下载模块到本地后 source
#    2) vpsge（已安装快捷命令）— 直接从本地 source
# ────────────────────────────────────────────────────────────────
load_modules() {
    # 判断脚本是否以流方式运行（/dev/fd/ 或 bash 管道）
    local is_pipe=false
    if [[ "$0" == *"/dev/fd/"* || "$0" == "bash" || "$0" == "-bash" ]]; then
        is_pipe=true
    fi

    # 如果模块目录不存在，或以流方式运行，则重新下载所有模块
    if [[ "$is_pipe" == "true" ]] || [[ ! -d "$VPSGE_MODULE_DIR" ]]; then
        echo "正在从 GitHub 下载脚本模块，请稍候..."
        mkdir -p "$VPSGE_MODULE_DIR"

        local dl_ok=true
        for mod in "${MODULES[@]}"; do
            local url="${VPSGE_BASE_URL}/${mod}"
            local dest="${VPSGE_MODULE_DIR}/${mod}"
            if curl -fsSL --connect-timeout 15 "$url" -o "$dest" 2>/dev/null; then
                chmod 644 "$dest"
            elif wget -qO "$dest" "$url" 2>/dev/null; then
                chmod 644 "$dest"
            else
                echo "[ERROR] 下载失败: $url"
                dl_ok=false
            fi
        done

        if [[ "$dl_ok" == "false" ]]; then
            echo "[ERROR] 部分模块下载失败，请检查网络或 GitHub 地址是否正确。"
            exit 1
        fi
        echo "模块下载完成。"
        echo ""
    fi

    # 从本地目录 source 所有模块
    for mod in "${MODULES[@]}"; do
        local f="${VPSGE_MODULE_DIR}/${mod}"
        if [[ ! -f "$f" ]]; then
            echo "[ERROR] 模块文件缺失: $f"
            echo "请重新运行: bash <(curl -fsSL ${VPSGE_REMOTE_URL})"
            exit 1
        fi
        # shellcheck source=/dev/null
        source "$f"
    done
}

load_modules

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
#  将 vpsge.sh 复制到 /usr/bin/vpsge，此后直接输入 vpsge 即可启动
# ────────────────────────────────────────────────────────────────
install_self() {
    local target="/usr/bin/vpsge"

    # 如果当前已经在 /usr/bin/vpsge 运行，跳过
    [[ "$0" == "$target" ]] && return 0

    # 无论哪种方式运行，统一从 GitHub 拉取最新版写入快捷命令
    if curl -fsSL --connect-timeout 10 "$https://raw.githubusercontent.com/github19999/ojddjo/main/vpsge.sh" -o "$target" 2>/dev/null || \
       wget -qO "$target" "$https://raw.githubusercontent.com/github19999/ojddjo/main/vpsge.shL" 2>/dev/null; then
        chmod 755 "$target"
    fi

    if is_cmd_exist vpsge; then
        log_success "已安装快捷命令: vpsge  （下次直接输入 vpsge 即可）"
    fi
}

# ────────────────────────────────────────────────────────────────
#  入口
# ────────────────────────────────────────────────────────────────
check_root
detect_distro
install_self
main_menu
