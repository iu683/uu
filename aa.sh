#!/bin/bash
# ========================================
# Rclone 管理菜单 (终极安全版，systemd 直接启动)
# ========================================

# 颜色
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
plain="\033[0m"

# 显示菜单
show_menu() {
    clear
    echo -e "${green}====== Rclone 管理菜单 =======${plain}"
    echo -e "${green} 1. 安装 Rclone${plain}"
    echo -e "${green} 2. 卸载 Rclone${plain}"
    echo -e "${green} 3. 配置 Rclone${plain}"
    echo -e "${green} 4. 挂载远程存储到本地${plain}"
    echo -e "${green} 5. 同步 本地 → 远程${plain}"
    echo -e "${green} 6. 同步 远程 → 本地${plain}"
    echo -e "${green} 7. 查看远程存储文件${plain}"
    echo -e "${green} 8. 查看远程存储列表${plain}"
    echo -e "${green} 9. 卸载挂载点${plain}"
    echo -e "${green}10. 查看当前挂载点${plain}"
    echo -e "${green}11. 卸载所有挂载点${plain}"
    echo -e "${green}12. 设置开机启动${plain}"
    echo -e "${green}13. 定时任务管理${plain}"
    echo -e "${green} 0. 退出${plain}${plain}"
}

# ====== 原有功能 ======
install_rclone() {
    echo -e "${yellow}正在安装 Rclone...${plain}"
    sudo -v
    curl https://rclone.org/install.sh | sudo bash
    echo -e "${green}Rclone 安装完成！${plain}"
}

uninstall_rclone() {
    echo -e "${yellow}正在卸载 Rclone...${plain}"
    sudo rm -f /usr/bin/rclone /usr/local/bin/rclone
    sudo systemctl stop 'rclone-mount@*' 2>/dev/null
    sudo systemctl disable 'rclone-mount@*' 2>/dev/null
    sudo rm -f /etc/systemd/system/rclone-mount@*.service
    sudo systemctl daemon-reload
    sudo rm -f /var/run/rclone_*.pid
    echo -e "${green}Rclone 及 systemd 挂载已卸载${plain}"
}

config_rclone() {
    rclone config
}

list_remotes() {
    rclone listremotes
}

mount_remote() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && { echo -e "${red}远程名称不能为空${plain}"; return; }

    path="/mnt/$remote"
    read -p "请输入挂载路径 (默认 $path): " input_path
    path=${input_path:-$path}
    mkdir -p "$path"

    if mount | grep -q "on $path type"; then
        echo -e "${yellow}$remote 已经挂载在 $path${plain}"
        return
    fi

    log="/var/log/rclone_${remote}.log"
    pidfile="/var/run/rclone_${remote}.pid"

    echo -e "${yellow}正在挂载 $remote 到 $path${plain}"
    nohup rclone mount "${remote}:" "$path" --allow-other --vfs-cache-mode writes --dir-cache-time 1000h &> "$log" &
    pid=$!
    echo $pid > "$pidfile"
    echo -e "${green}$remote 已挂载到 $path，PID: $pid${plain}"
}

unmount_remote_by_name() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && { echo -e "${red}远程名称不能为空${plain}"; return; }
    pidfile="/var/run/rclone_${remote}.pid"
    path="/mnt/$remote"

    if [ -f "$pidfile" ]; then
        fusermount -u "$path" 2>/dev/null || umount "$path" 2>/dev/null
        rm -f "$pidfile"
        echo -e "${green}已卸载远程: $remote${plain}"
    else
        echo -e "${red}找不到 $remote 的挂载 PID 文件${plain}"
    fi
}

unmount_all() {
    echo -e "${yellow}正在卸载所有 rclone 挂载点...${plain}"
    for pidfile in /var/run/rclone_*.pid; do
        [ -f "$pidfile" ] || continue
        remote=$(basename "$pidfile" | sed 's/rclone_//;s/\.pid//')
        path="/mnt/$remote"
        fusermount -u "$path" 2>/dev/null || umount "$path" 2>/dev/null
        rm -f "$pidfile"
        echo -e "${green}已卸载 $remote${plain}"
    done
}

