#!/bin/bash
# ── mod04_install_service.sh ── 由 vpsge.sh 通过 source 加载，请勿单独执行 ──
#
# ════════════════════════ 本次更新说明 (优化2) ════════════════════════
# 新增：Komari 探针监控面板的安装支持（最新稳定版 / 指定版本号 / 预发布Snapshot版）
#   - 部署方式与 Wallos / Sub-Store 完全一致：Docker 部署 + Nginx 反代到独立 8443 端口
#   - 支持已安装检测、导入旧链接、域名冲突检测、证书路径询问
#   - 新增菜单项 20/21/22，插入在 Xray 之后、批量执行之前
#
# ════════════════════════ 本次更新说明 (优化3：修复反代 Connection 头) ════════════════════════
# 修复：Sub-Store 与 Komari 的 Nginx 反代配置中，Connection 请求头被写死为 "upgrade"，
#   现改为 proxy_set_header Connection $http_connection; 根据客户端实际请求头动态传递。
#
# ════════════════════════ 本次更新说明 (优化4：修复反代 Host 头丢失端口号) ════════════════════════
# 修复：Sub-Store / Wallos / Komari 的 Nginx 反代统一改为 proxy_set_header Host $http_host;
#   完整保留客户端实际发送的 Host:端口，避免来源校验误判。
#
# ════════════════════════ 本次更新说明 (优化5) ════════════════════════
# 【1. Realm 单独部署后无法启动 —— 已定位并修复】
#   根因A：原 systemd 单元同时写了 User=root 与 DynamicUser=true，两者冲突（且 DynamicUser 会令 /root 只读），服务起不来。
#          → 已移除 DynamicUser；旧版已部署的服务文件会在「启动服务/添加转发」时自动修复。
#   根因B：部署时只 touch 了一个空的 config.toml，而 Realm 在配置里没有任何 [[endpoints]] 时会直接 panic
#          (missing field `endpoints`) 退出 → 反复重启失败。
#          → 部署后不再强行启动；添加第一条转发规则后才 enable + 启动；删除最后一条规则时自动停止服务。
#   其他：按 CPU 架构 (x86_64 / aarch64) 下载；下载后校验二进制可运行；添加转发时校验 IP/端口并防重复端口；
#         转发添加后同时 enable（原来仅 restart，重启 VPS 后不会自启）。
#
# 【2. 其他服务避免同类问题 + 依赖标注】
#   - 菜单中明确标注：Sub-Store / Wallos / Komari 【需要 Docker + Nginx】；sing-box / Xray / Realm / Nginx 【无需 Docker】。
#   - 面板类服务安装前统一做「依赖就绪检查」：Docker 未装→自动装；Docker 守护进程没跑→自动拉起；
#     Compose 缺失→自动补装；Nginx 未装→自动装。任何一项失败都会明确报错并中止，不再"装了一半才发现起不来"。
#     （Docker 已安装时不再重复弹出"是否重装 Docker"的询问）
#   - 容器启动后会等待并确认「稳定运行」，失败时直接打印容器日志；Nginx 重载前先 nginx -t，并提示 8443/8080 端口占用。
#
# 【3. Sub-Store 添加订阅「没有保存按钮 / 保存失败」—— 已定位并修复】
#   根因：新版 Sub-Store 后端内置了 CORS 来源校验，默认仅放行 sub-store.vercel.app 等少数来源；
#         浏览器对 POST/PUT/PATCH 等写请求会带上 Origin: https://你的域名:8443，被后端直接 403
#         (CORS origin not allowed)，所以"新增/保存订阅"全部失败（读取 GET 请求不带 Origin，所以页面能正常打开）。
#   修复：compose 中新增 SUB_STORE_CORS_ALLOWED_ORIGINS=https://域名:8443,https://域名 （仅放行自己的面板域名，其他来源仍被拒绝）。
#   顺带修复：原 SUB_STORE_DATA_BASE_PATH 指向 /app（未挂载），订阅数据只存在容器内，
#             「重新安装」或重建容器会丢失全部订阅 → 现改为 /app/data（已挂载到宿主机），
#             并会自动把旧容器里的 root.json / sub-store.json 抢救迁移出来。
#   前后端匹配：前后端版本号并不相同（如后端 2.42.x / 前端 2.34.x）。现按发布时间自动为所选后端匹配「同期」前端，
#             并记录到 version.txt；也可手动指定前端版本。下载经完整性校验后才替换，失败不影响现有面板。
#
# 【4. 新增「服务更新 / 版本切换」菜单 23~30】
#   Sub-Store(前后端匹配) / Wallos / Komari / sing-box / Xray / Realm / Nginx / Docker，
#   均支持：更新到最新、指定版本（可升级也可降级）、预发布版；更新前自动备份数据，失败自动回滚。
#
# 【5. 禁止服务后台自动更新】
#   - 容器类：全部固定在你选定的镜像标签上，只有你手动执行更新时才会拉取；compose 中加入
#     com.centurylinklabs.watchtower.enable=false 标签，即便机器上有 Watchtower 也会被排除；
#     Sub-Store 的前后端文件在宿主机目录由脚本管理，容器内没有任何自更新机制。
#   - sing-box：通过官方 apt 源安装后会被 apt upgrade / unattended-upgrades 悄悄升级，
#     现安装/更新后自动 apt-mark hold sing-box，仅在你通过本脚本更新时临时解除。
#   - Xray / Realm：二进制由本脚本管理，不带任何自更新任务。
#
# 【6. 修复 Sub-Store「Failed to download gist data / reading 'redirect'」】
#   根因：新版后端(2.42.x)依赖 Node 24（官方 runtime-manifest 标注 testedNode=24.x，并使用 node:sqlite 等新特性），
#         原 compose 固定使用 node:20.18.0，运行环境过旧。→ 现统一改为 node:24.15.0。
#         已部署的旧面板：菜单 23 → 选 4「保持当前版本，仅应用配置修复」即可自动改为 Node 24 并重建容器（数据不丢）。
#
# 【7. 新装系统 apt 被占用】系统刚装好时开机自动更新常占用 dpkg 锁，导致 sing-box/Nginx/Docker 全部安装失败。
#   现在执行安装前会自动等待锁释放（最多 15 分钟，不会删除任何锁文件）。
#
# 本次未改动：域名选择/证书询问/导入旧链接/冲突检测/菜单批量执行(100/101/102)/Nginx 反代配置内容/各卸载逻辑。
# ════════════════════════════════════════════════════════════════════


# ────────────────────────────────────────────────────────────────
#  优化5：公共辅助函数（统一使用 m4_ 前缀，避免与 vpsge.sh 其他模块冲突）
# ────────────────────────────────────────────────────────────────

# CPU 架构 → Go 风格命名 (amd64/arm64/armv7)
m4_arch_go() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l)        echo "armv7" ;;
        *)             echo "amd64" ;;
    esac
}

# 判断版本标签是否为预发布
m4_is_pre_tag() { [[ "${1,,}" =~ (alpha|beta|-rc|pre|snapshot|nightly) ]]; }

# apt 版本锁：阻止 apt upgrade / unattended-upgrades 在后台悄悄升级核心服务
m4_hold_pkg() {
    [[ "$PKG_MANAGER" == "apt" ]] || return 0
    local p
    for p in "$@"; do
        if dpkg -s "$p" >/dev/null 2>&1; then apt-mark hold "$p" >/dev/null 2>&1 || true; fi
    done
}
m4_unhold_pkg() {
    [[ "$PKG_MANAGER" == "apt" ]] || return 0
    apt-mark unhold "$@" >/dev/null 2>&1 || true
}

# 等待系统里其他 apt/dpkg 进程（如刚装完系统的开机自动更新）释放锁，最多 15 分钟；绝不删除锁文件
m4_wait_apt_lock() {
    [[ "$PKG_MANAGER" == "apt" ]] || return 0
    local i=0 max=900 who
    while pgrep -x 'apt|apt-get|aptitude|dpkg|unattended-upgr' >/dev/null 2>&1; do
        if (( i == 0 )); then
            who=$(pgrep -x 'apt|apt-get|aptitude|dpkg|unattended-upgr' | head -1)
            log_warn "检测到系统正在运行其他包管理任务 (pid ${who}: $(ps -p "$who" -o comm= 2>/dev/null))，通常是新系统的开机自动更新，等待其结束..."
        fi
        (( i >= max )) && { log_error "等待超过 15 分钟仍被占用，请手动检查: ps -fp \$(pgrep -x 'apt|apt-get|dpkg|unattended-upgr' | head -1)"; return 1; }
        sleep 5; i=$((i + 5))
        (( i % 60 == 0 )) && log_info "仍在等待 apt 锁释放 (${i}s)..."
    done
    (( i > 0 )) && log_success "apt 锁已释放，继续执行"
    return 0
}

# 备份目录为 tar.gz（保留最近 3 份）
m4_backup_dir() {
    local src="$1" name="$2" ts f
    [[ -d "$src" ]] || return 0
    ts=$(date +%Y%m%d-%H%M%S)
    mkdir -p /root/docker/backups
    f="/root/docker/backups/${name}-${ts}.tar.gz"
    if tar -czf "$f" -C "$(dirname "$src")" "$(basename "$src")" 2>/dev/null; then
        log_info "已自动备份: $f"
        ls -1t /root/docker/backups/"${name}"-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
        return 0
    fi
    log_warn "备份失败（磁盘空间不足？），请自行确认数据安全"
    return 1
}

