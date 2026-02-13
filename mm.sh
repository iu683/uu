#!/bin/bash
# ========================================
# Rclone 管理脚本 (全功能整合版)
# ========================================

# ================== 颜色 ==================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 全局变量 ==================
BASE_DIR="/opt/rclone_manager"
LOG_DIR="$BASE_DIR/log"
SCRIPT_DIR="$BASE_DIR/scripts"
mkdir -p "$LOG_DIR" "$SCRIPT_DIR"

TG_TOKEN="填入你的默认BotToken"
TG_CHAT_ID="填入你的默认ChatID"
VPS_NAME="未命名VPS"

REMOTE_SCRIPT_PATH="$BASE_DIR/remote_rclone.sh"
CRON_PREFIX="# rclone_sync_task:"

# ================== 首次运行下载远程脚本 ==================
if [[ ! -f "$REMOTE_SCRIPT_PATH" ]]; then
    echo -e "${CYAN}📥 首次运行，下载远程脚本...${RESET}"
    curl -fsSL "https://raw.githubusercontent.com/iu683/uu/main/zz.sh" -o "$REMOTE_SCRIPT_PATH"
    chmod +x "$REMOTE_SCRIPT_PATH"
    echo -e "${GREEN}✅ 远程脚本已下载到 $REMOTE_SCRIPT_PATH${RESET}"
    exec "$REMOTE_SCRIPT_PATH"
fi

# ================== 菜单 ==================
show_menu() {
    clear
    echo -e "${GREEN}====== Rclone 管理菜单 ======${RESET}"
    echo -e "${GREEN} 1. 安装 Rclone${RESET}"
    echo -e "${GREEN} 2. 更新 Rclone${RESET}"
    echo -e "${GREEN} 3. 配置 Rclone${RESET}"
    echo -e "${GREEN} 4. 挂载远程存储到本地${RESET}"
    echo -e "${GREEN} 5. 同步 本地 → 远程${RESET}"
    echo -e "${GREEN} 6. 同步 远程 → 本地${RESET}"
    echo -e "${GREEN} 7. 查看远程存储文件${RESET}"
    echo -e "${GREEN} 8. 查看远程存储列表${RESET}"
    echo -e "${GREEN} 9. 卸载挂载点${RESET}"
    echo -e "${GREEN}10. 查看当前挂载点${RESET}"
    echo -e "${GREEN}11. 卸载所有挂载点${RESET}"
    echo -e "${GREEN}12. systemd 自动挂载${RESET}"
    echo -e "${GREEN}13. 自动生成多挂载 systemd${RESET}"
    echo -e "${GREEN}14. 定时任务管理${RESET}"
    echo -e "${GREEN}15. 修改 TG 参数${RESET}"
    echo -e "${GREEN}16. 卸载 Rclone${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
}

# ================== 安装/更新/卸载 ==================
install_rclone() {
    echo -e "${YELLOW}正在安装 Rclone...${RESET}"
    sudo -v
    curl https://rclone.org/install.sh | sudo bash
    echo -e "${GREEN}Rclone 安装完成！${RESET}"
}

update_rclone() {
    echo -e "${YELLOW}正在更新 Rclone...${RESET}"
    sudo -v
    curl https://rclone.org/install.sh | sudo bash
    echo -e "${GREEN}Rclone 已更新完成！${RESET}"
    rclone version
}

uninstall_rclone() {

    echo -e "${YELLOW}正在彻底卸载 Rclone + 所有组件...${RESET}"

    #################################
    # 1️⃣ 停止 systemd 服务
    #################################
    sudo systemctl stop 'rclone-mount@*' 2>/dev/null
    sudo systemctl disable 'rclone-mount@*' 2>/dev/null

    #################################
    # 2️⃣ 删除二进制
    #################################
    sudo rm -f /usr/bin/rclone /usr/local/bin/rclone

    #################################
    # 3️⃣ 删除 systemd 服务文件
    #################################
    sudo rm -f /etc/systemd/system/rclone-mount@*.service
    sudo systemctl daemon-reload

    #################################
    # 4️⃣ 删除运行文件

config_rclone() { rclone config; }
list_remotes() { rclone listremotes; }

list_files_remote() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && { echo -e "${RED}远程名称不能为空${RESET}"; return; }
    read -p "请输入远程目录(默认 /): " remote_dir
    remote_dir=${remote_dir:-/}
    rclone ls "${remote}:${remote_dir}" || echo -e "${RED}访问失败，请检查权限${RESET}"
}

