#!/bin/bash
# ── mod01_globals.sh ── 由 vpsge.sh 通过 source 加载，请勿单独执行 ──

#!/bin/bash
# ================================================================
#   服务器一键管理脚本 (vpsge)
#   版本号：vpsge
#   集成：SSH安全加固 / SSL证书 / sing-box 安装配置 /节点生成 / Realm 转发
# ================================================================

# 遇到错误立即退出

# ────────────────────────────────────────────────────────────────
#  全局变量 & 直链配置
# ────────────────────────────────────────────────────────────────
VPSGE_REMOTE_URL="https://raw.githubusercontent.com/github19999/ojddjo/main/vpsge.sh"
SCRIPT_VERSION="vpsge"

# ────────────────────────────────────────────────────────────────
#  颜色 & 日志
# ────────────────────────────────────────────────────────────────
RED='[0;31m'
GREEN='[0;32m'
YELLOW='[1;33m'
BLUE='[0;34m'
PURPLE='[0;35m'
CYAN='[0;36m'
BOLD='[1m'
NC='[0m'

STOPPED_SERVICES=()
DOMAINS=()
MAIN_DOMAIN=""
CERT_DIR=""
OS=""
INSTALL_CMD=""
UPDATE_CMD=""
AUTO_DEFAULT=false

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }

press_enter() { echo ""; read -rp "$(echo -e "${CYAN}按 Enter 返回...${NC}")"; }

# ────────────────────────────────────────────────────────────────
#  强力全局命令探测 (无视 $PATH 缺失和 Hash 缓存异常)
# ────────────────────────────────────────────────────────────────
is_cmd_exist() {
    local cmd="$1"
    hash -r 2>/dev/null || true
    if command -v "$cmd" >/dev/null 2>&1; then return 0; fi
    for p in /usr/local/bin /usr/bin /usr/sbin /bin /sbin; do
        if [[ -x "$p/$cmd" ]]; then return 0; fi
    done
    return 1
}

# ────────────────────────────────────────────────────────────────
#  Root 检查
# ────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行，请使用 sudo 或切换到 root 用户"
        exit 1
    fi
}

# ────────────────────────────────────────────────────────────────
#  发行版检测
# ────────────────────────────────────────────────────────────────
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID%%.*}"
        PRETTY_NAME_CACHED="${PRETTY_NAME:-$DISTRO_ID}"
    else
        log_error "无法识别操作系统"
        exit 1
    fi

    case "$DISTRO_ID" in
        ubuntu|debian|raspbian) PKG_MANAGER="apt" ;;
        centos|rhel|almalinux|rocky|fedora)
            PKG_MANAGER="yum"
            is_cmd_exist dnf && PKG_MANAGER="dnf"
            ;;
        *) log_warn "未经测试的发行版: $DISTRO_ID，尝试使用 apt"; PKG_MANAGER="apt" ;;
    esac
}

# ────────────────────────────────────────────────────────────────
#  随机生成工具函数
# ────────────────────────────────────────────────────────────────
gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"; }

gen_password() {
    local length="${1:-24}"
    tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c "$length" 2>/dev/null || \
    python3 -c "import secrets,string; print(secrets.token_urlsafe($length))"
}

gen_ss2022_key_256() { openssl rand -base64 32; }
gen_ss2022_key_128() { openssl rand -base64 16; }

gen_short_id() { openssl rand -hex 4; }

gen_naive_username() {
    tr -dc 'a-z0-9' </dev/urandom | head -c 12 2>/dev/null || echo "naiveuser$(shuf -i 1000-9999 -n1)"
}

# ────────────────────────────────────────────────────────────────
#  通用输入函数 (含自动默认支持 & 重装检测)
# ────────────────────────────────────────────────────────────────
ask_val() {
    local varname="$1"
    local label="$2"
    local default="$3"
    local input result

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        result="$default"
        echo -e "  ${GREEN}✓ [自动] ${label} = ${result}${NC}"
        printf -v "$varname" '%s' "$result"
        return
    fi

    echo -e "  ${CYAN}◆ ${label}${NC}  (默认: ${YELLOW}${default}${NC}，回车确认)"
    read -rp "  > " input
    result="${input:-$default}"
    echo -e "  ${GREEN}✓ ${label} = ${result}${NC}"
    echo ""
    printf -v "$varname" '%s' "$result"
}

