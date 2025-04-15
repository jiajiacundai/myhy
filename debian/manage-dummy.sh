#!/bin/bash

# 定义自动生成IPv6地址的函数
generate_ipv6() {
  # 使用固定前缀 fd00:1234:5678:9abc::，末尾随机1-254
  local rand_num=$((RANDOM % 254 + 1))
  echo "fd00:1234:5678:9abc::${rand_num}/64"
}

# 定义自动生成网卡名称的函数
generate_netcard_name() {
  # 生成名称格式 dummyXXXX，其中 XXXX 是1000-9999之间的数字
  echo "dummy$(shuf -i 1000-9999 -n 1)"
}

echo "======================================"
echo " 虚拟网卡管理工具（systemd-networkd）"
echo "======================================"

# 第一步：选择操作（增加或删除），输入错误时重新输入
while true; do
  echo "请选择操作："
  echo " 1) 增加网卡"
  echo " 2) 删除网卡"
  read -p "请输入数字（1 或 2）: " ACTION
  if [[ "$ACTION" == "1" || "$ACTION" == "2" ]]; then
    break
  else
    echo "❌ 无效选项，请重新输入。"
  fi
done

# 第二步：选择网卡名称生成方式
while true; do
  echo "--------------------------------------"
  echo "请选择网卡名称方式："
  echo " 1) 自动生成网卡名称"
  echo " 2) 手动输入网卡名称"
  read -p "请输入数字（1 或 2）: " NAME_OPTION
  if [[ "$NAME_OPTION" == "1" || "$NAME_OPTION" == "2" ]]; then
    break
  else
    echo "❌ 无效选项，请重新输入。"
  fi
done

if [[ "$NAME_OPTION" == "1" ]]; then
  NETCARD=$(generate_netcard_name)
  echo "自动生成的网卡名称为：${NETCARD}"
elif [[ "$NAME_OPTION" == "2" ]]; then
  while true; do
    read -p "请输入网卡名称（例如 eth0 或 dummy0）： " NETCARD
    if [[ -n "$NETCARD" ]]; then
      break
    else
      echo "❌ 网卡名称不能为空，请重新输入。"
    fi
  done
fi

# 当选择增加网卡时，进一步选择IPv6地址配置方式
if [[ "$ACTION" == "1" ]]; then
  while true; do
    echo "--------------------------------------"
    echo "请选择IPv6地址配置方式："
    echo " 1) 自动生成内网IPv6地址 （格式: fd00:1234:5678:9abc::随机数/64）"
    echo " 2) 手动输入IPv6地址 （例如：2602:f92a:221:50::b/64）"
    read -p "请输入数字（1 或 2）: " IP_OPTION
    if [[ "$IP_OPTION" == "1" || "$IP_OPTION" == "2" ]]; then
      break
    else
      echo "❌ 无效选项，请重新输入。"
    fi
  done

  if [[ "$IP_OPTION" == "1" ]]; then
    IPV6_ADDR=$(generate_ipv6)
    echo "自动生成的IPv6地址为：${IPV6_ADDR}"
  elif [[ "$IP_OPTION" == "2" ]]; then
    while true; do
      read -p "请输入IPv6地址及子网掩码（例如：2602:f92a:221:50::b/64）： " IPV6_ADDR
      if [[ -n "$IPV6_ADDR" ]]; then
        break
      else
        echo "❌ IPv6地址不能为空，请重新输入。"
      fi
    done
  fi
fi

# 确保 systemd 网络配置目录存在
mkdir -p /etc/systemd/network

# 执行对应操作
if [[ "$ACTION" == "1" ]]; then
  echo "➕ 正在添加虚拟网卡 ${NETCARD} …"
  
  # 写入 netdev 配置文件
  cat <<EOF > /etc/systemd/network/10-${NETCARD}.netdev
[NetDev]
Name=${NETCARD}
Kind=dummy
EOF

  # 写入 network 配置文件
  cat <<EOF > /etc/systemd/network/10-${NETCARD}.network
[Match]
Name=${NETCARD}

[Network]
Address=${IPV6_ADDR}
EOF

  # 启用并重启 systemd-networkd 服务
  systemctl enable systemd-networkd
  systemctl restart systemd-networkd
  echo "✅ 已添加并启用网卡 ${NETCARD}，IPv6地址配置为：${IPV6_ADDR}"
  
elif [[ "$ACTION" == "2" ]]; then
  echo "🗑️ 正在删除网卡 ${NETCARD} 的配置 …"
  
  # 下架网卡（将网卡设置为 down）
  ip link set "$NETCARD" down 2>/dev/null
  
  # 删除配置文件
  rm -f /etc/systemd/network/10-${NETCARD}.netdev
  rm -f /etc/systemd/network/10-${NETCARD}.network

  systemctl restart systemd-networkd
  echo "🧹 已下架并删除网卡 ${NETCARD} 的配置"
fi