# ── GitHub 版本查询（不依赖 jq；优先走 github.com 页面，避免 API 限流）──
# 最新稳定版 tag
m4_gh_latest_tag() {
    curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" 2>/dev/null \
        | sed -n 's#.*/releases/tag/\(.*\)$#\1#p'
}
# 最近 N 个 tag（含预发布，新→旧）
m4_gh_recent_tags() {
    curl -fsSL "https://github.com/$1/releases.atom" 2>/dev/null \
        | grep -oE 'releases/tag/[^"<&]+' | sed 's#releases/tag/##' | awk '!s[$0]++' | head -n "${2:-8}"
}
# 从 Releases 列表网页解析「tag 发布时间」（无需 API，翻页，最多 N 页；每页约 10 个发布）
m4_gh_tag_dates_html() {
    local repo="$1" pages="${2:-6}" p html out
    for ((p = 1; p <= pages; p++)); do
        html=$(curl -fsSL "https://github.com/${repo}/releases?page=${p}" 2>/dev/null) || break
        out=$(echo "$html" | grep -oE "href=\"/${repo}/releases/tag/[^\"]+\"|datetime=\"[0-9T:Z-]+\"" \
            | awk -F'"' '/^href=/{n=split($2, a, "/tag/"); t=a[2]} /^datetime=/{if(t!=""){print t, $2; t=""}}')
        [[ -z "$out" ]] && break
        echo "$out"
    done | awk '!s[$1]++'
}
# 单个 tag 的发布时间（来自该 tag 的网页）
m4_gh_one_date() {
    curl -fsSL "https://github.com/$1/releases/tag/$2" 2>/dev/null | grep -oE 'datetime="[0-9]{4}-[0-9T:-]+Z"' | head -1 | cut -d'"' -f2
}
# 输出「tag 发布时间」列表（新→旧）。依次尝试：API(最多100条) → 网页翻页 → atom(最近10条)
m4_gh_tag_dates() {
    local repo="$1" out
    out=$(curl -fsSL "https://api.github.com/repos/${repo}/releases?per_page=100" 2>/dev/null \
        | tr ',' '\n' | awk -F'"' '/"tag_name"/{t=$4} /"published_at"/{if(t!=""){print t, $4; t=""}}')
    [[ -z "$out" ]] && out=$(m4_gh_tag_dates_html "$repo" 6)
    if [[ -z "$out" ]]; then
        out=$(curl -fsSL "https://github.com/${repo}/releases.atom" 2>/dev/null | awk '
            /<entry>/ {e=1; next}
            e && /<updated>/ {u=$0; gsub(/.*<updated>|<\/updated>.*/, "", u)}
            e && /releases\/tag\// {match($0, /releases\/tag\/[^"]+/); t=substr($0, RSTART+13, RLENGTH-13); print t, u; e=0}')
    fi
    echo "$out"
}
m4_epoch() { date -d "$1" +%s 2>/dev/null; }

# ── Docker / Nginx 依赖就绪检查 ──
m4_docker_alive() { docker info >/dev/null 2>&1; }

ensure_docker_ready() {
    if ! is_cmd_exist docker; then
        log_warn "未检测到 Docker：该服务运行在 Docker 容器中，正在自动安装 Docker 环境..."
        install_docker_env 1 || { log_error "Docker 安装失败，无法继续"; return 1; }
    fi
    if ! m4_docker_alive; then
        log_warn "Docker 守护进程未运行，正在尝试启动..."
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start docker >/dev/null 2>&1 || true
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do m4_docker_alive && break; sleep 1; done
    fi
    if ! m4_docker_alive; then
        log_error "Docker 守护进程无法启动（可执行 systemctl status docker 或 journalctl -u docker -n 30 查看原因）"
        return 1
    fi
    if ! docker compose version >/dev/null 2>&1 && ! is_cmd_exist docker-compose; then
        log_info "正在安装 Docker Compose 插件..."
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt update -y >/dev/null 2>&1 || true
            apt install -y docker-compose-plugin >/dev/null 2>&1 || true
        else
            $PKG_MANAGER install -y docker-compose-plugin >/dev/null 2>&1 || true
        fi
        if ! docker compose version >/dev/null 2>&1 && ! is_cmd_exist docker-compose; then
            log_error "Docker Compose 不可用，请先在菜单「安装 Docker 环境」中修复"
            return 1
        fi
    fi
    return 0
}

ensure_nginx_ready() {
    if ! is_cmd_exist nginx; then
        log_warn "未检测到 Nginx（面板的 HTTPS 反代依赖它），正在尝试自动预装..."
        install_nginx 1
        if ! is_cmd_exist nginx; then
            log_error "Nginx 安装失败，无法继续（面板需要 Nginx 反代）"
            return 1
        fi
    fi
    return 0
}

# 先 nginx -t 再重载，失败时打印原因
m4_reload_nginx() {
    if ! nginx -t >/dev/null 2>&1; then
        log_warn "Nginx 配置检测未通过，已放弃重载。详情："
        nginx -t 2>&1 | tail -8 | sed 's/^/    /'
        return 1
    fi
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    else
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl restart nginx 2>/dev/null || true
    fi
    if systemctl is-active --quiet nginx 2>/dev/null; then return 0; fi
    log_warn "Nginx 未能正常运行：$(journalctl -u nginx -n 3 --no-pager 2>/dev/null | tail -2 | tr '\n' ' ')"
    return 1
}

# 8443 / 8080 被非 nginx 进程占用时提前提醒
m4_check_panel_ports() {
    local p o
    for p in 8443 8080; do
        o=$(ss -ltnp 2>/dev/null | awk -v pat=":${p}\$" '$4 ~ pat {print $NF}' | head -1)
        if [[ -n "$o" && "$o" != *nginx* ]]; then
            log_warn "端口 $p 已被其他进程占用 ($o)，Nginx 可能无法监听该端口，面板将无法访问！"
        fi
    done
}

m4_compose() {
    if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}

# 等待容器「稳定运行」（避免 restart 循环被误判为成功）
m4_wait_running() {
    local name="$1" t="${2:-20}" i
    for ((i = 0; i < t; i++)); do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
            sleep 4
            [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" \
               && "$(docker inspect -f '{{.State.Restarting}}' "$name" 2>/dev/null)" != "true" ]] && return 0
            return 1
        fi
        sleep 1
    done
    return 1
}

# 启动/重建容器并确认稳定运行；$3 可传 --force-recreate
m4_compose_deploy() {
    local dir="$1" name="$2" extra="${3:-}"
    log_info "启动容器 (首次会拉取镜像，请稍候)..."
    if ! ( cd "$dir" && m4_compose up -d $extra ); then
        log_error "容器启动命令执行失败"
        return 1
    fi
    if ! m4_wait_running "$name" 25; then
        log_error "容器 $name 未能稳定运行，最近日志："
        docker logs --tail 25 "$name" 2>&1 | sed 's/^/    /'
        return 1
    fi
    log_success "容器 $name 运行正常"
    return 0
}


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
        
        # 解除版本锁（优化5：被 hold 的包无法被 purge）
        m4_unhold_pkg sing-box sing-box-beta
        
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
#  依赖速查：
#    · 无需 Docker : sing-box、Nginx、Xray、Realm
#    · 需要 Docker : Sub-Store、Wallos、Komari（并且需要 Nginx 做 HTTPS 反代）
# ────────────────────────────────────────────────────────────────
install_nginx() {
    local mode="${1:-1}"
    log_step "安装 Nginx..."
    
    if is_cmd_exist nginx; then
        local ver
        ver=$(nginx -v 2>&1 | head -1)
        log_info "当前已安装版本: $ver"
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
    
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl start nginx >/dev/null 2>&1 || true
    systemctl is-active --quiet nginx && log_success "Nginx 安装并启动成功" || log_warn "Nginx 启动失败"
}

install_docker_env() {
    local mode="${1:-1}"
    log_step "检查并配置 Docker 环境..."
    
    if ! is_cmd_exist docker; then
        log_info "正在安装 Docker..."
        
        if [[ "$mode" == "3" ]]; then
            curl -fsSL https://test.docker.com -o get-docker.sh
        else
            curl -fsSL https://get.docker.com -o get-docker.sh
        fi
        
        if [[ "$mode" == "2" ]]; then
            read -rp "请输入 Docker 版本号 (回车跳过使用默认): " d_ver
            if [[ -n "$d_ver" ]]; then
                VERSION="$d_ver" sh get-docker.sh || { log_error "Docker 安装失败"; return 1; }
            else
                sh get-docker.sh || { log_error "Docker 安装失败"; return 1; }
            fi
        else
            sh get-docker.sh || { log_error "Docker 安装失败"; return 1; }
        fi
        rm -f get-docker.sh
    else
        if ! prompt_reinstall "Docker 环境"; then
            systemctl enable docker >/dev/null 2>&1 || true
            systemctl start docker >/dev/null 2>&1 || true
            return 0
        fi
    fi
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true

    if ! docker compose version >/dev/null 2>&1; then
        log_info "正在安装 Docker Compose 插件..."
        if [[ "$PKG_MANAGER" == "apt" ]]; then apt update -y && apt install -y docker-compose-plugin
        else $PKG_MANAGER install -y docker-compose-plugin; fi
    else
        log_success "Docker Compose 已就绪"
    fi
}

install_xray() {
    local mode="${1:-1}"   # 1=最新稳定版 2=指定版本号 3=Beta预发布版
    log_step "安装 Xray-core..."

    if is_cmd_exist xray; then
        local ver
        ver=$(xray version 2>/dev/null | head -1)
        log_info "当前已安装版本: $ver"
        if ! prompt_reinstall "Xray-core"; then return 0; fi
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

# ────────────────────────────────────────────────────────────────
#  Sub-Store（【需要 Docker + Nginx】）
#  前端 / 后端是两个独立仓库、版本号体系不同，必须成套匹配
# ────────────────────────────────────────────────────────────────
SB_BACK_TAG=""
SB_FRONT_TAG=""
# 运行 Sub-Store 后端的 Node 版本：2.42.x 后端按 Node 24 测试，Node 20 下“从 Gist 下载”会报 reading 'redirect'（已实测修复）
SB_NODE_TAG="24.15.0"

m4_sb_back_url() {
    if [[ "$1" == "latest" ]]; then echo "https://github.com/sub-store-org/Sub-Store/releases/latest/download/sub-store.bundle.js"
    else echo "https://github.com/sub-store-org/Sub-Store/releases/download/$1/sub-store.bundle.js"; fi
}
m4_sb_front_url() {
    if [[ "$1" == "latest" ]]; then echo "https://github.com/sub-store-org/Sub-Store-Front-End/releases/latest/download/dist.zip"
    else echo "https://github.com/sub-store-org/Sub-Store-Front-End/releases/download/$1/dist.zip"; fi
}

# 为指定后端版本匹配「同期发布」的前端：取发布时间不晚于后端(+2小时容差)的最新前端
m4_substore_match_front() {
    local btag="$1" bdate bep="" limit allow_pre=0 ft fd fep best="" oldest=""
    m4_is_pre_tag "$btag" && allow_pre=1
    bdate=$(m4_gh_tag_dates "sub-store-org/Sub-Store" | awk -v t="$btag" '$1==t{print $2; exit}')
    [[ -z "$bdate" ]] && bdate=$(m4_gh_one_date "sub-store-org/Sub-Store" "$btag")   # 较老版本：直接取该 tag 页面时间
    [[ -n "$bdate" ]] && bep=$(m4_epoch "$bdate")
    if [[ -z "$bep" ]]; then
        m4_gh_latest_tag "sub-store-org/Sub-Store-Front-End"
        return 0
    fi
    limit=$((bep + 7200))
    while read -r ft fd; do
        [[ -z "$ft" ]] && continue
        if [[ "$allow_pre" == "0" ]] && m4_is_pre_tag "$ft"; then continue; fi
        fep=$(m4_epoch "$fd") || continue
        [[ -z "$fep" ]] && continue
        oldest="$ft"
        if (( fep <= limit )); then best="$ft"; break; fi
    done < <(m4_gh_tag_dates "sub-store-org/Sub-Store-Front-End")
    echo "${best:-$oldest}"
}

# 按模式确定「后端 + 前端」版本组合 → SB_BACK_TAG / SB_FRONT_TAG
# mode: 1=最新稳定版  2=指定版本(可升可降)  3=预发布版
m4_substore_pick_versions() {
    local mode="${1:-1}" in_b="" in_f=""
    SB_BACK_TAG=""; SB_FRONT_TAG=""
    if [[ "$mode" == "2" ]]; then
        local recent
        recent=$(m4_gh_recent_tags "sub-store-org/Sub-Store" 6 | tr '\n' ' ')
        [[ -n "$recent" ]] && log_info "后端最近版本: $recent"
        read -rp "请输入 Sub-Store 后端版本号 (例如 2.42.6，回车=最新稳定版): " in_b
        in_b="${in_b// /}"; in_b="${in_b#v}"
        if [[ -n "$in_b" ]]; then SB_BACK_TAG="$in_b"; else SB_BACK_TAG=$(m4_gh_latest_tag "sub-store-org/Sub-Store"); fi
        read -rp "请输入 Sub-Store 前端版本号 (例如 2.34.1，回车=自动匹配该后端的同期前端【推荐】): " in_f
        in_f="${in_f// /}"; in_f="${in_f#v}"
        [[ -n "$in_f" ]] && SB_FRONT_TAG="$in_f"
    elif [[ "$mode" == "3" ]]; then
        log_info "正在获取 Github 预发布版(Beta)..."
        SB_BACK_TAG=$(m4_gh_recent_tags "sub-store-org/Sub-Store" 1)
    else
        SB_BACK_TAG=$(m4_gh_latest_tag "sub-store-org/Sub-Store")
    fi

    if [[ -z "$SB_BACK_TAG" ]]; then
        log_warn "无法获取后端版本号(网络/限流)，回退为 latest 直链"
        SB_BACK_TAG="latest"
    fi
    if [[ -z "$SB_FRONT_TAG" ]]; then
        if [[ "$SB_BACK_TAG" == "latest" ]]; then
            SB_FRONT_TAG="latest"
        else
            SB_FRONT_TAG=$(m4_substore_match_front "$SB_BACK_TAG")
            [[ -z "$SB_FRONT_TAG" ]] && SB_FRONT_TAG="latest"
        fi
    fi
    log_info "本次前后端版本组合 → 后端: ${SB_BACK_TAG}  +  前端: ${SB_FRONT_TAG}"
}

# 下载并校验后替换（任何一步失败都不会动现有文件）
m4_substore_fetch() {
    local dir="$1" bt="$2" ft="$3" tmp feroot
    if ! is_cmd_exist unzip; then
        log_info "正在为您自动安装必要的 unzip 解压工具..."
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            apt update -y >/dev/null 2>&1 || true
            apt install -y unzip >/dev/null 2>&1 || true
        else
            $PKG_MANAGER install -y unzip >/dev/null 2>&1 || true
        fi
    fi
    tmp=$(mktemp -d /tmp/substore-dl.XXXXXX)
    log_info "正在下载后端 ($bt)..."
    if ! curl -fsSL -L "$(m4_sb_back_url "$bt")" -o "$tmp/sub-store.bundle.js" || [[ ! -s "$tmp/sub-store.bundle.js" ]]; then
        log_error "后端下载失败（版本 $bt 是否存在？网络是否可达 GitHub？）"
        rm -rf "$tmp"; return 1
    fi
    log_info "正在下载前端 ($ft)..."
    if ! curl -fsSL -L "$(m4_sb_front_url "$ft")" -o "$tmp/dist.zip" || [[ ! -s "$tmp/dist.zip" ]]; then
        log_error "前端下载失败（版本 $ft 是否存在？）"
        rm -rf "$tmp"; return 1
    fi
    if ! unzip -tq "$tmp/dist.zip" >/dev/null 2>&1; then
        log_error "前端压缩包校验失败（文件损坏或下载不完整）"
        rm -rf "$tmp"; return 1
    fi
    mkdir -p "$tmp/fe"
    unzip -qo "$tmp/dist.zip" -d "$tmp/fe" || { log_error "前端解压失败"; rm -rf "$tmp"; return 1; }
    feroot="$tmp/fe"
    [[ -d "$tmp/fe/dist" ]] && feroot="$tmp/fe/dist"
    if [[ ! -f "$feroot/index.html" ]]; then
        log_error "前端包内容异常（未找到 index.html）"
        rm -rf "$tmp"; return 1
    fi

    # 保留上一版本，便于启动失败时回滚
    rm -rf "$dir/frontend.prev" "$dir/sub-store.bundle.js.prev" "$dir/version.txt.prev"
    [[ -d "$dir/frontend" ]] && mv "$dir/frontend" "$dir/frontend.prev"
    [[ -f "$dir/sub-store.bundle.js" ]] && mv "$dir/sub-store.bundle.js" "$dir/sub-store.bundle.js.prev"
    [[ -f "$dir/version.txt" ]] && cp -f "$dir/version.txt" "$dir/version.txt.prev"
    mv "$feroot" "$dir/frontend"
    mv "$tmp/sub-store.bundle.js" "$dir/sub-store.bundle.js"
    rm -rf "$tmp"
    printf 'backend=%s\nfrontend=%s\n' "$bt" "$ft" > "$dir/version.txt"
    return 0
}

m4_substore_write_compose() {
    local dir="$1" sn="$2" api_path="$3"
    cat > "$dir/docker-compose.yml" <<EOF
version: '3.8'
services:
  substore:
    image: node:${SB_NODE_TAG}
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
      SUB_STORE_DATA_BASE_PATH: "/app/data"
      SUB_STORE_BACKEND_API_HOST: "127.0.0.1"
      SUB_STORE_BACKEND_API_PORT: "3000"
      SUB_STORE_CORS_ALLOWED_ORIGINS: "https://$sn:8443,https://$sn"
      TZ: "Asia/Shanghai"
    labels:
      - "com.centurylinklabs.watchtower.enable=false"
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
}

# 旧版本把订阅数据写在容器内 /app（未挂载），重建容器前先抢救出来
m4_substore_rescue_data() {
    local dir="$1" f
    docker inspect substore >/dev/null 2>&1 || return 0
    mkdir -p "$dir/data"
    for f in sub-store.json root.json; do
        if [[ ! -s "$dir/data/$f" ]]; then
            if docker cp "substore:/app/$f" "$dir/data/$f" >/dev/null 2>&1; then
                log_success "已从旧容器抢救迁移订阅数据文件: $f"
            fi
        fi
    done
}

# 本机自检：后端是否可用，且带 Origin 的请求(模拟浏览器保存订阅)不再被 403
m4_substore_verify() {
    local sn="$1" api="$2" code_plain code_origin
    sleep 2
    code_plain=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:3001/${api}/api/utils/env" 2>/dev/null)
    code_origin=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Origin: https://${sn}:8443" "http://127.0.0.1:3001/${api}/api/utils/env" 2>/dev/null)
    if [[ "$code_plain" == "200" && "$code_origin" == "200" ]]; then
        log_success "后端自检通过（含浏览器 Origin 校验），订阅的新增/保存可正常使用"
    elif [[ "$code_origin" == "403" ]]; then
        log_warn "后端自检：带 Origin 的请求被拒绝(403)，保存订阅可能失败。请确认面板域名与访问地址一致。"
    else
        log_warn "后端自检返回 HTTP ${code_plain}/${code_origin}，请稍后用 docker logs substore 查看状态"
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
        if [[ -f /root/docker/substore/domain.txt && -f /root/docker/substore/api_path.txt ]]; then
            local p_sn=$(cat /root/docker/substore/domain.txt)
            local p_api=$(cat /root/docker/substore/api_path.txt)
            echo -e "  🌐 为您找回的现有面板访问地址: ${GREEN}https://$p_sn:8443/?api=https://$p_sn:8443/$p_api${NC}"
        fi
        
        echo "  1) 不重新安装 (保留现有) [默认]"
        echo "  2) 重新安装 (覆盖更新)"
        echo "  3) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-3, 30秒后默认 1): " choice || true
        choice=${choice:-1}
        if [[ "$choice" == "1" ]]; then return 0; fi
        
        # 优化5：删容器前先抢救数据并备份，避免订阅丢失
        m4_substore_rescue_data /root/docker/substore
        m4_backup_dir /root/docker/substore substore
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
        echo -e "\n${CYAN}检测到 Sub-Store 未安装，请选择部署方式：${NC}"
        echo "  1) 直接安装 [默认]"
        echo "  2) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-2, 30秒后默认 1): " choice || true
        choice=${choice:-1}
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

    log_info "依赖检查：Sub-Store 运行于 Docker 容器，并通过 Nginx 反代 → 需要 Docker + Nginx"
    ensure_docker_ready || { log_error "Sub-Store 部署已中止（Docker 环境不可用）"; return 1; }
    ensure_nginx_ready || { log_error "Sub-Store 部署已中止（Nginx 不可用）"; return 1; }

    log_step "部署 Sub-Store (订阅转换中心)"

    # 前后端成套匹配（优化5）
    m4_substore_pick_versions "$sub_ver_choice"

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
        # 强制在选择域名时弹出版单给出选择（Sub-Store 默认选项 1）
        local prev_auto="$AUTO_DEFAULT"
        AUTO_DEFAULT="false" 
        select_server_name "sub.example.com" "" "1"
        sn="$SELECTED_SN"
        AUTO_DEFAULT="$prev_auto"
        
        ask_cert_paths "$sn"
        cp="$CERT_PATH"
        kp="$KEY_PATH"
    fi
    
    if [[ ! -f "$cp" || ! -f "$kp" ]]; then
        log_warn "⚠️ 警告：检测到证书或私钥文件实际不存在！"
        log_warn "Nginx 代理极有可能因此启动失败，导致面板无法访问！"
        log_warn "请后续确保将正确的证书文件放置于: $cp"
    fi

    mkdir -p /root/docker/substore/data
    cd /root/docker/substore

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
    echo "$sn" > domain.txt

    log_info "正在为您下载并部署选中版本的核心代码..."
    if ! m4_substore_fetch /root/docker/substore "$SB_BACK_TAG" "$SB_FRONT_TAG"; then
        log_error "Sub-Store 核心文件获取失败，部署已中止"
        return 1
    fi

    m4_substore_write_compose /root/docker/substore "$sn" "$api_path"

    m4_compose_deploy /root/docker/substore substore || log_warn "Sub-Store 容器未正常运行，请根据上方日志排查"

    log_step "配置 Nginx 安全反向代理 (专属隔离 8443 端口)"
    open_firewall_ports
    mkdir -p /etc/nginx/conf.d
    m4_check_panel_ports
    
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
    m4_reload_nginx || log_warn "Nginx 重载失败，请检查配置文件或证书是否存在"
    m4_substore_verify "$sn" "$api_path"
    
    echo ""
    log_success "Sub-Store 部署完成！"
    echo -e "  🌐 访问面板地址: ${GREEN}https://$sn:8443/?api=https://$sn:8443/$api_path${NC}"
    echo -e "  🔐 后台API路径:  ${YELLOW}/$api_path${NC}"
    echo -e "  📦 当前版本组合: 后端 ${SB_BACK_TAG} + 前端 ${SB_FRONT_TAG}"
    echo -e "  ${YELLOW}（如果不慎忘记该地址，可在脚本主菜单的「服务管理」中随时找回查看）${NC}"
    echo -e "  ${YELLOW}（若浏览器仍显示旧界面，请 Ctrl+F5 强制刷新，或清除该站点缓存后重新打开）${NC}"
    echo ""
}

# ── Sub-Store 更新 / 版本切换（前后端成套匹配，失败自动回滚）──
update_substore() {
    local dir="/root/docker/substore"
    log_step "更新 Sub-Store（前后端版本成套匹配）"
    is_cmd_exist docker || { log_error "未检测到 Docker，Sub-Store 尚未部署"; return 1; }
    ensure_docker_ready || return 1
    if [[ ! -d "$dir" ]] || ! docker inspect substore >/dev/null 2>&1; then
        log_error "未检测到已部署的 Sub-Store，请先通过安装菜单部署"; return 1
    fi
    if [[ ! -s "$dir/domain.txt" || ! -s "$dir/api_path.txt" ]]; then
        log_error "缺少 $dir/domain.txt 或 api_path.txt，无法安全更新（请用安装菜单的「导入旧链接」重新部署）"; return 1
    fi
    local sn api_path cur_ver
    sn=$(cat "$dir/domain.txt"); api_path=$(cat "$dir/api_path.txt")
    if [[ -f "$dir/version.txt" ]]; then
        cur_ver="$(tr '\n' ' ' < "$dir/version.txt")"
    else
        cur_ver="后端 $(docker logs substore 2>&1 | grep -oE 'Sub-Store -- v[0-9][0-9.A-Za-z-]*' | tail -1 | sed 's/.*-- v//')（前端版本未记录）"
    fi
    log_info "当前版本: ${cur_ver}"

    echo "  1) 更新到最新稳定版 (前后端自动匹配)"
    echo "  2) 指定版本 (升级 / 降级均可，前端默认自动匹配后端)"
    echo "  3) 更新到预发布版 (Beta)"
    echo "  4) 保持当前版本，仅应用配置修复 (保存订阅 403 / 数据持久化，并迁移旧数据)"
    echo "  0) 取消"
    local mode
    read -rp "  > 请选择 (默认 0): " mode
    mode=${mode:-0}
    [[ "$mode" == "0" ]] && return 0
    [[ "$mode" =~ ^[1-4]$ ]] || { log_warn "无效选择"; return 1; }

    if [[ "$mode" != "4" ]]; then
        m4_substore_pick_versions "$mode"
        read -rp "确认更新到上述版本组合？(y/N): " ok
        [[ "${ok,,}" == "y" ]] || { log_info "已取消"; return 0; }
    else
        read -rp "确认重建容器并应用配置修复？(y/N): " ok
        [[ "${ok,,}" == "y" ]] || { log_info "已取消"; return 0; }
    fi

    m4_substore_rescue_data "$dir"
    m4_backup_dir "$dir" substore
    cp -f "$dir/docker-compose.yml" "$dir/docker-compose.yml.prev" 2>/dev/null || true

    if [[ "$mode" != "4" ]]; then
        m4_substore_fetch "$dir" "$SB_BACK_TAG" "$SB_FRONT_TAG" || { log_error "下载/校验失败，现有 Sub-Store 未做任何改动"; return 1; }
    fi
    m4_substore_write_compose "$dir" "$sn" "$api_path"

    if ! m4_compose_deploy "$dir" substore --force-recreate; then
        log_warn "新版本未能正常运行，正在回滚到更新前的状态..."
        if [[ -d "$dir/frontend.prev" ]]; then rm -rf "$dir/frontend"; mv "$dir/frontend.prev" "$dir/frontend"; fi
        [[ -f "$dir/sub-store.bundle.js.prev" ]] && mv -f "$dir/sub-store.bundle.js.prev" "$dir/sub-store.bundle.js"
        [[ -f "$dir/version.txt.prev" ]] && mv -f "$dir/version.txt.prev" "$dir/version.txt"
        [[ -f "$dir/docker-compose.yml.prev" ]] && mv -f "$dir/docker-compose.yml.prev" "$dir/docker-compose.yml"
        m4_compose_deploy "$dir" substore --force-recreate || true
        log_error "已回滚，更新失败。数据备份位于 /root/docker/backups/"
        return 1
    fi
    rm -rf "$dir/frontend.prev" "$dir/sub-store.bundle.js.prev" "$dir/version.txt.prev" "$dir/docker-compose.yml.prev"
    m4_substore_verify "$sn" "$api_path"
    log_success "Sub-Store 更新完成：$(tr '\n' ' ' < "$dir/version.txt" 2>/dev/null)"
    echo -e "  ${YELLOW}（请在浏览器 Ctrl+F5 强制刷新，避免继续使用旧前端缓存）${NC}"
}

# ────────────────────────────────────────────────────────────────
#  Wallos（【需要 Docker + Nginx】）
# ────────────────────────────────────────────────────────────────
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
        echo "  1) 不重新安装 (保留现有) [默认]"
        echo "  2) 重新安装 (覆盖更新)"
        echo "  3) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-3, 30秒后默认 1): " choice || true
        choice=${choice:-1}
        if [[ "$choice" == "1" ]]; then return 0; fi
        
        m4_backup_dir /root/docker/wallos wallos
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
        echo -e "\n${CYAN}检测到 Wallos 未安装，请选择部署方式：${NC}"
        echo "  1) 直接安装 [默认]"
        echo "  2) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-2, 30秒后默认 1): " choice || true
        choice=${choice:-1}
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
        ask_val wallos_ver "请输入待部署的 Wallos 版本标签" "2.36.2"
    elif [[ "$wallos_mode" == "3" ]]; then
        wallos_ver="beta"
    fi

    log_info "依赖检查：Wallos 运行于 Docker 容器，并通过 Nginx 反代 → 需要 Docker + Nginx"
    ensure_docker_ready || { log_error "Wallos 部署已中止（Docker 环境不可用）"; return 1; }
    ensure_nginx_ready || { log_error "Wallos 部署已中止（Nginx 不可用）"; return 1; }

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
            # 强制在选择域名时弹出版单给出选择（Wallos 默认选项 2）
            local prev_auto="$AUTO_DEFAULT"
            AUTO_DEFAULT="false" 
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
    labels:
      - "com.centurylinklabs.watchtower.enable=false"
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

    m4_compose_deploy /root/docker/wallos wallos || log_warn "Wallos 容器未正常运行，请根据上方日志排查"

    log_step "配置 Nginx 安全反向代理 (专属隔离 8443 端口)"
    open_firewall_ports
    mkdir -p /etc/nginx/conf.d
    m4_check_panel_ports
    
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
    m4_reload_nginx || log_warn "Nginx 重载失败，请后续检查配置文件或证书是否存在"
    
    echo ""
    log_success "Wallos 部署完成！"
    echo -e "  🌐 访问面板地址: ${GREEN}https://$sn:8443${NC}"
    echo ""
}

# ────────────────────────────────────────────────────────────────
#  Komari（【需要 Docker + Nginx】）
# ────────────────────────────────────────────────────────────────
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
        echo "  1) 不重新安装 (保留现有) [默认]"
        echo "  2) 重新安装 (覆盖更新)"
        echo "  3) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-3, 30秒后默认 1): " choice || true
        choice=${choice:-1}
        if [[ "$choice" == "1" ]]; then return 0; fi

        m4_backup_dir /root/docker/komari komari
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
        echo -e "\n${CYAN}检测到 Komari 探针未安装，请选择部署方式：${NC}"
        echo "  1) 直接安装 [默认]"
        echo "  2) 导入旧链接 (手动粘贴)"
        local choice
        read -t 30 -rp "  > 请选择 (1-2, 30秒后默认 1): " choice || true
        choice=${choice:-1}
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
        local pre_tag
        pre_tag=$(m4_gh_recent_tags "komari-monitor/komari" 1)
        if [[ -n "$pre_tag" ]]; then
            komari_tag="$pre_tag"
        else
            log_warn "未能获取预发布版标签，回退为 latest"
            komari_tag="latest"
        fi
    fi

    log_info "依赖检查：Komari 运行于 Docker 容器，并通过 Nginx 反代 → 需要 Docker + Nginx"
    ensure_docker_ready || { log_error "Komari 部署已中止（Docker 环境不可用）"; return 1; }
    ensure_nginx_ready || { log_error "Komari 部署已中止（Nginx 不可用）"; return 1; }

    # 提前确认镜像标签真实存在，避免装到一半才失败
    if [[ "$komari_tag" != "latest" ]]; then
        if ! docker pull "ghcr.io/komari-monitor/komari:$komari_tag" >/dev/null 2>&1; then
            if [[ "$komari_ver_choice" == "3" ]]; then
                log_warn "预发布镜像标签 $komari_tag 拉取失败，回退为 latest"
                komari_tag="latest"
            else
                log_error "镜像 ghcr.io/komari-monitor/komari:$komari_tag 拉取失败，请确认版本号是否存在"
                return 1
            fi
        fi
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
            # 强制在选择域名时弹出版单给出选择（Komari 默认选项 3）
            local prev_auto="$AUTO_DEFAULT"
            AUTO_DEFAULT="false"
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
    read -rp "请输入 Komari 初始管理员用户名 (回车则由系统随机生成): " admin_user
    read -rp "请输入 Komari 初始管理员密码 (回车则由系统随机生成): " admin_pass

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
    labels:
      - "com.centurylinklabs.watchtower.enable=false"
    volumes:
      - ./data:/app/data
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    m4_compose_deploy /root/docker/komari komari || log_warn "Komari 容器未正常运行，请根据上方日志排查"

    log_step "配置 Nginx 安全反向代理 (专属隔离 8443 端口)"
    open_firewall_ports
    mkdir -p /etc/nginx/conf.d
    m4_check_panel_ports

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
    m4_reload_nginx || log_warn "Nginx 重载失败，请后续检查配置文件或证书是否存在"

    echo ""
    log_success "Komari 探针部署完成！"
    echo -e "  🌐 访问面板地址: ${GREEN}https://$sn:8443${NC}"
    echo -e "  ${YELLOW}（如未设置管理员账号密码，请使用 docker logs komari 查看系统自动生成的初始账号密码）${NC}"
    echo -e "  ${YELLOW}（如果不慎忘记该地址，可在脚本主菜单的「服务管理」中随时找回查看）${NC}"
    echo ""
}

# ────────────────────────────────────────────────────────────────
#  Wallos / Komari 通用「镜像标签」更新（升级、降级均可；先预拉取，失败不动现有服务）
#  参数: 容器名 目录 镜像(不含标签) 显示名 版本提示仓库 预发布方式(atom|具体标签) 示例标签
# ────────────────────────────────────────────────────────────────
m4_update_image_service() {
    local name="$1" dir="$2" image="$3" pretty="$4" tags_repo="$5" pre_kind="$6" example="$7"
    log_step "更新 ${pretty}"
    is_cmd_exist docker || { log_error "未检测到 Docker，${pretty} 尚未部署"; return 1; }
    ensure_docker_ready || return 1
    if [[ ! -f "$dir/docker-compose.yml" ]] || ! docker inspect "$name" >/dev/null 2>&1; then
        log_error "未检测到已部署的 ${pretty}，请先通过安装菜单部署"; return 1
    fi

    local cur_tag
    cur_tag=$(sed -n "s#^[[:space:]]*image:[[:space:]]*${image}:\(.*\)\$#\1#p" "$dir/docker-compose.yml" | head -1 | tr -d '\r \"'"'")
    log_info "当前镜像标签: ${cur_tag:-未知}"
    if [[ -n "$tags_repo" ]]; then
        local recent
        recent=$(m4_gh_recent_tags "$tags_repo" 8 | tr '\n' ' ')
        [[ -n "$recent" ]] && log_info "最近发布的版本: $recent"
    fi

    echo "  1) 更新到最新稳定版 (latest)"
    echo "  2) 指定版本标签 (升级 / 降级均可，例如 ${example})"
    echo "  3) 更新到预发布版"
    echo "  0) 取消"
    local mode new_tag=""
    read -rp "  > 请选择 (默认 0): " mode
    mode=${mode:-0}
    case "$mode" in
        0) return 0 ;;
        1) new_tag="latest" ;;
        2) read -rp "请输入目标版本标签 (如 ${example}): " new_tag
           new_tag="${new_tag// /}"
           [[ -z "$new_tag" ]] && { log_info "未输入，已取消"; return 0; } ;;
        3) if [[ "$pre_kind" == "atom" ]]; then
               new_tag=$(m4_gh_recent_tags "$tags_repo" 1)
               [[ -z "$new_tag" ]] && { log_warn "未能获取预发布标签，已取消"; return 1; }
           else
               new_tag="$pre_kind"
           fi ;;
        *) log_warn "无效选择"; return 1 ;;
    esac

    read -rp "确认将 ${pretty} 由 [${cur_tag:-?}] 切换到 [${new_tag}]？(y/N): " ok
    [[ "${ok,,}" == "y" ]] || { log_info "已取消"; return 0; }

    log_info "正在预拉取镜像 ${image}:${new_tag} ..."
    if ! docker pull "${image}:${new_tag}"; then
        log_error "镜像拉取失败（标签是否存在？），${pretty} 未做任何改动"
        return 1
    fi

    m4_backup_dir "$dir" "$name"
    cp -f "$dir/docker-compose.yml" "$dir/docker-compose.yml.prev"
    sed -i "s#^\([[:space:]]*image:[[:space:]]*${image}:\).*\$#\1${new_tag}#" "$dir/docker-compose.yml"

    if ! m4_compose_deploy "$dir" "$name" --force-recreate; then
        log_warn "新版本未能正常运行，正在回滚到 [${cur_tag:-原版本}]..."
        mv -f "$dir/docker-compose.yml.prev" "$dir/docker-compose.yml"
        m4_compose_deploy "$dir" "$name" --force-recreate || true
        log_error "已回滚，更新失败。数据备份位于 /root/docker/backups/"
        return 1
    fi
    rm -f "$dir/docker-compose.yml.prev"
    log_success "${pretty} 已切换到镜像标签: ${new_tag}"
    if [[ "$mode" == "2" ]]; then
        log_info "提示：降级可能遇到数据库结构不兼容，如异常可从 /root/docker/backups/ 恢复备份。"
    fi
}

