#!/bin/bash

# 脚本名称: uninstall_python2.sh
# 描述: 这个脚本用于在Debian 11系统上彻底卸载Python 2

# 设置日志文件
LOG_FILE="/tmp/uninstall_python2_$(date +%Y%m%d_%H%M%S).log"

# 日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 检查是否以root权限运行
if [ "$(id -u)" != "0" ]; then
   log "错误: 这个脚本必须以root权限运行" 
   exit 1
fi

# 开始卸载过程
log "开始彻底卸载Python 2..."

# 列出并卸载Python 2相关包
PYTHON2_PACKAGES=$(dpkg -l | grep -E "^(ii|rc)" | grep python2 | awk '{print $2}')
log "检测到以下Python 2相关包:"
echo "$PYTHON2_PACKAGES" | tee -a "$LOG_FILE"

for package in $PYTHON2_PACKAGES; do
    log "正在卸载并清理 $package..."
    apt purge -y "$package" >> "$LOG_FILE" 2>&1
done

# 处理反向依赖
log "正在处理Python 2的反向依赖..."
RDEPENDS=$(apt-cache rdepends python2 | grep -v "python2")
for package in $RDEPENDS; do
    if dpkg -l | grep -q "^ii.*$package"; then
        log "正在卸载反向依赖: $package..."
        apt purge -y "$package" >> "$LOG_FILE" 2>&1
    fi
done

# 自动移除不再需要的依赖
log "正在移除不再需要的依赖..."
apt autoremove -y >> "$LOG_FILE" 2>&1

# 清理残留的配置文件和目录
log "正在清理残留的配置文件和目录..."
apt purge -y $(dpkg -l | grep '^rc' | awk '{print $2}') >> "$LOG_FILE" 2>&1
rm -rf /etc/python2* >> "$LOG_FILE" 2>&1
rm -rf /usr/lib/python2* >> "$LOG_FILE" 2>&1
rm -rf /usr/local/lib/python2* >> "$LOG_FILE" 2>&1

# 检查是否还有遗留的Python 2文件
LEFTOVER_FILES=$(whereis python2)
if [ -n "$LEFTOVER_FILES" ] && [ "$LEFTOVER_FILES" != "python2:" ]; then
    log "检测到以下遗留文件:"
    echo "$LEFTOVER_FILES" | tee -a "$LOG_FILE"
    log "正在删除遗留文件..."
    rm -rf /usr/bin/python2* >> "$LOG_FILE" 2>&1
    rm -rf /usr/local/bin/python2* >> "$LOG_FILE" 2>&1
    for file in $LEFTOVER_FILES; do
        if [ -e "$file" ]; then
            rm -rf "$file" >> "$LOG_FILE" 2>&1
        fi
    done
else
    log "没有检测到遗留文件。"
fi

# 更新软件包列表
log "正在更新软件包列表..."
apt update >> "$LOG_FILE" 2>&1

# 完成
log "Python 2卸载完成。请检查日志文件 $LOG_FILE 以获取详细信息。"
log "警告: 此脚本已尝试彻底删除Python 2及其依赖。请仔细检查系统功能是否正常。"
