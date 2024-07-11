#!/bin/bash

# 更新软件包列表并升级所有已安装的软件包
sudo apt update -y && sudo apt upgrade -y

# 进行发行版本升级
sudo apt dist-upgrade -y

# 备份现有的 sources.list 文件
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak

# 使用新的源列表替换原有的 sources.list 文件
sudo tee /etc/apt/sources.list << EOF
# deb cdrom:[Debian GNU/Linux 11.0.0 _Bullseye_ - Official amd64 NETINST 20210814-10:07]/ bullseye main

#deb cdrom:[Debian GNU/Linux 11.0.0 _Bullseye_ - Official amd64 NETINST 20210814-10:07]/ bullseye main

deb http://deb.debian.org/debian/ bullseye main
deb-src http://deb.debian.org/debian/ bullseye main

deb http://security.debian.org/debian-security bullseye-security main
deb-src http://security.debian.org/debian-security bullseye-security main

# bullseye-updates, to get updates before a point release is made;
# see https://www.debian.org/doc/manuals/debian-reference/ch02.en.html#_updates_and_backports
deb http://deb.debian.org/debian/ bullseye-updates main
deb-src http://deb.debian.org/debian/ bullseye-updates main

# This system was installed using small removable media
# (e.g. netinst, live or single CD). The matching "deb cdrom"
# entries were disabled at the end of the installation process.
# For information about how to configure apt package sources,
# see the sources.list(5) manual.
EOF

# 更新软件包列表
sudo apt update

# 执行完全升级
sudo apt full-upgrade -y

# 再次更新软件包列表
sudo apt update

# 安装特定版本的内核
sudo apt install linux-image-cloud-amd64 -y

# 更新 GRUB 配置文件
sudo update-grub

# 查找并卸载 4.19 版本的内核
echo "# 查看已安装的内核"
dpkg --get-selections | grep linux
echo "# 开始卸载内核，注：完全卸载4.1内核选NO"
for kernel in $(dpkg --get-selections | grep -E 'linux-image-4\.19\..*-cloud-amd64' | awk '{print $1}'); do
    echo "卸载内核: $kernel"
    sudo apt remove --purge -y $kernel
done

# 卸载 linux-image-cloud-amd64 内核
echo "卸载内核: linux-image-cloud-amd64"
sudo apt remove --purge -y linux-image-cloud-amd64

# 更新 GRUB 配置文件
sudo update-grub

# 提示用户需要重启系统以使用新的内核
echo "内核已更新，请重启系统以使用新的内核版本。"

# 删除脚本
rm -f debain_up10_11.sh

# 卸载并删除python2
curl -s https://raw.githubusercontent.com/jiajiacundai/myhy/main/debian/remove_python2.sh | bash

if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "Installed Debian version: $VERSION"
else
    echo "Could not determine Debian version."
fi

# 添加swap
curl -s https://raw.githubusercontent.com/jiajiacundai/myhy/main/debian/addswap.sh | bash -s -- --add

# 清理独立包
# 更新包列表并安装 aptitude
echo "Updating package list and installing aptitude..."
sudo apt install -y aptitude

# 查找系统中的孤立包
echo "Searching for orphaned packages..."
orphaned_packages=$(sudo aptitude search '~o')

if [ -z "$orphaned_packages" ]; then
    echo "No orphaned packages found."
else
    echo "Orphaned packages found:"
    echo "$orphaned_packages"
    
    # 清理系统中的孤立包
    echo "Purging orphaned packages..."
    sudo aptitude purge -y '~o'
    echo "Orphaned packages have been purged."
fi

# 删除swap
curl -s https://raw.githubusercontent.com/jiajiacundai/myhy/main/debian/addswap.sh | bash -s -- --remove
rm -f addswap.sh

# 提示
echo "# 查看已安装的内核"
echo "dpkg --get-selections | grep linux"
echo "# 找到除了5.10.xxxx-cloud-amd64以外的所有内核，用如下命令卸载："
echo "apt autoremove --purge linux-image-4.19.0-5-amd64"
echo "apt autoremove"
echo "apt autoclean"

# 重启
reboot