sync_local_to_remote() {
    read -p "请输入本地目录路径: " local
    [ -z "$local" ] || [ ! -d "$local" ] && { echo -e "${red}本地路径不存在${plain}"; return; }
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && { echo -e "${red}远程名称不能为空${plain}"; return; }
    read -p "请输入远程目录 (默认 backup): " remote_dir
    remote_dir=${remote_dir:-backup}

    echo -e "${yellow}正在同步 $local → ${remote}:$remote_dir${plain}"
    rclone sync "$local" "${remote}:$remote_dir" -v -P
}

sync_remote_to_local() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && { echo -e "${red}远程名称不能为空${plain}"; return; }
    read -p "请输入本地目录路径: " local
    [ -z "$local" ] && { echo -e "${red}本地路径不能为空${plain}"; return; }
    read -p "请输入远程目录 (默认 backup): " remote_dir
    remote_dir=${remote_dir:-backup}

    echo -e "${yellow}正在同步 ${remote}:$remote_dir → $local${plain}"
    rclone sync "${remote}:$remote_dir" "$local" -v -P
}

list_files_remote() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && { echo -e "${red}远程名称不能为空${plain}"; return; }
    rclone ls "${remote}:"
}

generate_systemd_service() {
    read -p "请输入远程名称 (用于服务文件): " remote
    [ -z "$remote" ] && { echo -e "${red}远程名称不能为空${plain}"; return; }

    path="/mnt/$remote"
    mkdir -p "$path"
    service_file="/etc/systemd/system/rclone-mount@${remote}.service"

    sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=Rclone Mount ${remote}
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/rclone mount ${remote}: $path --allow-other --vfs-cache-mode writes --dir-cache-time 1000h
ExecStop=/bin/fusermount -u $path
Restart=always
RestartSec=10
StandardOutput=append:/var/log/rclone_${remote}.log
StandardError=append:/var/log/rclone_${remote}.log

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable rclone-mount@${remote}
    sudo systemctl start rclone-mount@${remote}

    echo -e "${green}Systemd 服务已生成并启动: $service_file${plain}"
}

# ====== 优化 show_mounts 支持 FUSE/R2 ======
show_mounts() {
    echo -e "${yellow}当前 rclone 挂载点:${plain}"
    for pidfile in /var/run/rclone_*.pid; do
        [ -f "$pidfile" ] || continue
        remote=$(basename "$pidfile" | sed 's/rclone_//;s/\.pid//')
        path="/mnt/$remote"
        if mount | grep -q "$path"; then
            echo -e "${green}$remote → $path${plain}"
        else
            echo -e "${red}$remote 挂载未检测到，但 PID 文件存在${plain}"
        fi
    done
}

# ====== 定时任务管理 ======
CRON_PREFIX="# rclone_sync_task:"

# 列出已有定时任务
list_cron() {
    crontab -l 2>/dev/null | grep "$CRON_PREFIX" || echo -e "${yellow}暂无定时任务${plain}"
}

