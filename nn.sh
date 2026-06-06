#!/bin/bash

# 系统快照备份工具一体化管理脚本（支持密钥自动复制、安装、卸载、修改配置、状态查询）
# 配置文件位置：/etc/snapshot_config.conf
# 脚本主程序：/usr/local/bin/system_snapshot.sh
# 快捷管理命令：bf

# 颜色设置
RED='\033;0;31m'
GREEN='\033;0;32m'
YELLOW='\033;0;33m'
BLUE='\033;0;34m'
PURPLE='\033;0;35m'
CYAN='\033;0;36m'
NC='\033;0m'

CONFIG_FILE="/etc/snapshot_config.conf"
BACKUP_SCRIPT="/usr/local/bin/system_snapshot.sh"
ADMIN_SCRIPT="/usr/local/bin/snapshot_admin.sh"
SERVICE_NAME="system-snapshot"
LOG_FILE="/var/log/snapshot_install.log"

# 日志与错误处理
log() { echo -e "$1" | tee -a "$LOG_FILE"; }
error_exit() { log "${RED}错误: $1${NC}"; exit 1; }

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误: 请使用 root 权限运行此脚本。${NC}"
    exit 1
fi

# 带有默认值的交互式读取函数
read_with_default() {
    local prompt="$1" local default_value="$2" local var_name="$3" local input_value
    if [ -n "$default_value" ]; then
        read -p "$(echo -e "${prompt} [当前值/默认: ${GREEN}${default_value}${NC}]: ")" input_value
        if [ -z "$input_value" ]; then eval "$var_name=\"\$default_value\""; else eval "$var_name=\"\$input_value\""; fi
    else
        read -p "$(echo -e "${prompt}: ")" input_value
        while [ -z "$input_value" ]; do
            echo -e "${RED}该项不能为空，请输入有效值${NC}"
            read -p "$(echo -e "${prompt}: ")" input_value
        done
        eval "$var_name=\"\$input_value\""
    fi
}

load_config() { if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi; }

draw_header() {
    clear
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${CYAN}          📸  Linux 系统快照备份工具${NC}"
    echo -e "${BLUE}============================================================${NC}"
}

# 显示状态看板
show_status_and_info() {
    load_config
    if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$BACKUP_SCRIPT" ]; then
        echo -e "${YELLOW} 当前工具状态: 系统快照工具 [ 尚未安装 ] 或者是配置不完整。${NC}"
        echo -e "------------------------------------------------------------"
        return 1
    fi
    local timer_active="未激活" local timer_color=$RED
    if systemctl is-active "${SERVICE_NAME}.timer" &>/dev/null; then timer_active="运行中 (Active)"; timer_color=$GREEN; fi
    local last_run="无记录" local next_run="未安排"
    if [ "$timer_color" == "$GREEN" ]; then
        last_run=$(systemctl list-timers "${SERVICE_NAME}.timer" 2>/dev/null | grep "${SERVICE_NAME}" | awk '{print $1" "$2}')
        next_run=$(systemctl list-timers "${SERVICE_NAME}.timer" 2>/dev/null | grep "${SERVICE_NAME}" | awk '{print $3" "$4}')
    fi
    local local_usage="0 MB" local local_count=0
    if [ -d "$BACKUP_DIR" ]; then
        local_count=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "system_snapshot_*.tar.gz" | wc -l)
        local_usage=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
    fi
    echo -e "${PURPLE}[ 自动化运行状态 ]${NC}"
    echo -e " 📅 定时任务状态: ${timer_color}${timer_active}${NC}"
    echo -e " ⏱️ 上次执行时间: ${YELLOW}${last_run:-'暂无数据'}${NC}"
    echo -e " 🚀 下次预计执行: ${GREEN}${next_run:-'暂无数据'}${NC}"
    echo -e " ⏰ 备份间隔天数: 每 ${BACKUP_INTERVAL_DAYS:-'5'} 天自动触发一次"
    echo -e "------------------------------------------------------------"
    echo -e "${PURPLE}[ 核心配置与数据信息 ]${NC}"
    echo -e " 🖥️ 本机标识名称: ${CYAN}${REMOTE_DIR_NAME:-'未配置'}${NC}"
    echo -e " 🌐 远程存储目标: ${CYAN}${TARGET_USER:-'N/A'}@${TARGET_IP:-'N/A'}:${SSH_PORT:-'22'}${NC}"
    echo -e " 📂 远程基础路径: ${CYAN}${TARGET_BASE_DIR:-'未配置'}${NC}"
    echo -e " 💾 本地备份目录: ${CYAN}${BACKUP_DIR:-'/backups'} ${NC}(共 ${GREEN}${local_count}${NC} 个快照, 占用 ${GREEN}${local_usage}${NC})"
    echo -e " 🗄️ 轮转策略留存: 本地 ${YELLOW}${LOCAL_SNAPSHOT_KEEP:-'2'}${NC} 个 | 远程 ${YELLOW}${REMOTE_SNAPSHOT_DAYS:-'15'}${NC} 天"
    echo -e "${BLUE}============================================================${NC}"
    return 0
}