ask_random() {
    local varname="$1"
    local label="$2"
    local randval="$3"
    local input result

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        result="$randval"
        echo -e "  ${GREEN}✓ [自动] ${label} = ${result}${NC}"
        printf -v "$varname" '%s' "$result"
        return
    fi

    echo -e "  ${CYAN}◆ ${label}${NC}"
    echo -e "    生成或提取的值: ${YELLOW}${randval}${NC}"
    echo -e "    (回车使用该值，或输入自定义值覆盖)"
    read -rp "  > " input
    result="${input:-$randval}"
    echo -e "  ${GREEN}✓ ${label} = ${result}${NC}"
    echo ""
    printf -v "$varname" '%s' "$result"
}

ask() {
    local prompt="$1" default="$2"
    ask_val REPLY_VAL "$prompt" "$default"
}

prompt_reinstall() {
    local svc_name="$1"
    echo -e "
  ${YELLOW}检测到 ${svc_name} 已经部署过了！${NC}"
    echo "  1) 不重新安装 (保留现有) [默认]"
    echo "  2) 重新安装 (覆盖更新)"
    local choice
    # 30秒倒计时，到期自动选择 1
    read -t 30 -rp "  > 请选择 (1-2, 30秒后默认 1): " choice || true
    choice=${choice:-1}
    echo ""
    if [[ "$choice" == "1" ]]; then
        log_info "已选择跳过 ${svc_name}，继续后续操作。"
        return 1 # Skip
    else
        log_info "准备重新部署 ${svc_name}..."
        return 0 # Reinstall
    fi
}

