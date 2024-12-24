#!/bin/bash

# 定义颜色变量
red="\033[0;31m"
green="\033[0;32m"
plain="\033[0m"

# 脚本版本
sh_ver="1.3"

# 初始化环境目录
init_env() {
    mkdir -p /root/realm
    mkdir -p /root/.realm
}

# 配置文件路径
CONFIG_PATH="/root/.realm/config.toml"

# 处理命令行参数
while getopts "l:r:" opt; do
  case $opt in
    l)
      listen_ip_port="$OPTARG"
      ;;
    r)
      remote_ip_port="$OPTARG"
      ;;
    *)
      echo "Usage: $0 [-l listen_ip:port] [-r remote_ip:port]"
      exit 1
      ;;
  esac
done

# 如果提供了 -l 和 -r 参数，追加配置到 config.toml
if [ -n "$listen_ip_port" ] && [ -n "$remote_ip_port" ]; then
    echo "配置中转机 IP 和端口为: $listen_ip_port"
    echo "配置落地机 IP 和端口为: $remote_ip_port"

    cat <<EOF >> "$CONFIG_PATH"

[[endpoints]]
listen = "$listen_ip_port"
remote = "$remote_ip_port"
EOF
    echo "配置已追加，listen = $listen_ip_port，remote = $remote_ip_port"
    exit 0
fi



# 更新realm状态
update_realm_status() {
    if [ -f "/root/realm/realm" ]; then
        realm_status="已安装"
        realm_status_color=$green
    else
        realm_status="未安装"
        realm_status_color=$red
    fi
}

# 检查realm服务状态
check_realm_service_status() {
    if systemctl is-active --quiet realm; then
        echo -e "${green}启用${plain}"
    else
        echo -e "${red}未启用${plain}"
    fi
}

# 更新脚本
Update_Shell() {
    echo -e "当前脚本版本为 [ ${sh_ver} ]，开始检测最新版本..."

    # 获取最新版本号
    sh_new_ver=$(wget --no-check-certificate -qO- "https://raw.githubusercontent.com/wcwq98/realm/main/realm.sh" | grep 'sh_ver="' | awk -F "=" '{print $NF}' | sed 's/\"//g' | head -1)
    if [[ -z ${sh_new_ver} ]]; then
        echo -e "${red}检测最新版本失败！请检查网络或稍后再试。${plain}"
        return 1
    fi

    if [[ ${sh_new_ver} == ${sh_ver} ]]; then
        echo -e "当前已是最新版本 [ ${sh_new_ver} ]！"
        return 0
    fi

    # 提示用户是否更新
    echo -e "发现新版本 [ ${sh_new_ver} ]，是否更新？[Y/n]"
    read -p "(默认: y): " yn
    yn=${yn:-y} # 默认值为 'y'
    if [[ ${yn} =~ ^[Yy]$ ]]; then
        # 下载最新脚本
        wget -N --no-check-certificate https://raw.githubusercontent.com/wcwq98/realm/main/realm.sh -O realm.sh
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载脚本失败，请检查网络连接！${plain}"
            return 1
        fi

        chmod +x realm.sh
        echo -e "脚本已更新为最新版本 [ ${sh_new_ver} ]！"

        # 自动重启更新后的脚本
        echo "正在重新启动脚本..."
        exec bash realm.sh
    else
        echo -e "已取消更新。"
    fi
}


# 初始化realm状态
update_realm_status() {
    if [ -f "/root/realm/realm" ]; then
        realm_status="已安装"
        realm_status_color=$green
    else
        realm_status="未安装"
        realm_status_color=$red
    fi
}

# 检查realm服务状态
check_realm_service_status() {
    if systemctl is-active --quiet realm; then
        echo -e "${green}启用${plain}"
    else
        echo -e "${red}未启用${plain}"
    fi
}

