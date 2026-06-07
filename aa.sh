#!/bin/bash

# 全局高优先环境变量配置
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 颜色控制 - 统一调整为绿色系列
GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
NC='\033[0m'

CONFIG_FILE="/etc/snapshot_config.conf"
SERVICE_NAME="system-snapshot"
LOG_FILE="/var/log/snapshot_info.log"

# 完全固定本地路径与脚本名称
ADMIN_SCRIPT="/usr/bin/snapshot.sh"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${GREEN}错误: 请使用 root 权限运行此脚本。${NC}"
    exit 1
fi

# ==============================================================================
# 绝对首次运行下载逻辑：只要本地有文件，瞬间截断并直接本地运行，绝不重复下载
# ==============================================================================
if [ -f "$ADMIN_SCRIPT" ]; then
    if [ "$(readlink -f "$0" 2>/dev/null)" != "$ADMIN_SCRIPT" ]; then
        exec "$ADMIN_SCRIPT" "$@"
    fi
else
    echo -e "${GREEN}检测到本地固定路径未安装，正在为您首次下载并固化到 ${ADMIN_SCRIPT}...${NC}"
    curl -sL https://raw.githubusercontent.com/iu683/uu/main/aa.sh > "$ADMIN_SCRIPT"
    if [ $? -eq 0 ] && [ -s "$ADMIN_SCRIPT" ]; then
        chmod +x "$ADMIN_SCRIPT"
        hash -r
        echo -e "${GREEN}脚本已成功固化到本地路径！后续直接运行: ${ADMIN_SCRIPT} 即可打开控制台。${NC}"
        echo -e "${GREEN}------------------------------------------------------------${NC}"
        exec "$ADMIN_SCRIPT" "$@"
    else
        echo -e "${GREEN}警告: 自动下载失败，请检查网络是否能正常访问 GitHub。本次将继续尝试在内存流中运行...${NC}"
    fi
fi

# ==============================================================================
# 模块一：后端静默备份与远程传输逻辑
# ==============================================================================
run_backend_backup() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 配置文件不存在，请先运行脚本进行安装与配置。"
        exit 1
    fi
    source "$CONFIG_FILE"
    TIMESTAMP=$(date +"%Y%m%d%H%M%S")
    mkdir -p "$BACKUP_DIR"
    SNAPSHOT_FILE="$BACKUP_DIR/system_snapshot_${TIMESTAMP}.tar.gz"
    FULL_REMOTE_PATH="$TARGET_BASE_DIR/$REMOTE_DIR_NAME"

    touch "$LOG_FILE"
    log_info() { echo "$(date '+%F %T') [INFO] $1" >> "$LOG_FILE"; }
    log_error() { echo "$(date '+%F %T') [ERROR] $1" >> "$LOG_FILE"; }

    log_info "========== 开始执行系统快照备份任务 =========="
    if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d text="开始创建快照 | $REMOTE_DIR_NAME" &>/dev/null
    fi

    # 系统核心打包 (屏蔽无关动态目录及快照自身)
    tar -czf "$SNAPSHOT_FILE" \
      --exclude="/dev/*" --exclude="/proc/*" --exclude="/sys/*" --exclude="/tmp/*" --exclude="/run/*" \
      --exclude="/mnt/*" --exclude="/media/*" --exclude="/lost+found" --exclude="/var/cache/*" \
      --exclude="/var/tmp/*" --exclude="/var/log/*" --exclude="/var/lib/apt/lists/*" \
      --exclude="${BACKUP_DIR}/*" \
      /boot /etc /usr /var /root /home /opt /bin /sbin /lib /lib64 > /dev/null 2>&1

    if [ $? -eq 0 ] || [ -s "$SNAPSHOT_FILE" ]; then
        SNAPSHOT_SIZE=$(du -h "$SNAPSHOT_FILE" | cut -f1)
        log_info "本地快照创建成功，大小: $SNAPSHOT_SIZE"
        
        log_info "正在通过 SSH 自动创建远程多级备份目录结构..."
        ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$TARGET_USER@$TARGET_IP" "mkdir -p \"$FULL_REMOTE_PATH/system_snapshots\"" &>/dev/null
        
        log_info "正在通过 rsync 增量安全传输快照至远程服务器..."
        rsync -avz --inplace --rsync-path="mkdir -p $FULL_REMOTE_PATH/system_snapshots && rsync" -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" "$SNAPSHOT_FILE" "$TARGET_USER@$TARGET_IP:$FULL_REMOTE_PATH/system_snapshots/" &>/dev/null
        
        if [ $? -eq 0 ]; then
            log_info "远程同步成功！文件已安全留存远端。"
            ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "$TARGET_USER@$TARGET_IP" "find \"$FULL_REMOTE_PATH/system_snapshots\" -type f -name '*.tar.gz' -mtime +$REMOTE_SNAPSHOT_DAYS -delete" &>/dev/null
        else
            log_error "远程传输失败！原因：无法连接或没有免密授权"
        fi
        
        find "$BACKUP_DIR" -maxdepth 1 -type f -name "system_snapshot_*.tar.gz" | sort -r | tail -n +$((LOCAL_SNAPSHOT_KEEP+1)) | xargs -r rm -f
        log_info "过期快照轮转清理完毕。"
        
        if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
            curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d text="快照成功: $SNAPSHOT_SIZE | $REMOTE_DIR_NAME" &>/dev/null
        fi
        log_info "========== 快照备份任务顺利结束 =========="
    else
        log_error "快照打包失败！"
    fi
    exit 0
}

