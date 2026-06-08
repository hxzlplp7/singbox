#!/bin/bash

# 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "错误：必须以 root 权限运行此脚本！"
   exit 1
fi

# 设置语言环境
export LANG=en_US.UTF-8

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

log_info() { echo -e "${GREEN}[信息] $1${PLAIN}"; }
log_warn() { echo -e "${YELLOW}[警告] $1${PLAIN}"; }
log_err() { echo -e "${RED}[错误] $1${PLAIN}"; }

show_logo() {
    echo -e "${BLUE}====================================================================${PLAIN}"
    echo -e "${GREEN}   ____  _             ____                ${YELLOW} __  __ _ _                      ${PLAIN}"
    echo -e "${GREEN}  / ___|(_)_ __   __ _| __ )  _____  __    ${YELLOW}|  \\/  (_) |__   ___  _ __ ___  ${PLAIN}"
    echo -e "${GREEN}  \\___ \\| | '_ \\ / _\` |  _ \\ / _ \\ \\/ /    ${YELLOW}| |\\/| | | '_ \\ / _ \\| '_ \` _ \\ ${PLAIN}"
    echo -e "${GREEN}   ___) | | | | | (_| | |_) | (_) >  <     ${YELLOW}| |  | | | | | | (_) | | | | | |${PLAIN}"
    echo -e "${GREEN}  |____/|_|_| |_|\\__, |____/ \\___/_/\\_\\    ${YELLOW}|_|  |_|_|_| |_|\\___/|_| |_| |_|${PLAIN}"
    echo -e "${GREEN}                 |___/                                              ${PLAIN}"
    echo -e "${BLUE}====================================================================${PLAIN}"
    echo -e "${BLUE}    Sing-box (7大入站+Argo+Nginx) <=========> Mihomo (分流出站+yacd) ${PLAIN}"
    echo -e "${BLUE}                        双核心联动一体化一键部署脚本                ${PLAIN}"
    echo -e "${BLUE}====================================================================${PLAIN}"
    echo ""
}

show_logo

create_sb_tool() {
cat > /usr/local/bin/sb <<'EOF'
#!/bin/bash
# Sing-box & Mihomo 双核心极简管理控制台

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：必须以 root 权限运行此脚本！${PLAIN}"
   exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# 重新生成 Nginx 配置
regenerate_nginx_conf() {
    if [[ ! -f /etc/nginx/conf.d/singbox-argo.conf ]]; then
        return
    fi
    
    local port_nginx=$(grep -oE "listen 127.0.0.1:[0-9]+" /etc/nginx/conf.d/singbox-argo.conf | head -n 1 | awk -F: '{print $2}')
    [[ -z "$port_nginx" ]] && port_nginx=8401
    
    local nginx_locations=""
    
    # 检查 VMess WS
    if jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local vmess_port=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .listen_port' /etc/s-box/sb.json)
        local vmess_path=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .transport.path' /etc/s-box/sb.json)
        nginx_locations="${nginx_locations}
    location ${vmess_path} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${vmess_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$http_host;
    }"
    fi
    
    # 检查 Trojan WS
    if jq -e '.inbounds[] | select(.tag=="trojan-ws-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local trojan_ws_port=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .listen_port' /etc/s-box/sb.json)
        local trojan_ws_path=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .transport.path' /etc/s-box/sb.json)
        nginx_locations="${nginx_locations}
    location ${trojan_ws_path} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${trojan_ws_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$http_host;
    }"
    fi
    
    cat > /etc/nginx/conf.d/singbox-argo.conf <<EOF2
server {
    listen 127.0.0.1:${port_nginx};
    server_name localhost;
    ${nginx_locations}
}
EOF2
    systemctl restart nginx >/dev/null 2>&1
}

