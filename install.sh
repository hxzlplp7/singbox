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

# 自动检测是否为 OpenRC (Alpine 等)
IS_OPENRC=false
if [[ -x "/sbin/openrc-run" || -x "/sbin/runlevels" ]]; then
    IS_OPENRC=true
fi

# Nginx 配置目录自适应
NGINX_CONF_DIR="/etc/nginx/conf.d"
[[ -d "/etc/nginx/http.d" ]] && NGINX_CONF_DIR="/etc/nginx/http.d"

# 服务控制函数
service_start() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" start >/dev/null 2>&1
    else
        systemctl start "$name" >/dev/null 2>&1
    fi
}

service_stop() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" stop >/dev/null 2>&1
    else
        systemctl stop "$name" >/dev/null 2>&1
    fi
}

service_restart() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" restart >/dev/null 2>&1
    else
        systemctl restart "$name" >/dev/null 2>&1
    fi
}

service_enable() {
    local name=$1
    if $IS_OPENRC; then
        rc-update add "$name" default >/dev/null 2>&1
    else
        systemctl enable "$name" >/dev/null 2>&1
    fi
}

service_disable() {
    local name=$1
    if $IS_OPENRC; then
        rc-update del "$name" default >/dev/null 2>&1
    else
        systemctl disable "$name" >/dev/null 2>&1
    fi
}

service_is_active() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" status | grep -q "started"
    else
        systemctl is-active --quiet "$name"
    fi
}

log_info "开始安装 Sing-box 多协议一键部署脚本..."

create_sb_tool() {
cat > /usr/local/bin/sb <<'EOF'
#!/bin/bash
# Sing-box 极简快捷管理工具

if [[ $EUID -ne 0 ]]; then
   echo "错误：必须以 root 权限运行此脚本！"
   exit 1
fi

# 自动加载 Argo 配置
USE_NGINX="y"
ARGO_PORT=""
ARGO_TARGET_PROTOCOL=""
if [[ -f /etc/s-box/argo.conf ]]; then
    source /etc/s-box/argo.conf
fi

# 自动检测是否为 OpenRC (Alpine 等)
IS_OPENRC=false
if [[ -x "/sbin/openrc-run" || -x "/sbin/runlevels" ]]; then
    IS_OPENRC=true
fi

# Nginx 配置目录自适应
NGINX_CONF_DIR="/etc/nginx/conf.d"
[[ -d "/etc/nginx/http.d" ]] && NGINX_CONF_DIR="/etc/nginx/http.d"

# 服务控制函数
service_start() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" start >/dev/null 2>&1
    else
        systemctl start "$name" >/dev/null 2>&1
    fi
}

service_stop() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" stop >/dev/null 2>&1
    else
        systemctl stop "$name" >/dev/null 2>&1
    fi
}

service_restart() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" restart >/dev/null 2>&1
    else
        systemctl restart "$name" >/dev/null 2>&1
    fi
}

service_is_active() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" status | grep -q "started"
    else
        systemctl is-active --quiet "$name"
    fi
}

service_enable() {
    local name=$1
    if $IS_OPENRC; then
        rc-update add "$name" default >/dev/null 2>&1
    else
        systemctl enable "$name" >/dev/null 2>&1
    fi
}

service_disable() {
    local name=$1
    if $IS_OPENRC; then
        rc-update del "$name" default >/dev/null 2>&1
    else
        systemctl disable "$name" >/dev/null 2>&1
    fi
}

# 重新生成 Nginx 配置
regenerate_nginx_conf() {
    if ! is_enabled "$USE_NGINX"; then
        return
    fi
    if [[ ! -f ${NGINX_CONF_DIR}/singbox-argo.conf ]]; then
        return
    fi
    
    local port_nginx=$(grep -oE "listen 127.0.0.1:[0-9]+" ${NGINX_CONF_DIR}/singbox-argo.conf | head -n 1 | awk -F: '{print $2}')
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
    
    local listen_ipv6=""
    if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -ne 1 ]]; then
        listen_ipv6="listen [::1]:${port_nginx};"
    fi

    cat > ${NGINX_CONF_DIR}/singbox-argo.conf <<EOF2
server {
    listen 127.0.0.1:${port_nginx};
    ${listen_ipv6}
    server_name localhost;
    \${nginx_locations}
}
EOF2
    service_restart nginx
}

