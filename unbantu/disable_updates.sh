#!/bin/bash

# 检查是否安装了 sudo
if ! command -v sudo &> /dev/null; then
    echo "sudo 命令未安装，请安装 sudo 后再运行此脚本。"
    exit 1
fi

# 修改配置文件
echo "修改配置文件..."
sudo sed -i.bak 's/1/0/' /etc/apt/apt.conf.d/10periodic
sudo sed -i.bak 's/1/0/' /etc/apt/apt.conf.d/20auto-upgrades

# 选择 No
# echo "重新配置 unattended-upgrades..."
# sudo dpkg-reconfigure unattended-upgrades

# 禁用 unattended-upgrades 服务
echo "禁用 unattended-upgrades 服务..."
sudo systemctl stop unattended-upgrades
sudo systemctl disable unattended-upgrades

# 可选：移除 unattended-upgrades
# echo "移除 unattended-upgrades..."
# sudo apt remove unattended-upgrades

# 清空 apt 缓存
echo "清空 apt 缓存..."
sudo apt autoremove # 移除不在使用的软件包
sudo apt clean && sudo apt autoclean # 清理下载文件的存档
sudo rm -rf /var/cache/apt
sudo rm -rf /var/lib/apt/lists
sudo rm -rf /var/lib/apt/periodic

# 插入更新信息
echo "插入更新信息..."
sudo sed -i '2i 0 updates can be installed immediately.' /var/lib/update-notifier/updates-available
sudo sed -i '3i 0 of these updates are security updates.' /var/lib/update-notifier/updates-available

# 禁用内核更新
echo "禁用内核更新..."
sudo apt-mark hold linux-generic linux-image-generic linux-headers-generic

echo "脚本执行完成。"