# 重新生成 info.log 分享链接与面板信息
regenerate_info_log() {
    local ipv4=$(curl -s4m5 icanhazip.com || curl -s4m5 api.ipify.org)
    local ipv6=$(curl -s6m5 icanhazip.com || curl -s6m5 api6.ipify.org)
    local ip=${ipv4:-$ipv6}
    
    local uuid=$(jq -r '.. | .uuid? // .password? | select(. != null)' /etc/s-box/sb.json | head -n 1)
    
    local public_key=""
    if [[ -f /etc/s-box/public.key ]]; then
        public_key=$(cat /etc/s-box/public.key)
    fi
    local short_id=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.reality.short_id[0] // empty' /etc/s-box/sb.json)
    
    local argo_domain=""
    if [[ -f /etc/s-box/argo.log ]]; then
        argo_domain=$(cat /etc/s-box/argo.log)
    fi

    cat > /etc/s-box/info.log <<EOF2
==================================================
        Sing-box + Mihomo 一键部署安装成功
        (入站全解密，出站统一桥接 Mihomo 路由)
==================================================
通用密码/UUID: ${uuid}

------------------【直连节点】--------------------
EOF2

    # 1. VLESS-Reality
    if jq -e '.inbounds[] | select(.tag=="vless-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_vless=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .listen_port' /etc/s-box/sb.json)
        local uuid_vless=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .users[0].uuid' /etc/s-box/sb.json)
        local sni_vless=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.server_name' /etc/s-box/sb.json)
        local vless_link="vless://${uuid_vless}@${ip}:${port_vless}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni_vless}&fp=chrome&pbk=${public_key}&sid=${short_id}#SB-VLESS-Reality"
        echo "1. VLESS-Reality:" >> /etc/s-box/info.log
        echo "${vless_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # 2. VMess-WS
    if jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .listen_port' /etc/s-box/sb.json)
        local uuid_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .users[0].uuid' /etc/s-box/sb.json)
        local path_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .transport.path' /etc/s-box/sb.json)
        local vmess_json=$(cat <<EOF2
{
  "v": "2",
  "ps": "SB-VMess-WS",
  "add": "${ip}",
  "port": "${port_vmess}",
  "id": "${uuid_vmess}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "",
  "path": "${path_vmess}",
  "tls": "none",
  "sni": ""
}
EOF2
)
        local vmess_link="vmess://$(echo -n "$vmess_json" | base64 -w 0)"
        echo "2. VMess-WS (无TLS):" >> /etc/s-box/info.log
        echo "${vmess_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # 3. Trojan-WS-TLS
    if jq -e '.inbounds[] | select(.tag=="trojan-tls-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .listen_port' /etc/s-box/sb.json)
        local pass_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .users[0].password' /etc/s-box/sb.json)
        local sni_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .tls.server_name' /etc/s-box/sb.json)
        local path_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .transport.path' /etc/s-box/sb.json)
        local path_trojan_encoded=$(echo -n "$path_trojan" | jq -sRr @uri)
        local trojan_link="trojan://${pass_trojan}@${ip}:${port_trojan}?security=tls&sni=${sni_trojan}&allowInsecure=1&type=ws&path=${path_trojan_encoded}#SB-Trojan-WS-TLS"
        echo "3. Trojan-WS-TLS (自签证书):" >> /etc/s-box/info.log
        echo "${trojan_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # 4. Hysteria2
    if jq -e '.inbounds[] | select(.tag=="hy2-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_hy2=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .listen_port' /etc/s-box/sb.json)
        local pass_hy2=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .users[0].password' /etc/s-box/sb.json)
        local hy2_link="hysteria2://${pass_hy2}@${ip}:${port_hy2}?insecure=1&sni=www.bing.com#SB-Hysteria2"
        echo "4. Hysteria2:" >> /etc/s-box/info.log
        echo "${hy2_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # 5. TUIC v5
    if jq -e '.inbounds[] | select(.tag=="tuic-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_tuic=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .listen_port' /etc/s-box/sb.json)
        local uuid_tuic=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].uuid' /etc/s-box/sb.json)
        local pass_tuic=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].password' /etc/s-box/sb.json)
        local tuic_link="tuic://${uuid_tuic}:${pass_tuic}@${ip}:${port_tuic}?alpn=h3&congestion_control=bbr&udp_relay=1&allow_insecure=1#SB-TUIC-v5"
        echo "5. TUIC v5:" >> /etc/s-box/info.log
        echo "${tuic_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # 6. AnyTLS
    if jq -e '.inbounds[] | select(.tag=="anytls-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_anytls=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .listen_port' /etc/s-box/sb.json)
        local pass_anytls=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .users[0].password' /etc/s-box/sb.json)
        local sni_anytls=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .tls.server_name' /etc/s-box/sb.json)
        local anytls_link="anytls://${pass_anytls}@${ip}:${port_anytls}?security=tls&sni=${sni_anytls}&allowInsecure=1#SB-AnyTLS"
        echo "6. AnyTLS:" >> /etc/s-box/info.log
        echo "${anytls_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # Argo
    if [[ -n "$argo_domain" ]]; then
        echo "------------------【Argo穿透】--------------------" >> /etc/s-box/info.log
        echo "Argo 临时域名: ${argo_domain}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log

        if jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
            local uuid_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .users[0].uuid' /etc/s-box/sb.json)
            local path_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .transport.path' /etc/s-box/sb.json)
            local vmess_argo_json=$(cat <<EOF2
{
  "v": "2",
  "ps": "SB-VMess-Argo-80",
  "add": "cdn.2020111.xyz",
  "port": "80",
  "id": "${uuid_vmess}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${argo_domain}",
  "path": "${path_vmess}",
  "tls": "none",
  "sni": ""
}
EOF2
)
            local vmess_argo_80_link="vmess://$(echo -n "$vmess_argo_json" | base64 -w 0)"

            local vmess_argo_tls_json=$(cat <<EOF2
{
  "v": "2",
  "ps": "SB-VMess-Argo-443",
  "add": "cdn.2020111.xyz",
  "port": "443",
  "id": "${uuid_vmess}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${argo_domain}",
  "path": "${path_vmess}",
  "tls": "tls",
  "sni": "${argo_domain}"
}
EOF2
)
            local vmess_argo_443_link="vmess://$(echo -n "$vmess_argo_tls_json" | base64 -w 0)"

            echo "1. VMess Argo (80端口):" >> /etc/s-box/info.log
            echo "${vmess_argo_80_link}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            echo "2. VMess Argo (443端口/TLS):" >> /etc/s-box/info.log
            echo "${vmess_argo_443_link}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi

        if jq -e '.inbounds[] | select(.tag=="trojan-ws-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
            local pass_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .users[0].password' /etc/s-box/sb.json)
            local path_trojan_ws=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .transport.path' /etc/s-box/sb.json)
            local path_trojan_ws_encoded=$(echo -n "$path_trojan_ws" | jq -sRr @uri)
            
            local trojan_argo_80_link="trojan://${pass_trojan}@cdn.2020111.xyz:80?security=none&type=ws&path=${path_trojan_ws_encoded}&host=${argo_domain}#SB-Trojan-Argo-80"
            local trojan_argo_443_link="trojan://${pass_trojan}@cdn.2020111.xyz:443?security=tls&sni=${argo_domain}&type=ws&path=${path_trojan_ws_encoded}&host=${argo_domain}#SB-Trojan-Argo-443"

            echo "3. Trojan Argo (80端口):" >> /etc/s-box/info.log
            echo "${trojan_argo_80_link}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            echo "4. Trojan Argo (443端口/TLS):" >> /etc/s-box/info.log
            echo "${trojan_argo_443_link}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi
    fi

    # 获取出站桥接与网页控制面板参数
    local mihomo_port=$(jq -r '.outbounds[] | select(.tag=="mihomo-out") | .server_port // "未配置"' /etc/s-box/sb.json)
    
    local yacd_port=$(grep -oE "external-controller:.*:[0-9]+" /etc/mihomo/config.yaml 2>/dev/null | awk -F: '{print $NF}' | tr -d "'\" ")
    [[ -z "$yacd_port" ]] && yacd_port=$(grep -oE "external-controller:.*" /etc/mihomo/config.yaml 2>/dev/null | head -n 1 | tr -d "'\" " | awk -F: '{print $NF}')
    [[ -z "$yacd_port" ]] && yacd_port="9090"
    
    local yacd_secret=$(grep -E "^secret:" /etc/mihomo/config.yaml 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d "'\" ")

    echo "------------------【出站桥接】--------------------" >> /etc/s-box/info.log
    echo "本地出站 Mihomo (Socks5) 端口: ${mihomo_port}" >> /etc/s-box/info.log
    echo "yacd 可视化控制面板访问地址: http://${ip}:${yacd_port}/ui" >> /etc/s-box/info.log
    echo "yacd 连接密钥/密码: ${yacd_secret}" >> /etc/s-box/info.log
    echo "==================================================" >> /etc/s-box/info.log
}

# 重新获取 Argo 临时域名并写入 argo.log
update_argo_domain() {
    if [[ ! -f /etc/nginx/conf.d/singbox-argo.conf ]]; then
        return
    fi
    echo "正在等待 Argo 隧道上线并获取临时域名..."
    sleep 6
    local argo_domain=""
    for i in {1..5}; do
        argo_domain=$(journalctl -u argo-tunnel -n 50 --no-pager | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | head -n 1)
        [[ -n "$argo_domain" ]] && break
        sleep 2
    done
    if [[ -n "$argo_domain" ]]; then
        echo "$argo_domain" > /etc/s-box/argo.log
        echo "成功获取 Argo 新域名: $argo_domain"
    else
        echo "警告：未获取到 Argo 域名，可能隧道启动较慢，请稍后查看。"
    fi
}

apply_changes() {
    echo "正在应用更改，重启 Sing-box 服务..."
    systemctl restart sing-box
    
    if [[ -f /etc/nginx/conf.d/singbox-argo.conf ]]; then
        echo "正在重启 Nginx 和 Argo 服务..."
        regenerate_nginx_conf
        systemctl restart argo-tunnel 2>/dev/null
        update_argo_domain
    fi
    
    regenerate_info_log
    echo "更改已成功应用并重启服务！"
}

check_port() {
    local port=$1
    if ss -tunlp | grep -q ":$port "; then
        return 1
    else
        return 0
    fi
}

