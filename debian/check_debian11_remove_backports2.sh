#!/bin/bash

# 检查是否为 Debian 11 系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "debian" ] && [ "$VERSION_ID" = "11" ]; then
        echo "系统为 Debian 11，开始处理 backports.list..."

        FILE="/etc/apt/sources.list.d/backports.list"

        # 创建空文件（不存在则创建，存在则清空）
        echo -n > "$FILE"

        # 设置为不可修改
        chattr +i "$FILE"

        echo "已创建并锁定 $FILE（chattr +i）"
    else
        echo "当前系统不是 Debian 11，无需处理。"
    fi
else
    echo "无法检测系统版本：缺少 /etc/os-release"
fi