# 重新生成 info.log 分享链接
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
    
    local argo_mode="temp"
    if [[ -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
        argo_mode=$ARGO_MODE
    fi

    cat > /etc/s-box/info.log <<EOF2
==================================================
        Sing-box 多协议一键部署脚本 安装成功
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
        if [[ "$argo_mode" == "token" ]]; then
            echo "Argo 固定域名: ${argo_domain}" >> /etc/s-box/info.log
        else
            echo "Argo 临时域名: ${argo_domain}" >> /etc/s-box/info.log
        fi
        echo "" >> /etc/s-box/info.log

        if is_enabled "$USE_NGINX"; then
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
        else
            # 免 Nginx 模式，根据绑定的目标协议生成相应的链接
            if [[ "$ARGO_TARGET_PROTOCOL" == "vmess" ]] && jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
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
            elif [[ "$ARGO_TARGET_PROTOCOL" == "trojan" ]] && jq -e '.inbounds[] | select(.tag=="trojan-ws-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
                local pass_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .users[0].password' /etc/s-box/sb.json)
                local path_trojan_ws=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .transport.path' /etc/s-box/sb.json)
                local path_trojan_ws_encoded=$(echo -n "$path_trojan_ws" | jq -sRr @uri)
                
                local trojan_argo_80_link="trojan://${pass_trojan}@cdn.2020111.xyz:80?security=none&type=ws&path=${path_trojan_ws_encoded}&host=${argo_domain}#SB-Trojan-Argo-80"
                local trojan_argo_443_link="trojan://${pass_trojan}@cdn.2020111.xyz:443?security=tls&sni=${argo_domain}&type=ws&path=${path_trojan_ws_encoded}&host=${argo_domain}#SB-Trojan-Argo-443"

                echo "1. Trojan Argo (80端口):" >> /etc/s-box/info.log
                echo "${trojan_argo_80_link}" >> /etc/s-box/info.log
                echo "" >> /etc/s-box/info.log
                echo "2. Trojan Argo (443端口/TLS):" >> /etc/s-box/info.log
                echo "${trojan_argo_443_link}" >> /etc/s-box/info.log
                echo "" >> /etc/s-box/info.log
            fi
        fi
    fi

    echo "==================================================" >> /etc/s-box/info.log
}

# 重新获取 Argo 临时域名并写入 argo.log
update_argo_domain() {
    if [[ ! -f ${NGINX_CONF_DIR}/singbox-argo.conf ]]; then
        return
    fi
    # 如果是 token 模式，不需要自动获取临时域名，直接返回
    if [[ -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
        if [[ "$ARGO_MODE" == "token" ]]; then
            return
        fi
    else
        # 兼容性检测，通过检测服务文件
        if $IS_OPENRC; then
            if grep -q "\--token" /etc/init.d/argo-tunnel 2>/dev/null; then
                return
            fi
        else
            if grep -q "\--token" /etc/systemd/system/argo-tunnel.service 2>/dev/null; then
                return
            fi
        fi
    fi
    # 清空旧日志，避免提取到旧域名
    : > /var/log/argo-tunnel.log 2>/dev/null
    : > /var/log/argo-tunnel.err 2>/dev/null
    service_restart argo-tunnel
    echo "正在等待 Argo 隧道上线并获取临时域名..."
    sleep 8
    local argo_domain=""
    for i in {1..10}; do
        if $IS_OPENRC; then
            argo_domain=$(cat /var/log/argo-tunnel.log /var/log/argo-tunnel.err 2>/dev/null | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -n 1)
        else
            argo_domain=$(journalctl -u argo-tunnel -n 50 --no-pager | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -n 1)
        fi
        [[ -n "$argo_domain" ]] && break
        sleep 3
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
    service_restart sing-box
    
    if [[ -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
    fi
    
    if is_enabled "$USE_NGINX" && [[ -f ${NGINX_CONF_DIR}/singbox-argo.conf ]]; then
        echo "正在重启 Nginx 和 Argo 服务..."
        regenerate_nginx_conf
        service_restart argo-tunnel
        update_argo_domain
    elif [[ -f /etc/s-box/argo.conf ]]; then
        echo "正在重启 Argo 服务..."
        service_restart argo-tunnel
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

modify_argo() {
    if [[ ! -f /usr/local/bin/cloudflared ]]; then
        echo "错误：未安装 Cloudflared，无法配置 Argo 隧道！"
        read -p "按回车键继续..." temp
        return
    fi

    while true; do
        local argo_mode="temp"
        local argo_token=""
        local argo_domain=""
        if [[ -f /etc/s-box/argo.conf ]]; then
            source /etc/s-box/argo.conf
            argo_mode=$ARGO_MODE
            argo_token=$ARGO_TOKEN
            argo_domain=$ARGO_DOMAIN
        else
            if $IS_OPENRC; then
                if grep -q "\--token" /etc/init.d/argo-tunnel 2>/dev/null; then
                    argo_mode="token"
                    argo_token=$(grep -oE "\--token[[:space:]]+[^[:space:]]+" /etc/init.d/argo-tunnel 2>/dev/null | awk '{print $2}')
                fi
            else
                if grep -q "\--token" /etc/systemd/system/argo-tunnel.service 2>/dev/null; then
                    argo_mode="token"
                    argo_token=$(grep -oE "\--token[[:space:]]+[^[:space:]]+" /etc/systemd/system/argo-tunnel.service 2>/dev/null | awk '{print $2}')
                fi
            fi
            if [[ -f /etc/s-box/argo.log ]]; then
                argo_domain=$(cat /etc/s-box/argo.log)
            fi
        fi

        echo "--------------------------------------------------"
        echo "          Argo 隧道参数修改"
        echo "--------------------------------------------------"
        if [[ "$argo_mode" == "token" ]]; then
            echo "当前模式: 固定域名隧道 (Token 模式)"
            echo "自备域名: $argo_domain"
            echo "Token值 : ${argo_token:0:15}... (已隐藏后续字符)"
        else
            echo "当前模式: 临时域名隧道 (TryCloudflare 模式)"
            echo "临时域名: $argo_domain"
        fi
        echo "--------------------------------------------------"
        echo "1. 切换为 临时域名隧道 (trycloudflare.com)"
        echo "2. 切换为 固定域名隧道 (使用 Cloudflare Tunnel Token)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-2]: " argo_choice
        
        if [[ "$argo_choice" == "0" || -z "$argo_choice" ]]; then
            break
        fi
        
        case $argo_choice in
            1)
                if [[ "$argo_mode" == "temp" ]]; then
                    echo "当前已是临时隧道模式，无需切换。"
                    continue
                fi
                echo "正在切换为临时域名隧道模式..."
                
                local argo_target_port="${ARGO_PORT}"
                local argo_depend="net sing-box"
                if is_enabled "$USE_NGINX"; then
                    local port_nginx=$(grep -oE "listen 127.0.0.1:[0-9]+" ${NGINX_CONF_DIR}/singbox-argo.conf 2>/dev/null | head -n 1 | awk -F: '{print $2}')
                    [[ -z "$port_nginx" ]] && port_nginx=8401
                    argo_target_port="${port_nginx}"
                    argo_depend="net sing-box nginx"
                fi
                
                if $IS_OPENRC; then
                    cat > /etc/init.d/argo-tunnel <<EOF_INIT
#!/sbin/openrc-run
name="argo-tunnel"
description="Argo Tunnel Service"
command="/usr/local/bin/cloudflared"
command_args="tunnel --url http://127.0.0.1:${argo_target_port}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/argo-tunnel.log"
error_log="/var/log/argo-tunnel.log"
depend() {
    need ${argo_depend}
}
EOF_INIT
                    chmod +x /etc/init.d/argo-tunnel
                else
                    cat > /etc/systemd/system/argo-tunnel.service <<EOF_SYSTEMD
[Unit]
Description=Argo Tunnel Service
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:${argo_target_port}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
                    systemctl daemon-reload
                fi
                
                cat > /etc/s-box/argo.conf <<EOF_ARGO
ARGO_MODE="temp"
ARGO_TOKEN=""
ARGO_DOMAIN=""
USE_NGINX="${USE_NGINX}"
ARGO_PORT="${ARGO_PORT}"
ARGO_TARGET_PROTOCOL="${ARGO_TARGET_PROTOCOL}"
EOF_ARGO
                
                service_restart argo-tunnel
                update_argo_domain
                regenerate_info_log
                echo "成功切换为临时域名隧道模式！"
                ;;
            2)
                read -p "请输入您的 Cloudflare Tunnel Token: " new_token
                if [[ -z "$new_token" ]]; then
                    echo "错误：Token 不能为空！"
                    continue
                fi
                read -p "请输入您在 Cloudflare 上为该隧道绑定的自定义域名 (如: argo.example.com): " new_domain
                if [[ -z "$new_domain" ]]; then
                    echo "错误：自定义域名不能为空！"
                    continue
                fi
                
                echo "正在配置固定域名隧道..."
                
                local argo_depend="net sing-box"
                if is_enabled "$USE_NGINX"; then
                    argo_depend="net sing-box nginx"
                fi
                
                if $IS_OPENRC; then
                    cat > /etc/init.d/argo-tunnel <<EOF_INIT
#!/sbin/openrc-run
name="argo-tunnel"
description="Argo Tunnel Service"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate run --token ${new_token}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/argo-tunnel.log"
error_log="/var/log/argo-tunnel.log"
depend() {
    need ${argo_depend}
}
EOF_INIT
                    chmod +x /etc/init.d/argo-tunnel
                else
                    cat > /etc/systemd/system/argo-tunnel.service <<EOF_SYSTEMD
[Unit]
Description=Argo Tunnel Service
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${new_token}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
                    systemctl daemon-reload
                fi
                
                cat > /etc/s-box/argo.conf <<EOF_ARGO
ARGO_MODE="token"
ARGO_TOKEN="${new_token}"
ARGO_DOMAIN="${new_domain}"
USE_NGINX="${USE_NGINX}"
ARGO_PORT="${ARGO_PORT}"
ARGO_TARGET_PROTOCOL="${ARGO_TARGET_PROTOCOL}"
EOF_ARGO
                echo "$new_domain" > /etc/s-box/argo.log
                
                service_restart argo-tunnel
                regenerate_info_log
                echo "成功配置并启用固定域名隧道！"
                local port_nginx=$(grep -oE "listen 127.0.0.1:[0-9]+" ${NGINX_CONF_DIR}/singbox-argo.conf 2>/dev/null | head -n 1 | awk -F: '{print $2}')
                [[ -z "$port_nginx" ]] && port_nginx=8401
                if is_enabled "$USE_NGINX"; then
                    echo -e "\033[1;33m【重要提示】请前往 Cloudflare Zero Trust 控制台，将该隧道对应的 Public Hostname 服务地址 (Service)"
                    echo -e "设置为: http://127.0.0.1:${port_nginx} (请务必使用 127.0.0.1，以避免 localhost 的 IPv6 解析冲突！)\033[0m"
                else
                    echo -e "\033[1;33m【重要提示】请前往 Cloudflare Zero Trust 控制台，将该隧道对应的 Public Hostname 服务地址 (Service)"
                    echo -e "设置为: http://127.0.0.1:${ARGO_PORT} (请务必使用 127.0.0.1，以避免 localhost 的 IPv6 解析冲突！)\033[0m"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
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
        
        jq -e '.inbounds[] | select(.tag=="vless-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_vless=true
        jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_vmess=true
        jq -e '.inbounds[] | select(.tag=="trojan-tls-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_trojan=true
        jq -e '.inbounds[] | select(.tag=="hy2-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_hy2=true
        jq -e '.inbounds[] | select(.tag=="tuic-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_tuic=true
        jq -e '.inbounds[] | select(.tag=="anytls-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_anytls=true
        
        local menu_index=1
        local opt_vless=0
        local opt_vmess=0
        local opt_trojan=0
        local opt_hy2=0
        local opt_tuic=0
        local opt_anytls=0
        
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
        else
            echo "无效的选项，请重新输入。"
        fi
    done
}

view_logs() {
    while true; do
        echo -e "\033[0;36m"
        echo "    ______   ____     ____    ______     _    __   ____    ____ "
        echo "   / ____/  / __ \   / __ \  / ____/    | |  / /  / __ \  / ___/ "
        echo "  / /__    / /_/ /  / / / / / / __      | | / /  / /_/ /  \\__ \\  "
        echo " / /___   / _, _/  / /_/ / / /_/ /      | |/ /  / ____/  ___/ /  "
        echo "/_____/  /_/ |_|   \\____/  \\____/       |___/  /_/      /____/   "
        echo -e "\033[0m"
        echo "============================================================"
        echo "  服务运行日志查看"
        echo "============================================================"
        echo "  1. 查看 sing-box 节点主进程日志"
        echo "  2. 查看 cloudflared Argo 节点穿透日志"
        echo "  3. 查看服务自愈守护日志"
        echo "------------------------------------------------------------"
        echo "  0. 返回主菜单"
        echo "============================================================"
        read -p "请选择操作 [0-3]: " log_choice
        case $log_choice in
            1)
                echo "========== sing-box 日志 (最近 30 行) =========="
                if $IS_OPENRC; then
                    tail -n 30 /var/log/sing-box.log 2>/dev/null
                else
                    journalctl -u sing-box -n 30 --no-pager
                fi
                echo "================================================="
                read -p "按回车键继续..." temp
                ;;
            2)
                echo "========== Argo 穿透日志 (最近 30 行) =========="
                if $IS_OPENRC; then
                    tail -n 30 /var/log/argo-tunnel.log 2>/dev/null
                else
                    journalctl -u argo-tunnel -n 30 --no-pager
                fi
                echo "================================================="
                read -p "按回车键继续..." temp
                ;;
            3)
                echo "========== 自愈守护日志 (最近 30 行) =========="
                if [[ -f /etc/s-box/monitor.log ]]; then
                    tail -n 30 /etc/s-box/monitor.log 2>/dev/null
                else
                    echo "暂无自愈守护日志。"
                fi
                echo "================================================="
                read -p "按回车键继续..." temp
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

if [[ "$1" == "cron" ]]; then
    log_file="/etc/s-box/monitor.log"
    # 如果日志文件超过 50KB 则进行清空截断，避免体积无限膨胀
    if [[ -f "$log_file" && $(wc -c < "$log_file") -gt 51200 ]]; then
        : > "$log_file"
    fi

    # 监测并重启 sing-box
    if ! service_is_active sing-box; then
        service_restart sing-box
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [自愈守护] 检测到 Sing-box 未运行，已自动拉起！" >> "$log_file"
    fi
    
    # 检查是否配置了 Argo
    if [[ -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
    fi
    if [[ -f ${NGINX_CONF_DIR}/singbox-argo.conf ]] || (! is_enabled "$USE_NGINX" && [[ -f /etc/s-box/argo.conf ]]); then
        if ! service_is_active argo-tunnel; then
            service_restart argo-tunnel
            
            # 判断 argo 模式
            argo_mode="temp"
            if [[ -f /etc/s-box/argo.conf ]]; then
                source /etc/s-box/argo.conf
                argo_mode=$ARGO_MODE
            else
                if $IS_OPENRC; then
                    if grep -q "\--token" /etc/init.d/argo-tunnel 2>/dev/null; then
                        argo_mode="token"
                    fi
                else
                    if grep -q "\--token" /etc/systemd/system/argo-tunnel.service 2>/dev/null; then
                        argo_mode="token"
                    fi
                fi
            fi
            
            # 只有在临时模式下才需要重新抓取临时域名
            if [[ "$argo_mode" == "temp" ]]; then
                update_argo_domain
            fi
            regenerate_info_log
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [自愈守护] 检测到 Argo 隧道未运行，已自动拉起并重置配置！" >> "$log_file"
        fi
    fi
    exit 0
fi

while true; do
    check_cron_status() {
        if crontab -l 2>/dev/null | grep -q "sb cron"; then
            echo -e "\033[0;32m已启用\033[0m"
        else
            echo -e "\033[0;31m已禁用\033[0m"
        fi
    }

    echo "=================================================="
    echo "          Sing-box 快捷管理工具 sb"
    echo "=================================================="
    echo "1. 查看已配置的节点分享链接"
    echo "2. 重启 Sing-box 和 Argo 隧道服务"
    echo "3. 停止 Sing-box 和 Argo 隧道服务"
    echo "4. 查看 Argo 隧道实时域名与连接状态"
    echo "5. 修改已搭建节点参数"
    echo "6. 配置 Argo 隧道参数"
    echo "7. 彻底卸载脚本环境"
    echo "8. 开启/关闭服务自愈守护任务 (当前: $(check_cron_status))"
    echo "9. 查看运行日志"
    echo "0. 退出"
    echo "=================================================="
    read -p "请输入选项 [0-9]: " menu_choice
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
            service_restart sing-box
            if [[ -f /etc/s-box/argo.conf ]]; then
                source /etc/s-box/argo.conf
            fi
            if is_enabled "$USE_NGINX" && [[ -f ${NGINX_CONF_DIR}/singbox-argo.conf ]]; then
                service_restart argo-tunnel
                update_argo_domain
            elif [[ -f /etc/s-box/argo.conf ]]; then
                service_restart argo-tunnel
                update_argo_domain
            fi
            regenerate_info_log
            echo "重启完成并已重新生成分享链接！"
            ;;
        3)
            echo "正在停止服务..."
            service_stop sing-box
            service_stop argo-tunnel
            echo "服务已停止！"
            ;;
        4)
            echo "正在获取隧道状态..."
            if service_is_active argo-tunnel; then
                echo "Argo 隧道处于运行状态："
                if $IS_OPENRC; then
                    tail -n 15 /var/log/argo-tunnel.log 2>/dev/null
                else
                    journalctl -u argo-tunnel -n 15 --no-pager
                fi
            else
                echo "Argo 隧道服务未运行。"
            fi
            ;;
        5)
            modify_node_params
            ;;
        6)
            modify_argo
            ;;
        7)
            if [[ -f /etc/s-box/uninstall.sh ]]; then
                bash /etc/s-box/uninstall.sh
                exit 0
            elif [[ -f /root/singbox/uninstall.sh ]]; then
                bash /root/singbox/uninstall.sh
                exit 0
            elif [[ -f ./uninstall.sh ]]; then
                bash ./uninstall.sh
                exit 0
            else
                echo "未找到卸载脚本，正在执行直接清理..."
                service_stop sing-box
                service_stop argo-tunnel
                service_disable sing-box
                service_disable argo-tunnel
                if $IS_OPENRC; then
                    rm -f /etc/init.d/sing-box /etc/init.d/argo-tunnel
                else
                    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo-tunnel.service
                    systemctl daemon-reload
                fi
                rm -rf /etc/s-box /usr/local/bin/cloudflared /usr/local/bin/sb
                if crontab -l 2>/dev/null | grep -q "sb cron"; then
                    crontab -l | grep -v "sb cron" | crontab -
                fi
                if is_enabled "$USE_NGINX"; then
                    service_restart nginx
                fi
                echo "清理完成！"
                exit 0
            fi
            ;;
        8)
            if crontab -l 2>/dev/null | grep -q "sb cron"; then
                crontab -l | grep -v "sb cron" | crontab -
                echo "已成功关闭自愈守护定时任务。"
                (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/sb cron >> /etc/s-box/monitor.log 2>&1") | crontab -
                : > /etc/s-box/monitor.log 2>/dev/null
                echo "已成功开启自愈守护定时任务 (每分钟检测重启一次)。"
            fi
            read -p "按回车键继续..." temp
            ;;
        9)
            view_logs
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
    echo "1. 进入 Sing-box 快捷管理菜单 (直接回车)"
    echo "2. 重新安装/更新 Sing-box 服务"
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
echo "          请选择要安装的节点组合"
echo "=================================================="
echo "1. 默认安装全部节点协议 (直接回车)"
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