modify_vless() {
    while true; do
        local cur_port=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .listen_port' /etc/s-box/sb.json)
        local cur_uuid=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .users[0].uuid' /etc/s-box/sb.json)
        local cur_sni=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.server_name' /etc/s-box/sb.json)
        local cur_dest=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.reality.handshake.server' /etc/s-box/sb.json)
        local cur_dest_port=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.reality.handshake.server_port' /etc/s-box/sb.json)
        
        echo "--------------------------------------------------"
        echo "          VLESS-Reality 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 UUID (当前: $cur_uuid)"
        echo "3. 修改 SNI 域名 (当前: $cur_sni)"
        echo "4. 修改目标 IP/强绑定域名 (当前: $cur_dest:$cur_dest_port)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-4]: " vless_choice
        
        if [[ "$vless_choice" == "0" || -z "$vless_choice" ]]; then
            break
        fi
        
        case $vless_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --argjson port "$new_port" '(.inbounds[] | select(.tag=="vless-in") | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新 UUID (留空随机生成): " new_uuid
                if [[ -z "$new_uuid" ]]; then
                    new_uuid=$(/etc/s-box/sing-box generate uuid)
                fi
                local temp_json=$(mktemp)
                jq --arg uuid "$new_uuid" '(.inbounds[] | select(.tag=="vless-in") | .users[0].uuid) = $uuid' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                echo "UUID 修改成功，新 UUID: $new_uuid"
                apply_changes
                ;;
            3)
                read -p "请输入新 SNI 域名: " new_sni
                if [[ -n "$new_sni" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg sni "$new_sni" '(.inbounds[] | select(.tag=="vless-in") | .tls.server_name) = $sni' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "SNI 修改成功，新 SNI: $new_sni"
                    apply_changes
                else
                    echo "域名不能为空！"
                fi
                ;;
            4)
                read -p "请输入新目标域名/IP: " new_dest
                read -p "请输入新目标端口 [默认 443]: " new_dest_port
                [[ -z "$new_dest_port" ]] && new_dest_port=443
                if [[ -n "$new_dest" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg dest "$new_dest" --argjson dest_port "$new_dest_port" '
                        (.inbounds[] | select(.tag=="vless-in") | .tls.reality.handshake.server) = $dest |
                        (.inbounds[] | select(.tag=="vless-in") | .tls.reality.handshake.server_port) = $dest_port
                    ' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "目标修改成功，新目标: $new_dest:$new_dest_port"
                    apply_changes
                else
                    echo "目标不能为空！"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_vmess() {
    while true; do
        local cur_port=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .listen_port' /etc/s-box/sb.json)
        local cur_uuid=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .users[0].uuid' /etc/s-box/sb.json)
        local cur_path=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .transport.path' /etc/s-box/sb.json)
        
        echo "--------------------------------------------------"
        echo "          VMess-WS 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 UUID (当前: $cur_uuid)"
        echo "3. 修改 WS 路径 (当前: $cur_path)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-3]: " vmess_choice
        
        if [[ "$vmess_choice" == "0" || -z "$vmess_choice" ]]; then
            break
        fi
        
        case $vmess_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --argjson port "$new_port" '(.inbounds[] | select(.tag=="vmess-in") | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新 UUID (留空随机生成): " new_uuid
                if [[ -z "$new_uuid" ]]; then
                    new_uuid=$(/etc/s-box/sing-box generate uuid)
                fi
                local temp_json=$(mktemp)
                jq --arg uuid "$new_uuid" '(.inbounds[] | select(.tag=="vmess-in") | .users[0].uuid) = $uuid' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                echo "UUID 修改成功，新 UUID: $new_uuid"
                apply_changes
                ;;
            3)
                read -p "请输入新 WS 路径 (必须以 / 开头，例如 /my-path): " new_path
                if [[ -n "$new_path" ]]; then
                    if [[ ! "$new_path" =~ ^/ ]]; then
                        new_path="/${new_path}"
                    fi
                    local temp_json=$(mktemp)
                    jq --arg path "$new_path" '(.inbounds[] | select(.tag=="vmess-in") | .transport.path) = $path' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "WS 路径修改成功，新路径: $new_path"
                    apply_changes
                else
                    echo "路径不能为空！"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_trojan() {
    while true; do
        local cur_port=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .listen_port' /etc/s-box/sb.json)
        local cur_pass=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .users[0].password' /etc/s-box/sb.json)
        local cur_sni=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .tls.server_name' /etc/s-box/sb.json)
        local cur_path=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .transport.path' /etc/s-box/sb.json)
        
        local has_trojan_ws=false
        local cur_ws_port=""
        local cur_ws_path=""
        if jq -e '.inbounds[] | select(.tag=="trojan-ws-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
            has_trojan_ws=true
            cur_ws_port=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .listen_port' /etc/s-box/sb.json)
            cur_ws_path=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .transport.path' /etc/s-box/sb.json)
        fi
        
        echo "--------------------------------------------------"
        echo "          Trojan-WS-TLS 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 密码 (当前: $cur_pass)"
        echo "3. 修改 伪装域名 (当前: $cur_sni)"
        echo "4. 修改 WS 路径 (当前: $cur_path)"
        if $has_trojan_ws; then
            echo "5. 修改 Argo 内部 Trojan-WS 端口 (当前: $cur_ws_port)"
            echo "6. 修改 Argo 内部 Trojan-WS 路径 (当前: $cur_ws_path)"
        fi
        echo "0. 返回"
        echo "--------------------------------------------------"
        local max_opt=4
        if $has_trojan_ws; then
            max_opt=6
        fi
        read -p "请选择修改项 [0-$max_opt]: " trojan_choice
        
        if [[ "$trojan_choice" == "0" || -z "$trojan_choice" ]]; then
            break
        fi
        
        case $trojan_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --argjson port "$new_port" '(.inbounds[] | select(.tag=="trojan-tls-in") | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新密码: " new_pass
                if [[ -n "$new_pass" ]]; then
                    local temp_json=$(mktemp)
                    if $has_trojan_ws; then
                        jq --arg password "$new_pass" '
                            ((.inbounds[] | select(.tag=="trojan-tls-in") | .users[0].password) = $password) |
                            ((.inbounds[] | select(.tag=="trojan-ws-in") | .users[0].password) = $password)
                        ' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    else
                        jq --arg password "$new_pass" '(.inbounds[] | select(.tag=="trojan-tls-in") | .users[0].password) = $password' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    fi
                    echo "密码修改成功，新密码: $new_pass"
                    apply_changes
                else
                    echo "密码不能为空！"
                fi
                ;;
            3)
                read -p "请输入新伪装域名: " new_sni
                if [[ -n "$new_sni" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg sni "$new_sni" '(.inbounds[] | select(.tag=="trojan-tls-in") | .tls.server_name) = $sni' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "伪装域名修改成功，新伪装域名: $new_sni"
                    apply_changes
                else
                    echo "域名不能为空！"
                fi
                ;;
            4)
                read -p "请输入新 WS 路径 (必须以 / 开头，例如 /my-path): " new_path
                if [[ -n "$new_path" ]]; then
                    if [[ ! "$new_path" =~ ^/ ]]; then
                        new_path="/${new_path}"
                    fi
                    local temp_json=$(mktemp)
                    jq --arg path "$new_path" '(.inbounds[] | select(.tag=="trojan-tls-in") | .transport.path) = $path' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "WS 路径修改成功，新路径: $new_path"
                    apply_changes
                else
                    echo "路径不能为空！"
                fi
                ;;
            5)
                if $has_trojan_ws; then
                    read -p "请输入新 Argo 内部 Trojan-WS 端口: " new_port
                    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                        if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_ws_port" ]; then
                            echo "警告：端口 $new_port 已被占用！"
                        else
                            local temp_json=$(mktemp)
                            jq --argjson port "$new_port" '(.inbounds[] | select(.tag=="trojan-ws-in") | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                            echo "Argo 内部 Trojan-WS 端口修改成功，新端口: $new_port"
                            apply_changes
                        fi
                    else
                        echo "无效端口！"
                    fi
                else
                    echo "无效选项！"
                fi
                ;;
            6)
                if $has_trojan_ws; then
                    read -p "请输入新 Argo 内部 Trojan-WS 路径 (必须以 / 开头): " new_path
                    if [[ -n "$new_path" ]]; then
                        if [[ ! "$new_path" =~ ^/ ]]; then
                            new_path="/${new_path}"
                        fi
                        local temp_json=$(mktemp)
                        jq --arg path "$new_path" '(.inbounds[] | select(.tag=="trojan-ws-in") | .transport.path) = $path' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "Argo 内部 Trojan-WS 路径修改成功，新路径: $new_path"
                        apply_changes
                    else
                        echo "路径不能为空！"
                    fi
                else
                    echo "无效选项！"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_hy2() {
    while true; do
        local cur_port=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .listen_port' /etc/s-box/sb.json)
        local cur_pass=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .users[0].password' /etc/s-box/sb.json)
        
        echo "--------------------------------------------------"
        echo "          Hysteria2 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 密码 (当前: $cur_pass)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-2]: " hy2_choice
        
        if [[ "$hy2_choice" == "0" || -z "$hy2_choice" ]]; then
            break
        fi
        
        case $hy2_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --argjson port "$new_port" '(.inbounds[] | select(.tag=="hy2-in") | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新密码: " new_pass
                if [[ -n "$new_pass" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg password "$new_pass" '(.inbounds[] | select(.tag=="hy2-in") | .users[0].password) = $password' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "密码修改成功，新密码: $new_pass"
                    apply_changes
                else
                    echo "密码不能为空！"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_tuic() {
    while true; do
        local cur_port=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .listen_port' /etc/s-box/sb.json)
        local cur_uuid=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].uuid' /etc/s-box/sb.json)
        
        echo "--------------------------------------------------"
        echo "          TUIC v5 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 UUID/密码 (当前: $cur_uuid)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-2]: " tuic_choice
        
        if [[ "$tuic_choice" == "0" || -z "$tuic_choice" ]]; then
            break
        fi
        
        case $tuic_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --argjson port "$new_port" '(.inbounds[] | select(.tag=="tuic-in") | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新 UUID/密码 (留空随机生成): " new_uuid
                if [[ -z "$new_uuid" ]]; then
                    new_uuid=$(/etc/s-box/sing-box generate uuid)
                fi
                local temp_json=$(mktemp)
                jq --arg uuid "$new_uuid" '
                    (.inbounds[] | select(.tag=="tuic-in") | .users[0].uuid) = $uuid |
                    (.inbounds[] | select(.tag=="tuic-in") | .users[0].password) = $uuid
                ' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                echo "UUID/密码 修改成功，新 UUID/密码: $new_uuid"
                apply_changes
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_anytls() {
    while true; do
        local cur_port=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .listen_port' /etc/s-box/sb.json)
        local cur_pass=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .users[0].password' /etc/s-box/sb.json)
        local cur_sni=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .tls.server_name' /etc/s-box/sb.json)
        
        echo "--------------------------------------------------"
        echo "          AnyTLS 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 密码 (当前: $cur_pass)"
        echo "3. 修改 伪装域名 (当前: $cur_sni)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-3]: " anytls_choice
        
        if [[ "$anytls_choice" == "0" || -z "$anytls_choice" ]]; then
            break
        fi
        
        case $anytls_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --argjson port "$new_port" '(.inbounds[] | select(.tag=="anytls-in") | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新密码: " new_pass
                if [[ -n "$new_pass" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg password "$new_pass" '(.inbounds[] | select(.tag=="anytls-in") | .users[0].password) = $password' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "密码修改成功，新密码: $new_pass"
                    apply_changes
                else
                    echo "密码不能为空！"
                fi
                ;;
            3)
                read -p "请输入新伪装域名: " new_sni
                if [[ -n "$new_sni" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg sni "$new_sni" '(.inbounds[] | select(.tag=="anytls-in") | .tls.server_name) = $sni' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "伪装域名修改成功，新伪装域名: $new_sni"
                    apply_changes
                else
                    echo "域名不能为空！"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_mihomo_port() {
    local cur_m_port=$(jq -r '.outbounds[] | select(.tag=="mihomo-out") | .server_port' /etc/s-box/sb.json)
    read -p "请输入新的本地 Mihomo Socks5 监听端口 [当前: $cur_m_port]: " new_m_port
    if [[ "$new_m_port" =~ ^[0-9]+$ ]] && [ "$new_m_port" -ge 1 ] && [ "$new_m_port" -le 65535 ]; then
        # 1. 修改 Sing-box 对接出站
        local temp_json=$(mktemp)
        jq --argjson port "$new_m_port" '(.outbounds[] | select(.tag=="mihomo-out") | .server_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
        
        # 2. 修改 Mihomo 端的配置监听
        if [[ -f /etc/mihomo/config.yaml ]]; then
            sed -i "/^mixed-port:/c\mixed-port: ${new_m_port}" /etc/mihomo/config.yaml
            systemctl restart mihomo
        fi
        
        # 3. 同步更新 update_sub.sh 中的常量，以防未来更新覆盖
        if [[ -f /etc/mihomo/update_sub.sh ]]; then
            sed -i "s/MIHOMO_PORT=[0-9]*/MIHOMO_PORT=${new_m_port}/g" /etc/mihomo/update_sub.sh
        fi
        
        echo "Mihomo 本地对接端口修改成功，新端口: $new_m_port"
        apply_changes
    else
        echo "无效端口！"
    fi
}

modify_yacd_params() {
    if [[ ! -f /etc/mihomo/config.yaml ]]; then
        echo "错误：未找到配置文件 /etc/mihomo/config.yaml"
        return
    fi
    
    local cur_y_port=$(grep -oE "external-controller:.*:[0-9]+" /etc/mihomo/config.yaml | awk -F: '{print $NF}' | tr -d "'\" ")
    [[ -z "$cur_y_port" ]] && cur_y_port=$(grep -oE "external-controller:.*" /etc/mihomo/config.yaml | head -n 1 | tr -d "'\" " | awk -F: '{print $NF}')
    [[ -z "$cur_y_port" ]] && cur_y_port=9090
    
    local cur_secret=$(grep -E "^secret:" /etc/mihomo/config.yaml | head -n 1 | awk '{print $2}' | tr -d "'\" ")

    while true; do
        echo "--------------------------------------------------"
        echo "          yacd 面板控制端参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改 yacd 控制端口 (当前: $cur_y_port)"
        echo "2. 修改 yacd 连接密码 (当前: $cur_secret)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-2]: " yacd_opt
        [[ -z "$yacd_opt" ]] && yacd_opt=0
        
        if [[ "$yacd_opt" == "0" ]]; then
            break
        fi
        
        case $yacd_opt in
            1)
                read -p "请输入新端口: " new_y_port
                if [[ "$new_y_port" =~ ^[0-9]+$ ]] && [ "$new_y_port" -ge 1 ] && [ "$new_y_port" -le 65535 ]; then
                    sed -i "/^external-controller:/c\external-controller: 0.0.0.0:${new_y_port}" /etc/mihomo/config.yaml
                    if [[ -f /etc/mihomo/update_sub.sh ]]; then
                        sed -i "s/YACD_PORT=[0-9]*/YACD_PORT=${new_y_port}/g" /etc/mihomo/update_sub.sh
                    fi
                    systemctl restart mihomo
                    cur_y_port=$new_y_port
                    echo "yacd 控制端口修改成功，新端口: $new_y_port"
                    regenerate_info_log
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新密钥/密码: " new_secret
                if [[ -n "$new_secret" ]]; then
                    sed -i "/^secret:/c\secret: \"${new_secret}\"" /etc/mihomo/config.yaml
                    if [[ -f /etc/mihomo/update_sub.sh ]]; then
                        sed -i "s/MIHOMO_SECRET=.*/MIHOMO_SECRET=\"${new_secret}\"/g" /etc/mihomo/update_sub.sh
                    fi
                    systemctl restart mihomo
                    cur_secret=$new_secret
                    echo "yacd 连接密码修改成功，新密码: $new_secret"
                    regenerate_info_log
                else
                    echo "密码不能为空！"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

update_mihomo_sub() {
    if [[ -f /etc/mihomo/update_sub.sh ]]; then
        log_info "正在手动拉取最新订阅..."
        /bin/bash /etc/mihomo/update_sub.sh
        if [[ -f /etc/s-box/info.log ]]; then
            regenerate_info_log
            cat /etc/s-box/info.log
        fi
    else
        echo "错误：未找到自动更新配置脚本 /etc/mihomo/update_sub.sh"
    fi
}

modify_node_params() {
    if [[ ! -f /etc/s-box/sb.json ]]; then
        echo "错误：未找到配置文件 /etc/s-box/sb.json"
        return
    fi

    while true; do
        echo "=================================================="
        echo "          修改已搭建节点参数"
        echo "=================================================="
        
        local has_vless=false
        local has_vmess=false
        local has_trojan=false
        local has_hy2=false
        local has_tuic=false
        local has_anytls=false
        local has_mihomo=false
        
        jq -e '.inbounds[] | select(.tag=="vless-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_vless=true
        jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_vmess=true
        jq -e '.inbounds[] | select(.tag=="trojan-tls-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_trojan=true
        jq -e '.inbounds[] | select(.tag=="hy2-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_hy2=true
        jq -e '.inbounds[] | select(.tag=="tuic-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_tuic=true
        jq -e '.inbounds[] | select(.tag=="anytls-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_anytls=true
        jq -e '.outbounds[] | select(.tag=="mihomo-out")' /etc/s-box/sb.json >/dev/null 2>&1 && has_mihomo=true
        
        local menu_index=1
        local opt_vless=0
        local opt_vmess=0
        local opt_trojan=0
        local opt_hy2=0
        local opt_tuic=0
        local opt_anytls=0
        local opt_mihomo=0
        local opt_yacd=0
        
        if $has_vless; then
            echo "${menu_index}. 修改 VLESS-Reality 节点参数"
            opt_vless=$menu_index
            ((menu_index++))
        fi
        if $has_vmess; then
            echo "${menu_index}. 修改 VMess-WS 节点参数"
            opt_vmess=$menu_index
            ((menu_index++))
        fi
        if $has_trojan; then
            echo "${menu_index}. 修改 Trojan-WS-TLS 节点参数"
            opt_trojan=$menu_index
            ((menu_index++))
        fi
        if $has_hy2; then
            echo "${menu_index}. 修改 Hysteria2 节点参数"
            opt_hy2=$menu_index
            ((menu_index++))
        fi
        if $has_tuic; then
            echo "${menu_index}. 修改 TUIC v5 节点参数"
            opt_tuic=$menu_index
            ((menu_index++))
        fi
        if $has_anytls; then
            echo "${menu_index}. 修改 AnyTLS 节点参数"
            opt_anytls=$menu_index
            ((menu_index++))
        fi
        if $has_mihomo; then
            echo "${menu_index}. 修改出站 Mihomo 本地对接端口"
            opt_mihomo=$menu_index
            ((menu_index++))
            echo "${menu_index}. 修改 yacd 网页控制端口与密码"
            opt_yacd=$menu_index
            ((menu_index++))
        fi
        echo "0. 返回主菜单"
        echo "=================================================="
        read -p "请输入要修改的节点选项 [0-$((menu_index-1))]: " modify_choice
        
        if [[ "$modify_choice" == "0" || -z "$modify_choice" ]]; then
            break
        fi
        
        if [[ "$modify_choice" == "$opt_vless" && $opt_vless -ne 0 ]]; then
            modify_vless
        elif [[ "$modify_choice" == "$opt_vmess" && $opt_vmess -ne 0 ]]; then
            modify_vmess
        elif [[ "$modify_choice" == "$opt_trojan" && $opt_trojan -ne 0 ]]; then
            modify_trojan
        elif [[ "$modify_choice" == "$opt_hy2" && $opt_hy2 -ne 0 ]]; then
            modify_hy2
        elif [[ "$modify_choice" == "$opt_tuic" && $opt_tuic -ne 0 ]]; then
            modify_tuic
        elif [[ "$modify_choice" == "$opt_anytls" && $opt_anytls -ne 0 ]]; then
            modify_anytls
        elif [[ "$modify_choice" == "$opt_mihomo" && $opt_mihomo -ne 0 ]]; then
            modify_mihomo_port
        elif [[ "$modify_choice" == "$opt_yacd" && $opt_yacd -ne 0 ]]; then
            modify_yacd_params
        else
            echo "无效的选项，请重新输入。"
        fi
    done
}

while true; do
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "${GREEN}   Sing-box ${YELLOW}(Inbound) ${PLAIN}<-> ${BLUE}Mihomo ${YELLOW}(Outbound)${PLAIN}"
    echo -e "${BLUE}        快捷管理工具 sb (双核心集成版)${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo "1. 查看已配置的节点及面板信息"
    echo "2. 重启双核心服务 (Sing-box, Mihomo, Argo)"
    echo "3. 停止所有服务"
    echo "4. 查看 Argo 隧道实时域名与连接状态"
    echo "5. 手动更新 Mihomo 订阅节点"
    echo "6. 修改已搭建节点及控制端口参数"
    echo "7. 彻底卸载双核心脚本环境"
    echo "0. 退出"
    echo -e "${BLUE}==================================================${PLAIN}"
    read -p "请输入选项 [0-7]: " menu_choice
    case $menu_choice in
        1)
            if [[ -f /etc/s-box/info.log ]]; then
                cat /etc/s-box/info.log
            else
                echo "未找到节点信息日志，请确认是否安装成功。"
            fi
            ;;
        2)
            echo "正在重启服务..."
            systemctl restart sing-box 2>/dev/null
            systemctl restart mihomo 2>/dev/null
            if [[ -f /etc/nginx/conf.d/singbox-argo.conf ]]; then
                systemctl restart argo-tunnel 2>/dev/null
                update_argo_domain
            fi
            regenerate_info_log
            echo "服务已全部重启，配置已更新！"
            ;;
        3)
            echo "正在停止服务..."
            systemctl stop sing-box 2>/dev/null
            systemctl stop mihomo 2>/dev/null
            systemctl stop argo-tunnel 2>/dev/null
            echo "服务已全部下线！"
            ;;
        4)
            echo "正在获取隧道状态..."
            if systemctl is-active --quiet argo-tunnel; then
                echo "Argo 隧道处于运行状态："
                journalctl -u argo-tunnel -n 15 --no-pager
            else
                echo "Argo 隧道服务未运行。"
            fi
            ;;
        5)
            update_mihomo_sub
            ;;
        6)
            modify_node_params
            ;;
        7)
            if [[ -f /etc/s-box/uninstall.sh ]]; then
                bash /etc/s-box/uninstall.sh
                exit 0
            else
                echo "未找到卸载脚本，执行直接清理..."
                systemctl stop sing-box mihomo argo-tunnel 2>/dev/null
                systemctl disable sing-box mihomo argo-tunnel 2>/dev/null
                rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/mihomo.service /etc/systemd/system/argo-tunnel.service
                systemctl daemon-reload
                rm -rf /etc/s-box /etc/mihomo /usr/local/bin/cloudflared /usr/local/bin/sb /usr/local/bin/mihomo
                systemctl restart nginx 2>/dev/null
                echo "卸载清理完毕！"
                exit 0
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            echo "无效输入，请重新选择。"
            ;;
    esac
done
EOF
chmod +x /usr/local/bin/sb
}

# 检测是否已安装
if [[ -f /etc/s-box/sb.json ]]; then
    echo "=================================================="
    echo "          检测到已安装 Sing-box 服务"
    echo "=================================================="
    echo "1. 进入一键快捷管理菜单 (直接回车)"
    echo "2. 重新安装/更新合体版服务"
    echo "0. 退出"
    echo "=================================================="
    read -p "请选择操作 [0-2, 默认1]: " init_choice
    [[ -z "$init_choice" ]] && init_choice=1
    
    if [[ "$init_choice" == "1" ]]; then
        create_sb_tool >/dev/null 2>&1
        if [[ -f /usr/local/bin/sb ]]; then
            bash /usr/local/bin/sb
            exit 0
        else
            log_warn "未找到快捷管理工具 /usr/local/bin/sb，自动进入安装流程。"
        fi
    elif [[ "$init_choice" == "0" ]]; then
        exit 0
    fi
fi

# 节点配置默认值
ENABLE_VLESS="y"
ENABLE_VMESS="y"
ENABLE_TROJAN="y"
ENABLE_HY2="y"
ENABLE_TUIC="y"
ENABLE_ANYTLS="y"
ENABLE_ARGO="y"

# 提供自定义组合的交互式提示
echo "=================================================="
echo "          请选择要安装的入站节点协议"
echo "=================================================="
echo "1. 默认安装全部入站协议 (直接回车)"
echo "2. 自定义选择需要安装的节点协议"
echo "=================================================="
read -p "请输入选项 [1-2, 默认1]: " menu_choice

if [[ "$menu_choice" == "2" ]]; then
    read -p "1. 是否安装 VLESS-Reality? [Y/n, 默认Y]: " opt; [[ -n "$opt" ]] && ENABLE_VLESS=$(echo "$opt" | tr 'A-Z' 'a-z')
    read -p "2. 是否安装 VMess-WS? [Y/n, 默认Y]: " opt; [[ -n "$opt" ]] && ENABLE_VMESS=$(echo "$opt" | tr 'A-Z' 'a-z')
    read -p "3. 是否安装 Trojan-WS-TLS (自签证书)? [Y/n, 默认Y]: " opt; [[ -n "$opt" ]] && ENABLE_TROJAN=$(echo "$opt" | tr 'A-Z' 'a-z')
    read -p "4. 是否安装 Hysteria2? [Y/n, 默认Y]: " opt; [[ -n "$opt" ]] && ENABLE_HY2=$(echo "$opt" | tr 'A-Z' 'a-z')
    read -p "5. 是否安装 TUIC v5? [Y/n, 默认Y]: " opt; [[ -n "$opt" ]] && ENABLE_TUIC=$(echo "$opt" | tr 'A-Z' 'a-z')
    read -p "6. 是否安装 AnyTLS? [Y/n, 默认Y]: " opt; [[ -n "$opt" ]] && ENABLE_ANYTLS=$(echo "$opt" | tr 'A-Z' 'a-z')
    read -p "7. 是否安装 Argo 隧道穿透 (支持 VMess/Trojan)? [Y/n, 默认Y]: " opt; [[ -n "$opt" ]] && ENABLE_ARGO=$(echo "$opt" | tr 'A-Z' 'a-z')
fi

# 交互获取 Mihomo 出站参数
echo "=================================================="
echo "          配置 Mihomo 出站客户端参数"
echo "=================================================="
while true; do
    read -p "请输入您的 Clash/Mihomo 订阅地址 (http/https): " SUB_URL
    if [[ -n "$SUB_URL" && "$SUB_URL" =~ ^https?:// ]]; then
        break
    else
        log_err "订阅链接格式不正确，必须以 http:// 或 https:// 开头！"
    fi
done

MIHOMO_PORT=7890
read -p "请输入本地 Socks5 对接端口 [默认 7890]: " opt_m_port
[[ -n "$opt_m_port" ]] && MIHOMO_PORT=$opt_m_port

YACD_PORT=9090
read -p "请输入 yacd 网页控制面板监听端口 [默认 9090]: " opt_y_port
[[ -n "$opt_y_port" ]] && YACD_PORT=$opt_y_port

MIHOMO_SECRET=$(openssl rand -hex 6)
read -p "请输入 yacd 面板连接密钥/密码 [默认 随机生成: ${MIHOMO_SECRET}]: " opt_secret
[[ -n "$opt_secret" ]] && MIHOMO_SECRET=$opt_secret

# 统一判断，空值或 y/yes 都视为启用
is_enabled() {
    [[ "$1" == "y" || "$1" == "yes" || -z "$1" ]] && return 0 || return 1
}

# 1. 系统检测与包管理器识别
if [[ -f /etc/redhat-release ]]; then
    release="CentOS"
elif grep -q -i "debian" /etc/issue || grep -q -i "debian" /proc/version; then
    release="Debian"
elif grep -q -i "ubuntu" /etc/issue || grep -q -i "ubuntu" /proc/version; then
    release="Ubuntu"
else
    log_err "暂不支持的系统类型。请使用 Ubuntu, Debian 或 CentOS。"
    exit 1
fi

# 架构检测
arch=$(uname -m)
case $arch in
    x86_64) 
        cpu="amd64" 
        mihomo_cpu="amd64-compatible"
        ;;
    aarch64) 
        cpu="arm64" 
        mihomo_cpu="arm64"
        ;;
    armv7l) 
        cpu="arm" 
        mihomo_cpu="arm32"
        ;;
    *)
        log_err "暂不支持的 CPU 架构: $arch"
        exit 1
        ;;
