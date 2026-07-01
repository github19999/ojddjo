#!/bin/bash
# ── mod07_gen_links.sh ── 由 vpsge.sh 通过 source 加载，请勿单独执行 ──
#
# ════════════════════════ 历史更新说明 ════════════════════════
#
# ── 优化(原优化3) ──────────────────────────────────────────────
# 新增：生成节点链接时，sing-box 与 Xray-core 节点分类显示
#   - 原 generate_links() 中针对 sing-box 的全部逻辑原封不动地抽到
#     generate_links_singbox()，行为与文件输出路径完全不变
#     (/etc/sing-box/subscription.txt /subscription.b64 /clash.yaml)
#   - 新增 generate_links_xray()：读取 mod05 写入的
#     /etc/xray/node_meta.conf + /usr/local/etc/xray/config.json，
#     生成 Xray REALITY/xhttp 节点链接，输出到
#     /usr/local/etc/xray/subscription.txt /subscription.b64
#   - generate_links() 改为总调度：若检测到 sing-box 配置则展示
#     "sing-box 节点" 分区，若检测到 Xray 配置则展示 "Xray-core 节点"
#     分区，两者互不影响，缺一不报错（仅跳过并提示）
#   - 菜单新增第 6/7 项查看 Xray 订阅文件，原有 1-5 项功能不变
#
# ── 优化1：sing-box REALITY 节点 address 使用服务器 IP ─────────
#   - generate_links_singbox() Python 段中，REALITY inbound 的
#     addr 强制使用 SERVER_IP，不再用 SNI 域名作为连接地址
#     （SNI 仅用于 TLS 握手伪装，用域名会连到第三方服务器）
#   - is_ip() 判断移到 VLESS 处理段外层，reality_on 时直接
#     addr = SERVER_IP，确保链接 address 始终是真实服务器 IP
#
# ── 优化2/3：generate_links_xray() 新增 VARIANT 5/6 支持 ──────
#   VARIANT=5 → xray-reality-tcp-vision（无防偷跑+有流控）
#               vless://UUID@IP:PORT?...flow=xtls-rprx-vision...
#   VARIANT=6 → xray-xhttp-plain（xhttp 裸协议，无 REALITY/TLS）
#               vless://UUID@IP:PORT?type=xhttp&security=none...
#   两种新变体的 tag 末尾不再附加 PRIVATE_KEY（裸协议/无私钥场景）
# ════════════════════════════════════════════════════════════════════

# ────────────────────────────────────────────────────────────────
#  六、生成节点链接
# ────────────────────────────────────────────────────────────────
urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || \
    printf '%s' "$1" | od -An -tx1 | tr ' ' '%' | tr -d '\n'
}

get_server_ip() {
    local ip=""
    for svc in "https://api.ipify.org" "https://ifconfig.me" "https://ip.sb" "https://ipinfo.io/ip"; do
        ip=$(curl -s --max-time 4 "$svc" 2>/dev/null | tr -d '[:space:]') && [[ -n "$ip" ]] && break
    done
    echo "${ip:-127.0.0.1}"
}