# 提供是否使用 Nginx 的选择
USE_NGINX="y"
ARGO_TARGET_PROTOCOL=""
if is_enabled "$ENABLE_ARGO"; then
    echo "=================================================="
    echo "          请选择 Argo 隧道的转发方式"
    echo "=================================================="
    echo "1. 启用 Nginx 作为反向代理分流 (推荐，支持多协议分流，直接回车)"
    echo "2. 不启用 Nginx (直接转发到指定协议端口，仿照 argosbx)"
    echo "=================================================="
    read -p "请输入选项 [1-2, 默认1]: " nginx_choice
    if [[ "$nginx_choice" == "2" ]]; then
        USE_NGINX="n"
        
        # 如果同时启用了 VMess 和 Trojan 协议，让用户选择绑定哪一个
        if is_enabled "$ENABLE_VMESS" && is_enabled "$ENABLE_TROJAN"; then
            echo "=================================================="
            echo "    不启用 Nginx 模式下，请选择 Argo 绑定的协议"
            echo "=================================================="
            echo "1. VMess-WS (直接回车)"
            echo "2. Trojan-WS"
            echo "=================================================="
            read -p "请输入选项 [1-2, 默认1]: " argo_proto_choice
            if [[ "$argo_proto_choice" == "2" ]]; then
                ARGO_TARGET_PROTOCOL="trojan"
            else
                ARGO_TARGET_PROTOCOL="vmess"
            fi
        elif is_enabled "$ENABLE_VMESS"; then
            ARGO_TARGET_PROTOCOL="vmess"
        elif is_enabled "$ENABLE_TROJAN"; then
            ARGO_TARGET_PROTOCOL="trojan"
        else
            ARGO_TARGET_PROTOCOL="none"
        fi
    fi