update_wallos()  { m4_update_image_service wallos  /root/docker/wallos  "bellamy/wallos"                 "Wallos"  ""                       "beta" "2.36.2"; }
update_komari()  { m4_update_image_service komari  /root/docker/komari  "ghcr.io/komari-monitor/komari"  "Komari"  "komari-monitor/komari"  "atom" "1.6.0"; }

# ----------------- Realm 端口转发功能模块（【无需 Docker / Nginx】，独立 systemd 服务）-----------------
m4_realm_has_endpoints() {
    [[ -f /root/realm/config.toml ]] && grep -q '^\[\[endpoints\]\]' /root/realm/config.toml
}

m4_realm_write_service() {
    cat > /etc/systemd/system/realm.service << 'EOF'
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=/root/realm
ExecStart=/root/realm/realm -c /root/realm/config.toml

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
}

# 自动修复旧版本遗留的 DynamicUser=true（与 User=root 冲突、且令 /root 只读，会导致服务无法启动）
m4_realm_fix_service() {
    if [[ -f /etc/systemd/system/realm.service ]] && grep -q '^DynamicUser=' /etc/systemd/system/realm.service; then
        sed -i '/^DynamicUser=/d' /etc/systemd/system/realm.service
        systemctl daemon-reload 2>/dev/null || true
        log_info "已自动修复旧版 realm.service（移除冲突的 DynamicUser 配置）"
    fi
}