# 检测由 systemd 定时器直接触发的后端运行
if [ "$1" == "--backend-run" ]; then
    run_backend_backup
fi

# ==============================================================================
# 模块二：前端交互式菜单与控制台逻辑
# ==============================================================================
read_with_default() {
    local prompt="$1" local default_value="$2" local var_name="$3" local input_value
    if [ -n "$default_value" ]; then
        read -p "$(echo -e "${prompt} [当前值/默认: ${GREEN}${default_value}${NC}]: ")" input_value
        if [ -z "$input_value" ]; then eval "$var_name=\"\$default_value\""; else eval "$var_name=\"\$input_value\""; fi
    else
        read -p "$(echo -e "${prompt}: ")" input_value
        if [ -z "$input_value" ] && [ "$var_name" == "NEW_TARGET_USER" ]; then
            eval "$var_name=\"root\""
        else
            while [ -z "$input_value" ]; do
                echo -e "${GREEN}该项不能为空，请输入有效值${NC}"
                read -p "$(echo -e "${prompt}: ")" input_value
            done
            eval "$var_name=\"\$input_value\""
        fi
    fi
}

load_config() { if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi; }

draw_header() {
    clear
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${LIGHT_GREEN}          Linux 系统快照备份工具 - 一体化控制台${NC}"
    echo -e "${GREEN}============================================================${NC}"
}