fi

# 统一判断，空值或 y/yes 都视为启用
is_enabled() {
    [[ "$1" == "y" || "$1" == "yes" || -z "$1" ]] && return 0 || return 1
}

# 1. 系统检测与包管理器识别
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
        release="Ubuntu"
    elif [[ "$ID" == "debian" ]]; then
        release="Debian"
    elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "rocky" || "$ID" == "almalinux" ]]; then
        release="CentOS"
    elif [[ "$ID" == "alpine" ]]; then
        release="Alpine"
    else
        log_err "暂不支持的系统类型: $NAME。请使用 Ubuntu, Debian, CentOS 或 Alpine。"
        exit 1
    fi
else
    if [[ -f /etc/redhat-release ]]; then
        release="CentOS"
    elif grep -q -i "debian" /etc/issue; then
        release="Debian"
    elif grep -q -i "ubuntu" /etc/issue; then
        release="Ubuntu"
    elif grep -q -i "alpine" /etc/issue; then
        release="Alpine"
    else
        log_err "暂不支持的系统类型。请使用 Ubuntu, Debian, CentOS 或 Alpine。"
        exit 1
    fi
fi

# 架构检测
arch=$(uname -m)
case $arch in
    x86_64) cpu="amd64" ;;
    aarch64) cpu="arm64" ;;
    armv7l) cpu="arm" ;;
    *)
        log_err "暂不支持的 CPU 架构: $arch"
        exit 1
        ;;