esac

# 2. 安装系统依赖和 Nginx
log_info "正在安装必要的系统依赖..."
if [[ "$release" == "CentOS" ]]; then
    yum install -y epel-release
    yum install -y jq openssl curl tar wget unzip gzip psmisc
    is_enabled "$ENABLE_ARGO" && yum install -y nginx
else
    apt-get update -y
    apt-get install -y jq openssl curl tar wget unzip gzip psmisc
    is_enabled "$ENABLE_ARGO" && apt-get install -y nginx
fi

# 3. 创建配置文件目录
mkdir -p /etc/s-box
mkdir -p /etc/mihomo
cd /etc/s-box

# 4. 下载并安装 Sing-box 最新内核
log_info "正在获取 Sing-box 最新版本号..."
latest_version_sb=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/v//')
[[ -z "$latest_version_sb" || "$latest_version_sb" == "null" ]] && latest_version_sb="1.11.0"

log_info "正在下载 Sing-box 内核 v$latest_version_sb ($cpu)..."
package_name="sing-box-${latest_version_sb}-linux-${cpu}"
download_url_sb="https://github.com/SagerNet/sing-box/releases/download/v${latest_version_sb}/${package_name}.tar.gz"

wget -qO sing-box.tar.gz "$download_url_sb"
if [[ -f "sing-box.tar.gz" ]]; then
    tar -xzf sing-box.tar.gz
    mv "$package_name/sing-box" ./sing-box
    rm -rf sing-box.tar.gz "$package_name"
    chmod +x sing-box
    log_info "Sing-box 内核安装成功：$(./sing-box version | head -n 1)"
