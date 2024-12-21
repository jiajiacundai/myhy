#!/bin/bash
#彩色
red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}
green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}
yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}
blue(){
    echo -e "\033[34m\033[01m$1\033[0m"
}


#获取本机IP
function getip(){
    lan=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(.\d+){3}')
    wan=$(curl -s https://myip.ipip.net/)
    date=$(date "+%Y-%m-%d %H:%M:%S")
    red "内网IP：$lan\n外网IP：$wan\n当前时间：$date"
}
#宝塔面板综合安装脚本
function bt(){

    # 更新软件包列表
    sudo apt update

    # 安装更新
    sudo apt upgrade -y
    # 安装宝塔
    wget -O install.sh https://download.bt.cn/install/install-ubuntu_6.0.sh && bash install.sh ed8484bec
    
}
#安装1Panel
function 1panel(){

    # 更新软件包列表
    sudo apt update

    # 安装更新
    sudo apt upgrade -y
    # 安装1Panel
    curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh && bash quick_start.sh
    
}
#安装CasaOS
function casaos(){

    # 更新软件包列表
    sudo apt update

    # 安装更新
    sudo apt upgrade -y
    # 安装CasaOS
    curl -fsSL https://get.casaos.io | sudo bash
    
}
#挂载TF卡
function tfcard(){
    if grep -qs "/dev/mmcblk" /etc/fstab; then
        red "TF卡已经挂载，跳过挂载步骤。"
    else
        blue "TF卡未挂载，执行挂载操作。"
        # 挂载 TF 卡的选择提示
        
        # 创建 TF 卡挂载目录
        sudo mkdir -p /mnt/tfcard
    
        # 挂载 mmcblk0p1 设备到 /mnt/tfcard
        sudo mount /dev/mmcblk0p1 /mnt/tfcard
    
        # 将挂载信息添加到 /etc/fstab
        echo "/dev/mmcblk0p1  /mnt/tfcard  auto  defaults  0  0" | sudo tee -a /etc/fstab
    
        # 重新加载挂载
        sudo mount -a
    
        red "已挂载TF卡到 /mnt/tfcard"
    fi
}
#切换中文
function chinese(){
    # 修改时区为东八区上海
    sudo timedatectl set-timezone Asia/Shanghai
    if [[ $(locale | grep LANG | cut -d= -f2) != "zh_CN.UTF-8" ]]; then
        # 修改系统语言为中文
        sudo sed -i 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/g' /etc/locale.gen
        sudo locale-gen zh_CN.UTF-8
        sudo update-locale LANG=zh_CN.UTF-8 LC_ALL=

        # 安装必要的软件包
        sudo apt install apt-transport-https ca-certificates

        red "已更换为中文环境，即将重启，请稍后重新连接后再次执行代码。"
        sudo reboot
        exit
    fi
}
#更换 Armbian 的源为国内源
function change_source(){
    sudo sed -i.bak 's#apt.armbian.com#mirrors.tuna.tsinghua.edu.cn/armbian#g' /etc/apt/sources.list.d/armbian.list
    sudo sed -i.bak 's#security.debian.org#mirrors.ustc.edu.cn/debian-security#g' /etc/apt/sources.list
    sudo sed -i.bak 's#deb.debian.org#mirrors.ustc.edu.cn#g' /etc/apt/sources.list
    sudo sed -i.bak 's#ports.ubuntu.com#mirrors.tuna.tsinghua.edu.cn/ubuntu-ports#g' /etc/apt/sources.list
    red "已更换源为国内源，即将进行更新检查。"
    # 更新软件包列表
    sudo apt update

    # 安装更新
    sudo apt upgrade -y
}
#宝塔面板 自动磁盘挂载工具
function btdisk(){
    wget -O auto_disk.sh http://download.bt.cn/tools/auto_disk.sh && bash auto_disk.sh
}
#主菜单
function start_menu(){
    clear
    if [ $(whoami) != "root" ];then
        echo "请使用root权限执行脚本命令！"
        exit 1;
    fi
    red " RuPu.Net Armbian 初始化脚本 "
    echo " "
    green  "██████╗  ██╗   ██╗ ██████╗  ██╗   ██╗     ███╗   ██╗ ███████╗ ████████╗"
    green  "██╔══██╗ ██║   ██║ ██╔══██╗ ██║   ██║     ████╗  ██║ ██╔════╝ ╚══██╔══╝"
    green  "██████╔╝ ██║   ██║ ██████╔╝ ██║   ██║     ██╔██╗ ██║ █████╗      ██║   "
    green  "██╔══██╗ ██║   ██║ ██╔═══╝  ██║   ██║     ██║╚██╗██║ ██╔══╝      ██║   "
    green  "██║  ██║ ╚██████╔╝ ██║      ╚██████╔╝ ██╗ ██║ ╚████║ ███████╗    ██║   "
    green  "╚═╝  ╚═╝  ╚═════╝  ╚═╝       ╚═════╝  ╚═╝ ╚═╝  ╚═══╝ ╚══════╝    ╚═╝   "
    echo " "
    green " https://rupu.net"
    echo " "
    blue "当前时间：$(date)"
    blue "当前系统：$(uname -srmo)"
    echo " "
    yellow " =================================================="
    green " 1. 切换为中文环境" 
    green " 2. 挂载 TF卡"
    green " 3. 切换为国内镜像源"
    green " 4. 获取本机IP"
    green " 5. 宝塔面板 自动磁盘挂载工具"
    green " 6. 安装 宝塔面板"
    green " 7. 安装 1Panel面板"
    green " 8. 安装 CasaOS面板"
    yellow " =================================================="
    green " 0. 退出脚本"
    echo
    read -p "请输入数字:" menuNumberInput
    case "$menuNumberInput" in
        1 )
           chinese
	        ;;
        2 )
           tfcard
	        ;;
        3 )
           change_source
	        ;;
        4 )
           getip
	        ;;
        5 )
           btdisk
	        ;;
        6 )
            bt
            ;;
        7 )
            1panel
            ;;
        8 )
            casaos
            ;;
        0 )
            exit 1
        ;;
        * )
            clear
            red "请输入正确数字 !"
            start_menu
        ;;
    esac
}
start_menu "first"