show_status_and_info() {
    load_config
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${GREEN}当前工具状态: 系统快照工具 [ 尚未安装 ] 或者是配置不完整。${NC}"
        echo -e "${GREEN}------------------------------------------------------------${NC}"
        return 1
    fi
    local timer_active="未激活"
    if systemctl is-active "${SERVICE_NAME}.timer" &>/dev/null; then timer_active="运行中 (Active)"; fi
    local last_run="无记录" local next_run="未安排"
    if [ "$timer_active" == "运行中 (Active)" ]; then
        last_run=$(systemctl list-timers "${SERVICE_NAME}.timer" 2>/dev/null | grep "${SERVICE_NAME}" | awk '{print $1" "$2}')
        next_run=$(systemctl list-timers "${SERVICE_NAME}.timer" 2>/dev/null | grep "${SERVICE_NAME}" | awk '{print $3" "$4}')
    fi
    local local_usage="0 MB" local local_count=0
    if [ -d "$BACKUP_DIR" ]; then
        local_count=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "system_snapshot_*.tar.gz" | wc -l)
        local_usage=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
    fi
    echo -e "${GREEN}[ 自动化运行状态 ]${NC}"
    echo -e " 定时任务状态: ${GREEN}${timer_active}${NC}"
    echo -e " 上次执行时间: ${GREEN}${last_run:-'暂无数据'}${NC}"
    echo -e " 下次预计执行: ${GREEN}${next_run:-'暂无数据'}${NC}"
    echo -e " 备份间隔天数: 每 ${BACKUP_INTERVAL_DAYS:-'5'} 天自动触发一次"
    echo -e "${GREEN}------------------------------------------------------------${NC}"
    echo -e "${GREEN}[ 核心配置与数据信息 ]${NC}"
    echo -e " 本机标识名称: ${GREEN}${REMOTE_DIR_NAME:-'未配置'}${NC}"
    echo -e " 远程存储目标: ${GREEN}${TARGET_USER:-'N/A'}@${TARGET_IP:-'N/A'}:${SSH_PORT:-'22'}${NC}"
    echo -e " 远程基础路径: ${GREEN}${TARGET_BASE_DIR:-'未配置'}${NC}"
    echo -e " 本地备份目录: ${GREEN}${BACKUP_DIR:-'/backups'} ${NC}(共 ${GREEN}${local_count}${NC} 个快照, 占用 ${GREEN}${local_usage}${NC})"
    echo -e " 轮转策略留存: 本地 ${GREEN}${LOCAL_SNAPSHOT_KEEP:-'2'}${NC} 个 | 远程 ${GREEN}${REMOTE_SNAPSHOT_DAYS:-'15'}${NC} 天"
    echo -e "${GREEN}============================================================${NC}"
    return 0
}

check_requirements() {
    for cmd in curl ssh rsync tar hostname; do
        if ! command -v $cmd &> /dev/null; then
            if command -v apt-get &> /dev/null; then apt-get update && apt-get install -y $cmd &>/dev/null
            elif command -v dnf &> /dev/null; then dnf install -y $cmd &>/dev/null
            elif command -v yum &> /dev/null; then yum install -y $cmd &>/dev/null
            fi
        fi
    done
}

auto_copy_ssh_key() {
    local ip="$1" local user="$2" local port="$3"
    local LOCAL_KEY="/root/.ssh/id_rsa.pub"

    # 检查并生成本地公钥
    if [ ! -f "$LOCAL_KEY" ]; then
        echo -e "${GREEN}未检测到本地公钥，正在生成新的 SSH 密钥对...${NC}"
        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q
        if [ $? -ne 0 ]; then
            echo -e "${GREEN}❌ 密钥生成失败，请检查 ssh-keygen 是否可用${NC}"
            return 1
        fi
        echo -e "${GREEN}✅ SSH 密钥生成完成: $LOCAL_KEY${NC}"
    else
        echo -e "${GREEN}✅ 已检测到本地公钥: $LOCAL_KEY${NC}"
    fi

    local PUBKEY_CONTENT=$(cat "$LOCAL_KEY")

    echo -e "${GREEN}⚠️ 第一次连接需要手动输入远程服务器密码进行鉴权操作${NC}"

    # 一次性远程执行：创建目录 -> 追加入公钥 -> 全局去重 -> 修复权限
    ssh -p "$port" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$user@$ip" "bash -s" <<EOF
        # 创建并保护 .ssh 目录
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys
        
        # 备份原始文件
        cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak

        # 先将新公钥追加到备份文件中（如果不存在的话）
        if ! grep -Fxq "$PUBKEY_CONTENT" ~/.ssh/authorized_keys.bak; then
            echo "$PUBKEY_CONTENT" >> ~/.ssh/authorized_keys.bak
        fi

        # 利用 awk 对包含新公钥的文件进行全局去重，并写回正式文件
        awk '!seen[\$0]++' ~/.ssh/authorized_keys.bak > ~/.ssh/authorized_keys
        rm -f ~/.ssh/authorized_keys.bak

        # 严格修复权限
        chmod 600 ~/.ssh/authorized_keys
        chown \$(whoami):\$(id -gn) ~/.ssh ~/.ssh/authorized_keys
        
        echo "远程免密互信写入配置完成。"
EOF

    if [ $? -ne 0 ]; then
        echo -e "${GREEN}❌ 远程操作失败，请检查网络连接、密码或端口是否正确。${NC}"
        return 1
    fi

    # 【新增强阻断确认】：尝试以无密码、短超时方式，直接读取远程公钥现状
    echo -e "\n${GREEN}📂 正在验证远程免密读取通道状态...${NC}"
    local verify_check=$(ssh -p "$port" -o ConnectTimeout=5 -o PasswordAuthentication=no -o StrictHostKeyChecking=no "$user@$ip" "cat ~/.ssh/authorized_keys" 2>/dev/null)
    
    if [ -n "$verify_check" ]; then
        echo -e "${GREEN}✅ 密钥同步结果最终验证通过！免密安全互信已成功建立。${NC}"
        return 0
    else
        echo -e "${GREEN}❌ 强校验错误: 密钥虽已传输，但当前机器仍无法进行免密登录，请检查远端 SSHD 权限配置。${NC}"
        return 1
    fi
}