# 检查环境与依赖
check_requirements() {
    for cmd in curl ssh rsync tar hostname ssh-copy-id sshpass; do
        if ! command -v $cmd &> /dev/null; then
            log "${YELLOW}未找到 $cmd，尝试自动安装...${NC}"
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y $cmd || error_exit "无法安装 $cmd"
            elif command -v dnf &> /dev/null; then
                dnf install -y $cmd || error_exit "无法安装 $cmd"
            elif command -v yum &> /dev/null; then
                yum install -y $cmd || error_exit "无法安装 $cmd"
            else
                error_exit "未知的包管理器，请手动安装 $cmd 依赖。"
            fi
        fi
    done
}

# 自动生成并复制密钥至远程服务器
auto_copy_ssh_key() {
    local ip="$1" local user="$2" local port="$3"
    if [ ! -f "/root/.ssh/id_rsa" ]; then
        echo -e "${YELLOW}本地未检测到密钥，正在自动生成 RSA 4096 位密钥对...${NC}"
        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa -q
    fi

    echo -e "\n${YELLOW}🔑 正在进行远程服务器 SSH 免密密钥授信...${NC}"
    ssh -p "$port" -o ConnectTimeout=3 -o PasswordAuthentication=no -o StrictHostKeyChecking=no "$user@$ip" "echo 'OK'" &>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 检测到当前机器与远程服务器已处于免密互信状态，跳过密钥传输。${NC}"
        return 0
    fi

    echo -e "${CYAN}提示: 接下来需要输入一次远程服务器 [ $user@$ip ] 的 SSH 登录密码以完成密钥复制。${NC}"
    read -s -p "请输入远程服务器密码: " REMOTE_PWD
    echo ""

    if [ -z "$REMOTE_PWD" ]; then
        echo -e "${RED}❌ 密码输入为空，放弃自动复制。您稍后可能需要手动建立免密。${NC}"
        return 1
    fi

    echo -e "${YELLOW}正在尝试自动向远程服务器分发公钥...${NC}"
    export SSHPASS="$REMOTE_PWD"
    sshpass -e ssh-copy-id -p "$port" -o StrictHostKeyChecking=no "$user@$ip" &>/dev/null
    local copy_status=$?
    unset SSHPASS

    if [ $copy_status -eq 0 ]; then
        echo -e "${GREEN}✓ 成功！密钥已自动安全复制到远程服务器，免密互信已建立。${NC}"
        return 0
    else
        echo -e "${RED}❌ 密钥自动复制失败。原因可能是密码错误、远程禁止了密码登录或端口不对。${NC}"
        read -p "是否跳过密钥传输继续后面的安装？[y/N]: " SKIP_KEY
        if [[ "$SKIP_KEY" =~ ^[Yy]$ ]]; then return 0; else return 1; fi
    fi
}

