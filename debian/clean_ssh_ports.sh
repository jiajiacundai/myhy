#!/bin/bash

# ------------------------------------------------------------------
# 脚本名称：clean_ssh_ports.sh
# 功能    ：检测 sshd 监听端口，删除除 22 端口外的配置文件，并重启 ssh 服务
# 注意    ：脚本中不使用 sudo，非 root 用户执行时会因为权限不足而报错
# 使用方法：直接运行 ./clean_ssh_ports.sh
# ------------------------------------------------------------------

# 1. 从 ss 输出中提取所有 sshd 正在监听的端口号
echo "正在检测 sshd 当前监听的端口……"
ports=$(ss -tlnp 2>&1 | grep sshd | \
        awk -F':' '{print $2}' | awk '{print $1}' | sort -n | uniq)

# 2. 筛选出除 22 以外的端口
extra_ports=$(echo "$ports" | grep -Ev '^22$' || true)

# 如果没有额外端口，则直接退出
if [[ -z "$extra_ports" ]]; then
    echo "未发现除 22 端口以外的 sshd 监听端口，退出。"
    exit 0
fi

# 3. 针对每个额外端口，查找并删除相关配置文件
echo "发现以下额外端口："
echo "$extra_ports"
for port in $extra_ports; do
    echo ">> 正在查找包含 “Port $port” 的配置文件……"
    # 在 /etc/ssh 和 /etc/ssh/sshd_config.d 中搜索，列出文件列表
    files=$(grep -R "^[[:space:]]*Port[[:space:]]\+$port" /etc/ssh /etc/ssh/sshd_config.d 2>/dev/null | cut -d: -f1 | uniq)
    if [[ -n "$files" ]]; then
        for file in $files; do
            echo "   删除配置文件：$file"
            rm -f "$file"  # 非 root 会在这里报权限错误
        done
    else
        echo "   未找到针对端口 $port 的单独配置文件。"
    fi
done

# 4. 重启 ssh 服务以生效（非 root 会在此报错）
echo "重启 ssh 服务……"
systemctl restart sshd

echo "脚本执行完毕。"