# ================== TG 参数 ==================
modify_tg() {
    read -p "请输入 TG Bot Token: " TG_TOKEN
    read -p "请输入 TG Chat ID: " TG_CHAT_ID
    read -p "请输入 VPS 名称: " VPS_NAME
    [ -z "$VPS_NAME" ] && VPS_NAME="未命名VPS"
    echo -e "${GREEN}TG 参数已更新${RESET}"
}

send_tg() {
    local msg="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" -d text="[$VPS_NAME] $msg" >/dev/null
}

# ================== 挂载 ==================
mount_remote() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && return
    path="/mnt/$remote"
    read -p "请输入挂载路径(默认 $path): " input_path
    path=${input_path:-$path}
    mkdir -p "$path"
    if mount | grep -q "on $path type"; then
        echo -e "${YELLOW}$remote 已挂载${RESET}"
        return
    fi
    log="$LOG_DIR/rclone_${remote}.log"
    pidfile="/var/run/rclone_${remote}.pid"
    echo -e "${YELLOW}挂载 $remote → $path${RESET}"
    nohup rclone mount "${remote}:" "$path" --allow-other --vfs-cache-mode writes --dir-cache-time 1000h &> "$log" &
    echo $! > "$pidfile"
    echo -e "${GREEN}$remote 已挂载，PID: $(cat $pidfile)${RESET}"
}

unmount_remote_by_name() {
    read -p "请输入远程名称: " remote
    pidfile="/var/run/rclone_${remote}.pid"
    path="/mnt/$remote"
    if [ -f "$pidfile" ]; then
        fusermount -u "$path" 2>/dev/null || umount "$path" 2>/dev/null
        rm -f "$pidfile"
        echo -e "${GREEN}已卸载 $remote${RESET}"
    else
        echo -e "${RED}PID 文件不存在${RESET}"
    fi
}

unmount_all() {
    for pidfile in /var/run/rclone_*.pid; do
        [ -f "$pidfile" ] || continue
        remote=$(basename "$pidfile" | sed 's/rclone_//;s/\.pid//')
        path="/mnt/$remote"
        fusermount -u "$path" 2>/dev/null || umount "$path" 2>/dev/null
        rm -f "$pidfile"
        echo -e "${GREEN}已卸载 $remote${RESET}"
    done
}

show_mounts() {
    echo -e "${YELLOW}当前挂载点:${RESET}"
    for pidfile in /var/run/rclone_*.pid; do
        [ -f "$pidfile" ] || continue
        remote=$(basename "$pidfile" | sed 's/rclone_//;s/\.pid//')
        path="/mnt/$remote"
        mount | grep -q "$path" && echo -e "${GREEN}$remote → $path${RESET}" || echo -e "${RED}$remote PID存在，但未挂载${RESET}"
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
StandardOutput=append:$LOG_DIR/rclone_${remote}.log
StandardError=append:$LOG_DIR/rclone_${remote}.log

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable rclone-mount@${remote}
    sudo systemctl start rclone-mount@${remote}
    echo -e "${GREEN}Systemd 挂载服务已生成并启动${RESET}"
}

generate_systemd_all() {
    for pidfile in /var/run/rclone_*.pid; do
        [ -f "$pidfile" ] || continue
        remote=$(basename "$pidfile" | sed 's/rclone_//;s/\.pid//')
        path="/mnt/$remote"
        service_file="/etc/systemd/system/rclone-mount@${remote}.service"
        [ -f "$service_file" ] && { echo -e "${GREEN}$remote systemd 已存在，跳过${RESET}"; continue; }
        generate_systemd_service <<<"$remote"
    done
    echo -e "${GREEN}所有挂载点 systemd 服务生成完成${RESET}"
}

# ================== 多目录同步 ==================
sync_local_to_remote_multi() {
    read -p "请输入本地目录，用空格分隔: " local_dirs
    [ -z "$local_dirs" ] && return
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && return
    read -p "请输入远程目录(默认 backup): " remote_dir
    remote_dir=${remote_dir:-backup}

    for d in $local_dirs; do
        [ ! -d "$d" ] && { echo -e "${RED}目录不存在: $d${RESET}"; continue; }

        name=$(basename "$d")
        target="${remote}:${remote_dir}/${name}"

        LOG_FILE="$LOG_DIR/rclone_sync_${name}.log"

        echo -e "${YELLOW}同步 $d → $target${RESET}"

        rclone sync "$d" "$target" -v -P >> "$LOG_FILE" 2>&1

        RET=$?
        if [ $RET -eq 0 ]; then
            echo "[ $(date '+%F %T') ] 同步完成 ✅" >> "$LOG_FILE"
            send_tg "Rclone 同步完成: $d → ${remote}:${remote_dir} ✅"
        else
            echo "[ $(date '+%F %T') ] 同步失败 ❌" >> "$LOG_FILE"
            send_tg "⚠️ Rclone 同步失败: $d → ${remote}:${remote_dir} ❌"
        fi
    done
}

