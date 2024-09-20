#!/bin/bash
# 修复sudo: 无法解析主机：ser384519863274: 未知的名称或服务

# 确保脚本以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# 获取当前主机名
current_hostname=$(hostname)

# 检查主机名是否已经在 /etc/hosts 文件中
if grep -q "$current_hostname" /etc/hosts; then
    echo "Hostname $current_hostname already exists in /etc/hosts. No changes needed."
    exit 0
fi

# 如果主机名不在 /etc/hosts 中，则进行更新
echo "Hostname $current_hostname not found in /etc/hosts. Updating configuration..."

# 更新 /etc/hosts 文件
sed -i "/127.0.1.1/c\127.0.1.1       $current_hostname.example.com $current_hostname" /etc/hosts

# 确保 /etc/hostname 文件包含正确的主机名
echo "$current_hostname" > /etc/hostname

# 立即应用新的主机名
hostnamectl set-hostname "$current_hostname"

# 重启网络服务以应用更改
systemctl restart networking

echo "Hostname configuration updated. Please reboot your system for changes to take full effect."