generate_links_singbox() {
    local CONFIG="/etc/sing-box/config.json"
    if [[ ! -f "$CONFIG" ]]; then
        log_error "配置文件不存在: $CONFIG"
        return 1
    fi

    if ! is_cmd_exist python3; then
        log_error "需要 python3，请先安装"; return 1
    fi

    local SERVER_IP="$1"

    python3 << PYEOF
import json, base64, sys, re, urllib.parse

CONFIG_FILE = "/etc/sing-box/config.json"
SERVER_IP   = "$SERVER_IP"
OUTPUT_FILE = "/etc/sing-box/subscription.txt"
B64_FILE    = "/etc/sing-box/subscription.b64"
CLASH_FILE  = "/etc/sing-box/clash.yaml"

def urlencode(s):
    return urllib.parse.quote(str(s), safe='')

def b64(s):
    return base64.urlsafe_b64encode(s.encode()).decode().rstrip('=')

def get_sni(tls, addr):
    if isinstance(tls, dict):
        return tls.get('server_name') or addr
    return addr

def strip_comments(text):
    return re.sub(r'(?<![:/])//[^\n]*', '', text)

def is_ip(s):
    return bool(re.match(r'^[\d.]+$', str(s)) or re.match(r'^[0-9a-fA-F:]+$', str(s)))

with open(CONFIG_FILE) as f:
    raw = f.read()

try:
    config = json.loads(raw)
except:
    try:
        config = json.loads(strip_comments(raw))
    except Exception as e:
        print(f"[ERROR] 解析配置失败: {e}")
        sys.exit(1)

links = []
clash_proxies = []
clash_proxy_names = []

inbounds = config.get('inbounds', [])
for ib in inbounds:
    t    = ib.get('type', '')
    tag  = ib.get('tag', t)
    port = ib.get('listen_port')
    if not port:
        continue

    listen = ib.get('listen', '::')
    # ── 优化1：address 始终使用服务器真实 IP ──────────────────────────
    # listen 为 "::" / "0.0.0.0" 时强制用 SERVER_IP，
    # 即便是 REALITY 节点也不能用 SNI 域名作为连接地址，
    # 否则客户端会连接到域名解析出的第三方服务器而非本机。
    addr = SERVER_IP if listen in ('::', '0.0.0.0') else listen

    tls = ib.get('tls', {})
    tls_on = tls.get('enabled', False)
    sni = get_sni(tls, addr)

    # 仅非 REALITY 节点且 SNI 是域名（非 IP）时才用 SNI 替换 addr
    reality = tls.get('reality', {})
    reality_on = reality.get('enabled', False)
    if not reality_on and tls_on and sni and not is_ip(sni):
        addr = sni

    users = ib.get('users', [])
    transport = ib.get('transport', {})
    net = transport.get('type', 'tcp')
    ws_path = transport.get('path', '/')

    if t == 'vless':
        if not users: continue
        u = users[0]
        uuid  = u.get('uuid', '')
        flow  = u.get('flow', '')

        display_tag = tag
        if reality_on and re.search(r'-[A-Za-z0-9_-]+$', tag):
            display_tag = tag.rsplit('-', 1)[0]
            
        tag_enc = urlencode(tag)

        if reality_on:
            pbk = ''
            try:
                with open('/etc/sing-box/reality_meta.conf') as _mf:
                    for _line in _mf:
                        _line = _line.strip()
                        if _line.startswith(f"{port}:"):
                            pbk = _line.split(':', 1)[1]
                            break
            except Exception:
                pass
            sid_val = reality.get('short_id', [''])
            sid = sid_val[0] if isinstance(sid_val, list) else sid_val
            # REALITY 节点 addr 强制使用 SERVER_IP（已在上方 addr 赋值逻辑中保证）
            params = f"encryption=none&flow={flow}&security=reality&sni={sni}&fp=chrome&pbk={urlencode(pbk)}&sid={sid}&type=tcp&headerType=none"
        else:
            sec = 'tls' if tls_on else 'none'
            params = f"encryption=none"
            if flow: params += f"&flow={flow}"
            params += f"&security={sec}&sni={sni}&fp=chrome&type={net}&headerType=none"
            if net in ('ws', 'http'):
                params += f"&path={urlencode(ws_path)}"
            if net == 'grpc':
                svc = ib.get('transport', {}).get('service_name', '')
                if svc:
                    params += f"&serviceName={urlencode(svc)}"

        link = f"vless://{uuid}@{addr}:{port}?{params}#{tag_enc}"
        links.append(link)

        cp = {
            'name': display_tag, 'type': 'vless', 'server': addr, 'port': port,
            'uuid': uuid, 'tls': tls_on, 'servername': sni,
            'network': net, 'udp': True
        }
        if flow: cp['flow'] = flow
        if reality_on:
            cp['reality-opts'] = {'public-key': pbk, 'short-id': sid}
            cp['tls'] = True
        if net == 'ws':
            cp['ws-opts'] = {'path': ws_path, 'headers': {'Host': sni}}
        clash_proxies.append(cp)
        clash_proxy_names.append(display_tag)

    elif t == 'vmess':
        if not users: continue
        u = users[0]
        uuid = u.get('uuid', '')
        aid  = u.get('alterId', 0)
        tls_s = 'tls' if tls_on else 'none'
        tag_enc = urlencode(tag)

        obj = {
            'v':'2','ps':tag,'add':addr,'port':str(port),
            'id':uuid,'aid':str(aid),'scy':'auto',
            'net':net,'type':'none','host':sni,
            'path':ws_path,'tls':tls_s,'sni':sni,'fp':'chrome'
        }
        # VMess 分享链接规范使用标准 base64（含 + / 字符与 = 填充），而非 urlsafe 变体；
        # 之前用 urlsafe_b64encode 会导致部分客户端/重新导入解析失败
        enc = base64.b64encode(json.dumps(obj).encode()).decode()
        links.append(f"vmess://{enc}")

        cp = {
            'name': tag, 'type': 'vmess', 'server': addr, 'port': port,
            'uuid': uuid, 'alterId': aid, 'cipher': 'auto',
            'tls': tls_on, 'servername': sni, 'network': net, 'udp': True
        }
        if net == 'ws':
            cp['ws-opts'] = {'path': ws_path, 'headers': {'Host': sni}}
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    elif t == 'trojan':
        if not users: continue
        pwd = users[0].get('password', '')
        tag_enc = urlencode(tag)
        params = f"security=tls&sni={sni}&type={net}"
        if net == 'ws':
            params += f"&path={urlencode(ws_path)}"
        links.append(f"trojan://{urlencode(pwd)}@{addr}:{port}?{params}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'trojan', 'server': addr, 'port': port,
            'password': pwd, 'sni': sni, 'udp': True, 'network': net
        }
        if net == 'ws':
            cp['ws-opts'] = {'path': ws_path, 'headers': {'Host': sni}}
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    elif t == 'shadowsocks':
        method = ib.get('method', '')
        server_pwd = ib.get('password', '')
        tag_enc = urlencode(tag)
        if not method or not server_pwd: continue

        if method.startswith('2022-'):
            user_pwd = ''
            if users:
                user_pwd = users[0].get('password', '')
            if user_pwd:
                raw = f"{method}:{server_pwd}:{user_pwd}"
            else:
                raw = f"{method}:{server_pwd}"
            info = base64.urlsafe_b64encode(raw.encode()).decode().rstrip('=')
            clash_pwd = f"{server_pwd}:{user_pwd}" if user_pwd else server_pwd
        else:
            info = base64.urlsafe_b64encode(f"{method}:{server_pwd}".encode()).decode().rstrip('=')
            clash_pwd = server_pwd

        links.append(f"ss://{info}@{addr}:{port}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'ss', 'server': addr, 'port': port,
            'cipher': method, 'password': clash_pwd, 'udp': True
        }
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    elif t == 'hysteria2':
        if not users: continue
        pwd    = users[0].get('password', '')
        tag_enc = urlencode(tag)
        up_m   = ib.get('up_mbps', 200)
        dn_m   = ib.get('down_mbps', 100)
        obfs_conf = ib.get('obfs', {})
        obfs_type = obfs_conf.get('type', '')
        obfs_pwd  = obfs_conf.get('password', '')
        params = f"sni={sni}&insecure=0&allowInsecure=0&upmbps={up_m}&downmbps={dn_m}"
        if obfs_type:
            params += f"&obfs={obfs_type}"
        if obfs_pwd:
            params += f"&obfs-password={urlencode(obfs_pwd)}"
        links.append(f"hysteria2://{pwd}@{addr}:{port}?{params}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'hysteria2', 'server': addr, 'port': port,
            'password': pwd, 'sni': sni, 'up': f"{up_m} Mbps", 'down': f"{dn_m} Mbps",
            'skip-cert-verify': False
        }
        if obfs_type:
            cp['obfs'] = obfs_type
        if obfs_pwd:
            cp['obfs-password'] = obfs_pwd
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    elif t == 'tuic':
        if not users: continue
        u    = users[0]
        uuid = u.get('uuid', '')
        pwd  = u.get('password', '')
        tag_enc = urlencode(tag)
        cc   = ib.get('congestion_control', 'bbr')
        params = f"sni={sni}&congestion_control={cc}&alpn=h3&udp_relay_mode=native"
        links.append(f"tuic://{uuid}:{urlencode(pwd)}@{addr}:{port}?{params}#{tag_enc}")

        cp = {
            'name': tag, 'type': 'tuic', 'server': addr, 'port': port,
            'uuid': uuid, 'password': pwd, 'alpn': ['h3'],
            'congestion-controller': cc, 'sni': sni, 'udp-relay-mode': 'native'
        }
        clash_proxies.append(cp)
        clash_proxy_names.append(tag)

    elif t == 'anytls':
        if not users: continue
        pwd    = users[0].get('password', '')
        tag_enc = urlencode(tag)
        params = f"security=tls&sni={sni}&insecure=0&allowInsecure=0&type=tcp"
        links.append(f"anytls://{pwd}@{addr}:{port}?{params}#{tag_enc}")

    elif t == 'naive':
        if not users: continue
        u    = users[0]
        uname = u.get('username', '')
        pwd   = u.get('password', '')
        tag_enc = urlencode(tag)
        links.append(f"naive+https://{urlencode(uname)}:{urlencode(pwd)}@{addr}:{port}?padding=true#{tag_enc}")

with open(OUTPUT_FILE, 'w') as f:
    f.write('\n'.join(links) + '\n')

with open(B64_FILE, 'w') as f:
    f.write(base64.b64encode('\n'.join(links).encode()).decode() + '\n')

try:
    import yaml
    clash_doc = {
        'mixed-port': 7890,
        'allow-lan': False,
        'mode': 'rule',
        'log-level': 'info',
        'proxies': clash_proxies,
        'proxy-groups': [{
            'name': 'Proxy',
            'type': 'select',
            'proxies': clash_proxy_names + ['DIRECT']
        }],
        'rules': ['MATCH,Proxy']
    }
    with open(CLASH_FILE, 'w') as f:
        yaml.dump(clash_doc, f, allow_unicode=True, default_flow_style=False)
    print(f"Clash/Mihomo 配置已写入: {CLASH_FILE}")
except ImportError:
    with open(CLASH_FILE, 'w') as f:
        f.write("mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\n\nproxies:\n")
        for p in clash_proxies:
            f.write(f"  - name: {json.dumps(p['name'], ensure_ascii=False)}\n")
            f.write(f"    type: {p['type']}\n")
            f.write(f"    server: {p['server']}\n")
            f.write(f"    port: {p['port']}\n")
            for k, v in p.items():
                if k not in ('name','type','server','port'):
                    f.write(f"    {k}: {json.dumps(v, ensure_ascii=False) if isinstance(v,(dict,list)) else v}\n")
        f.write("\nproxy-groups:\n  - name: Proxy\n    type: select\n    proxies:\n")
        for n in clash_proxy_names:
            f.write(f"      - {json.dumps(n, ensure_ascii=False)}\n")
        f.write("      - DIRECT\n\nrules:\n  - MATCH,Proxy\n")

print(f"\n[✓] 共生成 {len(links)} 条订阅链接")
print(f"[✓] 明文订阅: {OUTPUT_FILE}")
print(f"[✓] Base64订阅 (V2RayN): {B64_FILE}")
print(f"[✓] Clash/Mihomo: {CLASH_FILE}")
print("")
print("══════════════ 所有节点链接 ══════════════")
for lk in links:
    print(lk)
print("══════════════════════════════════════════")
PYEOF
}