# ────────────────────────────────────────────────────────────────
#  读取已安装证书域名
# ────────────────────────────────────────────────────────────────
get_cert_domains() {
    local domains=()

    if [[ -d /root/.acme.sh ]]; then
        while IFS= read -r dir; do
            local d
            d=$(basename "$dir")
            [[ -z "$d" || "$d" == "__INTERACT__" || "$d" == "ca" || "$d" == "account.conf" ]] && continue
            [[ "$d" == *_ecc ]] && continue
            [[ ! -d "$dir" ]] && continue

            domains+=("$d")

            local conf_file="$dir/${d}.conf"
            if [[ -f "$conf_file" ]]; then
                local le_alt
                le_alt=$(grep -oP "(?<=Le_Alt=')[^']+" "$conf_file" 2>/dev/null || true)
                if [[ -n "$le_alt" ]]; then
                    while IFS=, read -ra alt_list; do
                        for alt in "${alt_list[@]}"; do
                            alt="${alt// /}"
                            [[ -n "$alt" && "$alt" == *.* ]] && domains+=("$alt")
                        done
                    done <<< "$le_alt"
                fi
            fi

            local cert_file="$dir/fullchain.cer"
            [[ ! -f "$cert_file" ]] && cert_file="$dir/${d}.cer"
            if [[ -f "$cert_file" ]]; then
                while IFS= read -r san; do
                    san="${san#DNS:}"
                    san="${san// /}"
                    [[ -n "$san" && "$san" == *.* && "$san" != *\** ]] && domains+=("$san")
                done < <(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null | grep -oP "DNS:[^,\s]+" | tr ',' '
')
            fi

        done < <(find /root/.acme.sh -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi

    while IFS= read -r crt; do
        [[ -z "$crt" ]] && continue
        local cn
        cn=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | grep -oP '(?<=CN\s=\s)[^,/]+' | head -1)
        [[ -n "$cn" && "$cn" == *.* ]] && domains+=("$cn")
        while IFS= read -r san; do
            san="${san#DNS:}"
            san="${san// /}"
            [[ -n "$san" && "$san" == *.* && "$san" != *\** ]] && domains+=("$san")
        done < <(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -oP "DNS:[^,\s]+" | tr ',' '
')
    done < <(find /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl 2>/dev/null \
        \( -name "*.crt" -o -name "fullchain.cer" -o -name "*.pem" \) | head -30)

    printf '%s
' "${domains[@]}" | sort -u | grep -v '^\*' | grep '\.' | grep -v ' ' || true
}

# ────────────────────────────────────────────────────────────────
#  选择 server_name
# ────────────────────────────────────────────────────────────────
select_server_name() {
    local default_sn="${1:-example.com}"
    local old_sni="$2"
    local target_idx="${3:-1}" # 默认选择的编号

    # 兼容原本传递 "true" 的情况（原本 wallos 可能传的是 "true"）
    if [[ "$target_idx" == "true" ]]; then
        target_idx=2
    fi

    echo ""
    echo -e "  ${CYAN}◆ 选择或输入域名 (server_name / SNI)${NC}"

    local domains=()
    mapfile -t domains < <(get_cert_domains 2>/dev/null)

    if [[ "$AUTO_DEFAULT" == "true" ]]; then
        if [[ -n "$old_sni" ]]; then
            SELECTED_SN="$old_sni"
        elif [[ ${#domains[@]} -ge "$target_idx" ]]; then
            SELECTED_SN="${domains[$((target_idx-1))]}"
        elif [[ ${#domains[@]} -gt 0 ]]; then
            SELECTED_SN="${domains[0]}"
        else
            SELECTED_SN="${default_sn}"
        fi
        echo -e "  ${GREEN}✓ [自动] 选中域名 = ${SELECTED_SN}${NC}"
        echo ""
        return
    fi

    if [[ -n "$old_sni" ]]; then
        echo -e "    ${YELLOW}检测到旧配置域名为: ${old_sni}${NC}"
        default_sn="$old_sni"
    fi

    if [[ ${#domains[@]} -gt 0 ]]; then
        echo -e "    检测到已安装证书，请选择："
        for i in "${!domains[@]}"; do
            echo -e "    ${YELLOW}$((i+1)))${NC} ${domains[$i]}"
        done
        local manual_idx=$(( ${#domains[@]} + 1 ))
        echo -e "    ${YELLOW}${manual_idx})${NC} 手动输入其他域名"
        echo ""
        
        # 如果指定的默认索引大于实际的域名数量，防错回退到 1
        local actual_default_idx=$target_idx
        if [[ "$actual_default_idx" -gt "${#domains[@]}" ]]; then
            actual_default_idx=1
        fi

        local sn_choice
        read -rp "  > (编号，默认 ${actual_default_idx}): " sn_choice
        sn_choice=${sn_choice:-$actual_default_idx}

        if [[ "$sn_choice" =~ ^[0-9]+$ ]] && [[ "$sn_choice" -ge 1 ]] && [[ "$sn_choice" -le "${#domains[@]}" ]]; then
            SELECTED_SN="${domains[$((sn_choice-1))]}"
        else
            read -rp "  > 手动输入域名 (默认 ${default_sn}): " SELECTED_SN
            SELECTED_SN="${SELECTED_SN:-$default_sn}"
        fi
    else
        echo -e "    （未检测到已安装证书，请手动输入）"
        read -rp "  > 域名 (默认 ${default_sn}): " SELECTED_SN
        SELECTED_SN="${SELECTED_SN:-$default_sn}"
    fi

    echo -e "  ${GREEN}✓ 选中域名 = ${SELECTED_SN}${NC}"
    echo ""
}

# ────────────────────────────────────────────────────────────────
#  自动定位证书路径
# ────────────────────────────────────────────────────────────────
ask_cert_paths() {
    local sn="$1"
    local auto_cert="" auto_key=""

    for d in /etc/ssl/private /etc/ssl/certs /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/${sn}.crt"           ]] && auto_cert="$d/${sn}.crt"           && break
        [[ -f "$d/fullchain.cer"       ]] && auto_cert="$d/fullchain.cer"       && break
        [[ -f "$d/${sn}/fullchain.cer" ]] && auto_cert="$d/${sn}/fullchain.cer" && break
    done
    for d in /etc/ssl/private /etc/nginx/ssl /home/ssl; do
        [[ -f "$d/${sn}.key"   ]] && auto_key="$d/${sn}.key"   && break
        [[ -f "$d/private.key" ]] && auto_key="$d/private.key" && break
    done
    [[ -z "$auto_cert" && -f "/root/.acme.sh/${sn}/fullchain.cer" ]] && auto_cert="/root/.acme.sh/${sn}/fullchain.cer"
    [[ -z "$auto_key"  && -f "/root/.acme.sh/${sn}/${sn}.key"     ]] && auto_key="/root/.acme.sh/${sn}/${sn}.key"

    local default_cert="${auto_cert:-/etc/ssl/private/fullchain.cer}"
    local default_key="${auto_key:-/etc/ssl/private/private.key}"

    ask_val CERT_PATH "cert_path（证书文件路径）" "$default_cert"
    ask_val KEY_PATH  "key_path（私钥文件路径）"  "$default_key"
}