setup_systemd_timer() {
cat > "/etc/systemd/system/system-snapshot.service" << EOFSERVICE
[Unit]
Description=System Snapshot Backup Service
After=network.target

[Service]
Type=oneshot
ExecStart=$ADMIN_SCRIPT --backend-run
WorkingDirectory=/tmp
EOFSERVICE

cat > "/etc/systemd/system/system-snapshot.timer" << EOFTIMER
[Unit]
Description=Run System Snapshot Every ${NEW_BACKUP_INTERVAL_DAYS} Days

[Timer]
OnCalendar=*-*-1/${NEW_BACKUP_INTERVAL_DAYS} 00:00:00
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOFTIMER

    chmod 644 /etc/systemd/system/system-snapshot.*
    systemctl daemon-reload
    systemctl enable "system-snapshot.timer" &>/dev/null
    systemctl restart "system-snapshot.timer" &>/dev/null
}

configure_project() {
    load_config
    check_requirements
    if [ -f "$CONFIG_FILE" ]; then echo -e "${GREEN}进入修改配置模式。回车直接保留原当前值：${NC}\n"
    else echo -e "${GREEN}进入首次安装配置向导。请输入以下参数：${NC}\n"; fi

    read_with_default "请输入 Telegram Bot Token" "$BOT_TOKEN" NEW_BOT_TOKEN
    read_with_default "请输入 Telegram Chat ID" "$CHAT_ID" NEW_CHAT_ID
    echo
    read_with_default "请输入远程服务器 IP 地址" "$TARGET_IP" NEW_TARGET_IP
    read_with_default "请输入远程服务器用户名 (默认: root)" "${TARGET_USER:-root}" NEW_TARGET_USER
    read_with_default "请输入 SSH 连接端口" "${SSH_PORT:-22}" NEW_SSH_PORT
    echo
    
    # 强阻断校验：如果密钥复制或免密读取验证未通过，不允许保存配置，直接退回主菜单
    auto_copy_ssh_key "$NEW_TARGET_IP" "$NEW_TARGET_USER" "$NEW_SSH_PORT"
    if [ $? -ne 0 ]; then
        echo -e "\n${GREEN}由于免密授权未真正生效，配置流程已强行中断，未写入任何更改。${NC}"
        echo -e "${GREEN}请确保远程服务器网络畅通、端口及密码正确后重新尝试。${NC}"
        read -p "按任意键返回主菜单..." -n 1
        return 1
    fi
    echo
    
    read_with_default "请输入远程基础备份目录" "${TARGET_BASE_DIR:-/root/remote_backup}" NEW_TARGET_BASE_DIR
    local current_hostname=$(hostname)
    read_with_default "请输入本机在远程的子目录名" "${REMOTE_DIR_NAME:-$current_hostname}" NEW_REMOTE_DIR_NAME
    echo
    read_with_default "请输入本地快照落盘目录" "${BACKUP_DIR:-/backups}" NEW_BACKUP_DIR
    echo
    read_with_default "请输入本地最大保留快照数量(个)" "${LOCAL_SNAPSHOT_KEEP:-2}" NEW_LOCAL_SNAPSHOT_KEEP
    read_with_default "请输入远程快照过期删除时间(天)" "${REMOTE_SNAPSHOT_DAYS:-15}" NEW_REMOTE_SNAPSHOT_DAYS
    echo
    read_with_default "请输入备份执行间隔天数(1-30天)" "${BACKUP_INTERVAL_DAYS:-5}" NEW_BACKUP_INTERVAL_DAYS
    
    mkdir -p "$NEW_BACKUP_DIR"
    cat > "$CONFIG_FILE" << EOF
#!/bin/bash
BOT_TOKEN="$NEW_BOT_TOKEN"
CHAT_ID="$NEW_CHAT_ID"
TARGET_IP="$NEW_TARGET_IP"
TARGET_USER="$NEW_TARGET_USER"
SSH_PORT="$NEW_SSH_PORT"
TARGET_BASE_DIR="$NEW_TARGET_BASE_DIR"
REMOTE_DIR_NAME="$NEW_REMOTE_DIR_NAME"
BACKUP_DIR="$NEW_BACKUP_DIR"
LOCAL_SNAPSHOT_KEEP=$NEW_LOCAL_SNAPSHOT_KEEP
REMOTE_SNAPSHOT_DAYS=$NEW_REMOTE_SNAPSHOT_DAYS
BACKUP_INTERVAL_DAYS=$NEW_BACKUP_INTERVAL_DAYS
EOF
    chmod 600 "$CONFIG_FILE"
    
    # 建立自动化定时器
    setup_systemd_timer
    
    echo -e "\n${GREEN}✓ 全新配置和 Systemd 自动化定时任务已同步刷新并生效！${NC}"
    read -p "按任意键返回主菜单..." -n 1
}

