#!/bin/bash

# 脚本名称: uninstall_python2.sh
# 描述: 这个脚本用于在Debian 11系统上卸载Python 2

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
log "开始卸载Python 2..."

# 列出并卸载Python 2相关包
PYTHON2_PACKAGES=$(dpkg -l | grep python2 | awk '{print $2}')
log "检测到以下Python 2相关包:"
echo "$PYTHON2_PACKAGES" | tee -a "$LOG_FILE"

for package in $PYTHON2_PACKAGES; do
    log "正在卸载 $package..."
    apt remove -y "$package" >> "$LOG_FILE" 2>&1
done

# 自动移除不再需要的依赖
log "正在移除不再需要的依赖..."
apt autoremove -y >> "$LOG_FILE" 2>&1

# 清理残留的配置文件
log "正在清理残留的配置文件..."
apt purge -y python2 python2-minimal >> "$LOG_FILE" 2>&1

# 检查是否还有遗留的Python 2文件
LEFTOVER_FILES=$(whereis python2)
if [ -n "$LEFTOVER_FILES" ]; then
    log "检测到以下遗留文件:"
    echo "$LEFTOVER_FILES" | tee -a "$LOG_FILE"
    log "正在删除遗留文件..."
    rm -rf /usr/bin/python2* >> "$LOG_FILE" 2>&1
    rm -rf /usr/lib/python2* >> "$LOG_FILE" 2>&1
else
    log "没有检测到遗留文件。"
fi

# 更新软件包列表
log "正在更新软件包列表..."
apt update >> "$LOG_FILE" 2>&1

# 完成
log "Python 2卸载完成。请检查日志文件 $LOG_FILE 以获取详细信息。"
log "注意: 某些系统工具可能依赖Python 2。请确保系统仍能正常运行。"
