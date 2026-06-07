#!/bin/bash
# ========================================
# Rclone 管理脚本
# ========================================

# ================== 颜色 ==================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 全局变量 & 目录配置 ==================
BASE_DIR="/opt/rclone_manager"
LOG_DIR="$BASE_DIR/log"
SCRIPT_DIR="$BASE_DIR/scripts"
CONFIG_FILE="$BASE_DIR/config.env"
CRON_PREFIX="# rclone_sync_task:"

mkdir -p "$LOG_DIR" "$SCRIPT_DIR"

# ================== 载入或初始化配置文件 ==================
init_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<EOF
TG_TOKEN="填入你的默认BotToken"
TG_CHAT_ID="填入你的默认ChatID"
VPS_NAME="未命名VPS"
EOF
    fi
    source "$CONFIG_FILE"
}
init_config

# ================== 动态状态获取 ==================
get_system_status() {
    echo -e "${GREEN}====== 系统实时状态面板 ======${RESET}"
    
    # 1. 检测 Rclone 安装与版本
    if command -v rclone &> /dev/null; then
        local rclone_ver=$(rclone version | head -n 1 | awk '{print $2}')
        echo -e "Rclone 状态: ${GREEN}已安装 (${rclone_ver})${RESET}"
    else
        echo -e "Rclone 状态: ${RED}未安装${RESET}"
    fi

    # 2. 检测已配置的 Remote 数量
    if command -v rclone &> /dev/null; then
        local remote_count=$(rclone listremotes 2>/dev/null | wc -l)
        echo -e "已配置网盘: ${CYAN}${remote_count} 个${RESET}"
    else
        echo -e "已配置网盘: ${YELLOW}----${RESET}"
    fi

    # 3. 检测活跃挂载点 (融合手动后台与 Systemd 挂载)
    local active_mounts=$(mount | grep -i "rclone" | awk '{print $3}')
    if [ -n "$active_mounts" ]; then
        echo -e "活跃挂载点: "
        echo "$active_mounts" | while read -r mnt; do
            echo -e "  ${GREEN}●${RESET} $mnt"
        done
    else
        echo -e "活跃挂载点: ${YELLOW}暂无活跃挂载${RESET}"
    fi

    # 4. 检测定时任务数量
    local cron_count=$(crontab -l 2>/dev/null | grep "$CRON_PREFIX" | wc -l)
    echo -e "同步定时任务: ${CYAN}${cron_count} 个活跃任务${RESET}"

    # 5. 检测 TG 通知配置
    if [[ "$TG_TOKEN" == "填入你的默认BotToken" || -z "$TG_TOKEN" ]]; then
        echo -e "TG 通知状态: ${YELLOW}未配置 (部分功能将缺乏推送)${RESET}"
    else
        echo -e "TG 通知状态: ${GREEN}已启用 (${VPS_NAME})${RESET}"
    fi
    echo -e "${GREEN}======================================${RESET}"
}

# ================== 菜单 ==================
show_menu() {
    clear
    # 首先打印实时状态
    get_system_status
    
    echo -e "${GREEN}====== Rclone 管理菜单 ======${RESET}"
    echo -e "${CYAN} 1)${RESET} 安装 Rclone          ${CYAN} 2)${RESET} 更新 Rclone"
    echo -e "${CYAN} 3)${RESET} 配置 Rclone (config) ${CYAN} 4)${RESET} 查看远程存储列表"
    echo -e "${CYAN} 5)${RESET} 查看远程存储文件"
    echo -e "----------------------------------------"
    echo -e "${GREEN} [挂载管理 (手动后台)]${RESET}"
    echo -e "${CYAN} 6)${RESET} 挂载远程存储到本地   ${CYAN} 7)${RESET} 查看当前挂载详情"
    echo -e "${CYAN} 8)${RESET} 卸载指定挂载点       ${CYAN} 9)${RESET} 卸载所有手动挂载"
    echo -e "----------------------------------------"
    echo -e "${GREEN} [Systemd 守护自动挂载]${RESET}"
    echo -e "${CYAN}10)${RESET} 创建 Systemd 自动挂载 ${CYAN}11)${RESET} 将当前挂载转移至 Systemd"
    echo -e "----------------------------------------"
    echo -e "${GREEN} [数据同步与任务]${RESET}"
    echo -e "${CYAN}12)${RESET} 手动同步 本地 → 远程 ${CYAN}13)${RESET} 手动同步 远程 → 本地"
    echo -e "${CYAN}14)${RESET} 定时任务管理 (Cron)"
    echo -e "----------------------------------------"
    echo -e "${GREEN} [全局设置与常规]${RESET}"
    echo -e "${CYAN}15)${RESET} 修改 TG 通知参数     ${CYAN}16)${RESET} 彻底卸载 Rclone"
    echo -e "${CYAN} 0)${RESET} 退出脚本"
    echo -e "${GREEN}======================================${RESET}"
}

