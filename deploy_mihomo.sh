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
    echo -e "${YELLOW}       __  __ _ _                      ____        _     _          ${PLAIN}"
    echo -e "${YELLOW}      |  \\/  (_) |__   ___  _ __ ___  | __ ) _ __ (_) __| | __ _    ${PLAIN}"
    echo -e "${YELLOW}      | |\\/| | | '_ \\ / _ \\| '_ \` _ \\ |  _ \\| '__|| |/ _\` |/ _\` |   ${PLAIN}"
    echo -e "${YELLOW}      | |  | | | | | | (_) | | | | | || |_) | |   | | (_| | (_| |   ${PLAIN}"
    echo -e "${YELLOW}      |_|  |_|_|_| |_|\\___/|_| |_| |_||____/|_|   |_|\\__,_|\\__, |   ${PLAIN}"
    echo -e "${YELLOW}                                                           |___/    ${PLAIN}"
    echo -e "${BLUE}====================================================================${PLAIN}"
    echo -e "${BLUE}                Mihomo (Clash Meta) 客户端一键部署脚本              ${PLAIN}"
    echo -e "${BLUE}              支持拉取订阅、配置 Socks5 监听、集成本地 yacd         ${PLAIN}"
    echo -e "${BLUE}====================================================================${PLAIN}"
    echo ""
}

show_logo

# 1. 检测系统架构与包管理器
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

arch=$(uname -m)
case $arch in
    x86_64) cpu="amd64-compatible" ;;
    aarch64) cpu="arm64" ;;
    armv7l) cpu="arm32" ;;
    *)
        log_err "暂不支持的 CPU 架构: $arch"
        exit 1
        ;;
esac

# 2. 安装必要依赖
log_info "正在安装必要的系统依赖..."
if [[ "$release" == "CentOS" ]]; then
    yum install -y jq curl tar wget unzip gzip psmisc
else
    apt-get update -y
    apt-get install -y jq curl tar wget unzip gzip psmisc
fi

# 创建配置目录
mkdir -p /etc/mihomo