# 交互式配置修改/安装
configure_project() {
    load_config
    check_requirements
    
    local is_update=0
    if [ -f "$CONFIG_FILE" ]; then
        is_update=1
        echo -e "${YELLOW}💡 检测到当前已存在配置，进入【修改配置模式】。回车直接保留原当前值：${NC}\n"
    else
        echo -e "${YELLOW}🚀 进入【首次安装配置向导】。请输入以下参数：${NC}\n"
    fi

    echo -e "${YELLOW}📱 Telegram 通知配置:${NC}"
    read_with_default "请输入 Telegram Bot Token" "$BOT_TOKEN" NEW_BOT_TOKEN
    read_with_default "请输入 Telegram Chat ID" "$CHAT_ID" NEW_CHAT_ID
    echo
    
    echo -e "${YELLOW}🌐 远程目标服务器配置:${NC}"
    read_with_default "请输入远程服务器 IP 地址" "$TARGET_IP" NEW_TARGET_IP
    read_with_default "请输入远程服务器用户名" "$TARGET_USER" NEW_TARGET_USER
    read_with_default "请输入 SSH 连接端口" "${SSH_PORT:-22}" NEW_SSH_PORT
    echo
    
    auto_copy_ssh_key "$NEW_TARGET_IP" "$NEW_TARGET_USER" "$NEW_SSH_PORT"
    if [ $? -ne 0 ]; then
        echo -e "${RED}配置终止。${NC}"
        read -p "按任意键返回主菜单..." -n 1
        return
    fi
    echo
    
    echo -e "${YELLOW}📁 远程存储目录路径配置:${NC}"
    read_with_default "请输入远程基础备份目录" "${TARGET_BASE_DIR:-/root/remote_backup}" NEW_TARGET_BASE_DIR
    local current_hostname=$(hostname)
    read_with_default "请输入本机在远程的子目录名" "${REMOTE_DIR_NAME:-$current_hostname}" NEW_REMOTE_DIR_NAME
    local new_full_remote_path="$NEW_TARGET_BASE_DIR/$NEW_REMOTE_DIR_NAME"
    echo
    
    echo -e "${YELLOW}💾 本地存储路径配置:${NC}"
    read_with_default "请输入本地快照落盘目录" "${BACKUP_DIR:-/backups}" NEW_BACKUP_DIR
    echo
    
    echo -e "${YELLOW}🗄️ 备份保留留存策略:${NC}"
    read_with_default "请输入本地最大保留快照数量(个)" "${LOCAL_SNAPSHOT_KEEP:-2}" NEW_LOCAL_SNAPSHOT_KEEP
    read_with_default "请输入远程快照过期删除时间(天)" "${REMOTE_SNAPSHOT_DAYS:-15}" NEW_REMOTE_SNAPSHOT_DAYS
    echo
    
    echo -e "${YELLOW}⏰ 自动化执行周期频率:${NC}"
    read_with_default "请输入备份执行间隔天数(1-30天)" "${BACKUP_INTERVAL_DAYS:-5}" NEW_BACKUP_INTERVAL_DAYS
    while [[ ! "$NEW_BACKUP_INTERVAL_DAYS" =~ ^[1-9]$|^[1-2][0-9]$|^30$ ]]; do
        read_with_default "请输入备份执行间隔天数(1-30天)" "${BACKUP_INTERVAL_DAYS:-5}" NEW_BACKUP_INTERVAL_DAYS
    done
    echo

    # 写入配置文件
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
LOG_FILE="/var/log/snapshot_info.log"
DEBUG_LOG="/var/log/snapshot_debug.log"
EOF
    chmod 600 "$CONFIG_FILE"

    # 生成主快照脚本
    cat > "$BACKUP_SCRIPT" << 'EOF'
#!/bin/bash
if [ -f "/etc/snapshot_config.conf" ]; then source /etc/snapshot_config.conf; else exit 1; fi
TIMESTAMP=$(date +"%Y%m%d%H%M%S")
mkdir -p "$BACKUP_DIR"
SNAPSHOT_FILE="$BACKUP_DIR/system_snapshot_${TIMESTAMP}.tar.gz"
FULL_REMOTE_PATH="$TARGET_BASE_DIR/$REMOTE_DIR_NAME"

log_info() { echo "$(date '+%F %T') [INFO] $1" >> "$LOG_FILE"; }
log_error() { echo "$(date '+%F %T') [ERROR] $1" >> "$LOG_FILE"; }

setup_systemd_timer() {
    cat > "/etc/systemd/system/system-snapshot.service" << EOFSERVICE
[Unit]
Description=System Snapshot Backup Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/system_snapshot.sh
Environment="SYSTEMD_TIMER=1"
WorkingDirectory=/tmp

[Install]
WantedBy=multi-user.target
EOFSERVICE

    cat > "/etc/systemd/system/system-snapshot.timer" << EOFTIMER
[Unit]
Description=Run System Snapshot Every ${BACKUP_INTERVAL_DAYS} Days

[Timer]
OnCalendar=*-*-1/${BACKUP_INTERVAL_DAYS} 00:00:00
RandomizedDelaySec=12h
Persistent=true

[Install]
WantedBy=timers.target
EOFTIMER

    chmod 644 /etc/systemd/system/system-snapshot.*
    systemctl daemon-reload
    systemctl enable "system-snapshot.timer" &>/dev/null
    systemctl restart "system-snapshot.timer" &>/dev/null
}

if [ -z "$SYSTEMD_TIMER" ]; then setup_systemd_timer; fi

curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d text="🔄 开始创建 system_snapshot | 本机: $REMOTE_DIR_NAME" &>/dev/null

tar -czf "$SNAPSHOT_FILE" \
  --exclude="/dev/*" --exclude="/proc/*" --exclude="/sys/*" --exclude="/tmp/*" --exclude="/run/*" \
  --exclude="/mnt/*" --exclude="/media/*" --exclude="/lost+found" --exclude="/var/cache/*" \
  --exclude="/var/tmp/*" --exclude="/var/log/*" --exclude="/var/lib/apt/lists/*" \
  --exclude="/usr/share/doc/*" --exclude="/usr/share/man/*" --exclude="${BACKUP_DIR}/*" --exclude="*.log" \
  --warning=no-file-changed --warning=no-file-ignored \
  /boot /etc /usr /var /root /home /opt /bin /sbin /lib /lib64 > /tmp/snapshot_output.log 2>/tmp/snapshot_error.log

if [ $? -eq 0 ] || [ -s "$SNAPSHOT_FILE" ]; then
    SNAPSHOT_SIZE=$(du -h "$SNAPSHOT_FILE" | cut -f1)
    log_info "系统快照生成成功: $SNAPSHOT_FILE ($SNAPSHOT_SIZE)"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d text="📸 快照创建成功! 大小: $SNAPSHOT_SIZE | 本机: $REMOTE_DIR_NAME" &>/dev/null
    
    ssh -p "$SSH_PORT" -o ConnectTimeout=10 "$TARGET_USER@$TARGET_IP" "mkdir -p $FULL_REMOTE_PATH/system_snapshots" &>/dev/null
    if [ $? -eq 0 ]; then
        rsync -avz --inplace --partial --timeout=60 -e "ssh -p $SSH_PORT" "$SNAPSHOT_FILE" "$TARGET_USER@$TARGET_IP:$FULL_REMOTE_PATH/system_snapshots/" &>/dev/null
        if [ $? -eq 0 ]; then
            curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d text="📤 远程快照同步成功! | 本机: $REMOTE_DIR_NAME" &>/dev/null
            ssh -p "$SSH_PORT" "$TARGET_USER@$TARGET_IP" "find $FULL_REMOTE_PATH/system_snapshots -type f -name '*.tar.gz' -mtime +$REMOTE_SNAPSHOT_DAYS -delete" &>/dev/null
        fi
    fi
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "system_snapshot_*.tar.gz" | sort -r | tail -n +$((LOCAL_SNAPSHOT_KEEP+1)) | xargs -r rm -f
else
    log_error "快照执行失败"
fi
EOF
    chmod +x "$BACKUP_SCRIPT"

    if [ -f "/etc/systemd/system/system-snapshot.timer" ]; then bash "$BACKUP_SCRIPT"; fi
    echo -e "\n${GREEN}✓ 配置成功，定时任务已同步刷新生效！${NC}"
    read -p "按任意键返回主菜单..." -n 1
}