# ================== 基础操作 ==================
install_rclone() {
    echo -e "${YELLOW}正在安装 Rclone...${RESET}"
    curl https://rclone.org/install.sh | sudo bash
    echo -e "${GREEN}Rclone 安装完成！${RESET}"
}

update_rclone() {
    echo -e "${YELLOW}正在更新 Rclone...${RESET}"
    curl https://rclone.org/install.sh | sudo bash
    echo -e "${GREEN}Rclone 已更新完成！${RESET}"
    rclone version
}

config_rclone() { rclone config; }
list_remotes() { rclone listremotes; }

list_files_remote() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && { echo -e "${RED}远程名称不能为空${RESET}"; return; }
    read -p "请输入远程目录(默认 /): " remote_dir
    remote_dir=${remote_dir:-/}
    rclone ls "${remote}:${remote_dir}" || echo -e "${RED}访问失败，请检查名称或权限${RESET}"
}

# ================== TG 参数持久化 ==================
modify_tg() {
    read -p "请输入 TG Bot Token (当前: $TG_TOKEN): " input_token
    read -p "请输入 TG Chat ID (当前: $TG_CHAT_ID): " input_id
    read -p "请输入 VPS 名称 (当前: $VPS_NAME): " input_name

    TG_TOKEN=${input_token:-$TG_TOKEN}
    TG_CHAT_ID=${input_id:-$TG_CHAT_ID}
    VPS_NAME=${input_name:-$VPS_NAME}

    cat > "$CONFIG_FILE" <<EOF
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
VPS_NAME="$VPS_NAME"
EOF
    echo -e "${GREEN}TG 参数已成功保存到本地配置文件！${RESET}"
}

send_tg() {
    local msg="$1"
    source "$CONFIG_FILE"
    if [[ "$TG_TOKEN" != "填入你的默认BotToken" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" -d text="[$VPS_NAME] $msg" >/dev/null
    fi
}

# ================== 挂载管理 (Nohup后台模式) ==================
mount_remote() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && return
    default_path="/mnt/$remote"
    read -p "请输入挂载路径(默认 $default_path): " input_path
    path=${input_path:-$default_path}
    
    mkdir -p "$path"
    if mount | grep -q "on $path type"; then
        echo -e "${YELLOW}路径 $path 已被挂载${RESET}"
        return
    fi

    log="$LOG_DIR/rclone_${remote}.log"
    pidfile="/var/run/rclone_${remote}.pid"
    
    echo -e "${YELLOW}正在后台挂载 $remote → $path...${RESET}"
    nohup rclone mount "${remote}:" "$path" --allow-other --vfs-cache-mode writes --dir-cache-time 1000h &> "$log" &
    echo $! > "$pidfile"
    sleep 1
    if kill -0 $(cat "$pidfile") 2>/dev/null; then
        echo -e "${GREEN}$remote 已成功挂载到 $path，PID: $(cat $pidfile)${RESET}"
    else
        echo -e "${RED}挂载失败，请检查日志: $log${RESET}"
    fi
}

unmount_remote_by_name() {
    read -p "请输入想要卸载的远程名称: " remote
    pidfile="/var/run/rclone_${remote}.pid"
    path="/mnt/$remote"
    
    fusermount -u "$path" 2>/dev/null || umount -l "$path" 2>/dev/null
    if [ -f "$pidfile" ]; then rm -f "$pidfile"; fi
    echo -e "${GREEN}已尝试卸载 $remote 并清理 PID 文件${RESET}"
}

unmount_all() {
    for pidfile in /var/run/rclone_*.pid; do
        [ -f "$pidfile" ] || continue
        remote=$(basename "$pidfile" | sed 's/rclone_//;s/\.pid//')
        path="/mnt/$remote"
        fusermount -u "$path" 2>/dev/null || umount -l "$path" 2>/dev/null
        rm -f "$pidfile"
    done
    # 广义清理所有挂载点
    local active_mounts=$(mount | grep -i "rclone" | awk '{print $3}')
    if [ -n "$active_mounts" ]; then
        echo "$active_mounts" | while read -r mnt; do
            fusermount -u "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null
        done
    fi
    echo -e "${GREEN}所有手动挂载点清理完成。${RESET}"
}

show_mounts() {
    echo -e "${YELLOW}当前完整挂载详情:${RESET}"
    if mount | grep -i "rclone" > /dev/null; then
        mount | grep -i "rclone" | awk '{print CYAN "● " $1 " 挂载在 " GREEN $3 RESET}'
    else
        echo -e "${YELLOW}无活跃挂载。${RESET}"
    fi
}

# ================== Systemd 守护管理 ==================
generate_systemd_service() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && return
    default_path="/mnt/$remote"
    read -p "请输入挂载路径(默认 $default_path): " input_path
    path=${input_path:-$default_path}
    
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
StandardOutput=append:$LOG_DIR/rclone_${remote}_sys.log
StandardError=append:$LOG_DIR/rclone_${remote}_sys.log

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable rclone-mount@${remote}
    sudo systemctl start rclone-mount@${remote}
    echo -e "${GREEN}Systemd 自动挂载服务 [rclone-mount@${remote}] 已启动并开机自启！${RESET}"
}

