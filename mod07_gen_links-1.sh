#!/bin/bash
# ── mod07_gen_links.sh ── 由 vpsge.sh 通过 source 加载，请勿单独执行 ──


# ────────────────────────────────────────────────────────────────
#  六、生成节点链接
# ────────────────────────────────────────────────────────────────
urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || \
    printf '%s' "$1" | od -An -tx1 | tr ' ' '%' | tr -d '
'
}

get_server_ip() {
    local ip=""
    for svc in "https://api.ipify.org" "https://ifconfig.me" "https://ip.sb" "https://ipinfo.io/ip"; do
        ip=$(curl -s --max-time 4 "$svc" 2>/dev/null | tr -d '[:space:]') && [[ -n "$ip" ]] && break
    done
    echo "${ip:-127.0.0.1}"
}

generate_links() {
    local CONFIG="/etc/sing-box/config.json"
    if [[ ! -f "$CONFIG" ]]; then
        log_error "配置文件不存在: $CONFIG"
        return 1
    fi

    if ! is_cmd_exist python3; then
        log_error "需要 python3，请先安装"; return 1
    fi

    local SERVER_IP
    log_info "获取服务器 IP..."
    SERVER_IP=$(get_server_ip)
    log_info "服务器 IP: $SERVER_IP"
    echo ""

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
    return re.sub(r'(?<![:/])//[^
]*', '', text)

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
    addr = SERVER_IP if listen in ('::', '0.0.0.0') else listen

    tls = ib.get('tls', {})
    tls_on = tls.get('enabled', False)
    sni = get_sni(tls, addr)

    def is_ip(s):
        import re
        return bool(re.match(r'^[\d.]+$', s) or re.match(r'^[0-9a-fA-F:]+$', s))
    if tls_on and sni and not is_ip(sni):
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

        reality = tls.get('reality', {})
        reality_on = reality.get('enabled', False)
        
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
        enc = base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip('=')
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
    f.write('
'.join(links) + '
')

with open(B64_FILE, 'w') as f:
    f.write(base64.b64encode('
'.join(links).encode()).decode() + '
')

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
        f.write("mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

proxies:
")
        for p in clash_proxies:
            f.write(f"  - name: {json.dumps(p['name'], ensure_ascii=False)}
")
            f.write(f"    type: {p['type']}
")
            f.write(f"    server: {p['server']}
")
            f.write(f"    port: {p['port']}
")
            for k, v in p.items():
                if k not in ('name','type','server','port'):
                    f.write(f"    {k}: {json.dumps(v, ensure_ascii=False) if isinstance(v,(dict,list)) else v}
")
        f.write("
proxy-groups:
  - name: Proxy
    type: select
    proxies:
")
        for n in clash_proxy_names:
            f.write(f"      - {json.dumps(n, ensure_ascii=False)}
")
        f.write("      - DIRECT

rules:
  - MATCH,Proxy
")

print(f"
[✓] 共生成 {len(links)} 条订阅链接")
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

menu_links() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}══ 六、生成节点链接 ══${NC}"
        echo ""
        echo "  1) 生成所有节点链接（singbox / V2RayN / Clash Mihomo）"
        echo "  2) 查看明文订阅"
        echo "  3) 查看 Base64 订阅（V2RayN 用）"
        echo "  4) 查看 Clash/Mihomo 配置"
        echo "  5) 显示订阅文件路径"
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
                press_enter ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}