else
    log_err "下载 Sing-box 失败，请检查网络。"
    exit 1
fi

# 5. 下载并安装 Mihomo 内核
log_info "正在获取 Mihomo 最新版本号..."
latest_version_mh=$(curl -Ls https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | jq -r '.tag_name')
[[ -z "$latest_version_mh" || "$latest_version_mh" == "null" ]] && latest_version_mh="v1.18.9"

log_info "正在下载 Mihomo 内核 ${latest_version_mh} ($mihomo_cpu)..."
download_url_mh="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version_mh}/mihomo-linux-${mihomo_cpu}-${latest_version_mh}.gz"

wget -qO /etc/mihomo/mihomo.gz "$download_url_mh"
if [[ -f "/etc/mihomo/mihomo.gz" ]]; then
    gzip -d -f /etc/mihomo/mihomo.gz
    mv /etc/mihomo/mihomo /usr/local/bin/mihomo
    chmod +x /usr/local/bin/mihomo
    log_info "Mihomo 内核安装成功：$(/usr/local/bin/mihomo -v)"
else
    log_err "下载 Mihomo 失败，使用本地环境已存核心（若有），或请重新运行脚本。"
fi

# 6. 下载并安装本地 yacd 控制面板
log_info "正在部署本地版 yacd 控制面板..."
wget -qO /etc/mihomo/yacd.zip https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip
if [[ -f "/etc/mihomo/yacd.zip" ]]; then
    unzip -qo /etc/mihomo/yacd.zip -d /etc/mihomo/
    rm -rf /etc/mihomo/yacd
    mv /etc/mihomo/Yacd-meta-gh-pages /etc/mihomo/yacd
    rm -f /etc/mihomo/yacd.zip
    log_info "本地 yacd 控制面板解压完成。"
