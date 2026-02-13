#!/bin/bash
# ========================================
# Rclone 管理菜单 (终极安全版，多目录 + TG + 定时 + systemd)
# ========================================

# 颜色
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
PLAIN="\033[0m"

# ==================== 菜单 ====================
show_menu() {
    clear
    echo -e "${GREEN}====== Rclone 管理菜单 ======${PLAIN}"
    echo -e "${GREEN} 1. 安装 Rclone${PLAIN}"
    echo -e "${GREEN} 2. 卸载 Rclone${PLAIN}"
    echo -e "${GREEN} 3. 配置 Rclone${PLAIN}"
    echo -e "${GREEN} 4. 挂载远程存储到本地${PLAIN}"
    echo -e "${GREEN} 5. 同步 本地 → 远程${PLAIN}"
    echo -e "${GREEN} 6. 同步 远程 → 本地${PLAIN}"
    echo -e "${GREEN} 7. 查看远程存储文件${PLAIN}"
    echo -e "${GREEN} 8. 查看远程存储列表${PLAIN}"
    echo -e "${GREEN} 9. 卸载挂载点${PLAIN}"
    echo -e "${GREEN}10. 查看当前挂载点${PLAIN}"
    echo -e "${GREEN}11. 卸载所有挂载点${PLAIN}"
    echo -e "${GREEN}12. systemd自动挂载${PLAIN}"
    echo -e "${GREEN}13. 定时任务管理${PLAIN}"
    echo -e "${GREEN}14. 更新 Rclone${PLAIN}"
    echo -e "${GREEN}15. 自动生成多挂载systemd${PLAIN}"
    echo -e "${GREEN} 0. 退出${PLAIN}"
}

# ==================== 安装/更新/卸载 ====================
install_rclone() {
    echo -e "${YELLOW}正在安装 Rclone...${PLAIN}"
    sudo -v
    curl https://rclone.org/install.sh | sudo bash
    echo -e "${GREEN}Rclone 安装完成！${PLAIN}"
}

update_rclone() {
    echo -e "${YELLOW}正在更新 Rclone 到最新版本...${PLAIN}"
    sudo -v
    curl https://rclone.org/install.sh | sudo bash
    echo -e "${GREEN}Rclone 已更新完成！${PLAIN}"
    rclone version
}

uninstall_rclone() {
    echo -e "${YELLOW}正在卸载 Rclone...${PLAIN}"
    sudo rm -f /usr/bin/rclone /usr/local/bin/rclone
    sudo systemctl stop 'rclone-mount@*' 2>/dev/null
    sudo systemctl disable 'rclone-mount@*' 2>/dev/null
    sudo rm -f /etc/systemd/system/rclone-mount@*.service
    sudo systemctl daemon-reload
    sudo rm -f /var/run/rclone_*.pid
    echo -e "${GREEN}Rclone 及 systemd 挂载已卸载${PLAIN}"
}

config_rclone() {
    rclone config
}

list_remotes() {
    rclone listremotes
}

list_files_remote() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && { echo -e "${RED}远程名称不能为空${PLAIN}"; return; }
    rclone ls "${remote}:"
}

# ==================== 挂载/卸载 ====================
mount_remote() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && { echo -e "${RED}远程名称不能为空${PLAIN}"; return; }

    path="/mnt/$remote"
    read -p "请输入挂载路径 (默认 $path): " input_path
    path=${input_path:-$path}
    mkdir -p "$path"

    if mount | grep -q "on $path type"; then
        echo -e "${YELLOW}$remote 已挂载在 $path${PLAIN}"
        return
    fi

    log="/var/log/rclone_${remote}.log"
    pidfile="/var/run/rclone_${remote}.pid"

    echo -e "${YELLOW}正在挂载 $remote 到 $path${PLAIN}"
    nohup rclone mount "${remote}:" "$path" --allow-other --vfs-cache-mode writes --dir-cache-time 1000h &> "$log" &
    pid=$!
    echo $pid > "$pidfile"
    echo -e "${GREEN}$remote 已挂载到 $path，PID: $pid${PLAIN}"
}

unmount_remote_by_name() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && return
    pidfile="/var/run/rclone_${remote}.pid"
    path="/mnt/$remote"

    if [ -f "$pidfile" ]; then
        fusermount -u "$path" 2>/dev/null || umount "$path" 2>/dev/null
        rm -f "$pidfile"
        echo -e "${GREEN}已卸载远程: $remote${PLAIN}"
    else
        echo -e "${RED}找不到 $remote 的挂载 PID 文件${PLAIN}"
    fi
}

unmount_all() {
    echo -e "${YELLOW}正在卸载所有挂载点...${PLAIN}"
    for pidfile in /var/run/rclone_*.pid; do
        [ -f "$pidfile" ] || continue
        remote=$(basename "$pidfile" | sed 's/rclone_//;s/\.pid//')
        path="/mnt/$remote"
        fusermount -u "$path" 2>/dev/null || umount "$path" 2>/dev/null
        rm -f "$pidfile"
        echo -e "${GREEN}已卸载 $remote${PLAIN}"
    done
}

