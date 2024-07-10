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

# 提示用户需要重启系统以使用新的内核
echo "内核已更新，请重启系统以使用新的内核版本。"