else
    log_warn "拉取 yacd 失败，稍后请通过在线面板 https://yacd.metacubex.one 远程管理。"
fi

# 7. 下载并转换 Mihomo 节点订阅
log_info "正在拉取 Clash 订阅配置..."
curl -L -k --connect-timeout 10 --max-time 30 -H "User-Agent: clash" -o /etc/mihomo/config.yaml "$SUB_URL"
if [[ -f "/etc/mihomo/config.yaml" && -s "/etc/mihomo/config.yaml" ]]; then
    # Base64 自动解密
    if ! grep -q "proxies:" /etc/mihomo/config.yaml && ! grep -q "port:" /etc/mihomo/config.yaml; then
        if base64 -d /etc/mihomo/config.yaml > /etc/mihomo/config_decoded.yaml 2>/dev/null; then
            mv /etc/mihomo/config_decoded.yaml /etc/mihomo/config.yaml
            log_info "Clash 订阅 Base64 格式解码成功！"
        fi
    fi
    # 清除原有的冲突配置
    sed -i '/^port:/d' /etc/mihomo/config.yaml
    sed -i '/^socks-port:/d' /etc/mihomo/config.yaml
    sed -i '/^mixed-port:/d' /etc/mihomo/config.yaml
    sed -i '/^external-controller:/d' /etc/mihomo/config.yaml
    sed -i '/^external-ui:/d' /etc/mihomo/config.yaml
    sed -i '/^secret:/d' /etc/mihomo/config.yaml

    # 注入覆盖属性
    cat <<EOF >> /etc/mihomo/config.yaml