esac

# 2. 安装系统依赖 and Nginx
log_info "正在安装必要的系统依赖..."
if [[ "$release" == "Alpine" ]]; then
    apk update
    apk add --no-cache bash jq openssl curl tar wget procps coreutils iproute2
    is_enabled "$ENABLE_ARGO" && is_enabled "$USE_NGINX" && apk add --no-cache nginx
elif [[ "$release" == "CentOS" ]]; then
    yum install -y epel-release
    yum install -y jq openssl curl tar wget psmisc
    is_enabled "$ENABLE_ARGO" && is_enabled "$USE_NGINX" && yum install -y nginx
else
    apt-get update -y
    apt-get install -y jq openssl curl tar wget psmisc
    is_enabled "$ENABLE_ARGO" && is_enabled "$USE_NGINX" && apt-get install -y nginx
fi

# 安装完依赖后重新检测 Nginx 配置目录（Alpine 安装 nginx 后目录才出现）
if is_enabled "$ENABLE_ARGO" && is_enabled "$USE_NGINX"; then
    NGINX_CONF_DIR="/etc/nginx/conf.d"
    [[ -d "/etc/nginx/http.d" ]] && NGINX_CONF_DIR="/etc/nginx/http.d"
    mkdir -p "${NGINX_CONF_DIR}"
fi

# 3. 创建配置文件目录
mkdir -p /etc/s-box
cd /etc/s-box

# 4. 下载并安装 Sing-box 最新内核
log_info "正在获取 Sing-box 最新版本号..."
latest_version=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/v//')
if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
    latest_version="1.11.0" # 回退默认版本
    log_warn "获取最新版本号失败，使用默认版本 v$latest_version"
fi

log_info "正在下载 Sing-box 内核 v$latest_version ($cpu)..."
package_name="sing-box-${latest_version}-linux-${cpu}"
download_url="https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/${package_name}.tar.gz"

wget -qO sing-box.tar.gz "$download_url"
if [[ ! -f "sing-box.tar.gz" ]]; then
    log_err "下载 Sing-box 失败，请检查网络。"
    exit 1
fi

tar -xzf sing-box.tar.gz
mv "$package_name/sing-box" ./sing-box
rm -rf sing-box.tar.gz "$package_name"
chmod +x sing-box
log_info "Sing-box 内核安装成功：$(./sing-box version | head -n 1)"

# 5. 如果开启了 Argo，则下载并安装 Cloudflared
if is_enabled "$ENABLE_ARGO"; then
    log_info "正在下载 Cloudflared 客户端..."
    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cpu}"
    wget -qO /usr/local/bin/cloudflared "$cf_url"
    chmod +x /usr/local/bin/cloudflared
    log_info "Cloudflared 安装成功：$(cloudflared --version)"
fi

# 6. 生成安全凭证与证书
log_info "正在生成配置凭证..."
UUID=$(./sing-box generate uuid)

# 无论选了什么，为了简化逻辑均生成 Reality 密钥对和自签证书
reality_keys=$(./sing-box generate reality-keypair)
private_key=$(echo "$reality_keys" | awk '/PrivateKey/{print $2}')
public_key=$(echo "$reality_keys" | awk '/PublicKey/{print $2}')
echo "$public_key" > /etc/s-box/public.key
short_id=$(openssl rand -hex 8)