show_mounts() {
    echo -e "${YELLOW}当前挂载点:${PLAIN}"
    for pidfile in /var/run/rclone_*.pid; do
        [ -f "$pidfile" ] || continue
        remote=$(basename "$pidfile" | sed 's/rclone_//;s/\.pid//')
        path="/mnt/$remote"
        if mount | grep -q "$path"; then
            echo -e "${GREEN}$remote → $path${PLAIN}"
        else
            echo -e "${RED}$remote 挂载未检测到，但 PID 文件存在${PLAIN}"
        fi
    done
}

generate_systemd_service() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && return

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
    echo -e "${GREEN}Systemd 自动挂载已生成并启动${PLAIN}"
}

generate_systemd_all() {
    echo -e "${YELLOW}扫描已有挂载点，生成 systemd 服务...${PLAIN}"
    for pidfile in /var/run/rclone_*.pid; do
        [ -f "$pidfile" ] || continue
        remote=$(basename "$pidfile" | sed 's/rclone_//;s/\.pid//')
        path="/mnt/$remote"
        service_file="/etc/systemd/system/rclone-mount@${remote}.service"
        [ -f "$service_file" ] && { echo -e "${GREEN}$remote 的 systemd 已存在，跳过${PLAIN}"; continue; }
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
        echo -e "${GREEN}$remote systemd 服务已生成并启动${PLAIN}"
    done
    echo -e "${GREEN}所有挂载点 systemd 服务生成完成${PLAIN}"
}

# ==================== 多目录同步 ====================
sync_local_to_remote_multi() {
    read -p "请输入本地目录，用空格分隔: " local_dirs
    [ -z "$local_dirs" ] && return

    for d in $local_dirs; do
        [ ! -d "$d" ] && { echo -e "${RED}目录不存在: $d${PLAIN}"; return; }
    done

    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && return
    read -p "请输入远程目录 (默认 backup): " remote_dir
    remote_dir=${remote_dir:-backup}
    read -p "是否启用 Telegram 通知? (y/N): " use_tg
    if [[ "$use_tg" =~ ^[Yy]$ ]]; then
        read -p "请输入 Bot Token: " TG_TOKEN
        read -p "请输入 Chat ID: " TG_CHAT_ID
        read -p "请输入 VPS 名称（自定义，用于 TG 通知）: " VPS_NAME
        [ -z "$VPS_NAME" ] && VPS_NAME="未命名VPS"
        send_tg() {
            local msg="$1"
            curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                -d chat_id="${TG_CHAT_ID}" \
                -d text="[$VPS_NAME] $msg"
        }
    else
        send_tg() { :; }
    fi

    for d in $local_dirs; do
        base=$(basename "$d")
        target_remote_dir="${remote_dir}/${base}"
        echo -e "${YELLOW}同步 $d → ${remote}:$target_remote_dir${PLAIN}"
        LOG_FILE="/var/log/rclone_sync_${base}.log"
        rclone sync "$d" "${remote}:$target_remote_dir" -v -P >> "$LOG_FILE" 2>&1
        RET=$?
        if [ $RET -eq 0 ]; then
            echo "[\$(date '+%F %T')] 同步完成 ✅" >> "$LOG_FILE"
            send_tg "Rclone 同步完成: $d → ${remote}:$target_remote_dir ✅"
        else
            echo "[\$(date '+%F %T')] 同步失败 ❌" >> "$LOG_FILE"
            send_tg "⚠️ Rclone 同步失败: $d → ${remote}:$target_remote_dir ❌"
        fi
    done
}

sync_remote_to_local() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && return
    read -p "请输入本地目录: " local
    [ -z "$local" ] && return
    read -p "请输入远程目录 (默认 backup): " remote_dir
    remote_dir=${remote_dir:-backup}
    rclone sync "${remote}:$remote_dir" "$local" -v -P
}

# ==================== 定时任务 ====================
CRON_PREFIX="# rclone_sync_task:"

list_cron() {
    crontab -l 2>/dev/null | grep "$CRON_PREFIX" || echo -e "${YELLOW}暂无定时任务${PLAIN}"
}

# （定时任务同步脚本同样使用 basename 分目录）
schedule_add() {
    read -p "任务名(自定义): " TASK_NAME
    [ -z "$TASK_NAME" ] && return
    read -p "本地目录(空格分隔): " LOCAL_DIR
    [ -z "$LOCAL_DIR" ] && return
    read -p "远程名称: " REMOTE_NAME
    [ -z "$REMOTE_NAME" ] && return
    read -p "远程目录(默认 backup): " REMOTE_DIR
    REMOTE_DIR=${REMOTE_DIR:-backup}
    read -p "是否启用 Telegram 通知? (y/N): " use_tg
    if [[ "$use_tg" =~ ^[Yy]$ ]]; then
        read -p "Bot Token: " TG_TOKEN
        read -p "Chat ID: " TG_CHAT_ID
        read -p "VPS 名称: " VPS_NAME
        [ -z "$VPS_NAME" ] && VPS_NAME="未命名VPS"
    fi

    echo -e "${GREEN}1. 每天0点${PLAIN}"
    echo -e "${GREEN}2. 每周一0点${PLAIN}"
    echo -e "${GREEN}3. 每月1号0点${PLAIN}"
    echo -e "${GREEN}4. 自定义cron${PLAIN}"
    read -p "选择: " t
    case $t in
        1) cron_expr="0 0 * * *" ;;
        2) cron_expr="0 0 * * 1" ;;
        3) cron_expr="0 0 1 * *" ;;
        4) read -p "请输入自定义 cron 表达式: " cron_expr ;;
        *) echo -e "${RED}❌ 无效选择${PLAIN}"; return ;;
    esac

    SCRIPT_PATH="/opt/rclone_sync_${TASK_NAME}.sh"
    cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