# --- 自定义出站重定向配置 (Sing-box 桥接) ---
mixed-port: ${MIHOMO_PORT}
external-controller: 0.0.0.0:${YACD_PORT}
secret: "${MIHOMO_SECRET}"
external-ui: yacd
# --- 自定义配置结束 ---
EOF
    log_info "Mihomo 订阅解析重写完成。"
else
    log_err "拉取订阅失败，请确保您输入的链接在服务器上直接可用。"
    exit 1
fi

# 8. 下载并安装 Argo 隧道（如启用）
if is_enabled "$ENABLE_ARGO"; then
    log_info "正在下载 Cloudflared 客户端..."
    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cpu}"
    wget -qO /usr/local/bin/cloudflared "$cf_url"
    chmod +x /usr/local/bin/cloudflared
    log_info "Cloudflared 安装成功：$(cloudflared --version)"
fi

# 9. 生成凭证证书与 Reality 密钥
log_info "正在生成 Reality 密钥对和自签证书..."
UUID=$(./sing-box generate reality-keypair) # 借用生成器，实际上只需要 UUID
UUID=$(./sing-box generate uuid)

reality_keys=$(./sing-box generate reality-keypair)
private_key=$(echo "$reality_keys" | awk '/PrivateKey/{print $2}')
public_key=$(echo "$reality_keys" | awk '/PublicKey/{print $2}')
echo "$public_key" > /etc/s-box/public.key
short_id=$(openssl rand -hex 8)

openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private.key
openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/s-box/cert.pem -subj "/CN=www.bing.com"

# 10. 端口分配
PORT_NGINX=8401
get_random_port_in_range() {
    local min=$1
    local max=$2
    local port
    while true; do
        port=$(shuf -i ${min}-${max} -n 1)
        if ss -tunlp | grep -q ":$port " || [ "$port" -eq "$MIHOMO_PORT" ] || [ "$port" -eq "$YACD_PORT" ]; then
            continue
        else
            echo "$port"
            break
        fi
    done
}

get_custom_port() {
    local name=$1
    local default_val=$2
    local port
    while true; do
        read -p "请输入 ${name} 的监听端口 [默认 ${default_val}]: " port
        [[ -z "$port" ]] && port=$default_val
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if ss -tunlp | grep -q ":$port " || [ "$port" -eq "$MIHOMO_PORT" ] || [ "$port" -eq "$YACD_PORT" ]; then
                log_warn "端口已被占用或与 Mihomo/yacd 冲突，请重新输入！"
            else
                echo "$port"
                break
            fi
        else
            log_err "输入不合法，请输入 1-65535 之间的数字！"
        fi
    done
}

