#!/bin/bash

# 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "错误：必须以 root 权限运行此脚本！"
   exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
PLAIN='\033[0m'

log_info() { echo -e "${GREEN}[信息] $1${PLAIN}"; }
log_err() { echo -e "${RED}[错误] $1${PLAIN}"; }

log_info "正在开始卸载 Sing-box 多协议环境..."

# 1. 停止并禁用相关服务
log_info "正在停止 systemd 服务..."
systemctl stop sing-box mihomo clash argo-tunnel 2>/dev/null
systemctl disable sing-box mihomo clash argo-tunnel 2>/dev/null

if [[ -f /root/clash-for-linux-install/uninstall.sh ]]; then
    log_info "正在卸载 Mihomo (clashctl)..."
    bash /root/clash-for-linux-install/uninstall.sh >/dev/null 2>&1
fi

# 2. 清理 systemd 服务文件
log_info "正在清理服务定义文件..."
rm -f /etc/systemd/system/sing-box.service
rm -f /etc/systemd/system/mihomo.service
rm -f /etc/systemd/system/clash.service
rm -f /etc/systemd/system/argo-tunnel.service
systemctl daemon-reload

# 3. 清理 Nginx 反代配置
log_info "正在清理 Nginx 配置..."
rm -f /etc/nginx/conf.d/singbox-argo.conf
systemctl restart nginx 2>/dev/null

# 4. 删除二进制文件和数据目录
log_info "正在删除安装目录及二进制程序..."
rm -rf /etc/s-box
rm -rf /etc/mihomo
rm -f /usr/local/bin/cloudflared
rm -f /usr/local/bin/sb
rm -f /usr/local/bin/mihomo
rm -rf /root/clashctl
rm -rf /root/clash-for-linux-install

log_info "卸载完成！"