# 下载并校验指定 tag 的 Realm 到目录；先试 fork 仓库，再试上游仓库
m4_realm_download() {
    local tag="$1" outdir="$2" arch_s repo url
    case "$(uname -m)" in
        x86_64|amd64)  arch_s="x86_64" ;;
        aarch64|arm64) arch_s="aarch64" ;;
        *) log_error "Realm 暂不支持当前架构: $(uname -m)"; return 1 ;;
    esac
    mkdir -p "$outdir"
    for repo in github19999/fork-realm zhboner/realm; do
        url="https://github.com/${repo}/releases/download/${tag}/realm-${arch_s}-unknown-linux-gnu.tar.gz"
        rm -f "$outdir/realm" "$outdir/realm.tar.gz"
        curl -fsSL -L "$url" -o "$outdir/realm.tar.gz" 2>/dev/null || continue
        tar -xzf "$outdir/realm.tar.gz" -C "$outdir" 2>/dev/null || continue
        [[ -f "$outdir/realm" ]] || continue
        chmod +x "$outdir/realm"
        "$outdir/realm" -v >/dev/null 2>&1 || continue
        log_info "已从 ${repo} 获取 Realm ${tag}"
        return 0
    done
    log_error "Realm ${tag} 下载或校验失败（该版本不存在，或当前架构无对应文件）"
    return 1
}