generate_systemd_all() {
    for pidfile in /var/run/rclone_*.pid; do
        [ -f "$pidfile" ] || continue
        remote=$(basename "$pidfile" | sed 's/rclone_//;s/\.pid//')
        local_pid=$(cat "$pidfile")
        kill "$local_pid" 2>/dev/null
        rm -f "$pidfile"
        
        generate_systemd_service <<< "$remote"
    done
}

# ================== 同步功能 ==================
sync_local_to_remote_multi() {
    read -p "请输入本地目录路径（多个用空格分隔）: " local_dirs
    [ -z "$local_dirs" ] && return
    read -p "请输入远程存储名称: " remote
    [ -z "$remote" ] && return
    read -p "请输入远程目标目录(默认 backup): " remote_dir
    remote_dir=${remote_dir:-backup}

    for d in $local_dirs; do
        if [ ! -d "$d" ]; then
            echo -e "${RED}目录不存在，跳过: $d${RESET}"
            continue
        fi
        name=$(basename "$d")
        target="${remote}:${remote_dir}/${name}"
        LOG_FILE="$LOG_DIR/rclone_sync_${name}.log"

        echo -e "${YELLOW}正在同步: $d → $target ...${RESET}"
        rclone sync "$d" "$target" -v -P 2>&1 | tee -a "$LOG_FILE"

        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo "[ $(date '+%F %T') ] 同步完成 ✅" >> "$LOG_FILE"
            send_tg "Rclone 同步完成: $d → $target ✅"
        else
            echo "[ $(date '+%F %T') ] 同步失败 ❌" >> "$LOG_FILE"
            send_tg "⚠️ Rclone 同步失败: $d → $target ❌"
        fi
    done
}

sync_remote_to_local() {
    read -p "请输入远程名称: " remote
    [ -z "$remote" ] && return
    read -p "请输入远程备份目录 (例如 backup): " remote_dir
    read -p "请输入本地恢复目标目录: " local_dir
    [ -z "$local_dir" ] && return
    
    mkdir -p "$local_dir"
    rclone sync "${remote}:${remote_dir}" "$local_dir" -v -P
}

# ================== 定时任务管理 (Cron) ==================
list_cron() {
    crontab -l 2>/dev/null | grep "$CRON_PREFIX" || echo -e "${YELLOW}暂无关联的定时任务${RESET}"
}

schedule_add() {
    read -p "任务唯一标识名 (英文字母): " TASK_NAME
    read -p "本地同步目录 (多个用空格隔开): " LOCAL_DIR
    read -p "远程存储名称: " REMOTE_NAME
    read -p "远程目标目录 (默认 backup): " REMOTE_DIR
    REMOTE_DIR=${REMOTE_DIR:-backup}

    echo -e "${GREEN}选择执行周期:\n 1. 每天0点\n 2. 每周一0点\n 3. 每月1号0点\n 4. 自定义 Cron 表达式${RESET}"
    read -p "请选择: " t
    case $t in
        1) cron_expr="0 0 * * *" ;;
        2) cron_expr="0 0 * * 1" ;;
        3) cron_expr="0 0 1 * *" ;;
        4) read -p "请输入标准 5 位 Cron 表达式: " cron_expr ;;
        *) echo -e "${RED}❌ 无效选择${RESET}"; return ;;
    esac

    SCRIPT_PATH="$SCRIPT_DIR/rclone_sync_${TASK_NAME}.sh"
    
    cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
CONFIG_FILE="/opt/rclone_manager/config.env"
if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi
EOF

    cat >> "$SCRIPT_PATH" << EOF
LOG_FILE="$LOG_DIR/rclone_sync_${TASK_NAME}.log"