generate_links_xray() {
    local SERVER_IP="$1"
    local META="/etc/xray/node_meta.conf"
    local CONFIG="/usr/local/etc/xray/config.json"

    if [[ ! -f "$CONFIG" || ! -f "$META" ]]; then
        log_error "Xray 配置或元数据不存在，请先在「四、配置节点」中完成 Xray 配置"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$META"

    # 连接地址必须是服务器真实 IP，不能用 SNI 域名（SNI 仅用于 TLS 握手伪装，
    # 用域名会导致客户端实际连接到域名解析出的第三方服务器而不是本机，造成不通）
    local addr="$SERVER_IP"

    local tag="" link="" params=""
    case "${VARIANT:-1}" in
        1)
            tag="xray-reality-vision"
            params="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none"
            ;;
        2)
            tag="xray-reality"
            params="encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none"
            ;;
        3)
            tag="xray-reality-xhttp"
            params="encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=$(urlencode "${XHTTP_PATH:-/}")&mode=auto"
            ;;
        4)
            tag="xray-reality-xhttp-anti"
            params="encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=$(urlencode "${XHTTP_PATH:-/}")&mode=auto"
            ;;
        5)
            # VARIANT=5：原版REALITY + 无防偷跑 + 有流控（参考节点2.conf 结构）
            # 直接 0.0.0.0 监听，带 xtls-rprx-vision 流控，无 dokodemo-door
            tag="xray-reality-tcp-vision"
            params="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none"
            ;;
        6)
            # VARIANT=6：xhttp 裸协议（无 REALITY，无 TLS），套 CDN 或直连
            # 无私钥，tag 末尾不附加 PRIVATE_KEY
            tag="xray-xhttp-plain"
            params="encryption=none&security=none&type=xhttp&path=$(urlencode "${XHTTP_PATH:-/}")&mode=auto"
            ;;
        *)
            log_error "未知的 Xray 节点变体: ${VARIANT:-}"
            return 1
            ;;
    esac

    local tag_enc
    # 把 PrivateKey 编码进 tag(#fragment) 末尾：下次把这条链接粘贴回面板「导入旧节点」时，
    # mod05 的解析器会自动从 tag 末尾的 43 位 base64url 串还原私钥，无需再手动粘贴
    # VARIANT=6（xhttp 裸协议）无 REALITY 私钥，不附加
    if [[ -n "${PRIVATE_KEY:-}" && "${VARIANT}" != "6" ]]; then
        tag="${tag}-${PRIVATE_KEY}"
    fi
    tag_enc=$(urlencode "$tag")
    link="vless://${UUID}@${addr}:${PORT}?${params}#${tag_enc}"

    mkdir -p /usr/local/etc/xray
    echo "$link" > /usr/local/etc/xray/subscription.txt
    base64 -w0 /usr/local/etc/xray/subscription.txt > /usr/local/etc/xray/subscription.b64 2>/dev/null \
        || base64 /usr/local/etc/xray/subscription.txt | tr -d '\n' > /usr/local/etc/xray/subscription.b64
    echo "" >> /usr/local/etc/xray/subscription.b64

    echo ""
    echo "[✓] 共生成 1 条 Xray 节点链接"
    echo "[✓] 明文订阅: /usr/local/etc/xray/subscription.txt"
    echo "[✓] Base64订阅 (V2RayN): /usr/local/etc/xray/subscription.b64"
    if [[ "${VARIANT}" == "3" || "${VARIANT}" == "4" ]]; then
        echo "[i] 提示: xhttp+REALITY 节点暂不支持自动生成 Clash/Mihomo 配置，请使用支持 xhttp 的客户端导入上方链接"
    fi
    if [[ "${VARIANT}" == "6" ]]; then
        echo "[i] 提示: xhttp 裸协议节点请配合 CDN（如 Cloudflare）使用，或仅用于本地/内网直连"
    fi
    echo ""
    echo "$link"
}