deploy_realm() {
    if [[ -f "/root/realm/realm" ]]; then
        if ! prompt_reinstall "Realm"; then return 0; fi
        systemctl stop realm 2>/dev/null || true
    fi

    log_step "部署 Realm 端口转发环境 (无需 Docker / Nginx)"
    mkdir -p /root/realm
    local tag="v2.6.0" tmp
    if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
        # fork 的 v2.6.0 没有 aarch64 文件，ARM 机器使用其最新版
        tag=$(m4_gh_latest_tag "github19999/fork-realm")
        tag="${tag:-v2.9.2}"
    fi
    tmp=$(mktemp -d /tmp/realm-dl.XXXXXX)
    if ! m4_realm_download "$tag" "$tmp"; then
        rm -rf "$tmp"
        return 1
    fi
    install -m 755 "$tmp/realm" /root/realm/realm
    rm -rf "$tmp"

    if [[ ! -f /root/realm/config.toml ]]; then
        printf '# Realm 配置：至少需要一条 [[endpoints]] 转发规则，Realm 才能运行\n' > /root/realm/config.toml
    fi
    m4_realm_write_service

    if m4_realm_has_endpoints; then
        systemctl reset-failed realm 2>/dev/null || true
        systemctl enable realm >/dev/null 2>&1 || true
        systemctl restart realm 2>/dev/null || true
        sleep 2
        systemctl is-active --quiet realm && log_info "检测到已有转发规则，Realm 服务已启动" \
            || log_warn "Realm 启动失败，请查看: journalctl -u realm -n 20 --no-pager"
    else
        log_info "提示：Realm 要求配置中至少有一条转发规则才能运行。请选择「添加转发」，添加后会自动启动并设为开机自启。"
    fi
    log_success "Realm 部署完成 ($(/root/realm/realm -v 2>&1 | head -1))。"
}