# 添加任务
schedule_add() {
    read -p "请输入任务名称(自定义): " TASK_NAME
    [ -z "$TASK_NAME" ] && { echo -e "${red}任务名称不能为空${plain}"; return; }

    read -p "请输入本地目录: " LOCAL_DIR
    [ -z "$LOCAL_DIR" ] || [ ! -d "$LOCAL_DIR" ] && { echo -e "${red}本地目录不存在${plain}"; return; }

    read -p "请输入远程名称: " REMOTE_NAME
    [ -z "$REMOTE_NAME" ] && { echo -e "${red}远程名称不能为空${plain}"; return; }

    read -p "请输入远程目录 (默认 backup): " REMOTE_DIR
    REMOTE_DIR=${REMOTE_DIR:-backup}

    read -p "请输入 Telegram Bot Token: " TG_TOKEN
    read -p "请输入 Telegram Chat ID: " TG_CHAT_ID

    read -p "请输入 Cron 表达式 (默认每天 2 点: 0 2 * * *): " CRON_EXPR
    CRON_EXPR=${CRON_EXPR:-"0 2 * * *"}

    SCRIPT_PATH="/opt/rclone_sync_${TASK_NAME}.sh"

    # 生成同步脚本
    cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
LOG_FILE="/var/log/rclone_sync_${TASK_NAME}.log"

send_tg() {
    local msg="\$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" -d chat_id="${TG_CHAT_ID}" -d text="\$msg"
}

echo "[\$(date '+%F %T')] 开始同步 ${LOCAL_DIR} → ${REMOTE_NAME}:${REMOTE_DIR}" >> "\$LOG_FILE"
rclone sync "${LOCAL_DIR}" "${REMOTE_NAME}:${REMOTE_DIR}" -v >> "\$LOG_FILE" 2>&1
RET=\$?

if [ \$RET -eq 0 ]; then
    echo "[\$(date '+%F %T')] 同步完成 ✅" >> "\$LOG_FILE"
    send_tg "Rclone 同步完成 [${TASK_NAME}]: ${LOCAL_DIR} → ${REMOTE_NAME}:${REMOTE_DIR} ✅"
else
    echo "[\$(date '+%F %T')] 同步失败 ❌" >> "\$LOG_FILE"
    send_tg "⚠️ Rclone 同步失败 [${TASK_NAME}]: ${LOCAL_DIR} → ${REMOTE_NAME}:${REMOTE_DIR} ❌"
fi
EOF

    chmod +x "$SCRIPT_PATH"

    # 写入 crontab
    (crontab -l 2>/dev/null; echo "$CRON_EXPR $SCRIPT_PATH $CRON_PREFIX$TASK_NAME") | crontab -

    echo -e "${green}定时任务 ${TASK_NAME} 已添加${plain}"
}

# 删除单个任务
schedule_del_one() {
    list_cron
    read -p "请输入要删除的任务名称: " TASK_NAME
    [ -z "$TASK_NAME" ] && return
    crontab -l 2>/dev/null | grep -v "$CRON_PREFIX$TASK_NAME" | crontab -
    rm -f "/opt/rclone_sync_${TASK_NAME}.sh"
    echo -e "${green}任务 ${TASK_NAME} 已删除${plain}"
}

# 清空全部定时任务
schedule_del_all() {
    read -p "确认清空所有 Rclone 定时任务? (y/N): " CONFIRM
    [ "$CONFIRM" != "y" ] && return
    crontab -l 2>/dev/null | grep -v "$CRON_PREFIX" | crontab -
    rm -f /opt/rclone_sync_*.sh
    echo -e "${green}所有定时任务已清空${plain}"
}

# 定时任务管理菜单
cron_task_menu() {
    while true; do
        echo -e "${green}=== 定时任务管理 ===${plain}"
        echo -e "${green}------------------------${plain}"
        list_cron
        echo -e "${green}------------------------${plain}"
        echo -e "${green}1. 添加任务${plain}"
        echo -e "${green}2. 删除任务${plain}"
        echo -e "${green}3. 清空全部${plain}"
        echo -e "${green}0. 返回${plain}"
        read -p "选择: " c
        case $c in
            1) schedule_add ;;
            2) schedule_del_one ;;
            3) schedule_del_all ;;
            0) break ;;
            *) echo -e "${red}❌ 无效选择${plain}" ;;
        esac
        read -p "按回车继续..."
    done
}


# ====== 主循环 ======
while true; do
    show_menu
    read -p "$(echo -e ${green} 请选择:${plain}) : " choice
    case $choice in
        1) install_rclone ;;
        2) uninstall_rclone ;;
        3) config_rclone ;;
        4) mount_remote ;;
        5) sync_local_to_remote ;;
        6) sync_remote_to_local ;;
        7) list_files_remote ;;
        8) list_remotes ;;
        9) unmount_remote_by_name ;;
        10) show_mounts ;;
        11) unmount_all ;;
        12) generate_systemd_service ;;
        13) cron_task_menu ;;
        0) exit 0 ;;
        *) echo -e "${red}无效选项，请重新输入${plain}" ;;
    esac
    read -r -p "按回车继续..."
done