get_port_range() {
    local range_str
    local start_port
    local end_port
    while true; do
        read -p "请输入端口范围 [格式例如 10000-20000, 默认 20000-60000]: " range_str
        if [[ -z "$range_str" ]]; then
            start_port=20000
            end_port=60000
            break
        fi
        if [[ "$range_str" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start_port=${BASH_REMATCH[1]}
            end_port=${BASH_REMATCH[2]}
            if [ "$start_port" -ge 1 ] && [ "$start_port" -le 65535 ] && \
               [ "$end_port" -ge 1 ] && [ "$end_port" -le 65535 ] && \
               [ "$start_port" -le "$end_port" ]; then
                break
            fi
        fi
        log_err "输入不合法！格式应为: 起始端口-结束端口 (如 10000-20000)。"
    done
    echo "${start_port} ${end_port}"
}

echo "=================================================="
echo "          请选择端口配置方式"
echo "=================================================="
echo "1. 自动随机端口分配 (20000-60000 范围，直接回车)"
echo "2. 手动为每个选定协议指定固定端口"
echo "3. 指定自定义端口范围并在此范围内随机分配"
echo "=================================================="
read -p "请输入选项 [1-3, 默认1]: " port_choice

if [[ "$port_choice" == "2" ]]; then
    is_enabled "$ENABLE_VLESS" && PORT_VLESS=$(get_custom_port "VLESS-Reality" 28201)
    is_enabled "$ENABLE_VMESS" && PORT_VMESS=$(get_custom_port "VMess-WS" 38202)
    is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_TLS=$(get_custom_port "Trojan-WS-TLS" 48203)
    if is_enabled "$ENABLE_ARGO"; then
        is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_WS=$(get_custom_port "Trojan-WS (Argo内部)" 58204)
        PORT_NGINX=8401
    fi
    is_enabled "$ENABLE_HY2" && PORT_HY2=$(get_custom_port "Hysteria2" 21092)
    is_enabled "$ENABLE_TUIC" && PORT_TUIC=$(get_custom_port "TUIC v5" 33104)
    is_enabled "$ENABLE_ANYTLS" && PORT_ANYTLS=$(get_custom_port "AnyTLS" 48205)
elif [[ "$port_choice" == "3" ]]; then
    read start_p end_p <<< $(get_port_range)
    is_enabled "$ENABLE_VLESS" && PORT_VLESS=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_VMESS" && PORT_VMESS=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_TLS=$(get_random_port_in_range $start_p $end_p)
    if is_enabled "$ENABLE_ARGO"; then
        is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_WS=$(get_random_port_in_range $start_p $end_p)
        PORT_NGINX=8401
    fi
    is_enabled "$ENABLE_HY2" && PORT_HY2=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_TUIC" && PORT_TUIC=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_ANYTLS" && PORT_ANYTLS=$(get_random_port_in_range $start_p $end_p)
else
    is_enabled "$ENABLE_VLESS" && PORT_VLESS=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_VMESS" && PORT_VMESS=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_TLS=$(get_random_port_in_range 20000 60000)
    if is_enabled "$ENABLE_ARGO"; then
        is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_WS=$(get_random_port_in_range 20000 60000)
        PORT_NGINX=8401
    fi
    is_enabled "$ENABLE_HY2" && PORT_HY2=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_TUIC" && PORT_TUIC=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_ANYTLS" && PORT_ANYTLS=$(get_random_port_in_range 20000 60000)
fi

# 11. 动态生成 sing-box 配置文件 sb.json
log_info "正在生成 sing-box 配置文件..."
inbounds=()
enabled_tags=()

if is_enabled "$ENABLE_VLESS"; then
    enabled_tags+=('"vless-in"')
    inbounds+=('{
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": '"${PORT_VLESS}"',
      "users": [
        {
          "uuid": "'"${UUID}"'",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "apple.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "apple.com",
            "server_port": 443
          },
          "private_key": "'"${private_key}"'",
          "short_id": [
            "'"${short_id}"'"
          ]
        }
      }
    }')
fi

if is_enabled "$ENABLE_VMESS"; then
    enabled_tags+=('"vmess-in"')
    inbounds+=('{
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": '"${PORT_VMESS}"',
      "users": [
        {
          "uuid": "'"${UUID}"'",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/'"${UUID}"'-vm",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }')
fi

if is_enabled "$ENABLE_TROJAN"; then
    enabled_tags+=('"trojan-tls-in"')
    inbounds+=('{
      "type": "trojan",
      "tag": "trojan-tls-in",
      "listen": "::",
      "listen_port": '"${PORT_TROJAN_TLS}"',
      "users": [
        {
          "password": "'"${UUID}"'"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      },
      "transport": {
        "type": "ws",
        "path": "/'"${UUID}"'-tr"
      }
    }')
fi

if is_enabled "$ENABLE_ARGO" && is_enabled "$ENABLE_TROJAN"; then
    enabled_tags+=('"trojan-ws-in"')
    inbounds+=('{
      "type": "trojan",
      "tag": "trojan-ws-in",
      "listen": "::",
      "listen_port": '"${PORT_TROJAN_WS}"',
      "users": [
        {
          "password": "'"${UUID}"'"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/'"${UUID}"'-tr-argo"
      }
    }')
fi

if is_enabled "$ENABLE_HY2"; then
    enabled_tags+=('"hy2-in"')
    inbounds+=('{
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": '"${PORT_HY2}"',
      "users": [
        {
          "password": "'"${UUID}"'"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    }')
fi

if is_enabled "$ENABLE_TUIC"; then
    enabled_tags+=('"tuic-in"')
    inbounds+=('{
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": '"${PORT_TUIC}"',
      "users": [
        {
          "uuid": "'"${UUID}"'",
          "password": "'"${UUID}"'"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    }')
fi

if is_enabled "$ENABLE_ANYTLS"; then
    enabled_tags+=('"anytls-in"')
    inbounds+=('{
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": '"${PORT_ANYTLS}"',
      "users": [
        {
          "password": "'"${UUID}"'"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    }')
fi

# 拼接 inbounds 数组
inbounds_json=""
for i in "${!inbounds[@]}"; do
    if [[ $i -eq 0 ]]; then
        inbounds_json="${inbounds[$i]}"
    else
        inbounds_json="${inbounds_json},${inbounds[$i]}"
    fi
done

# 拼接路由 tag
tags_json=""
for i in "${!enabled_tags[@]}"; do
    if [[ $i -eq 0 ]]; then
        tags_json="${enabled_tags[$i]}"
    else
        tags_json="${tags_json},${enabled_tags[$i]}"
    fi
done

cat > /etc/s-box/sb.json <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    ${inbounds_json}
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "mihomo-out",
      "server": "127.0.0.1",
      "server_port": ${MIHOMO_PORT}
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": [
          ${tags_json}
        ],
        "outbound": "mihomo-out"
      }
    ]
  }
}
EOF

# 12. 配置 Nginx 反代 (如启用 Argo)
if is_enabled "$ENABLE_ARGO"; then
    log_info "正在配置 Nginx..."
    nginx_locations=""
    if is_enabled "$ENABLE_VMESS"; then
        nginx_locations="${nginx_locations}
    location /${UUID}-vm {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_VMESS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$http_host;
    }"
    fi

    if is_enabled "$ENABLE_TROJAN"; then
        nginx_locations="${nginx_locations}
    location /${UUID}-tr-argo {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_TROJAN_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$http_host;
    }"
    fi

    cat > /etc/nginx/conf.d/singbox-argo.conf <<EOF
server {
    listen 127.0.0.1:${PORT_NGINX};
    server_name localhost;
    ${nginx_locations}
}
EOF
    systemctl restart nginx
fi

# 13. 创建 Systemd 守护服务
log_info "正在注册 systemd 系统守护服务..."

# Sing-box 服务
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/s-box
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

# Mihomo 服务
cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Daemon, Clash Meta Core.
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=always
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box mihomo
systemctl restart sing-box mihomo

# Argo 隧道服务
if is_enabled "$ENABLE_ARGO"; then
    cat > /etc/systemd/system/argo-tunnel.service <<EOF
[Unit]
Description=Argo Tunnel Service
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:${PORT_NGINX}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable argo-tunnel
    systemctl restart argo-tunnel

    log_info "正在等待 Argo 隧道上线，获取节点临时域名..."
    sleep 6

    ARGO_DOMAIN=""
    for i in {1..5}; do
        ARGO_DOMAIN=$(journalctl -u argo-tunnel -n 50 --no-pager | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | head -n 1)
        [[ -n "$ARGO_DOMAIN" ]] && break
        sleep 2
    done

    if [[ -z "$ARGO_DOMAIN" ]]; then
        log_warn "获取 Argo 域名超时，请稍后手动查看日志。"
        ARGO_DOMAIN="[未获取到Argo域名]"
    fi
    echo "$ARGO_DOMAIN" > /etc/s-box/argo.log
fi

# 14. 编写定时更新订阅脚本及 Cron 任务
log_info "正在配置订阅定时更新任务..."
cat > /etc/mihomo/update_sub.sh <<EOF
#!/bin/bash
# 自动拉取更新订阅脚本

export LANG=en_US.UTF-8

curl -L -k --connect-timeout 10 --max-time 30 -H "User-Agent: clash" -o /etc/mihomo/config.yaml.tmp "${SUB_URL}"
if [[ -f /etc/mihomo/config.yaml.tmp && -s /etc/mihomo/config.yaml.tmp ]]; then
    # Base64 解密
    if ! grep -q "proxies:" /etc/mihomo/config.yaml.tmp && ! grep -q "port:" /etc/mihomo/config.yaml.tmp; then
        base64 -d /etc/mihomo/config.yaml.tmp > /etc/mihomo/config_decoded.yaml.tmp 2>/dev/null
        if [[ -f /etc/mihomo/config_decoded.yaml.tmp && -s /etc/mihomo/config_decoded.yaml.tmp ]]; then
            mv /etc/mihomo/config_decoded.yaml.tmp /etc/mihomo/config.yaml.tmp
        fi
    fi
    sed -i '/^port:/d' /etc/mihomo/config.yaml.tmp
    sed -i '/^socks-port:/d' /etc/mihomo/config.yaml.tmp
    sed -i '/^mixed-port:/d' /etc/mihomo/config.yaml.tmp
    sed -i '/^external-controller:/d' /etc/mihomo/config.yaml.tmp
    sed -i '/^external-ui:/d' /etc/mihomo/config.yaml.tmp
    sed -i '/^secret:/d' /etc/mihomo/config.yaml.tmp
    
    cat <<EOF2 >> /etc/mihomo/config.yaml.tmp

# --- 自定义出站重定向配置 (Sing-box 桥接) ---
mixed-port: ${MIHOMO_PORT}
external-controller: 0.0.0.0:${YACD_PORT}
secret: "${MIHOMO_SECRET}"
external-ui: yacd
# --- 自定义配置结束 ---
EOF2
    mv /etc/mihomo/config.yaml.tmp /etc/mihomo/config.yaml
    systemctl restart mihomo
    echo "\$(date): 自动订阅更新成功！" >> /etc/mihomo/update.log
else
    echo "\$(date): 更新失败，订阅文件下载为空。" >> /etc/mihomo/update.log
fi
EOF

chmod +x /etc/mihomo/update_sub.sh

# 加入定时任务 (每天 3:00 更新)
if ! crontab -l 2>/dev/null | grep -q "/etc/mihomo/update_sub.sh"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * /bin/bash /etc/mihomo/update_sub.sh >/dev/null 2>&1") | crontab -
fi

# 15. 创建合体彻底卸载脚本
cat > /etc/s-box/uninstall.sh <<EOF
#!/bin/bash
if [[ \$EUID -ne 0 ]]; then
   echo "错误：必须以 root 权限运行此脚本！"
   exit 1
fi
echo "正在开始彻底卸载双核心代理环境..."
systemctl stop sing-box mihomo argo-tunnel 2>/dev/null
systemctl disable sing-box mihomo argo-tunnel 2>/dev/null
rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/mihomo.service /etc/systemd/system/argo-tunnel.service
systemctl daemon-reload
rm -f /etc/nginx/conf.d/singbox-argo.conf
systemctl restart nginx 2>/dev/null
rm -rf /etc/s-box /etc/mihomo /usr/local/bin/cloudflared /usr/local/bin/mihomo /usr/local/bin/sb
echo "卸载清理彻底完成！"
EOF
chmod +x /etc/s-box/uninstall.sh

# 16. 创建并初始化分享连接日志
log_info "正在生成分享连接并初始化日志..."
create_sb_tool
regenerate_info_log

# 备份一份卸载脚本在根部
if [[ -f ./uninstall.sh ]]; then
    cp ./uninstall.sh /etc/s-box/uninstall.sh 2>/dev/null
    chmod +x /etc/s-box/uninstall.sh 2>/dev/null
fi

IPV4=$(curl -s4m5 icanhazip.com || curl -s4m5 api.ipify.org)
IPV6=$(curl -s6m5 icanhazip.com || curl -s6m5 api6.ipify.org)
IP=${IPV4:-$IPV6}

# 打印日志到终端
cat /etc/s-box/info.log

log_info "合二为一双核心环境部署完毕！"
log_info "自动更新订阅已加入 Crontab 计划任务。"
log_info "你可以直接在终端输入【 sb 】来随时打开控制菜单刷新订阅或修改端口。"