# 3. 交互获取配置参数
echo "=================================================="
echo "          配置 Mihomo 客户端参数"
echo "=================================================="
while true; do
    read -p "请输入您的 Clash/Mihomo 订阅链接 (http/https): " SUB_URL
    if [[ -n "$SUB_URL" && "$SUB_URL" =~ ^https?:// ]]; then
        break
    else
        log_err "订阅链接格式不正确，必须以 http:// 或 https:// 开头！"
    fi
done

MIHOMO_PORT=7890
read -p "请输入 Mihomo 本地 Socks5/HTTP 混合监听端口 [默认 7890]: " opt_m_port
[[ -n "$opt_m_port" ]] && MIHOMO_PORT=$opt_m_port

YACD_PORT=9090
read -p "请输入 yacd 网页控制面板监听端口 [默认 9090]: " opt_y_port
[[ -n "$opt_y_port" ]] && YACD_PORT=$opt_y_port

MIHOMO_SECRET=$(openssl rand -hex 6)
read -p "请输入 yacd 面板连接密钥/密码 [默认 随机生成: ${MIHOMO_SECRET}]: " opt_secret
[[ -n "$opt_secret" ]] && MIHOMO_SECRET=$opt_secret

# 4. 下载并安装 Mihomo 内核
log_info "正在获取 Mihomo (Clash Meta) 最新版本号..."
latest_version=$(curl -Ls https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | jq -r '.tag_name')
if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
    latest_version="v1.18.9" # 回退版本
    log_warn "获取最新版本号失败，使用默认版本 $latest_version"
fi

log_info "正在下载 Mihomo 内核 ${latest_version} ($cpu)..."
download_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/mihomo-linux-${cpu}-${latest_version}.gz"

wget -qO /etc/mihomo/mihomo.gz "$download_url"
if [[ ! -f "/etc/mihomo/mihomo.gz" ]]; then
    log_err "下载 Mihomo 内核失败，请检查网络。"
    exit 1
fi

gzip -d -f /etc/mihomo/mihomo.gz
mv /etc/mihomo/mihomo /usr/local/bin/mihomo
chmod +x /usr/local/bin/mihomo
log_info "Mihomo 内核安装成功：$(/usr/local/bin/mihomo -v)"

# 5. 下载并解析订阅配置文件
log_info "正在从订阅链接下载配置文件..."
curl -L -o /etc/mihomo/config.yaml "$SUB_URL"

if [[ ! -f "/etc/mihomo/config.yaml" || ! -s "/etc/mihomo/config.yaml" ]]; then
    log_err "配置文件下载为空或失败，请检查您的订阅链接是否可用。"
    exit 1
fi

# 解密 Base64 检测 (很多机场直接返回 Base64 密文)
if ! grep -q "proxies:" /etc/mihomo/config.yaml && ! grep -q "port:" /etc/mihomo/config.yaml; then
    if base64 -d /etc/mihomo/config.yaml > /etc/mihomo/config_decoded.yaml 2>/dev/null; then
        mv /etc/mihomo/config_decoded.yaml /etc/mihomo/config.yaml
        log_info "成功解密 Base64 格式的订阅配置。"
    else
        log_warn "未检测到 YAML 代理结构，且尝试 Base64 解码失败。如果后续启动报错，请确认订阅链接是否正确。"
    fi
fi

# 移除可能冲突的重复配置项
sed -i '/^port:/d' /etc/mihomo/config.yaml
sed -i '/^socks-port:/d' /etc/mihomo/config.yaml
sed -i '/^mixed-port:/d' /etc/mihomo/config.yaml
sed -i '/^external-controller:/d' /etc/mihomo/config.yaml
sed -i '/^external-ui:/d' /etc/mihomo/config.yaml
sed -i '/^secret:/d' /etc/mihomo/config.yaml

# 注入我们的重写桥接配置
cat <<EOF >> /etc/mihomo/config.yaml

# --- 自定义出站重定向配置 (Sing-box 桥接) ---
mixed-port: ${MIHOMO_PORT}
external-controller: 0.0.0.0:${YACD_PORT}
secret: "${MIHOMO_SECRET}"
external-ui: yacd
# --- 自定义配置结束 ---
EOF

log_info "Mihomo 配置文件处理完毕。"

# 6. 下载并安装本地版 yacd 控制面板
log_info "正在下载本地 yacd (Meta 专版) 控制面板..."
wget -qO /etc/mihomo/yacd.zip https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip
if [[ ! -f "/etc/mihomo/yacd.zip" ]]; then
    log_warn "下载 yacd 面板失败，您可以稍后手动下载部署，或直接使用在线版：https://yacd.metacubex.one"
else
    unzip -qo /etc/mihomo/yacd.zip -d /etc/mihomo/
    rm -rf /etc/mihomo/yacd
    mv /etc/mihomo/Yacd-meta-gh-pages /etc/mihomo/yacd
    rm -f /etc/mihomo/yacd.zip
    log_info "本地版 yacd 网页控制面板部署成功。"
fi

# 7. 创建 systemd 服务
log_info "正在创建 systemd 服务守护..."
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
systemctl enable mihomo
systemctl restart mihomo

# 8. 创建自动更新订阅脚本与定时任务
log_info "正在创建定时更新订阅脚本..."
cat > /etc/mihomo/update_sub.sh <<EOF
#!/bin/bash
# Mihomo 订阅自动更新脚本

export LANG=en_US.UTF-8

# 下载新订阅
curl -L -o /etc/mihomo/config.yaml.tmp "${SUB_URL}"
if [[ -f /etc/mihomo/config.yaml.tmp && -s /etc/mihomo/config.yaml.tmp ]]; then
    # Base64 解码检查
    if ! grep -q "proxies:" /etc/mihomo/config.yaml.tmp && ! grep -q "port:" /etc/mihomo/config.yaml.tmp; then
        base64 -d /etc/mihomo/config.yaml.tmp > /etc/mihomo/config_decoded.yaml.tmp 2>/dev/null
        if [[ -f /etc/mihomo/config_decoded.yaml.tmp && -s /etc/mihomo/config_decoded.yaml.tmp ]]; then
            mv /etc/mihomo/config_decoded.yaml.tmp /etc/mihomo/config.yaml.tmp
        fi
    fi
    # 清除冲突项
    sed -i '/^port:/d' /etc/mihomo/config.yaml.tmp
    sed -i '/^socks-port:/d' /etc/mihomo/config.yaml.tmp
    sed -i '/^mixed-port:/d' /etc/mihomo/config.yaml.tmp
    sed -i '/^external-controller:/d' /etc/mihomo/config.yaml.tmp
    sed -i '/^external-ui:/d' /etc/mihomo/config.yaml.tmp
    sed -i '/^secret:/d' /etc/mihomo/config.yaml.tmp
    
    # 注入出站重定向
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
    echo "\$(date): 订阅更新完成并已重启 Mihomo 服务。" >> /etc/mihomo/update.log
else
    echo "\$(date): 更新失败，下载配置为空或失败。" >> /etc/mihomo/update.log
fi
EOF

chmod +x /etc/mihomo/update_sub.sh

# 加入定时任务 (每天凌晨 3:00 自动更新)
if ! crontab -l 2>/dev/null | grep -q "/etc/mihomo/update_sub.sh"; then
    (crontab -l 2>/dev/null; echo "0 3 * * * /bin/bash /etc/mihomo/update_sub.sh >/dev/null 2>&1") | crontab -
    log_info "自动更新订阅定时任务已添加 (每天凌晨 3 点运行)。"
fi

# 输出完成信息
IPV4=$(curl -s4m5 icanhazip.com || curl -s4m5 api.ipify.org)
IPV6=$(curl -s6m5 icanhazip.com || curl -s6m5 api6.ipify.org)
IP=${IPV4:-$IPV6}

echo ""
echo "=================================================="
echo "      Mihomo (Clash Meta) 部署安装成功"
echo "=================================================="
echo "1. 本地监听的 Socks5 端口: ${MIHOMO_PORT} (用于对接 Sing-box 出站)"
echo "2. yacd 外部控制面板地址: http://${IP}:${YACD_PORT}/ui"
echo "3. yacd 面板安全密钥/密码: ${MIHOMO_SECRET}"
echo ""
echo "💡 使用说明："
echo "在浏览器打开上述 yacd 地址，输入 Host (您的公网IP)、Port (${YACD_PORT}) 和 Secret (${MIHOMO_SECRET}) 即可进行分流节点切换与网络监控。"
echo "=================================================="
echo ""