action_manual_backup() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${GREEN}错误: 请先进行配置再执行此操作。${NC}"; else
        echo -e "\n${GREEN}正在触发后端快照打包与多级远程传输进程，请稍候...${NC}"
        $ADMIN_SCRIPT --backend-run
        echo -e "${GREEN}✓ 手动执行完结。${NC}"
    fi
    read -p "按任意键返回主菜单..." -n 1
}

action_view_logs() {
    if [ -f "$LOG_FILE" ]; then 
        echo -e "\n${GREEN}正在加载最近的 15 条备份流日志：${NC}"
        tail -n 15 "$LOG_FILE"
    else echo -e "${GREEN}暂无备份任务的日志流产生。${NC}"; fi
    read -p "按任意键返回主菜单..." -n 1
}

uninstall_project() {
    systemctl stop system-snapshot.timer 2>/dev/null
    systemctl disable system-snapshot.timer 2>/dev/null
    rm -f /etc/systemd/system/system-snapshot.*
    systemctl daemon-reload
    rm -f "$CONFIG_FILE" "$ADMIN_SCRIPT"
    echo -e "${GREEN}✓ 快照工具及定时任务已从本机完全干净卸载。${NC}"
    exit 0
}

menu_loop() {
    while true; do
        draw_header
        show_status_and_info
        echo -e "  [1] 安装或修改核心参数配置"
        echo -e "  [2] 立即手动触发执行一次系统快照"
        echo -e "  [3] 查看系统备份日志流明细"
        echo -e "  [4] 从本机彻底卸载该备份工具"
        echo -e "  [5] 退出管理控制台"
        read -p " 请选择操作编号 [1-5]: " choice
        case $choice in
            1) configure_project ;;
            2) action_manual_backup ;;
            3) action_view_logs ;;
            4) uninstall_project ;;
            5) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

menu_loop