# 生成自签证书
openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private.key
openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/s-box/cert.pem -subj "/CN=www.bing.com"

# 7. 端口自动分配与自定义（检查端口冲突）
check_port() {
    local port=$1
    if ss -tunlp | grep -q ":$port "; then
        return 1
    else
        return 0
    fi
}

get_random_port_in_range() {
    local min=$1
    local max=$2
    local port
    while true; do
        port=$(shuf -i ${min}-${max} -n 1)
        if check_port "$port"; then
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
            if check_port "$port"; then
                echo "$port"
                break
            else
                log_warn "端口 $port 已被占用，请重新输入！"
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
        log_err "输入不合法！格式应为: 起始端口-结束端口 (如 10000-20000)，且在 1-65535 之间。"
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
        if is_enabled "$USE_NGINX" || [[ "$ARGO_TARGET_PROTOCOL" == "trojan" ]]; then
            is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_WS=$(get_custom_port "Trojan-WS (Argo内部)" 58204)
        fi
        is_enabled "$USE_NGINX" && PORT_NGINX=8401
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
        if is_enabled "$USE_NGINX" || [[ "$ARGO_TARGET_PROTOCOL" == "trojan" ]]; then
            is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_WS=$(get_random_port_in_range $start_p $end_p)
        fi
        is_enabled "$USE_NGINX" && PORT_NGINX=8401
    fi
    is_enabled "$ENABLE_HY2" && PORT_HY2=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_TUIC" && PORT_TUIC=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_ANYTLS" && PORT_ANYTLS=$(get_random_port_in_range $start_p $end_p)
else
    is_enabled "$ENABLE_VLESS" && PORT_VLESS=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_VMESS" && PORT_VMESS=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_TLS=$(get_random_port_in_range 20000 60000)
    if is_enabled "$ENABLE_ARGO"; then
        if is_enabled "$USE_NGINX" || [[ "$ARGO_TARGET_PROTOCOL" == "trojan" ]]; then
            is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_WS=$(get_random_port_in_range 20000 60000)
        fi
        is_enabled "$USE_NGINX" && PORT_NGINX=8401
    fi
    is_enabled "$ENABLE_HY2" && PORT_HY2=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_TUIC" && PORT_TUIC=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_ANYTLS" && PORT_ANYTLS=$(get_random_port_in_range 20000 60000)
fi

ARGO_PORT=""
if is_enabled "$ENABLE_ARGO"; then
    if is_enabled "$USE_NGINX"; then
        ARGO_PORT=$PORT_NGINX
    else
        if [[ "$ARGO_TARGET_PROTOCOL" == "vmess" ]]; then
            ARGO_PORT=$PORT_VMESS
        elif [[ "$ARGO_TARGET_PROTOCOL" == "trojan" ]]; then
            ARGO_PORT=$PORT_TROJAN_WS
        fi
    fi
fi

# 获取服务器公网 IP
IPV4=$(curl -s4m5 icanhazip.com || curl -s4m5 api.ipify.org)
IPV6=$(curl -s6m5 icanhazip.com || curl -s6m5 api6.ipify.org)
IP=${IPV4:-$IPV6}

# 8. 动态生成 sing-box 配置文件 sb.json
log_info "正在生成 sing-box 配置文件..."
inbounds=()

if is_enabled "$ENABLE_VLESS"; then
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

# 如果启用了 Argo，且启用了 Trojan，并且（启用了 Nginx 或 Argo 目标协议为 Trojan），则为 Argo 创建无 TLS 的 Trojan 端口
if is_enabled "$ENABLE_ARGO" && is_enabled "$ENABLE_TROJAN" && { is_enabled "$USE_NGINX" || [[ "$ARGO_TARGET_PROTOCOL" == "trojan" ]]; }; then
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

# 将 inbounds 数组转为 JSON 片段
inbounds_json=""
for i in "${!inbounds[@]}"; do
    if [[ $i -eq 0 ]]; then
        inbounds_json="${inbounds[$i]}"
    else
        inbounds_json="${inbounds_json},${inbounds[$i]}"
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
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# 9. 配置 Nginx（仅如果启用了 Argo）
if is_enabled "$ENABLE_ARGO"; then
    log_info "正在配置 Nginx..."
    
    # 动态写入 nginx location 块
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

    # 删除 Alpine/Debian 默认的 Nginx 站点配置，避免冲突
    rm -f ${NGINX_CONF_DIR}/default.conf 2>/dev/null
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null

    local listen_ipv6=""
    if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -ne 1 ]]; then
        listen_ipv6="listen [::1]:${PORT_NGINX};"
    fi

    cat > ${NGINX_CONF_DIR}/singbox-argo.conf <<EOF
server {
    listen 127.0.0.1:${PORT_NGINX};
    ${listen_ipv6}
    server_name localhost;
    ${nginx_locations}
}
EOF
    # 测试 Nginx 配置是否合法
    if ! nginx -t >/dev/null 2>&1; then
        log_warn "Nginx 配置测试失败，尝试修复..."
        nginx -t 2>&1 | tail -n 5
    fi
    service_enable nginx
    service_restart nginx
    # 验证 Nginx 是否真正监听了指定端口
    sleep 1
    if ss -tlnp 2>/dev/null | grep -q ":${PORT_NGINX} " || netstat -tlnp 2>/dev/null | grep -q ":${PORT_NGINX} "; then
        log_info "Nginx 已成功启动并监听端口 ${PORT_NGINX}"
    else
        log_warn "Nginx 未在端口 ${PORT_NGINX} 上监听，请检查 Nginx 配置！"
        nginx -t 2>&1
    fi
fi

# 10. 创建守护服务
if $IS_OPENRC; then
    log_info "正在创建 OpenRC 服务..."
    
    # Sing-box OpenRC 服务
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Service"
command="/etc/s-box/sing-box"
command_args="run -c /etc/s-box/sb.json"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/sing-box
    service_enable sing-box
    service_restart sing-box
else
    log_info "正在创建 systemd 服务..."
    
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

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