generate_links() {
    local SERVER_IP
    log_info "获取服务器 IP..."
    SERVER_IP=$(get_server_ip)
    log_info "服务器 IP: $SERVER_IP"
    echo ""

    local has_any=false

    if [[ -f /etc/sing-box/config.json ]]; then
        echo -e "${BOLD}${CYAN}══════════════ sing-box 节点 ══════════════${NC}"
        generate_links_singbox "$SERVER_IP"
        echo -e "${BOLD}${CYAN}════════════════════════════════════════════${NC}"
        has_any=true
    else
        log_warn "未检测到 sing-box 配置文件 (/etc/sing-box/config.json)，跳过 sing-box 节点生成"
    fi

    echo ""

    if [[ -f /usr/local/etc/xray/config.json ]]; then
        echo -e "${BOLD}${CYAN}══════════════ Xray-core 节点 ══════════════${NC}"
        generate_links_xray "$SERVER_IP"
        echo -e "${BOLD}${CYAN}════════════════════════════════════════════${NC}"
        has_any=true
    else
        log_warn "未检测到 Xray 配置文件 (/usr/local/etc/xray/config.json)，跳过 Xray 节点生成"
    fi

    if [[ "$has_any" == "false" ]]; then
        log_error "未检测到任何核心的配置文件，请先在「四、配置节点」完成节点配置"
        return 1
    fi
}