LOG_FILE="/var/log/rclone_sync_${TASK_NAME}.log"

send_tg() {
EOF
    if [[ "$use_tg" =~ ^[Yy]$ ]]; then
        echo "curl -s -X POST \"https://api.telegram.org/bot${TG_TOKEN}/sendMessage\" -d chat_id=\"${TG_CHAT_ID}\" -d text=\"[$VPS_NAME] \$1\"" >> "$SCRIPT_PATH"
    else
        echo ": # 不发送 TG" >> "$SCRIPT_PATH"
    fi
    cat >> "$SCRIPT_PATH" <<EOF
for d in $LOCAL_DIR; do
    base=\$(basename "\$d")
    target_remote_dir="${REMOTE_DIR}/\${base}"
    echo "[\$(date '+%F %T')] 开始同步 \$d → ${REMOTE_NAME}:\$target_remote_dir" >> "\$LOG_FILE"
    rclone sync "\$d" "${REMOTE_NAME}:\$target_remote_dir" -v >> "\$LOG_FILE" 2>&1
    RET=\$?
    if [ \$RET -eq 0 ]; then
        echo "[\$(date '+%F %T')] 同步完成 ✅" >> "\$LOG_FILE"
        send_tg "Rclone 同步完成: \$d → ${REMOTE_NAME}:\$target_remote_dir ✅"
    else
        echo "[\$(date '+%F %T')] 同步失败 ❌" >> "\$LOG_FILE"
        send_tg "⚠️ Rclone 同步失败: \$d → ${REMOTE_NAME}:\$target_remote_dir ❌"
    fi
done
EOF
    chmod +x "$SCRIPT_PATH"
    (crontab -l 2>/dev/null; echo "$cron_expr $SCRIPT_PATH $CRON_PREFIX$TASK_NAME") | crontab -
    echo -e "${GREEN}任务 ${TASK_NAME} 已添加${PLAIN}"
}

schedule_del_one() {
    list_cron
    read -p "删除任务名称: " TASK_NAME
    [ -z "$TASK_NAME" ] && return
    crontab -l 2>/dev/null | grep -v "$CRON_PREFIX$TASK_NAME" | crontab -
    rm -f "/opt/rclone_sync_${TASK_NAME}.sh"
    echo -e "${GREEN}任务 ${TASK_NAME} 已删除${PLAIN}"
}

schedule_del_all() {
    read -p "确认清空所有 Rclone 定时任务? (y/N): " CONFIRM
    [ "$CONFIRM" != "y" ] && return
    crontab -l 2>/dev/null | grep -v "$CRON_PREFIX" | crontab -
    rm -f /opt/rclone_sync_*.sh
    echo -e "${GREEN}所有定时任务已清空${PLAIN}"
}

cron_task_menu() {
    while true; do
        echo -e "${GREEN}=== 定时任务管理 ===${PLAIN}"
        echo -e "${GREEN}------------------------${PLAIN}"
        list_cron
        echo -e "${GREEN}------------------------${PLAIN}"
        echo -e "${GREEN}1. 添加任务${PLAIN}"
        echo -e "${GREEN}2. 删除任务${PLAIN}"
        echo -e "${GREEN}3. 清空全部${PLAIN}"
        echo -e "${GREEN}0. 返回${PLAIN}"
        read -p "选择: " c
        case $c in
            1) schedule_add ;;
            2) schedule_del_one ;;
            3) schedule_del_all ;;
            0) break ;;
            *) echo -e "${RED}❌ 无效选择${PLAIN}" ;;
        esac
        read -p "按回车继续..."
    done
}

# ==================== 主循环 ====================
while true; do
    show_menu
    read -p "$(echo -e ${GREEN}请选择:${PLAIN})" choice
    case $choice in
        1) install_rclone ;;
        2) uninstall_rclone ;;
        3) config_rclone ;;
        4) mount_remote ;;
        5) sync_local_to_remote_multi ;;
        6) sync_remote_to_local ;;
        7) list_files_remote ;;
        8) list_remotes ;;
        9) unmount_remote_by_name ;;
        10) show_mounts ;;
        11) unmount_all ;;
        12) generate_systemd_service ;;
        13) cron_task_menu ;;
        14) update_rclone ;;
        15) generate_systemd_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}" ;;
    esac
    read -r -p "按回车继续..."
done
