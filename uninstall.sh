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

# 自动检测是否为 OpenRC (Alpine 等)
IS_OPENRC=false
if [[ -x "/sbin/openrc-run" || -x "/sbin/runlevels" ]]; then
    IS_OPENRC=true
fi

# Nginx 配置目录自适应
NGINX_CONF_DIR="/etc/nginx/conf.d"
[[ -d "/etc/nginx/http.d" ]] && NGINX_CONF_DIR="/etc/nginx/http.d"

# 服务控制函数
service_stop() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" stop >/dev/null 2>&1
    else
        systemctl stop "$name" >/dev/null 2>&1
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

service_restart() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" restart >/dev/null 2>&1
    else
        systemctl restart "$name" >/dev/null 2>&1
    fi
}

log_info "正在开始卸载 Sing-box 多协议环境..."

# 1. 停止并禁用相关服务
log_info "正在停止系统服务..."
service_stop sing-box
service_stop argo-tunnel
service_disable sing-box
service_disable argo-tunnel

# 2. 清理服务定义文件
log_info "正在清理服务定义文件..."
if $IS_OPENRC; then
    rm -f /etc/init.d/sing-box /etc/init.d/argo-tunnel
else
    rm -f /etc/systemd/system/sing-box.service
    rm -f /etc/systemd/system/argo-tunnel.service
    systemctl daemon-reload
fi

# 3. 清理 Nginx 反代配置
log_info "正在清理 Nginx 配置..."
rm -f ${NGINX_CONF_DIR}/singbox-argo.conf
service_restart nginx

# 4. 删除二进制文件和数据目录
log_info "正在删除安装目录及二进制程序..."
rm -rf /etc/s-box
rm -f /usr/local/bin/cloudflared
rm -f /usr/local/bin/sb

# 5. 清理 cron 守护任务
log_info "正在清理定时守护任务..."
if crontab -l 2>/dev/null | grep -q "sb cron"; then
    crontab -l | grep -v "sb cron" | crontab -
fi

log_info "卸载完成！"