# 显示菜单的函数
show_menu() {
    clear
    echo "欢迎使用realm一键转发脚本"
    echo "================="
    echo "1. 部署环境"
    echo "2. 添加转发"
    echo "3. 添加端口段转发"
    echo "4. 删除转发"
    echo "5. 启动服务"
    echo "6. 停止服务"
    echo "7. 重启服务"
    echo "8. 检测更新"
    echo "9. 一键卸载"
    echo "10. 更新脚本"
    echo "0. 退出脚本"
    echo "================="
    echo -e "realm 状态：${realm_status_color}${realm_status}${plain}"
    echo -n "realm 转发状态："
    check_realm_service_status
}

# 部署环境的函数
deploy_realm() {
    mkdir -p /root/realm
    cd /root/realm

    _version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    if [ -z "$_version" ]; then
        echo "获取版本号失败，请检查本机能否链接 https://api.github.com/repos/zhboner/realm/releases/latest"
        return 1
    else
        echo "当前最新版本为: ${_version}"
    fi

    arch=$(uname -m)
    os=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$arch-$os" in
        x86_64-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-x86_64-unknown-linux-gnu.tar.gz"
            ;;
        x86_64-darwin)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-x86_64-apple-darwin.tar.gz"
            ;;
        aarch64-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-aarch64-unknown-linux-gnu.tar.gz"
            ;;
        aarch64-darwin)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-aarch64-apple-darwin.tar.gz"
            ;;
        arm-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-arm-unknown-linux-gnueabi.tar.gz"
            ;;
        armv7-linux)
            download_url="https://github.com/zhboner/realm/releases/download/${_version}/realm-armv7-unknown-linux-gnueabi.tar.gz"
            ;;
        *)
            echo "不支持的架构: $arch-$os"
            return
            ;;
    esac

    wget -O "/root/realm/realm-${_version}.tar.gz" "$download_url"
    tar -xvf "/root/realm/realm-${_version}.tar.gz" -C /root/realm/
    chmod +x /root/realm/realm

# 创建 config.toml 模板
    mkdir -p /root/.realm    
    cat <<EOF > "$CONFIG_PATH"


[network]
no_tcp = false #是否关闭tcp转发
use_udp = true #是否开启udp转发

#参考模板
# [[endpoints]]
# listen = "0.0.0.0:本地端口"
# remote = "落地鸡ip:目标端口"

[[endpoints]]
listen = "0.0.0.0:1234"
remote = "0.0.0.0:5678"

EOF

    echo "[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
DynamicUser=true
WorkingDirectory=/root/realm
ExecStart=/root/realm/realm -c /root/.realm/config.toml

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/realm.service

    systemctl daemon-reload
    update_realm_status
    echo "部署完成。"
}

# 卸载realm
uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload

    rm -f /root/realm/realm
    echo "realm已被卸载。"

    read -e -p "是否删除配置文件 (Y/N, 默认N): " delete_config
    delete_config=${delete_config:-N}

    if [[ $delete_config == "Y" || $delete_config == "y" ]]; then
        rm -rf /root/realm
        echo "配置文件已删除。"
    else
        echo "配置文件保留。"
    fi

    update_realm_status
}