add_forward_realm() {
    log_step "添加 Realm 转发规则"
    if [[ ! -f /root/realm/realm ]]; then
        log_error "未安装 Realm，请先执行「部署环境」"
        return 1
    fi
    if [ ! -f "/root/realm/config.toml" ]; then
        touch /root/realm/config.toml
    fi
    local ip port answer
    while true; do
        read -p "请输入目标 IP: " ip
        read -p "请输入本地/目标端口 (同端口): " port
        if [[ -z "$ip" ]] || ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            log_warn "目标 IP 不能为空，端口须为 1-65535 的数字，本条已跳过"
        elif grep -q "listen = \"0.0.0.0:${port}\"" /root/realm/config.toml; then
            log_warn "本地端口 ${port} 已存在转发规则，本条已跳过"
        else
            echo "[[endpoints]]" >> /root/realm/config.toml
            echo "listen = \"0.0.0.0:$port\"" >> /root/realm/config.toml
            echo "remote = \"$ip:$port\"" >> /root/realm/config.toml
        fi
        
        read -p "是否继续添加(Y/N)? " answer
        if [[ "${answer,,}" != "y" ]]; then
            break
        fi
    done
    if ! m4_realm_has_endpoints; then
        log_warn "当前没有任何有效转发规则，Realm 暂不启动。"
        return 0
    fi
    m4_realm_fix_service
    systemctl reset-failed realm 2>/dev/null || true
    systemctl enable realm >/dev/null 2>&1 || true
    systemctl restart realm 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet realm; then
        log_success "转发规则已添加并生效（已设为开机自启）。"
    else
        log_error "Realm 启动失败，最近日志："
        journalctl -u realm -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
    fi
}

delete_forward_realm() {
    log_step "删除 Realm 转发规则"
    if [ ! -f "/root/realm/config.toml" ]; then
        log_warn "未找到配置文件 /root/realm/config.toml"
        return
    fi
    echo "当前转发规则："
    local IFS=$'\n'
    local lines=($(grep -n 'remote =' /root/realm/config.toml))
    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi
    local index=1
    for line in "${lines[@]}"; do
        echo "${index}. $(echo "$line" | cut -d '"' -f 2)"
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

    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#lines[@]} ]; then
        echo "选择超出范围，请输入有效序号。"
        return
    fi

    local chosen_line=${lines[$((choice-1))]}
    local line_number=$(echo "$chosen_line" | cut -d ':' -f 1)

    local start_line=$((line_number - 2))
    local end_line=$line_number
    [ "$start_line" -lt 1 ] && start_line=1

    sed -i "${start_line},${end_line}d" /root/realm/config.toml

    log_success "转发规则已删除。"
    if m4_realm_has_endpoints; then
        systemctl restart realm 2>/dev/null || true
    else
        # Realm 没有任何规则时无法运行，直接停止，避免反复崩溃重启
        systemctl stop realm 2>/dev/null || true
        systemctl disable realm >/dev/null 2>&1 || true
        log_info "已无任何转发规则，Realm 服务已停止（添加新规则后会自动重新启动）。"
    fi
}

start_service_realm() {
    if ! m4_realm_has_endpoints; then
        log_warn "尚未添加任何转发规则，Realm 无规则无法运行。请先选择「添加转发」。"
        return 1
    fi
    m4_realm_fix_service
    systemctl unmask realm.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed realm 2>/dev/null || true
    systemctl restart realm.service 2>/dev/null || true
    systemctl enable realm.service 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet realm; then
        log_success "realm 服务已启动并设置为开机自启。"
    else
        log_error "realm 启动失败，最近日志："
        journalctl -u realm -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
    fi
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

update_realm() {
    log_step "更新 Realm"
    [[ -f /root/realm/realm ]] || { log_error "未安装 Realm，请先部署"; return 1; }
    log_info "当前版本: $(/root/realm/realm -v 2>&1 | head -1)"
    local recent
    recent=$(m4_gh_recent_tags "github19999/fork-realm" 8 | tr '\n' ' ')
    [[ -n "$recent" ]] && log_info "可用版本(fork 仓库): $recent"
    echo "  1) 更新到最新版 (fork 仓库最新发布)"
    echo "  2) 指定版本 (升级 / 降级均可，例如 v2.6.0、v2.9.2；fork 没有时自动尝试上游仓库)"
    echo "  0) 取消"
    local mode tag=""
    read -rp "  > 请选择 (默认 0): " mode
    mode=${mode:-0}
    case "$mode" in
        0) return 0 ;;
        1) tag=$(m4_gh_latest_tag "github19999/fork-realm"); [[ -z "$tag" ]] && { log_error "无法获取最新版本号"; return 1; } ;;
        2) read -rp "请输入版本号 (如 v2.9.2): " tag
           tag="${tag// /}"
           [[ -z "$tag" ]] && { log_info "未输入，已取消"; return 0; }
           [[ "$tag" =~ ^[0-9] ]] && tag="v$tag" ;;
        *) log_warn "无效选择"; return 1 ;;
    esac
    read -rp "确认更新到 ${tag}？(y/N): " ok
    [[ "${ok,,}" == "y" ]] || { log_info "已取消"; return 0; }

    local tmp was_active=false
    tmp=$(mktemp -d /tmp/realm-dl.XXXXXX)
    m4_realm_download "$tag" "$tmp" || { rm -rf "$tmp"; return 1; }
    systemctl is-active --quiet realm && was_active=true
    cp -f /root/realm/realm /root/realm/realm.bak-update
    systemctl stop realm 2>/dev/null || true
    install -m 755 "$tmp/realm" /root/realm/realm
    rm -rf "$tmp"
    m4_realm_fix_service

    if [[ "$was_active" == "true" ]] && m4_realm_has_endpoints; then
        systemctl reset-failed realm 2>/dev/null || true
        systemctl start realm 2>/dev/null || true
        sleep 2
        if ! systemctl is-active --quiet realm; then
            log_warn "新版本启动失败（可能与现有配置不兼容），正在回滚..."
            install -m 755 /root/realm/realm.bak-update /root/realm/realm
            systemctl start realm 2>/dev/null || true
            log_error "已回滚到更新前的版本"
            return 1
        fi
    fi
    rm -f /root/realm/realm.bak-update
    log_success "Realm 已更新: $(/root/realm/realm -v 2>&1 | head -1)"
}

menu_manage_realm() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 管理 Realm (端口转发) ══${NC}"
        echo -e "  ${CYAN}（无需 Docker / Nginx；至少添加一条转发规则后服务才会运行）${NC}"
        echo ""
        
        local is_installed=false
        if [[ -f "/root/realm/realm" ]]; then
            is_installed=true
        fi

        local status_str="${RED}○ 未安装${NC}"
        if [[ "$is_installed" == "true" ]]; then
            if systemctl is-active --quiet realm 2>/dev/null; then
                status_str="${GREEN}● 运行中${NC}"
            elif ! m4_realm_has_endpoints; then
                status_str="${YELLOW}○ 未运行 (尚未添加转发规则)${NC}"
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
        echo "  7) 更新 Realm (升级 / 降级)"
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
            7) update_realm; press_enter ;;
            0) return ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}
# ----------------------------------------------------------

# ────────────────────────────────────────────────────────────────
#  sing-box / Xray 更新（二进制替换：先校验现有配置，失败自动回滚）
# ────────────────────────────────────────────────────────────────
m4_service_bin() { # 从 systemd 单元解析实际运行的二进制路径
    local unit="$1" fallback="$2" bin
    bin=$(systemctl cat "$unit" 2>/dev/null | grep -m1 '^ExecStart=' | sed 's/^ExecStart=//; s/^[-@+!:]*//' | awk '{print $1}')
    [[ -n "$bin" && -x "$bin" ]] || bin=$(command -v "$fallback" 2>/dev/null)
    echo "$bin"
}

