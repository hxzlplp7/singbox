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

log_info "开始安装 Sing-box 多协议一键部署脚本..."

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
    x86_64) cpu="amd64" ;;
    aarch64) cpu="arm64" ;;
    armv7l) cpu="arm" ;;
    *)
        log_err "暂不支持的 CPU 架构: $arch"
        exit 1
        ;;
esac

# 2. 安装系统依赖和 Nginx
log_info "正在安装必要的系统依赖..."
if [[ "$release" == "CentOS" ]]; then
    yum install -y epel-release
    yum install -y jq openssl curl tar wget psmisc
    is_enabled "$ENABLE_ARGO" && yum install -y nginx
else
    apt-get update -y
    apt-get install -y jq openssl curl tar wget psmisc
    is_enabled "$ENABLE_ARGO" && apt-get install -y nginx
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

# 7. 端口自动分配（检查端口冲突）
check_port() {
    local port=$1
    if ss -tunlp | grep -q ":$port "; then
        return 1
    else
        return 0
    fi
}

get_random_port() {
    local port
    while true; do
        port=$(shuf -i 20000-60000 -n 1)
        if check_port "$port"; then
            echo "$port"
            break
        fi
    done
}

# 动态为已选协议分配随机端口
is_enabled "$ENABLE_VLESS" && PORT_VLESS=$(get_random_port)
is_enabled "$ENABLE_VMESS" && PORT_VMESS=$(get_random_port)
is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_TLS=$(get_random_port)
if is_enabled "$ENABLE_ARGO"; then
    is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_WS=$(get_random_port)
    PORT_NGINX=8401
fi
is_enabled "$ENABLE_HY2" && PORT_HY2=$(get_random_port)
is_enabled "$ENABLE_TUIC" && PORT_TUIC=$(get_random_port)
is_enabled "$ENABLE_ANYTLS" && PORT_ANYTLS=$(get_random_port)

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

# 如果启用了 Argo 并且启用了 Trojan，则为 Argo 创建无 TLS 的 Trojan 端口
if is_enabled "$ENABLE_ARGO" && is_enabled "$ENABLE_TROJAN"; then
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

    cat > /etc/nginx/conf.d/singbox-argo.conf <<EOF
server {
    listen 127.0.0.1:${PORT_NGINX};
    server_name localhost;
    ${nginx_locations}
}
EOF
    systemctl restart nginx
fi

# 10. 创建 systemd 服务
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

# Argo 隧道服务（仅在启用 Argo 时）
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

    # 提取 trycloudflare 域名
    ARGO_DOMAIN=""
    for i in {1..5}; do
        ARGO_DOMAIN=$(journalctl -u argo-tunnel -n 50 --no-pager | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | head -n 1)
        if [[ -n "$ARGO_DOMAIN" ]]; then
            break
        fi
        sleep 2
    done

    if [[ -z "$ARGO_DOMAIN" ]]; then
        log_warn "获取 Argo 域名超时，请稍后使用 'journalctl -u argo-tunnel' 命令手动查看。"
        ARGO_DOMAIN="[未获取到Argo域名]"
    fi
    echo "$ARGO_DOMAIN" > /etc/s-box/argo.log
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
    echo "Argo 临时域名: ${ARGO_DOMAIN}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log

    if is_enabled "$ENABLE_VMESS"; then
        VMESS_ARGO_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-Argo-80",
  "add": "${ARGO_DOMAIN}",
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
  "add": "${ARGO_DOMAIN}",
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
        TROJAN_ARGO_80_LINK="trojan://${UUID}@${ARGO_DOMAIN}:80?security=none&type=ws&path=%2F${UUID}-tr-argo#SB-Trojan-Argo-80"
        TROJAN_ARGO_443_LINK="trojan://${UUID}@${ARGO_DOMAIN}:443?security=tls&sni=${ARGO_DOMAIN}&type=ws&path=%2F${UUID}-tr-argo#SB-Trojan-Argo-443"

        echo "3. Trojan Argo (80端口):" >> /etc/s-box/info.log
        echo "${TROJAN_ARGO_80_LINK}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
        echo "4. Trojan Argo (443端口/TLS):" >> /etc/s-box/info.log
        echo "${TROJAN_ARGO_443_LINK}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi
fi

echo "==================================================" >> /etc/s-box/info.log

# 创建 sb 快捷管理工具
log_info "正在生成快捷管理工具 sb..."
cat > /usr/local/bin/sb <<EOF
#!/bin/bash
# Sing-box 极简快捷管理工具

if [[ \$EUID -ne 0 ]]; then
   echo "错误：必须以 root 权限运行此脚本！"
   exit 1
fi

while true; do
    echo "=================================================="
    echo "          Sing-box 快捷管理工具 sb"
    echo "=================================================="
    echo "1. 查看已配置的节点分享链接"
    echo "2. 重启 Sing-box 和 Argo 隧道服务"
    echo "3. 停止 Sing-box 和 Argo 隧道服务"
    echo "4. 查看 Argo 隧道实时域名与连接状态"
    echo "5. 彻底卸载脚本环境"
    echo "0. 退出"
    echo "=================================================="
    read -p "请输入选项 [0-5]: " menu_choice
    case \$menu_choice in
        1)
            if [[ -f /etc/s-box/info.log ]]; then
                cat /etc/s-box/info.log
            else
                echo "未找到节点信息日志，请确认是否安装成功。"
            fi
            ;;
        2)
            echo "正在重启服务..."
            systemctl restart sing-box
            systemctl restart argo-tunnel 2>/dev/null
            echo "重启完成！"
            ;;
        3)
            echo "正在停止服务..."
            systemctl stop sing-box
            systemctl stop argo-tunnel 2>/dev/null
            echo "服务已停止！"
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
                systemctl stop sing-box argo-tunnel 2>/dev/null
                systemctl disable sing-box argo-tunnel 2>/dev/null
                rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo-tunnel.service
                systemctl daemon-reload
                rm -rf /etc/s-box /usr/local/bin/cloudflared /usr/local/bin/sb
                systemctl restart nginx 2>/dev/null
                echo "清理完成！"
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

# 备份一份 uninstall.sh 在 /etc/s-box 中以便 sb 工具直接调用
if [[ -f ./uninstall.sh ]]; then
    cp ./uninstall.sh /etc/s-box/uninstall.sh
    chmod +x /etc/s-box/uninstall.sh
fi

# 打印信息到终端
cat /etc/s-box/info.log
log_info "所有已选节点的链接已保存至 /etc/s-box/info.log"
log_info "快捷管理工具已安装。今后你可以直接在终端输入【 sb 】来管理你的服务与节点配置。"