# Argo 隧道服务（仅在启用 Argo 时）
if is_enabled "$ENABLE_ARGO"; then
    local argo_mode="temp"
    local argo_token=""
    local argo_domain=""
    if [[ -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
        argo_mode=$ARGO_MODE
        argo_token=$ARGO_TOKEN
        argo_domain=$ARGO_DOMAIN
    fi

    if $IS_OPENRC; then
        local cf_args="tunnel --url http://127.0.0.1:${PORT_NGINX}"
        if [[ "$argo_mode" == "token" ]]; then
            cf_args="tunnel --no-autoupdate run --token ${argo_token}"
        fi
        cat > /etc/init.d/argo-tunnel <<EOF
#!/sbin/openrc-run
name="argo-tunnel"
description="Argo Tunnel Service"
command="/usr/local/bin/cloudflared"
command_args="${cf_args}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/argo-tunnel.log"
error_log="/var/log/argo-tunnel.log"
depend() {
    need net sing-box nginx
}
EOF
        chmod +x /etc/init.d/argo-tunnel
        service_enable argo-tunnel
        # 清空旧日志，避免提取到旧域名
        : > /var/log/argo-tunnel.log 2>/dev/null
        : > /var/log/argo-tunnel.err 2>/dev/null
        service_restart argo-tunnel
    else
        local cf_exec="/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:${PORT_NGINX}"
        if [[ "$argo_mode" == "token" ]]; then
            cf_exec="/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${argo_token}"
        fi
        cat > /etc/systemd/system/argo-tunnel.service <<EOF
[Unit]
Description=Argo Tunnel Service
After=network.target

[Service]
User=root
ExecStart=${cf_exec}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable argo-tunnel
        systemctl restart argo-tunnel
    fi

    if [[ "$argo_mode" == "token" ]]; then
        ARGO_DOMAIN="${argo_domain}"
        echo "$ARGO_DOMAIN" > /etc/s-box/argo.log
        cat > /etc/s-box/argo.conf <<EOF_ARGO
ARGO_MODE="token"
ARGO_TOKEN="${argo_token}"
ARGO_DOMAIN="${ARGO_DOMAIN}"
EOF_ARGO
    else
        log_info "正在等待 Argo 隧道上线，获取节点临时域名..."
        sleep 6

        # 提取 trycloudflare 域名
        ARGO_DOMAIN=""
        for i in {1..5}; do
            if $IS_OPENRC; then
                ARGO_DOMAIN=$(cat /var/log/argo-tunnel.log /var/log/argo-tunnel.err 2>/dev/null | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -n 1)
            else
                ARGO_DOMAIN=$(journalctl -u argo-tunnel -n 50 --no-pager | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -n 1)
            fi
            if [[ -n "$ARGO_DOMAIN" ]]; then
                break
            fi
            sleep 3
        done

        if [[ -z "$ARGO_DOMAIN" ]]; then
            if $IS_OPENRC; then
                log_warn "获取 Argo 域名超时，请稍后查看 /var/log/argo-tunnel.log。"
            else
                log_warn "获取 Argo 域名超时，请稍后使用 'journalctl -u argo-tunnel' 命令手动查看。"
            fi
            ARGO_DOMAIN="[未获取到Argo域名]"
        fi
        echo "$ARGO_DOMAIN" > /etc/s-box/argo.log
        cat > /etc/s-box/argo.conf <<EOF_ARGO
ARGO_MODE="temp"
ARGO_TOKEN=""
ARGO_DOMAIN="${ARGO_DOMAIN}"
USE_NGINX="${USE_NGINX}"
ARGO_PORT="${ARGO_PORT}"
ARGO_TARGET_PROTOCOL="${ARGO_TARGET_PROTOCOL}"
EOF_ARGO
    fi
fi

# 11. 节点输出与分享链接生成
log_info "所有已选服务部署并启动完毕！"

# 初始化 info.log
cat > /etc/s-box/info.log <<EOF
==================================================
        Sing-box 多协议一键部署脚本 安装成功
==================================================
通用密码/UUID: ${UUID}

------------------【直连节点】--------------------
EOF

# 动态追加直连链接
if is_enabled "$ENABLE_VLESS"; then
    VLESS_LINK="vless://${UUID}@${IP}:${PORT_VLESS}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apple.com&fp=chrome&pbk=${public_key}&sid=${short_id}#SB-VLESS-Reality"
    echo "1. VLESS-Reality:" >> /etc/s-box/info.log
    echo "${VLESS_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

if is_enabled "$ENABLE_VMESS"; then
    VMESS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-WS",
  "add": "${IP}",
  "port": "${PORT_VMESS}",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "",
  "path": "/${UUID}-vm",
  "tls": "none",
  "sni": ""
}
EOF
)
    VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
    echo "2. VMess-WS (无TLS):" >> /etc/s-box/info.log
    echo "${VMESS_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

if is_enabled "$ENABLE_TROJAN"; then
    TROJAN_LINK="trojan://${UUID}@${IP}:${PORT_TROJAN_TLS}?security=tls&sni=www.bing.com&allowInsecure=1&type=ws&path=%2F${UUID}-tr#SB-Trojan-WS-TLS"
    echo "3. Trojan-WS-TLS (自签证书):" >> /etc/s-box/info.log
    echo "${TROJAN_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

if is_enabled "$ENABLE_HY2"; then
    HY2_LINK="hysteria2://${UUID}@${IP}:${PORT_HY2}?insecure=1&sni=www.bing.com#SB-Hysteria2"
    echo "4. Hysteria2:" >> /etc/s-box/info.log
    echo "${HY2_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

if is_enabled "$ENABLE_TUIC"; then
    TUIC_LINK="tuic://${UUID}:${UUID}@${IP}:${PORT_TUIC}?alpn=h3&congestion_control=bbr&udp_relay=1&allow_insecure=1#SB-TUIC-v5"
    echo "5. TUIC v5:" >> /etc/s-box/info.log
    echo "${TUIC_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

if is_enabled "$ENABLE_ANYTLS"; then
    ANYTLS_LINK="anytls://${UUID}@${IP}:${PORT_ANYTLS}?security=tls&sni=www.bing.com&allowInsecure=1#SB-AnyTLS"
    echo "6. AnyTLS:" >> /etc/s-box/info.log
    echo "${ANYTLS_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