update_singbox() {
    log_step "更新 sing-box（无需 Docker）"
    is_cmd_exist sing-box || { log_error "未检测到 sing-box，请先安装"; return 1; }
    log_info "当前版本: $(sing-box version 2>/dev/null | head -1)"
    local recent
    recent=$(m4_gh_recent_tags "SagerNet/sing-box" 8 | tr '\n' ' ')
    [[ -n "$recent" ]] && log_info "最近发布: $recent"
    echo "  1) 更新到最新稳定版"
    echo "  2) 指定版本 (升级 / 降级均可，例如 1.12.0)"
    echo "  3) 更新到 Beta / 预发布版"
    echo "  0) 取消"
    local mode tag=""
    read -rp "  > 请选择 (默认 0): " mode
    mode=${mode:-0}
    case "$mode" in
        0) return 0 ;;
        1) tag=$(m4_gh_latest_tag "SagerNet/sing-box") ;;
        2) read -rp "请输入版本号 (如 1.12.0): " tag; tag="${tag// /}" ;;
        3) tag=$(m4_gh_recent_tags "SagerNet/sing-box" 1) ;;
        *) log_warn "无效选择"; return 1 ;;
    esac
    [[ -z "$tag" ]] && { log_error "未能确定目标版本"; return 1; }
    local ver="${tag#v}" arch tmp url bin new
    read -rp "确认更新到 sing-box ${ver}？(y/N): " ok
    [[ "${ok,,}" == "y" ]] || { log_info "已取消"; return 0; }

    arch=$(m4_arch_go)
    url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
    tmp=$(mktemp -d /tmp/singbox-up.XXXXXX)
    if ! curl -fsSL -L "$url" -o "$tmp/sb.tar.gz" || ! tar -xzf "$tmp/sb.tar.gz" -C "$tmp"; then
        log_error "下载/解压失败（版本是否存在？）：$url"; rm -rf "$tmp"; return 1
    fi
    new=$(find "$tmp" -type f -name sing-box -perm -u+x | head -1)
    if [[ -z "$new" ]] || ! "$new" version >/dev/null 2>&1; then
        log_error "新版本二进制不可用（架构不匹配？）"; rm -rf "$tmp"; return 1
    fi
    if [[ -s /etc/sing-box/config.json ]]; then
        if ! ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true "$new" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
            log_warn "新版本无法通过当前配置校验（跨大版本常见：配置字段被废弃/调整）："
            ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true "$new" check -c /etc/sing-box/config.json 2>&1 | head -5 | sed 's/^/    /'
            read -rp "仍要继续更新吗？(y/N): " go
            [[ "${go,,}" == "y" ]] || { rm -rf "$tmp"; log_info "已取消，现有 sing-box 未改动"; return 0; }
        fi
    fi

    bin=$(m4_service_bin sing-box sing-box)
    [[ -z "$bin" ]] && bin="/usr/bin/sing-box"
    local was_active=false
    systemctl is-active --quiet sing-box && was_active=true
    cp -f "$bin" "${bin}.bak-update" 2>/dev/null || true
    systemctl stop sing-box 2>/dev/null || true
    install -m 755 "$new" "$bin"
    # 同步 /usr/local/bin 与 /usr/bin 里可能并存的另一份，防止 PATH 优先级导致"更新了却没生效"
    local other
    for other in /usr/local/bin/sing-box /usr/bin/sing-box; do
        [[ "$other" != "$bin" && -f "$other" ]] && install -m 755 "$new" "$other"
    done
    rm -rf "$tmp"
    hash -r 2>/dev/null || true
    m4_hold_pkg sing-box sing-box-beta   # 锁定版本，禁止 apt 后台自动升级

    if [[ "$was_active" == "true" ]]; then
        systemctl start sing-box 2>/dev/null || true
        sleep 3
        if ! systemctl is-active --quiet sing-box; then
            log_warn "新版本启动失败，正在回滚..."
            [[ -f "${bin}.bak-update" ]] && install -m 755 "${bin}.bak-update" "$bin"
            systemctl start sing-box 2>/dev/null || true
            log_error "已回滚。失败原因: $(journalctl -u sing-box -n 3 --no-pager 2>/dev/null | tail -2 | tr '\n' ' ')"
            return 1
        fi
    fi
    rm -f "${bin}.bak-update"
    log_success "sing-box 已更新: $(sing-box version 2>/dev/null | head -1)"
}

update_xray() {
    log_step "更新 Xray-core（无需 Docker）"
    is_cmd_exist xray || { log_error "未检测到 Xray-core，请先安装"; return 1; }
    log_info "当前版本: $(xray version 2>/dev/null | head -1)"
    local recent
    recent=$(m4_gh_recent_tags "XTLS/Xray-core" 8 | tr '\n' ' ')
    [[ -n "$recent" ]] && log_info "最近发布: $recent"
    echo "  1) 更新到最新稳定版"
    echo "  2) 指定版本 (升级 / 降级均可，例如 1.8.24 或 v25.1.1)"
    echo "  3) 更新到 Beta / 预发布版 (最新发布)"
    echo "  0) 取消"
    local mode tag=""
    read -rp "  > 请选择 (默认 0): " mode
    mode=${mode:-0}
    case "$mode" in
        0) return 0 ;;
        1) tag=$(m4_gh_latest_tag "XTLS/Xray-core") ;;
        2) read -rp "请输入版本号: " tag; tag="${tag// /}"; [[ -n "$tag" && "$tag" != v* ]] && tag="v$tag" ;;
        3) tag=$(m4_gh_recent_tags "XTLS/Xray-core" 1) ;;
        *) log_warn "无效选择"; return 1 ;;
    esac
    [[ -z "$tag" ]] && { log_error "未能确定目标版本"; return 1; }
    read -rp "确认更新到 Xray ${tag}？(y/N): " ok
    [[ "${ok,,}" == "y" ]] || { log_info "已取消"; return 0; }

    local arch_s
    case "$(uname -m)" in
        x86_64) arch_s="64" ;;
        aarch64) arch_s="arm64-v8a" ;;
        armv7l) arch_s="arm32-v7a" ;;
        *) arch_s="64" ;;
    esac
    if ! is_cmd_exist unzip; then
        if [[ "$PKG_MANAGER" == "apt" ]]; then apt update -y >/dev/null 2>&1 || true; apt install -y unzip >/dev/null 2>&1 || true
        else $PKG_MANAGER install -y unzip >/dev/null 2>&1 || true; fi
    fi
    local tmp new bin cfg="/usr/local/etc/xray/config.json" was_active=false
    tmp=$(mktemp -d /tmp/xray-up.XXXXXX)
    if ! curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${arch_s}.zip" -o "$tmp/x.zip" \
       || ! unzip -tq "$tmp/x.zip" >/dev/null 2>&1 || ! unzip -qo "$tmp/x.zip" -d "$tmp"; then
        log_error "下载/解压失败（版本 ${tag} 是否存在？）"; rm -rf "$tmp"; return 1
    fi
    new="$tmp/xray"
    if [[ ! -f "$new" ]]; then log_error "压缩包内未找到 xray"; rm -rf "$tmp"; return 1; fi
    chmod +x "$new"
    "$new" version >/dev/null 2>&1 || { log_error "新版本二进制不可用（架构不匹配？）"; rm -rf "$tmp"; return 1; }
    if [[ -s "$cfg" ]] && ! "$new" run -test -config "$cfg" >/dev/null 2>&1; then
        log_warn "新版本无法通过当前配置校验："
        "$new" run -test -config "$cfg" 2>&1 | tail -4 | sed 's/^/    /'
        read -rp "仍要继续更新吗？(y/N): " go
        [[ "${go,,}" == "y" ]] || { rm -rf "$tmp"; log_info "已取消，现有 Xray 未改动"; return 0; }
    fi

    bin=$(m4_service_bin xray xray)
    [[ -z "$bin" ]] && bin="/usr/local/bin/xray"
    systemctl is-active --quiet xray && was_active=true
    cp -f "$bin" "${bin}.bak-update" 2>/dev/null || true
    systemctl stop xray 2>/dev/null || true
    install -m 755 "$new" "$bin"
    mkdir -p /usr/local/share/xray
    [[ -f "$tmp/geoip.dat" ]] && install -m 644 "$tmp/geoip.dat" /usr/local/share/xray/geoip.dat
    [[ -f "$tmp/geosite.dat" ]] && install -m 644 "$tmp/geosite.dat" /usr/local/share/xray/geosite.dat
    rm -rf "$tmp"
    hash -r 2>/dev/null || true

    if [[ "$was_active" == "true" ]]; then
        systemctl start xray 2>/dev/null || true
        sleep 3
        if ! systemctl is-active --quiet xray; then
            log_warn "新版本启动失败，正在回滚..."
            [[ -f "${bin}.bak-update" ]] && install -m 755 "${bin}.bak-update" "$bin"
            systemctl start xray 2>/dev/null || true
            log_error "已回滚。失败原因: $(journalctl -u xray -n 3 --no-pager 2>/dev/null | tail -2 | tr '\n' ' ')"
            return 1
        fi
    fi
    rm -f "${bin}.bak-update"
    log_success "Xray-core 已更新: $(xray version 2>/dev/null | head -1)"
}