menu_links() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 六、生成节点链接 ══${NC}"
        echo ""
        echo "  1) 生成所有节点链接（sing-box / Xray-core 分类显示，支持 V2RayN / Clash Mihomo）"
        echo "  2) 查看明文订阅 (sing-box)"
        echo "  3) 查看 Base64 订阅 (sing-box, V2RayN 用)"
        echo "  4) 查看 Clash/Mihomo 配置 (sing-box)"
        echo "  5) 显示订阅文件路径"
        echo "  6) 查看明文订阅 (Xray-core)"
        echo "  7) 查看 Base64 订阅 (Xray-core, V2RayN 用)"
        echo ""
        echo "  0) 返回主菜单"
        echo ""
        read -rp "请选择 (默认 0): " opt
        opt=${opt:-0}
        case $opt in
            1) generate_links; press_enter ;;
            2) cat /etc/sing-box/subscription.txt 2>/dev/null || log_warn "文件不存在，请先生成链接"; press_enter ;;
            3) cat /etc/sing-box/subscription.b64 2>/dev/null || log_warn "文件不存在，请先生成链接"; press_enter ;;
            4) cat /etc/sing-box/clash.yaml 2>/dev/null || log_warn "文件不存在，请先生成链接"; press_enter ;;
            5)
                echo "  明文订阅:       /etc/sing-box/subscription.txt"
                echo "  Base64 订阅:    /etc/sing-box/subscription.b64"
                echo "  Clash/Mihomo:   /etc/sing-box/clash.yaml"
                echo "  Xray 明文订阅:  /usr/local/etc/xray/subscription.txt"
                echo "  Xray Base64:    /usr/local/etc/xray/subscription.b64"
                press_enter ;;
            6) cat /usr/local/etc/xray/subscription.txt 2>/dev/null || log_warn "文件不存在，请先生成链接"; press_enter ;;
            7) cat /usr/local/etc/xray/subscription.b64 2>/dev/null || log_warn "文件不存在，请先生成链接"; press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}
