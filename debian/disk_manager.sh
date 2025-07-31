#!/bin/bash

# Debian硬盘挂载管理脚本
# 作者: Claude AI
# 版本: 2.0

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用sudo或root权限运行此脚本${NC}"
        exit 1
    fi
}

# 显示硬盘分区详情
show_disk_details() {
    echo -e "${BLUE}=== 硬盘分区详情 ===${NC}"
    echo ""
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
    echo ""
}

# 检查硬盘是否有分区并且分区已被使用
is_disk_in_use() {
    local disk="$1"
    local disk_name=$(basename "$disk")
    
    # 检查该硬盘是否有分区
    local partitions=$(lsblk -ln -o NAME "$disk" | grep -v "^${disk_name}$")
    
    if [ -z "$partitions" ]; then
        return 1  # 没有分区
    fi
    
    # 检查分区是否被挂载或者是系统分区
    while IFS= read -r partition; do
        local full_partition="/dev/$partition"
        local mountpoint=$(lsblk -ln -o MOUNTPOINT "$full_partition" 2>/dev/null | grep -v '^$')
        
        # 如果有挂载点，说明在使用中
        if [ ! -z "$mountpoint" ]; then
            return 0  # 在使用中
        fi
        
        # 检查是否是系统关键分区（根据文件系统类型和大小判断）
        local fstype=$(lsblk -ln -o FSTYPE "$full_partition" 2>/dev/null)
        if [[ "$fstype" == "ext4" ]] || [[ "$fstype" == "vfat" ]] || [[ "$fstype" == "swap" ]]; then
            # 进一步检查是否可能是系统分区
            local size=$(lsblk -ln -o SIZE "$full_partition" 2>/dev/null | sed 's/[^0-9.]//g')
            if (( $(echo "$size > 1" | bc -l 2>/dev/null || echo "1") )); then
                return 0  # 可能是系统分区
            fi
        fi
    done <<< "$partitions"
    
    return 1  # 不在使用中
}

# 显示可挂载的分区
show_mountable_partitions() {
    echo -e "${BLUE}=== 可挂载的分区 ===${NC}"
    echo ""
    
    # 创建临时文件存储分区列表
    > /tmp/partition_list_$$
    
    local counter=1
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $4}')
        local type=$(echo "$line" | awk '{print $6}')
        local mountpoint=$(echo "$line" | awk '{print $7}')
        local fstype=$(lsblk -ln -o FSTYPE "/dev/$name" 2>/dev/null)
        
        # 只显示分区，跳过磁盘、loop设备和swap
        if [[ $type != "part" ]] || [[ $name =~ loop ]] || [[ $fstype == "swap" ]]; then
            continue
        fi
        
        # 跳过系统关键分区
        if [[ "$mountpoint" == "/" ]] || [[ "$mountpoint" == "/boot" ]] || [[ "$mountpoint" == "/boot/efi" ]]; then
            continue
        fi
        
        # 显示分区信息
        if [ -z "$mountpoint" ]; then
            mountpoint="未挂载"
        fi
        
        if [ -z "$fstype" ]; then
            fstype="无文件系统"
        fi
        
        echo -e "${counter}. ${GREEN}/dev/${name}${NC} - 大小: ${YELLOW}${size}${NC} - 文件系统: ${fstype} - 挂载点: ${mountpoint}"
        echo "/dev/${name}" >> /tmp/partition_list_$$
        ((counter++))
    done < <(lsblk -ln -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINT)
    
    echo ""
}

