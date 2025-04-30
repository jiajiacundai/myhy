#!/usr/bin/env bash
#
# auto_fan_control.sh
# 一键安装/管理/卸载 CPU 风扇自动控制服务，并支持手动模式
#

SERVICE_NAME="auto-fan"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_DEST="/usr/local/bin/auto_fan_control.sh"

# 自动识别 hwmon 目录与 temp 输入，配置 pwm1
find_hwmon() {
    for d in /sys/class/hwmon/hwmon*; do
        if [[ -e "$d/pwm1_enable" && -e "$d/pwm1" ]]; then
            HWMON_DIR="$d"
            break
        fi
    done
    if [[ -z "$HWMON_DIR" ]]; then
        echo "未找到支持 pwm1 控制的 hwmon 设备，退出。" >&2
        exit 1
    fi
    for f in "$HWMON_DIR"/temp*_input; do
        if [[ -e "$f" ]]; then
            TEMP_INPUT="$f"
            break
        fi
    done
    if [[ -z "$TEMP_INPUT" ]]; then
        echo "在 $HWMON_DIR 中未找到 temp*_input，退出。" >&2
        exit 1
    fi
}

# 运行温控循环：每10秒检查一次，
# 温度 ≤30°C => 20%
# 温度 30–75°C => 线性映射 20%–75%
# 温度 ≥75°C => 80%
run_loop() {
    find_hwmon

    # 强制开启手动 PWM 模式
    echo 1 > "$HWMON_DIR/pwm1_enable"

    echo "$(date '+%F %T') 启动 CPU 风扇自动控制 (≤30°C:20%; 30–75°C:20→75%; ≥75°C:80%)，每10秒调整一次。"

    local sleep_interval=10
    local min_temp=30      # °C
    local max_temp=75      # °C
    local min_pct=20       # 映射下限
    local max_pct=75       # 映射上限
    local above_pct=80     # 超过阈值后的固定转速
    local range_temp=$(( max_temp - min_temp ))
    local range_pct=$(( max_pct - min_pct ))

    while true; do
        raw_temp=$(cat "$TEMP_INPUT")
        temp_c=$(( raw_temp / 1000 ))

        if (( temp_c <= min_temp )); then
            pct=$min_pct
        elif (( temp_c >= max_temp )); then
            pct=$above_pct
        else
            pct=$(( min_pct + (temp_c - min_temp) * range_pct / range_temp ))
        fi

        pwm_val=$(( 255 * pct / 100 ))
        echo "$pwm_val" > "$HWMON_DIR/pwm1"
        echo "$(date '+%F %T') 温度: ${temp_c}°C => 转速: ${pct}% (PWM=${pwm_val})"

        sleep "$sleep_interval"
    done
}

# 安装：复制脚本、创建 service、启用并启动
install_service() {
    echo "[安装] 复制脚本到 $SCRIPT_DEST..."
    cp "$0" "$SCRIPT_DEST" && chmod +x "$SCRIPT_DEST"

    echo "[安装] 创建 systemd 服务文件 $SERVICE_PATH..."
    tee "$SERVICE_PATH" > /dev/null << EOF
[Unit]
Description=Automatic CPU Fan Control
After=multi-user.target

[Service]
Type=simple
ExecStart=$SCRIPT_DEST run
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    echo "[安装] 重新加载 systemd 并启用服务..."
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    echo "[安装] 服务已启动。"
}

# 控制服务：停止/启动/重启
control_service() {
    echo "请选择操作："
    echo "  1) 停止服务"
    echo "  2) 启动服务"
    echo "  3) 重启服务"
    read -p "输入编号[1-3]: " op
    case "$op" in
        1) systemctl stop "$SERVICE_NAME"  && echo "服务已停止。" ;;
        2) systemctl start "$SERVICE_NAME" && echo "服务已启动。" ;;
        3) systemctl restart "$SERVICE_NAME" && echo "服务已重启。" ;;
        *) echo "无效选项。" ;;
    esac
}

# 手动控制风扇转速
manual_control() {
    find_hwmon
    echo "[手动模式] 停止自动控制服务..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null

    echo "进入手动 PWM 控制模式。"
    echo 1 > "$HWMON_DIR/pwm1_enable"
    PS3="请选择风扇转速百分比（或输入 0 退出手动模式）: "
    options=("0" "20" "40" "60" "80" "100")
    select opt in "${options[@]}"; do
        if [[ "$REPLY" == "0" ]]; then
            echo "退出手动模式。"
            break
        fi
        if [[ " ${options[*]} " == *" $opt "* ]]; then
            pwm_val=$((255 * opt / 100))
            echo "$pwm_val" > "$HWMON_DIR/pwm1"
            echo "已设置转速 ${opt}% (PWM=${pwm_val})。"
        else
            echo "无效选项，请重新选择。"
        fi
    done
}

# 卸载服务和脚本
uninstall_service() {
    echo "[卸载] 停止并禁用服务..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null

    echo "[卸载] 删除 service 文件 $SERVICE_PATH..."
    rm -f "$SERVICE_PATH"

    echo "[卸载] 删除脚本 $SCRIPT_DEST..."
    rm -f "$SCRIPT_DEST"

    echo "[卸载] 重新加载 systemd..."
    systemctl daemon-reload

    echo "[卸载] 完成。"
}

# 如果以 run 参数启动，直接进入温控循环
if [[ "$1" == "run" ]]; then
    run_loop
    exit 0
fi

# 主菜单
while true; do
    echo
    echo "========== CPU 风扇自动控制 管理菜单 =========="
    echo "1) 安装并创建 systemd 服务"
    echo "2) 停止/启动/重启 服务"
    echo "3) 手动控制风扇转速"
    echo "4) 卸载服务和脚本"
    echo "5) 退出"
    read -p "请输入选项 [1-5]: " choice
    case "$choice" in
        1) install_service ;;
        2) control_service ;;
        3) manual_control ;;
        4) uninstall_service ;;
        5) echo "退出。" && exit 0 ;;
        *) echo "无效输入，请重试。" ;;
    esac
done