action_manual_backup() {
    if [ ! -f "$BACKUP_SCRIPT" ]; then echo -e "${RED}错误: 请先进行配置再执行此操作。${NC}"; else
        echo -e "\n${YELLOW}正在触发后端快照打包与远程传输进程，请稍候...${NC}"
        bash "$BACKUP_SCRIPT"
        echo -e "${GREEN}✓ 手动执行完结。${NC}"
    fi
    read -p "按任意键返回主菜单..." -n 1
}

action_view_logs() {
    if [ -f "/var/log/snapshot_info.log" ]; then
        echo -e "\n${YELLOW}正在加载最近的 15 条运行日志记录：${NC}"
        tail -n 15 /var/log/snapshot_info.log
    else echo -e "${YELLOW}暂无备份任务的日志流产生。${NC}"; fi
    read -p "按任意键返回主菜单..." -n 1
}

uninstall_project() {
    echo -e "\n${RED}⚠️  警告: 您正在准备完全卸载并清除系统快照备份工具！${NC}"
    read -p "确定要继续吗？[y/N]: " UN_CONFIRM
    if [[ ! "$UN_CONFIRM" =~ ^[Yy]$ ]]; then return; fi
    systemctl stop system-snapshot.timer 2>/dev/null
    systemctl disable system-snapshot.timer 2>/dev/null
    rm -f /etc/systemd/system/system-snapshot.*
    systemctl daemon-reload
    rm -f "$CONFIG_FILE" "$BACKUP_SCRIPT" /usr/bin/snapshot /usr/bin/bf
    echo -e "${GREEN}✓ 工具已成功彻底卸载。${NC}"
    exit 0
}