# 动态追加 Argo 链接
if is_enabled "$ENABLE_ARGO"; then
    echo "------------------【Argo穿透】--------------------" >> /etc/s-box/info.log
    if [[ "$argo_mode" == "token" ]]; then
        echo "Argo 固定域名: ${ARGO_DOMAIN}" >> /etc/s-box/info.log
    else
        echo "Argo 临时域名: ${ARGO_DOMAIN}" >> /etc/s-box/info.log
    fi
    echo "" >> /etc/s-box/info.log

    if is_enabled "$USE_NGINX"; then
        if is_enabled "$ENABLE_VMESS"; then
            VMESS_ARGO_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-Argo-80",
  "add": "cdn.2020111.xyz",
  "port": "80",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${ARGO_DOMAIN}",
  "path": "/${UUID}-vm",
  "tls": "none",
  "sni": ""
}
EOF
)
            VMESS_ARGO_80_LINK="vmess://$(echo -n "$VMESS_ARGO_JSON" | base64 -w 0)"

            VMESS_ARGO_TLS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-Argo-443",
  "add": "cdn.2020111.xyz",
  "port": "443",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${ARGO_DOMAIN}",
  "path": "/${UUID}-vm",
  "tls": "tls",
  "sni": "${ARGO_DOMAIN}"
}
EOF
)
            VMESS_ARGO_443_LINK="vmess://$(echo -n "$VMESS_ARGO_TLS_JSON" | base64 -w 0)"

            echo "1. VMess Argo (80端口):" >> /etc/s-box/info.log
            echo "${VMESS_ARGO_80_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            echo "2. VMess Argo (443端口/TLS):" >> /etc/s-box/info.log
            echo "${VMESS_ARGO_443_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi

        if is_enabled "$ENABLE_TROJAN"; then
            TROJAN_ARGO_80_LINK="trojan://${UUID}@cdn.2020111.xyz:80?security=none&type=ws&path=%2F${UUID}-tr-argo&host=${ARGO_DOMAIN}#SB-Trojan-Argo-80"
            TROJAN_ARGO_443_LINK="trojan://${UUID}@cdn.2020111.xyz:443?security=tls&sni=${ARGO_DOMAIN}&type=ws&path=%2F${UUID}-tr-argo&host=${ARGO_DOMAIN}#SB-Trojan-Argo-443"

            echo "3. Trojan Argo (80端口):" >> /etc/s-box/info.log
            echo "${TROJAN_ARGO_80_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            echo "4. Trojan Argo (443端口/TLS):" >> /etc/s-box/info.log
            echo "${TROJAN_ARGO_443_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi
    else
        # 免 Nginx 模式，根据绑定的目标协议生成相应的链接
        if [[ "$ARGO_TARGET_PROTOCOL" == "vmess" ]] && is_enabled "$ENABLE_VMESS"; then
            VMESS_ARGO_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-Argo-80",
  "add": "cdn.2020111.xyz",
  "port": "80",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${ARGO_DOMAIN}",
  "path": "/${UUID}-vm",
  "tls": "none",
  "sni": ""
}
EOF
)
            VMESS_ARGO_80_LINK="vmess://$(echo -n "$VMESS_ARGO_JSON" | base64 -w 0)"

            VMESS_ARGO_TLS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-Argo-443",
  "add": "cdn.2020111.xyz",
  "port": "443",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${ARGO_DOMAIN}",
  "path": "/${UUID}-vm",
  "tls": "tls",
  "sni": "${ARGO_DOMAIN}"
}
EOF
)
            VMESS_ARGO_443_LINK="vmess://$(echo -n "$VMESS_ARGO_TLS_JSON" | base64 -w 0)"

            echo "1. VMess Argo (80端口):" >> /etc/s-box/info.log
            echo "${VMESS_ARGO_80_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            echo "2. VMess Argo (443端口/TLS):" >> /etc/s-box/info.log
            echo "${VMESS_ARGO_443_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        elif [[ "$ARGO_TARGET_PROTOCOL" == "trojan" ]] && is_enabled "$ENABLE_TROJAN"; then
            TROJAN_ARGO_80_LINK="trojan://${UUID}@cdn.2020111.xyz:80?security=none&type=ws&path=%2F${UUID}-tr-argo&host=${ARGO_DOMAIN}#SB-Trojan-Argo-80"
            TROJAN_ARGO_443_LINK="trojan://${UUID}@cdn.2020111.xyz:443?security=tls&sni=${ARGO_DOMAIN}&type=ws&path=%2F${UUID}-tr-argo&host=${ARGO_DOMAIN}#SB-Trojan-Argo-443"

            echo "1. Trojan Argo (80端口):" >> /etc/s-box/info.log
            echo "${TROJAN_ARGO_80_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            echo "2. Trojan Argo (443端口/TLS):" >> /etc/s-box/info.log
            echo "${TROJAN_ARGO_443_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi
    fi
fi

echo "==================================================" >> /etc/s-box/info.log

# 创建 sb 快捷管理工具
log_info "正在生成快捷管理工具 sb..."
create_sb_tool

# 备份一份 uninstall.sh 在 /etc/s-box 中以便 sb 工具直接调用
if [[ -f ./uninstall.sh ]]; then
    cp ./uninstall.sh /etc/s-box/uninstall.sh
else
    curl -sL https://raw.githubusercontent.com/hxzlplp7/singbox/main/uninstall.sh -o /etc/s-box/uninstall.sh 2>/dev/null \
        || wget -qO /etc/s-box/uninstall.sh https://raw.githubusercontent.com/hxzlplp7/singbox/main/uninstall.sh 2>/dev/null
fi
chmod +x /etc/s-box/uninstall.sh 2>/dev/null

# 添加守护自愈定时任务（每分钟检查一次）
if ! crontab -l 2>/dev/null | grep -q "sb cron"; then
    (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/sb cron >> /etc/s-box/monitor.log 2>&1") | crontab -
    : > /etc/s-box/monitor.log 2>/dev/null
    log_info "已成功添加 Sing-box / Argo 服务监控守护定时任务。"
fi

# 打印信息到终端
cat /etc/s-box/info.log
log_info "所有已选节点的链接已保存至 /etc/s-box/info.log"
log_info "快捷管理工具已安装。今后你可以直接在终端输入【 sb 】来管理你的服务与节点配置。"