# ────────────────────────────────────────────────────────────────
#  Nginx / Docker 更新（基于系统包管理器 / 官方脚本）
# ────────────────────────────────────────────────────────────────
update_nginx() {
    log_step "更新 Nginx（无需 Docker）"
    is_cmd_exist nginx || { log_error "未检测到 Nginx，请先安装"; return 1; }
    log_info "当前版本: $(nginx -v 2>&1 | head -1)"
    echo "  1) 更新到软件源中的最新版"
    echo "  2) 指定版本 (升级 / 降级均可，需软件源中存在该版本)"
    echo "  0) 取消"
    local mode ver=""
    read -rp "  > 请选择 (默认 0): " mode
    mode=${mode:-0}
    case "$mode" in
        0) return 0 ;;
        1) : ;;
        2)
            if [[ "$PKG_MANAGER" == "apt" ]]; then
                apt-cache madison nginx 2>/dev/null | awk '{print "    " $3}' | head -8
            fi
            read -rp "请输入完整版本号 (与上方列表一致): " ver; ver="${ver// /}"
            [[ -z "$ver" ]] && { log_info "未输入，已取消"; return 0; } ;;
        *) log_warn "无效选择"; return 1 ;;
    esac
    read -rp "确认更新 Nginx？这会重载所有面板的反代配置。(y/N): " ok
    [[ "${ok,,}" == "y" ]] || { log_info "已取消"; return 0; }

    m4_backup_dir /etc/nginx nginx
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt-get update -y >/dev/null 2>&1 || true
        if [[ -n "$ver" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades -o Dpkg::Options::="--force-confold" "nginx=$ver" \
                || { log_error "指定版本安装失败"; return 1; }
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade -o Dpkg::Options::="--force-confold" nginx \
                || { log_error "Nginx 更新失败"; return 1; }
        fi
    else
        if [[ -n "$ver" ]]; then $PKG_MANAGER install -y "nginx-$ver" || $PKG_MANAGER downgrade -y "nginx-$ver" || { log_error "指定版本安装失败"; return 1; }
        else $PKG_MANAGER update -y nginx || { log_error "Nginx 更新失败"; return 1; }; fi
    fi
    hash -r 2>/dev/null || true
    if m4_reload_nginx; then
        log_success "Nginx 已更新并正常运行: $(nginx -v 2>&1 | head -1)"
    else
        log_warn "Nginx 已更新但未能正常重载，配置备份位于 /root/docker/backups/，请检查上方提示"
    fi
}

update_docker() {
    log_step "更新 Docker（面板类服务所需环境）"
    is_cmd_exist docker || { log_error "未检测到 Docker，请先安装"; return 1; }
    log_info "当前版本: $(docker --version 2>/dev/null)"
    echo -e "  ${YELLOW}注意：升级会重启 Docker 守护进程，所有容器将短暂中断 (restart: unless-stopped 的容器会自动恢复)。${NC}"
    echo "  1) 更新到软件源中的最新版"
    echo "  2) 指定版本 (通过官方安装脚本，例如 27.3.1；降级可能需要先手动处理)"
    echo "  0) 取消"
    local mode ver=""
    read -rp "  > 请选择 (默认 0): " mode
    mode=${mode:-0}
    case "$mode" in
        0) return 0 ;;
        1) : ;;
        2) read -rp "请输入 Docker 版本号: " ver; ver="${ver// /}"; [[ -z "$ver" ]] && { log_info "未输入，已取消"; return 0; } ;;
        *) log_warn "无效选择"; return 1 ;;
    esac
    read -rp "确认继续？(y/N): " ok
    [[ "${ok,,}" == "y" ]] || { log_info "已取消"; return 0; }

    if [[ -n "$ver" ]]; then
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || { log_error "下载安装脚本失败"; return 1; }
        VERSION="$ver" sh /tmp/get-docker.sh || { log_error "指定版本安装失败"; rm -f /tmp/get-docker.sh; return 1; }
        rm -f /tmp/get-docker.sh
    elif [[ "$PKG_MANAGER" == "apt" ]]; then
        apt-get update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io \
            || { log_error "Docker 更新失败"; return 1; }
    else
        $PKG_MANAGER update -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || { log_error "Docker 更新失败"; return 1; }
    fi
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    local i; for i in 1 2 3 4 5 6 7 8 9 10; do m4_docker_alive && break; sleep 1; done
    if m4_docker_alive; then
        log_success "Docker 已更新: $(docker --version 2>/dev/null)"
        docker ps --format '    容器 {{.Names}}: {{.Status}}' 2>/dev/null || true
    else
        log_error "Docker 更新后守护进程未能启动，请执行 journalctl -u docker -n 30 排查"
        return 1
    fi
}

menu_install_service() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 三、安装服务 (包含 Docker/拓展) ══${NC}"
        echo ""
        echo -e "  ${YELLOW}依赖说明：${NC}Sub-Store / Wallos / Komari 运行在 Docker 容器中，【需要 Docker + Nginx】(缺失时自动补装)；"
        echo -e "  ${YELLOW}        ${NC}sing-box / Xray / Realm / Nginx 为独立程序，【无需 Docker】。"
        echo ""
        echo -e "  ${CYAN}── 核心代理 (sing-box)【无需 Docker】 ──${NC}"
        echo "  1) 安装 sing-box 最新稳定版"
        echo "  2) 安装 sing-box 指定版本号"
        echo "  3) 安装 sing-box Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Nginx (用于反代和回落)【无需 Docker】 ──${NC}"
        echo "  4) 安装 Nginx 最新稳定版"
        echo "  5) 安装 Nginx 指定版本号"
        echo "  6) 安装 Nginx Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── 安装/修复 Docker 环境 (面板类服务的基础) ──${NC}"
        echo "  7) 安装 Docker 最新稳定版"
        echo "  8) 安装 Docker 指定版本号"
        echo "  9) 安装 Docker Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Sub-Store (订阅转换中心)【需要 Docker + Nginx】 ──${NC}"
        echo " 10) 安装 Sub-Store 最新稳定版"
        echo " 11) 安装 Sub-Store 指定版本号"
        echo " 12) 安装 Sub-Store / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Wallos (个人财务与订阅追踪)【需要 Docker + Nginx】 ──${NC}"
        echo " 13) 安装 Wallos 最新稳定版"
        echo " 14) 安装 Wallos 指定版本号 (默认: 2.36.2，回车确认)"
        echo " 15) 安装 Wallos Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Realm (端口转发工具)【无需 Docker】 ──${NC}"
        echo " 16) 进入 Realm 管理面板 (部署/转发/更新/卸载)"
        echo ""
        echo -e "  ${CYAN}── 核心代理 (Xray)【无需 Docker】 ──${NC}"
        echo " 17) 安装 Xray 最新稳定版"
        echo " 18) 安装 Xray 指定版本号"
        echo " 19) 安装 Xray Beta / 预发布版"
        echo ""
        echo -e "  ${CYAN}── Komari (轻量级服务器监控探针)【需要 Docker + Nginx】 ──${NC}"
        echo " 20) 安装 Komari 最新稳定版"
        echo " 21) 安装 Komari 指定版本号"
        echo " 22) 安装 Komari Snapshot / 预发布版"
        echo ""
        echo -e "  ${CYAN}── 服务更新 / 版本切换 (可升级也可降级；自动备份，失败自动回滚；不会改动你的域名/证书/配置) ──${NC}"
        echo " 23) 更新 Sub-Store  (前后端版本自动成套匹配)"
        echo " 24) 更新 Wallos"
        echo " 25) 更新 Komari"
        echo " 26) 更新 sing-box"
        echo " 27) 更新 Xray"
        echo " 28) 更新 Realm"
        echo " 29) 更新 Nginx"
        echo " 30) 更新 Docker"
        echo ""
        echo -e "  ${CYAN}── 批量执行 ──${NC}"
        echo -e " ${GREEN}100) 全部自动执行 (所有服务)${NC}"
        echo -e " ${YELLOW}101) 全部手动执行 (所有服务)${NC}"
        echo -e " ${PURPLE}102) 请输入服务（例如 1 4 7 10 14 16 17 20，默认 0）${NC}"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        echo -e "  ${YELLOW}说明：所有服务均不会在后台自动更新，只有您在此菜单手动更新时才会变动版本。${NC}"
        echo ""
        read -rp "请选择 (默认 0): " vc_raw
        vc_raw=${vc_raw:-0}

        local SVC_CHOICES=()
        if [[ "$vc_raw" == "100" ]]; then
            SVC_CHOICES=(1 4 7 10 14 160 17 20)
            AUTO_DEFAULT=true
        elif [[ "$vc_raw" == "101" ]]; then
            SVC_CHOICES=(1 4 7 10 14 160 20)
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

        m4_wait_apt_lock || { press_enter; continue; }   # 优化5：先等待 apt 锁释放，避免新系统刚装完时安装全部失败
        for vc in "${SVC_CHOICES[@]}"; do
            case $vc in
                0) return ;;
                1|2|3)
                    if is_cmd_exist sing-box; then
                        local ver
                        ver=$(sing-box version 2>/dev/null | head -1)
                        log_info "当前已安装版本: $ver"
                        if ! prompt_reinstall "sing-box"; then
                            [[ "$is_batch" == "false" ]] && press_enter
                            continue
                        fi
                    fi

                    # 优化5：解除 apt 版本锁，否则重装/升级会被 apt 拒绝（安装完成后会重新锁定）
                    m4_unhold_pkg sing-box sing-box-beta

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
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box run -c /etc/sing-box/config.json
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
                        
                        # 优化5：锁定版本，禁止 apt upgrade / unattended-upgrades 后台悄悄升级
                        m4_hold_pkg sing-box sing-box-beta

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
                23) update_substore; [[ "$is_batch" == "false" ]] && press_enter ;;
                24) update_wallos;   [[ "$is_batch" == "false" ]] && press_enter ;;
                25) update_komari;   [[ "$is_batch" == "false" ]] && press_enter ;;
                26) update_singbox;  [[ "$is_batch" == "false" ]] && press_enter ;;
                27) update_xray;     [[ "$is_batch" == "false" ]] && press_enter ;;
                28) update_realm;    [[ "$is_batch" == "false" ]] && press_enter ;;
                29) update_nginx;    [[ "$is_batch" == "false" ]] && press_enter ;;
                30) update_docker;   [[ "$is_batch" == "false" ]] && press_enter ;;
                *) log_warn "未知选项或服务: $vc，跳过"; sleep 1 ;;
            esac
        done

        if [[ "$is_batch" == "true" ]]; then
            log_success "所有指定的安装步骤均已执行完毕！"
            press_enter
        fi
    done
}
