#!/bin/bash
# -----------------------------------------------------------
# 脚本功能：自动检测物理网卡，获取公网 IPv4/IPv6 地址及网关，
#         生成对应的网络配置并写入 Debian/Ubuntu 系统的网络配置文件，
#         其他系统则输出推荐的配置供手动调整
# -----------------------------------------------------------

# 获取所有网卡并剔除虚拟网卡（只保留第一个物理网卡）
network_interface=$(ls /sys/class/net/ | grep -v "$(ls /sys/devices/virtual/net/)" | head -n 1)
if [ -z "$network_interface" ]; then
    echo "未找到有效的物理网卡"
    exit 1
fi
echo "检测到的网卡：$network_interface"

# ----------------------------
# 获取 IPv4 信息
# ----------------------------

# 获取公网 IPv4 地址（过滤内网及回环地址，不带子网掩码）
ipv4_address=$(ip -4 addr show "$network_interface" | \
    grep -oP '(?<=inet\s)\d+(\.\d+){3}' | \
    grep -vE '^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^127\.')

# 获取 IPv4 网关
ipv4_gateway=$(ip -4 route | grep default | grep "$network_interface" | awk '{print $3}')

# 获取 IPv4 子网掩码（CIDR格式）
ipv4_cidr=$(ip -4 addr show "$network_interface" | \
    grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n 1 | cut -d'/' -f2)

# 将 CIDR 格式转换为标准子网掩码
if [ -n "$ipv4_cidr" ]; then
    ipv4_netmask=$(perl -e "printf '%d.%d.%d.%d', ((0xffffffff << (32 - $ipv4_cidr)) >> 24) & 0xff, ((0xffffffff << (32 - $ipv4_cidr)) >> 16) & 0xff, ((0xffffffff << (32 - $ipv4_cidr)) >> 8) & 0xff, (0xffffffff << (32 - $ipv4_cidr)) & 0xff")
fi

# ----------------------------
# 获取 IPv6 信息
# ----------------------------

# 获取带子网掩码的 global IPv6 地址
ipv6_with_prefix=$(ip -6 addr show "$network_interface" | grep global | awk '{print $2}' | head -n 1)
# 获取 IPv6 网关
ipv6_gateway=$(ip -6 route | grep default | grep "$network_interface" | awk '{print $3}')

if [ -n "$ipv6_with_prefix" ]; then
    ipv6_address=$(echo "$ipv6_with_prefix" | cut -d'/' -f1)
    ipv6_prefix=$(echo "$ipv6_with_prefix" | cut -d'/' -f2)

    # 检查 IPv6 是否为公网地址（排除链路本地、ULA、本地回环等）
    if echo "$ipv6_address" | grep -qiE '^fe80:|^fc|^fd|^::1$|^::$'; then
        echo "检测到的 IPv6 地址不是公网地址：$ipv6_address"
        exit 1
    fi
else
    echo "未检测到 IPv6 地址"
    exit 1
fi

# ----------------------------
# 输出检测结果
# ----------------------------

if [ -n "$ipv4_address" ]; then
    echo "公网 IPv4 地址：$ipv4_address"
    if [ -n "$ipv4_gateway" ]; then
        echo "IPv4 网关：$ipv4_gateway"
    else
        echo "未检测到 IPv4 网关"
    fi
else
    echo "未检测到公网 IPv4 地址"
fi

echo "公网 IPv6 地址：$ipv6_address/$ipv6_prefix"
if [ -n "$ipv6_gateway" ]; then
    echo "IPv6 网关：$ipv6_gateway"
else
    echo "未检测到 IPv6 网关"
fi

# ----------------------------
# 检测系统类型：Debian/Ubuntu
# ----------------------------

is_debian_ubuntu=false
if [ -f /etc/debian_version ] || grep -qi 'ubuntu\|debian' /etc/os-release; then
    is_debian_ubuntu=true
fi

# ----------------------------
# 生成网络配置内容
# ----------------------------

config="auto lo
iface lo inet loopback
"

# 添加 IPv4 配置（仅当所有信息齐全时）
if [ -n "$ipv4_address" ] && [ -n "$ipv4_netmask" ] && [ -n "$ipv4_gateway" ]; then
    config+="
auto $network_interface
iface $network_interface inet static
    address $ipv4_address
    netmask $ipv4_netmask
    gateway $ipv4_gateway
    dns-nameservers 8.8.8.8 8.8.4.4
"
fi

# 添加 IPv6 配置（仅当所有信息齐全时）
if [ -n "$ipv6_address" ] && [ -n "$ipv6_prefix" ] && [ -n "$ipv6_gateway" ]; then
    config+="
auto $network_interface
iface $network_interface inet6 static
    address $ipv6_address
    netmask $ipv6_prefix
    gateway $ipv6_gateway
    dns-nameservers 2001:4860:4860::8888 2001:4860:4860::8844
"
fi

# ----------------------------
# 写入或输出配置
# ----------------------------

if [ "$is_debian_ubuntu" = true ]; then
    echo "检测到 Debian/Ubuntu 系统，准备写入配置到 /etc/network/interfaces"
    echo "将要写入的配置内容:"
    echo "======================================"
    echo "$config"
    echo "======================================"

    # 创建配置文件备份
    cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%Y%m%d%H%M%S)

    # 写入新配置
    echo "$config" > /etc/network/interfaces
    echo "配置已写入 /etc/network/interfaces"
    echo "请执行: sudo systemctl restart networking 来重启网络服务以应用新配置"
else
    echo "非 Debian/Ubuntu 系统，请手动配置网络。以下是推荐的网络配置:"
    echo "======================================"
    echo "$config"
    echo "======================================"
    if [ -f /etc/redhat-release ]; then
        echo "CentOS/RHEL 系统需要将上述配置转换后写入 /etc/sysconfig/network-scripts/ifcfg-$network_interface"
    else
        echo "请根据您的系统类型，将上述配置转换为相应格式并写入对应的配置文件"
    fi
fi