# 全局环境注册链接维护
ensure_admin_symlink() {
    if [ ! -f "$ADMIN_SCRIPT" ]; then cp "$0" "$ADMIN_SCRIPT" 2>/dev/null; chmod +x "$ADMIN_SCRIPT" 2>/dev/null; fi
    
    # 清除旧可能存在的旧版链接
    if [ -L "/usr/bin/snapshot" ]; then rm -f /usr/bin/snapshot; fi
    
    # 建立全新短指令 bf 的链接
    if [ ! -L "/usr/bin/bf" ]; then ln -sf "$ADMIN_SCRIPT" /usr/bin/bf 2>/dev/null; fi
}

menu_loop() {
    ensure_admin_symlink
    while true; do
        draw_header
        show_status_and_info
        local is_installed=$?
        if [ $is_installed -eq 1 ]; then
            echo -e "  [1] 📥 ${GREEN}首次安装并配置系统快照工具${NC}"
            echo -e "  [5] ❌ 退出管理控制台"
            read -p " 请选择操作编号 [1/5]: " choice
        else
            echo -e "  [1] ⚙️  ${YELLOW}修改核心参数配置${NC}"
            echo -e "  [2] 🚀 立即手动触发执行一次系统快照"
            echo -e "  [3] 📝 查看系统备份日志流明细"
            echo -e "  [4] 🗑️  ${RED}从本机彻底卸载并停用该备份工具${NC}"
            echo -e "  [5] ❌ 退出管理控制台"
            read -p " 请选择操作编号 [1-5]: " choice
        fi
        case $choice in
            1) configure_project ;;
            2) if [ $is_installed -eq 0 ]; then action_manual_backup; fi ;;
            3) if [ $is_installed -eq 0 ]; then action_view_logs; fi ;;
            4) if [ $is_installed -eq 0 ]; then uninstall_project; fi ;;
            5) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

menu_loop