# 删除转发规则的函数
delete_forward() {
    echo "当前转发规则："
    local IFS=$'\n'
    local lines=($(grep -n 'remote =' /root/realm/config.toml))
    if [ ${#lines[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi
    local index=1
    for line in "${lines[@]}"; do
        echo "${index}. $(echo $line | cut -d '"' -f 2)"
        let index+=1
    done

    echo "请输入要删除的转发规则序号，直接按回车返回主菜单。"
    read -p "选择: " choice
    if [ -z "$choice" ]; then
        echo "返回主菜单。"
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]]; then
        echo "无效输入，请输入数字。"
        return
    fi

    if [ $choice -lt 1 ] || [ $choice -gt ${#lines[@]} ]; then
        echo "选择超出范围，请输入有效序号。"
        return
    fi

    local chosen_line=${lines[$((choice-1))]}
    local line_number=$(echo $chosen_line | cut -d ':' -f 1)

    local start_line=$line_number
    local end_line=$(($line_number + 2))

    sed -i "${start_line},${end_line}d" /root/realm/config.toml

    echo "转发规则已删除。"
}

# 添加转发规则
add_forward() {
    while true; do
        read -e -p "请输入落地鸡的IP: " ip
        read -e -p "请输入本地中转鸡的端口（port1）: " port1
        read -e -p "请输入落地鸡端口（port2）: " port2
        echo "[[endpoints]]
listen = \"0.0.0.0:$port1\"
remote = \"$ip:$port2\"" >> /root/realm/config.toml

        read -e -p "是否继续添加转发规则(Y/N)? " answer
        if [[ $answer != "Y" && $answer != "y" ]]; then
            break
        fi
    done
}

# 添加端口段转发
add_port_range_forward() {
    read -e -p "请输入落地鸡的IP: " ip
    read -e -p "请输入本地中转鸡的起始端口: " start_port
    read -e -p "请输入本地中转鸡的截止端口: " end_port
    read -e -p "请输入落地鸡端口: " remote_port

    for ((port=$start_port; port<=$end_port; port++)); do
        echo "[[endpoints]]
listen = \"0.0.0.0:$port\"
remote = \"$ip:$remote_port\"" >> /root/realm/config.toml
    done

    echo "端口段转发规则已添加。"
}

# 启动服务
start_service() {
    systemctl unmask realm.service
    systemctl daemon-reload
    systemctl restart realm.service
    systemctl enable realm.service
    echo "realm服务已启动并设置为开机自启。"
    update_realm_status

    # 检查服务状态
    if ! systemctl is-active --quiet realm; then
        echo "请检查是否存在config.toml或config.toml配置是否正确"
    fi
}
# 停止服务
stop_service() {
    systemctl stop realm
    echo "realm服务已停止。"
    update_realm_status
}

# 重启服务
restart_service() {
    systemctl restart realm
    echo "realm服务已重启。"
    update_realm_status

    # 检查服务状态
    if ! systemctl is-active --quiet realm; then
        echo "请检查是否存在config.toml或config.toml配置是否正确"
    fi
}

# 更新realm
update_realm() {
    echo "> 检测并更新 realm"

    current_version=$(/root/realm/realm --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    tag_version=$(curl -Ls "https://api.github.com/repos/zhboner/realm/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    if [[ -z "$tag_version" ]]; then
        echo -e "${red}获取 realm 版本失败，可能是由于 GitHub API 限制，请稍后再试${plain}"
        exit 1
    fi

    if [[ "$current_version" == "$tag_version" ]]; then
        echo "当前已经是最新版本: ${current_version}"
        return
    fi

    echo -e "获取到 realm 最新版本: ${tag_version}，开始安装..."

    arch=$(uname -m)
    wget -N --no-check-certificate -O /root/realm/realm.tar.gz "https://github.com/zhboner/realm/releases/download/${tag_version}/realm-${arch}-unknown-linux-gnu.tar.gz"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下载 realm 失败，请确保您的服务器可以访问 GitHub${plain}"
        exit 1
    fi

    cd /root/realm
    tar -xvf realm.tar.gz
    chmod +x realm

    echo -e "realm 更新成功。"
    update_realm_status
}

# 初始化realm状态
update_realm_status

# 主循环
while true; do
    show_menu
    read -p "请选择一个选项: " choice
    case $choice in
        1) deploy_realm ;;
        2) add_forward ;;
        3) add_port_range_forward ;;
        4) delete_forward ;;
        5) start_service ;;
        6) stop_service ;;
        7) restart_service ;;
        8) update_realm ;;
        9) uninstall_realm ;;
        10) Update_Shell ;;
        0) echo "退出脚本。"; exit 0 ;;
        *) echo "无效选项: $choice" ;;
    esac
    read -p "按任意键继续..." key
done