# 挂载硬盘
mount_disk() {
    echo -e "${BLUE}=== 挂载硬盘分区 ===${NC}"
    echo ""
    
    # 显示硬盘详情
    show_disk_details
    
    # 创建临时文件存储分区列表
    > /tmp/partition_list_$$
    
    show_mountable_partitions
    
    # 检查是否有可用分区
    if [ ! -s /tmp/partition_list_$$ ]; then
        echo -e "${RED}没有找到可挂载的分区${NC}"
        rm -f /tmp/partition_list_$$
        return
    fi
    
    # 选择分区
    echo -n "请选择要挂载的分区编号: "
    read partition_choice
    
    # 验证输入
    if ! [[ "$partition_choice" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效的选择${NC}"
        rm -f /tmp/partition_list_$$
        return
    fi
    
    # 获取选择的分区
    selected_partition=$(sed -n "${partition_choice}p" /tmp/partition_list_$$)
    rm -f /tmp/partition_list_$$
    
    if [ -z "$selected_partition" ]; then
        echo -e "${RED}无效的选择${NC}"
        return
    fi
    
    echo -e "选择的分区: ${GREEN}${selected_partition}${NC}"
    
    # 检查分区是否已经挂载
    current_mount=$(lsblk -n -o MOUNTPOINT "$selected_partition" 2>/dev/null | grep -v '^$' | head -1)
    if [ ! -z "$current_mount" ]; then
        echo -e "${YELLOW}警告: 该分区已挂载到 ${current_mount}${NC}"
        echo -n "是否继续挂载到新位置? (y/N): "
        read confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "操作已取消"
            return
        fi
        
        # 先卸载当前挂载
        echo "正在卸载当前挂载点..."
        umount "$selected_partition"
        if [ $? -ne 0 ]; then
            echo -e "${RED}无法卸载当前挂载点，操作取消${NC}"
            return
        fi
    fi
    
    # 输入挂载目录
    echo -n "请输入挂载目录 (回车默认 /mnt/data): "
    read mount_point
    
    if [ -z "$mount_point" ]; then
        mount_point="/mnt/data"
    fi
    
    echo -e "挂载点: ${GREEN}${mount_point}${NC}"
    
    # 创建挂载目录
    if [ ! -d "$mount_point" ]; then
        echo "创建挂载目录: $mount_point"
        mkdir -p "$mount_point"
        if [ $? -ne 0 ]; then
            echo -e "${RED}创建目录失败${NC}"
            return
        fi
    fi
    
    # 检查文件系统类型
    fs_type=$(blkid -o value -s TYPE "$selected_partition" 2>/dev/null)
    if [ -z "$fs_type" ]; then
        echo -e "${YELLOW}警告: 未检测到文件系统，可能需要格式化${NC}"
        echo -n "是否格式化为ext4文件系统? (y/N): "
        read format_confirm
        if [[ "$format_confirm" =~ ^[Yy]$ ]]; then
            echo "正在格式化为ext4..."
            # 格式化分区保留默认空间为5%，下面设置保留空间为2%
            mkfs.ext4 -m 2 "$selected_partition"
            if [ $? -ne 0 ]; then
                echo -e "${RED}格式化失败${NC}"
                return
            fi
            fs_type="ext4"
        else
            echo "操作已取消"
            return
        fi
    fi
    
    # 挂载分区
    echo "正在挂载分区..."
    mount "$selected_partition" "$mount_point"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}分区挂载成功!${NC}"
        
        # 获取UUID
        uuid=$(blkid -o value -s UUID "$selected_partition")
        
        # 添加到fstab实现开机自动挂载
        if [ ! -z "$uuid" ]; then
            # 检查fstab中是否已存在该UUID
            if ! grep -q "$uuid" /etc/fstab; then
                echo "添加开机自动挂载配置..."
                echo "UUID=$uuid $mount_point $fs_type defaults 0 2" >> /etc/fstab
                echo -e "${GREEN}已配置开机自动挂载${NC}"
            else
                echo -e "${YELLOW}fstab中已存在该分区的挂载配置${NC}"
            fi
        fi
        
        # 显示挂载信息
        echo ""
        echo -e "${BLUE}挂载信息:${NC}"
        df -h "$mount_point"
    else
        echo -e "${RED}挂载失败${NC}"
    fi
}

# 卸载硬盘
unmount_disk() {
    echo -e "${BLUE}=== 卸载硬盘分区 ===${NC}"
    echo ""
    
    # 显示磁盘详情
    show_disk_details
    
    # 创建临时文件存储已挂载分区列表
    > /tmp/mounted_partition_list_$$
    
    echo -e "${BLUE}=== 已挂载分区信息 ===${NC}"
    echo ""
    
    local counter=1
    # 列出所有 /dev/* 设备，并跳过系统挂载点
    while IFS= read -r line; do
        local device=$(echo "$line" | awk '{print $1}')
        local fstype=$(echo "$line" | awk '{print $2}')
        local size=$(echo "$line" | awk '{print $3}')
        local used=$(echo "$line" | awk '{print $4}')
        local available=$(echo "$line" | awk '{print $5}')
        local mountpoint=$(echo "$line" | awk '{print $7}')
        
        # 跳过根分区、boot 分区、proc/sys/dev/run 等系统关键挂载点
        if [[ "$mountpoint" == "/" ]] || [[ "$mountpoint" == "/boot" ]] || [[ "$mountpoint" == "/boot/efi" ]] \
           || [[ "$mountpoint" =~ ^/proc ]] || [[ "$mountpoint" =~ ^/sys ]] \
           || [[ "$mountpoint" =~ ^/dev ]] || [[ "$mountpoint" =~ ^/run ]]; then
            continue
        fi
        
        printf "%d. ${GREEN}%s${NC} - 文件系统: ${YELLOW}%s${NC} - 大小: %s - 已用: %s - 可用: %s - 挂载点: %s\n" \
            "$counter" "$device" "$fstype" "$size" "$used" "$available" "$mountpoint"
        echo "${device}|${mountpoint}" >> /tmp/mounted_partition_list_$$
        ((counter++))
    done < <(df -hT | grep '^/dev/')
    
    echo ""
    
    # 如果没有可卸载的分区
    if [ ! -s /tmp/mounted_partition_list_$$ ]; then
        echo -e "${RED}没有找到可卸载的分区${NC}"
        rm -f /tmp/mounted_partition_list_$$
        return
    fi
    
    # 选择要卸载的分区
    echo -n "请选择要卸载的分区编号: "
    read partition_choice
    
    # 验证输入
    if ! [[ "$partition_choice" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效的选择${NC}"
        rm -f /tmp/mounted_partition_list_$$
        return
    fi
    
    # 读取选中的设备和挂载点
    selected_info=$(sed -n "${partition_choice}p" /tmp/mounted_partition_list_$$)
    rm -f /tmp/mounted_partition_list_$$
    
    if [ -z "$selected_info" ]; then
        echo -e "${RED}无效的选择${NC}"
        return
    fi
    
    selected_device=$(echo "$selected_info" | cut -d'|' -f1)
    selected_mountpoint=$(echo "$selected_info" | cut -d'|' -f2)
    
    echo -e "选择的分区: ${GREEN}${selected_device}${NC}"
    echo -e "挂载点: ${GREEN}${selected_mountpoint}${NC}"
    
    # 检查是否有进程在使用该挂载点
    echo "检查挂载点使用情况..."
    local processes=$(lsof +f -- "$selected_mountpoint" 2>/dev/null | wc -l)
    if [ "$processes" -gt 1 ]; then
        echo -e "${YELLOW}警告: 有进程正在使用该挂载点${NC}"
        echo "占用进程信息:"
        lsof +f -- "$selected_mountpoint" 2>/dev/null
        echo -n "是否强制卸载? (y/N): "
        read force_unmount
        if [[ "$force_unmount" =~ ^[Yy]$ ]]; then
            echo "正在终止占用进程..."
            fuser -km "$selected_mountpoint" 2>/dev/null
            sleep 2
        else
            echo "操作已取消"
            return
        fi
    fi
    
    # 询问是否清除分区数据
    echo -n "是否清除分区数据? (y/N，默认不清除): "
    read clear_data
    
    # 尝试卸载
    echo "正在卸载分区..."
    if umount -l "$selected_mountpoint"; then
        echo -e "${GREEN}分区卸载成功!${NC}"
        
        # 从 fstab 中删除自动挂载配置
        if uuid=$(blkid -o value -s UUID "$selected_device" 2>/dev/null); then
            cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
            grep -v "$uuid" /etc/fstab > /tmp/fstab_new_$$
            mv /tmp/fstab_new_$$ /etc/fstab
            echo -e "${GREEN}已删除开机自动挂载配置${NC}"
        fi
        
        # 如果选择清除数据
        if [[ "$clear_data" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}警告: 即将清除分区所有数据!${NC}"
            echo -n "请再次确认是否清除数据? (yes/no): "
            read final_confirm
            if [ "$final_confirm" = "yes" ]; then
                echo "正在清除分区数据..."
                wipefs -af "$selected_device" 2>/dev/null
                dd if=/dev/zero of="$selected_device" bs=1M count=100 2>/dev/null
                echo -e "${GREEN}分区数据已清除${NC}"
            else
                echo "跳过数据清除"
            fi
        fi
        
        # 可选择删除挂载点目录
        if [ -d "$selected_mountpoint" ]; then
            echo -n "是否删除挂载点目录 $selected_mountpoint? (y/N): "
            read remove_dir
            if [[ "$remove_dir" =~ ^[Yy]$ ]]; then
                if rmdir "$selected_mountpoint" 2>/dev/null; then
                    echo -e "${GREEN}挂载点目录已删除${NC}"
                else
                    echo -e "${YELLOW}挂载点目录不为空，未删除${NC}"
                fi
            fi
        fi
        
    else
        echo -e "${RED}卸载失败${NC}"
        echo "尝试强制卸载..."
        if umount -lf "$selected_mountpoint"; then
            echo -e "${GREEN}强制卸载成功${NC}"
        else
            echo -e "${RED}强制卸载也失败，请检查系统状态${NC}"
        fi
    fi
}

# 显示主菜单
show_menu() {
    clear
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}    Debian硬盘挂载管理工具${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
    echo "1. 挂载硬盘分区"
    echo "2. 卸载硬盘分区"
    echo "3. 查看硬盘详情"
    echo "4. 退出"
    echo ""
}

# 查看硬盘详情
view_disk_info() {
    clear
    show_disk_details
    echo -n "按回车键返回主菜单..."
    read
}

# 主函数
main() {
    check_root
    
    while true; do
        show_menu
        echo -n "请选择操作 (1-4): "
        read choice
        
        case $choice in
            1)
                mount_disk
                echo ""
                echo -n "按回车键继续..."
                read
                ;;
            2)
                unmount_disk
                echo ""
                echo -n "按回车键继续..."
                read
                ;;
            3)
                view_disk_info
                ;;
            4)
                echo -e "${GREEN}感谢使用，再见!${NC}"
                # 清理临时文件
                rm -f /tmp/partition_list_$$ /tmp/mounted_partition_list_$$ /tmp/fstab_new_$$
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入${NC}"
                sleep 2
                ;;
        esac
    done
}

# 脚本入口
main "$@"