send_tg() {
    if [[ "\$TG_TOKEN" != "填入你的默认BotToken" ]]; then
        curl -s -X POST "https://api.telegram.org/bot\${TG_TOKEN}/sendMessage" \
        -d chat_id="\${TG_CHAT_ID}" -d text="[\${VPS_NAME}] \$1" >/dev/null
    fi
}

for d in $LOCAL_DIR; do
    [ ! -d "\$d" ] && continue
    name=\$(basename "\$d")
    target="${REMOTE_NAME}:${REMOTE_DIR}/\$name"

    rclone sync "\$d" "\$target" -v >> "\$LOG_FILE" 2>&1
    if [ \$? -eq 0 ]; then
        echo "[\$(date '+%F %T')] \$d 同步完成 ✅" >> "\$LOG_FILE"
        send_tg "定时任务 [${TASK_NAME}] 同步成功: \$d ✅"
    else
        echo "[\$(date '+%F %T')] \$d 同步失败 ❌" >> "\$LOG_FILE"
        send_tg "⚠️ 定时任务 [${TASK_NAME}] 同步失败: \$d ❌"
    fi
done
EOF

    chmod +x "$SCRIPT_PATH"
    (crontab -l 2>/dev/null | grep -v "$CRON_PREFIX$TASK_NAME"; echo "$cron_expr $SCRIPT_PATH $CRON_PREFIX$TASK_NAME") | crontab -
    echo -e "${GREEN}定时任务 $TASK_NAME 已成功添加！${RESET}"
}

schedule_del_one() {
    read -p "请输入要删除的任务名称: " TASK_NAME
    crontab -l 2>/dev/null | grep -v "$CRON_PREFIX$TASK_NAME" | crontab -
    rm -f "$SCRIPT_DIR/rclone_sync_${TASK_NAME}.sh"
    echo -e "${GREEN}任务 $TASK_NAME 已被移除${RESET}"
}

schedule_del_all() {
    read -p "确定要清空所有相关定时任务吗? (y/N): " CONFIRM
    [ "$CONFIRM" != "y" ] && return
    crontab -l 2>/dev/null | grep -v "$CRON_PREFIX" | crontab -
    rm -f "$SCRIPT_DIR/rclone_sync_*.sh"
    echo -e "${GREEN}所有相关的定时任务已彻底清理完毕${RESET}"
}

cron_task_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 定时任务管理 (Cron) ===${RESET}"
        list_cron
        echo -e "----------------------------------------"
        echo -e "${CYAN}1.${RESET} 添加新定时任务"
        echo -e "${CYAN}2.${RESET} 删除指定定时任务"
        echo -e "${CYAN}3.${RESET} 清空全部相关任务"
        echo -e "${CYAN}0.${RESET} 返回主菜单"
        echo -e "${GREEN}===========================${RESET}"
        read -p "请选择操作: " c
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

# ================== 卸载全面清理 ==================
uninstall_rclone() {
    read -p "确定要彻底卸载 Rclone 及所有管理配置吗？(y/N): " SECURE_CONFIRM
    [ "$SECURE_CONFIRM" != "y" ] && return

    echo -e "${YELLOW}正在全面清理 Rclone 环境与组件...${RESET}"
    sudo systemctl stop 'rclone-mount@*' 2>/dev/null
    sudo systemctl disable 'rclone-mount@*' 2>/dev/null
    sudo rm -f /etc/systemd/system/rclone-mount@*.service
    sudo systemctl daemon-reload

    crontab -l 2>/dev/null | grep -v "$CRON_PREFIX" | crontab -
    unmount_all

    sudo rm -f /usr/bin/rclone /usr/local/bin/rclone
    sudo rm -rf ~/.config/rclone
    sudo rm -rf "$BASE_DIR"

    echo -e "${GREEN}卸载完成！所有组件、挂载点及系统残留已清理。${RESET}"
    exit 0
}

# ================== 主循环入口 ==================
while true; do
    show_menu
    read -p "$(echo -e ${GREEN}请输入选项数字: ${RESET})" choice
    case $choice in
        1) install_rclone ;;
        2) update_rclone ;;
        3) config_rclone ;;
        4) list_remotes ;;
        5) list_files_remote ;;
        6) mount_remote ;;
        7) show_mounts ;;
        8) unmount_remote_by_name ;;
        9) unmount_all ;;
        10) generate_systemd_service ;;
        11) generate_systemd_all ;;
        12) sync_local_to_remote_multi ;;
        13) sync_remote_to_local ;;
        14) cron_task_menu ;;
        15) modify_tg ;;
        16) uninstall_rclone ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误，请输入菜单中的有效数字！${RESET}" ;;
    esac
    read -r -p "按回车键继续..."
done