sync_remote_to_local() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && return
    read -p "请输入本地目录: " local
    [ -z "$local" ] && return
    read -p "请输入远程目录(默认 backup): " remote_dir
    remote_dir=${remote_dir:-backup}
    rclone sync "${remote}:${remote_dir}" "$local" -v -P
}

# ================== 定时任务 ==================
list_cron() {
    crontab -l 2>/dev/null | grep "$CRON_PREFIX" || echo -e "${YELLOW}暂无定时任务${RESET}"
}

schedule_add() {
    read -p "任务名: " TASK_NAME
    read -p "本地目录(空格分隔): " LOCAL_DIR
    read -p "远程名称: " REMOTE_NAME
    read -p "远程目录(默认 backup): " REMOTE_DIR
    REMOTE_DIR=${REMOTE_DIR:-backup}

    echo -e "${GREEN}1. 每天0点  2. 每周一0点  3. 每月1号0点  4. 自定义 cron${RESET}"
    read -p "选择: " t
    case $t in
        1) cron_expr="0 0 * * *" ;;
        2) cron_expr="0 0 * * 1" ;;
        3) cron_expr="0 0 1 * *" ;;
        4) read -p "请输入自定义 cron 表达式: " cron_expr ;;
        *) echo -e "${RED}❌ 无效选择${RESET}"; return ;;
    esac

    SCRIPT_PATH="$SCRIPT_DIR/rclone_sync_${TASK_NAME}.sh"
    cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
LOG_FILE="$LOG_DIR/rclone_sync_${TASK_NAME}.log"
send_tg() {
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" -d chat_id="${TG_CHAT_ID}" -d text="\$1" >/dev/null
}
for d in $LOCAL_DIR; do
    name=\$(basename "\$d")
    target="${REMOTE_NAME}:${REMOTE_DIR}/\$name"

    rclone sync "\$d" "\$target" -v >> "\$LOG_FILE" 2>&1

    RET=\$?
    if [ \$RET -eq 0 ]; then
        echo "[\$(date '+%F %T')] 同步完成 ✅" >> "\$LOG_FILE"
        send_tg "Rclone 同步完成: \$d → ${REMOTE_NAME}:${REMOTE_DIR} ✅"
    else
        echo "[\$(date '+%F %T')] 同步失败 ❌" >> "\$LOG_FILE"
        send_tg "⚠️ Rclone 同步失败: \$d → ${REMOTE_NAME}:${REMOTE_DIR} ❌"
    fi
done
EOF
    chmod +x "$SCRIPT_PATH"
    (crontab -l 2>/dev/null; echo "$cron_expr $SCRIPT_PATH $CRON_PREFIX$TASK_NAME") | crontab -
    echo -e "${GREEN}任务 $TASK_NAME 已添加${RESET}"
}

schedule_del_one() {
    list_cron
    read -p "删除任务名称: " TASK_NAME
    crontab -l 2>/dev/null | grep -v "$CRON_PREFIX$TASK_NAME" | crontab -
    rm -f "$SCRIPT_DIR/rclone_sync_${TASK_NAME}.sh"
    echo -e "${GREEN}任务 $TASK_NAME 已删除${RESET}"
}

schedule_del_all() {
    read -p "确认清空所有 Rclone 定时任务? (y/N): " CONFIRM
    [ "$CONFIRM" != "y" ] && return
    crontab -l 2>/dev/null | grep -v "$CRON_PREFIX" | crontab -
    rm -f "$SCRIPT_DIR/rclone_sync_*.sh"
    echo -e "${GREEN}所有定时任务已清空${RESET}"
}

cron_task_menu() {
    while true; do
        echo -e "${GREEN}=== 定时任务管理 ===${RESET}"
        list_cron
        echo -e "${GREEN}1. 添加任务  2. 删除任务  3. 清空全部  0. 返回${RESET}"
        read -p "选择: " c
        case $c in
            1) schedule_add ;;
            2) schedule_del_one ;;
            3) schedule_del_all ;;
            0) break ;;
            *) echo -e "${RED}❌ 无效选择${RESET}" ;;
        esac
        read -p "按回车继续..."
    done
}

# ================== 主循环 ==================
while true; do
    show_menu
    read -p "请选择: " choice
    case $choice in
        1) install_rclone ;;
        2) update_rclone ;;
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
        13) generate_systemd_all ;;
        14) cron_task_menu ;;
        15) modify_tg ;;
        16) uninstall_rclone ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    read -r -p "按回车继续..."
done
