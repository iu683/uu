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

# 获取系统环境名称
if [ -f /etc/os-release ]; then
    OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
else
    OS=$(uname -s)
fi

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
    echo -e "${GREEN}=========== 系统实时状态面板 ==========${RESET}"
    
    if command -v rclone &> /dev/null; then
        local rclone_ver=$(rclone version | head -n 1 | awk '{print $2}')
        echo -e "Rclone 状态: ${GREEN}已安装 (${rclone_ver})${RESET}"
    else
        echo -e "Rclone 状态: ${RED}未安装${RESET}"
    fi

    if command -v rclone &> /dev/null; then
        local remote_count=$(rclone listremotes 2>/dev/null | wc -l)
        echo -e "已配置网盘: ${CYAN}${remote_count} 个${RESET}"
    else
        echo -e "已配置网盘: ${YELLOW}----${RESET}"
    fi

    local active_mounts=$(mount | grep -i "rclone" | awk '{print $3}')
    if [ -n "$active_mounts" ]; then
        echo -e "活跃挂载点: "
        echo "$active_mounts" | while read -r mnt; do
            echo -e "  ${GREEN}●${RESET} $mnt (已开启开机自启)"
        done
    else
        echo -e "活跃挂载点: ${YELLOW}暂无活跃挂载${RESET}"
    fi

    local cron_count=$(crontab -l 2>/dev/null | grep "$CRON_PREFIX" | wc -l)
    echo -e "同步定时任务: ${CYAN}${cron_count} 个活跃任务${RESET}"

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
    get_system_status
    
    echo -e "${GREEN}=========== Rclone 管理菜单 ==========${RESET}"
    echo -e "${CYAN} 1)${RESET} 安装 Rclone          ${CYAN} 2)${RESET} 更新 Rclone"
    echo -e "${CYAN} 3)${RESET} 配置 Rclone (config) ${CYAN} 4)${RESET} 查看远程存储列表"
    echo -e "${CYAN} 5)${RESET} 查看远程存储文件"
    echo -e "----------------------------------------"
    echo -e "${GREEN} [ 挂载管理 (自动配置开机自启) ]${RESET}"
    echo -e "${CYAN} 6)${RESET} 挂载网盘            ${CYAN}  7)${RESET} 查看已创建的资产清单"
    echo -e "${CYAN} 8)${RESET} 卸载指定挂载点       ${CYAN} 9)${RESET} 卸载所有挂载点"
    echo -e "${CYAN}10)${RESET} 查看挂载运行状态     ${CYAN}11)${RESET} 查看挂载实时日志"
    echo -e "----------------------------------------"
    echo -e "${GREEN} [ 数据同步与任务 ]${RESET}"
    echo -e "${CYAN}12)${RESET} 手动同步 本地 → 远程 ${CYAN}13)${RESET} 手动同步 远程 → 本地"
    echo -e "${CYAN}14)${RESET} 定时任务管理 (Cron)"
    echo -e "----------------------------------------"
    echo -e "${GREEN} [ 全局设置与常规 ]${RESET}"
    echo -e "${CYAN}15)${RESET} 修改 TG 通知参数     ${CYAN}16)${RESET} 卸载 Rclone"
    echo -e "${CYAN} 0)${RESET} 退出"
    echo -e "${GREEN}======================================${RESET}"
}

# ================== 基础操作 ==================
install_rclone() {
    echo -e "${YELLOW}正在检测并安装 FUSE 挂载依赖组件...${RESET}"
    
    # 1. 智能识别包管理器并安装 FUSE
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -y
        # 优先安装 fuse3，如果失败则尝试安装 fuse
        sudo apt-get install -y fuse3 || sudo apt-get install -y fuse
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y fuse3 || sudo dnf install -y fuse
    elif command -v yum &> /dev/null; then
        sudo yum install -y fuse3 || sudo yum install -y fuse
    else
        echo -e "${YELLOW}未检测到主流包管理器，请手动确保系统已安装 fuse / fuse3，否则挂载功能可能无法使用。${RESET}"
    fi

    # 2. 验证 FUSE 是否安装成功
    if command -v fusermount3 &> /dev/null || command -v fusermount &> /dev/null; then
        echo -e "${GREEN}FUSE 依赖组件安装/检查成功！${RESET}"
    else
        echo -e "${RED}⚠️ FUSE 依赖安装可能失败，后续网盘挂载功能（Option 6）可能会报错。${RESET}"
    fi

    # 3. 安装 Rclone 本体
    echo -e "${YELLOW}正在安装 Rclone 本体...${RESET}"
    if curl https://rclone.org/install.sh | sudo bash; then
        echo -e "${GREEN}Rclone 安装完成！${RESET}"
    else
        echo -e "${RED}❌ Rclone 本体安装失败，请检查网络连接。${RESET}"
    fi
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
    read -p "请输入Rclone创建的网盘名称: " remote
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


# ================== 智能挂载自启动一体化 ==================
mount_remote() {


    read -p "请输入Rclone创建的网盘名称: " remote
    [ -z "$remote" ] && return
    
    read -p "请输入网盘内的存储桶/子目录 (如 sss): " remote_dir
    
    # 如果用户输入了桶名，自动去掉前后的斜杠
    remote_dir=$(echo "$remote_dir" | sed 's/^\///;s/\/$//')
    
    # 智能生成默认本地路径
    if [ -z "$remote_dir" ]; then
        default_path="/mnt/${remote}"
        local mount_source="${remote}:"
    else
        # 如果有桶名，本地目录名变成 /mnt/CF_sss，更直观
        default_path="/mnt/${remote}_${remote_dir}"
        local mount_source="${remote}:${remote_dir}"
    fi
    
    read -p "请输入VPS本地挂载路径 (默认 $default_path): " input_path
    path=${input_path:-$default_path}
    
    # 1. 检查防冲突与强行清理僵尸挂载
    if mount | grep -q "on $path type"; then
        echo -e "${YELLOW}该本地路径 $path 已经被挂载。正在执行热刷新升级...${RESET}"
        sudo umount -l "$path" 2>/dev/null
    fi

    # 清理可能残留的 PID（新版 Rclone 推荐靠 systemd 管理进程）
    [ -f "/var/run/rclone_${remote}.pid" ] && rm -f "/var/run/rclone_${remote}.pid"

    sudo mkdir -p "$path"
    service_file="/etc/systemd/system/rclone-mount@${remote}.service"
    
    # 2. 写入 Systemd (完美适配 R2 特性参数)
    sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=Rclone Mount ${remote}
After=network-online.target

[Service]
Type=simple
User=root
# 核心参数优化：加入了权限允许、写入缓存
ExecStart=/usr/bin/rclone mount ${mount_source} $path \\
    --allow-other \\
    --vfs-cache-mode full \\
    --vfs-cache-max-age 24h \\
    --vfs-cache-max-size 10G \\
    --buffer-size 64M \\
    --dir-cache-time 1h \\
    --drive-chunk-size 64M
# 使用更强壮的 lazy umount 停止服务，防止卸载时卡死
ExecStop=/usr/bin/umount -l $path
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/rclone_${remote}_sys.log
StandardError=append:$LOG_DIR/rclone_${remote}_sys.log

[Install]
WantedBy=multi-user.target
EOF

    # 3. 启动服务
    sudo systemctl daemon-reload
    sudo systemctl enable rclone-mount@${remote}
    sudo systemctl restart rclone-mount@${remote} # 用 restart 确保应用新配置
    
    echo "正在等待挂载启动..."
    sleep 3
    
    # 4. 验证挂载状态
    if systemctl is-active --quiet "rclone-mount@${remote}"; then
        echo -e "${GREEN}✅ 已成功将网盘 [${mount_source}] 挂载到本地 [${path}]！${RESET}"
        echo -e "${GREEN}ℹ️ 缓存刷新时间设为 1 小时，新文件会在 1 小时内自动同步。${RESET}"
        echo -e "${GREEN}⚙️ 开机自启动守护已妥善配置。可以使用 'df -h' 查看状态。${RESET}"
    else
        echo -e "${RED}❌ 挂载启动失败！${RESET}"
        echo -e "${RED}请运行以下命令查看具体报错日志:${RESET}"
        echo -e "${YELLOW}tail -n 20 $LOG_DIR/rclone_${remote}_sys.log${RESET}"
    fi
}


unmount_remote_by_name() {
    read -p "请输入想要卸载的Rclone创建的网盘名称 (如 CF): " remote
    [ -z "$remote" ] && return
    
    local svc="rclone-mount@${remote}"
    local service_file="/etc/systemd/system/${svc}.service"
    local path=""

    # 核心改进：从现有的 systemd 服务文件中提取真正的本地挂载路径
    if [ -f "$service_file" ]; then
        # 匹配 ExecStart 中最后一个以 / 开头的路径参数
        path=$(grep "ExecStart=" "$service_file" | awk '{print $NF}')
    fi
    
    # 如果没找到服务文件，则降级使用默认猜测路径
    if [ -z "$path" ]; then
        path="/mnt/${remote}"
    fi
    
    # 1. 停止并移除 Systemd 自启守护服务
    if [ -f "$service_file" ] || systemctl list-unit-files | grep -q "^${svc}"; then
        echo -e "${YELLOW}正在停止并移除 [${remote}] 的开机自启动守护服务...${RESET}"
        sudo systemctl stop "$svc" 2>/dev/null
        sudo systemctl disable "$svc" 2>/dev/null
        sudo rm -f "$service_file"
        sudo systemctl daemon-reload
    fi

    # 2. 强行解除本地挂载（优先使用通用的 umount -l，防止死锁）
    echo -e "${YELLOW}正在解除路径 [${path}] 的网络挂载...${RESET}"
    sudo umount -l "$path" 2>/dev/null || sudo fusermount -u "$path" 2>/dev/null
    
    # 3. 清理残留
    [ -f "/var/run/rclone_${remote}.pid" ] && rm -f "/var/run/rclone_${remote}.pid"

    echo -e "${GREEN}✅ 远程存储 ${remote} 卸载完成，本地目录 [${path}] 已释放，自启同步移除！${RESET}"
}

unmount_all() {
    echo -e "${YELLOW}正在全面清空并移除所有网盘挂载与开机自启动...${RESET}"
    
    # 核心改进：直接从配置目录扫描所有 rclone-mount@ 开头的服务文件，不管它当前是运行还是停止
    local sys_services=$(find /etc/systemd/system/ -name "rclone-mount@*.service" -exec basename {} \;)
    
    if [ -n "$sys_services" ]; then
        for svc in $sys_services; do
            echo -e "${CYAN} ➜ 正在彻底清理服务: $svc${RESET}"
            sudo systemctl stop "$svc" 2>/dev/null
            sudo systemctl disable "$svc" 2>/dev/null
            sudo rm -f "/etc/systemd/system/$svc"
        done
        sudo systemctl daemon-reload
    fi

    # 清理所有相关的 PID 文件
    rm -f /var/run/rclone_*.pid

    # 强行拆除所有处于 rclone 类型的挂载点（通过 mount 动态抓取，绝不漏网）
    local active_mounts=$(mount | grep -i "rclone" | awk '{print $3}')
    if [ -n "$active_mounts" ]; then
        echo "$active_mounts" | while read -r mnt; do
            echo -e "${CYAN} ➜ 正在强制卸载僵尸目录: $mnt${RESET}"
            sudo umount -l "$mnt" 2>/dev/null || sudo fusermount -u "$mnt" 2>/dev/null
        done
    fi
    echo -e "${GREEN}✅ 系统内所有 Rclone 挂载及相关自启服务已全部清洗完毕。${RESET}"
}
# ================== 资产清单综合查看面板 ==================
show_assets_manifest() {
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}       📁 Rclone 已创资产名称清单      ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    
    # 1. 扫描已生成的自启动挂载服务
    echo -e "${CYAN}[1] 已创建的自启动挂载服务名字信息：${RESET}"
    local service_files=$(ls /etc/systemd/system/rclone-mount@*.service 2>/dev/null)
    if [ -n "$service_files" ]; then
        echo "$service_files" | while read -r file; do
            # 提取网盘名称
            local r_name=$(basename "$file" | sed 's/rclone-mount@//;s/\.service//')
            # 提取挂载路径
            local m_path=$(grep -E '^ExecStart=' "$file" | awk '{print $4}')
            # 检查当前是否在运行
            if systemctl is-active --quiet "rclone-mount@${r_name}"; then
                local r_status="${GREEN}● 正在运行${RESET}"
            else
                local r_status="${RED}○ 已停止${RESET}"
            fi
            echo -e "  网盘名称: ${YELLOW}${r_name}${RESET}  |  挂载路径: ${YELLOW}${m_path}${RESET}  [${r_status}]"
        done
    else
        echo -e "  ${YELLOW}(暂无通过本脚本创建的挂载服务)${RESET}"
    fi

    echo -e "---------------------------------------"

    # 2. 扫描本脚本生成的 Cron 定时同步任务
    echo -e "${CYAN}[2] 已创建的定时任务(Cron)名字信息：${RESET}"
    local cron_tasks=$(crontab -l 2>/dev/null | grep "$CRON_PREFIX")
    if [ -n "$cron_tasks" ]; then
        echo "$cron_tasks" | while read -r line; do
            # 提取任务唯一标识名
            local task_id=$(echo "$line" | awk -F "$CRON_PREFIX" '{print $2}')
            # 提取运行周期表达式
            local cron_time=$(echo "$line" | awk -F "/opt/rclone_manager" '{print $1}')
            echo -e "  任务名字: ${YELLOW}${task_id}${RESET}  |  执行周期: ${YELLOW}${cron_time}${RESET}"
        done
    else
        echo -e "  ${YELLOW}(暂无通过本脚本创建的定时同步任务)${RESET}"
    fi
    echo -e "${GREEN}=======================================${RESET}"
}

# ================== 状态和日志查看 ==================
view_mount_status() {
    read -p "请输入想要查看状态的Rclone创建网盘名称: " remote
    [ -z "$remote" ] && return
    local svc="rclone-mount@${remote}"
    
    if systemctl list-unit-files | grep -q "^${svc}"; then
        echo -e "${CYAN}--- Systemd 状态服务信息 ---${RESET}"
        sudo systemctl status "$svc"
    else
        echo -e "${RED}未找到该网盘 [${remote}] 对应的挂载守护服务，请确认名称是否正确。${RESET}"
    fi
}

view_mount_logs() {
    read -p "想要查看实时日志，请输入Rclone创建的网盘名称: " remote
    [ -z "$remote" ] && return
    local log_file="$LOG_DIR/rclone_${remote}_sys.log"
    
    if [ -f "$log_file" ]; then
        echo -e "${CYAN}--- 正在读取实时日志 (按 Ctrl+C 退出日志查看模式) ---${RESET}"
        tail -n 50 -f "$log_file"
    else
        echo -e "${RED}未找到对应的日志文件: ${log_file}${RESET}"
    fi
}

# ================== 高级定时任务管理面板 ==================
show_cron_panel() {
    local TASK_COUNT=$(crontab -l 2>/dev/null | grep -v '^\s*#' | grep -vE '^(LANG|LC_ALL|LANGUAGE)=' | grep -v 'run-parts' | grep -v '/etc/periodic' | grep '[^\s]' | wc -l)

    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}        ◈  Cron 定时任务管理面板  ◈      ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 当前系统环境 : ${YELLOW}${OS}${RESET}"
    echo -e "${GREEN} 活跃任务总数 : ${YELLOW}${TASK_COUNT} 条${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN} 📋 当前系统定时任务快照：${RESET}"
    
    if [ "$TASK_COUNT" -gt 0 ]; then
        crontab -l 2>/dev/null | grep -v '^\s*#' | grep -vE '^(LANG|LC_ALL|LANGUAGE)=' | grep -v 'run-parts' | grep -v '/etc/periodic' | grep '[^\s]' | awk -v cyan="$CYAN" -v reset="$RESET" '{print "   " cyan "•" reset " " $0}'
    else
        echo -e "   ${YELLOW}(暂无用户自定义的定时任务)${RESET}"
    fi
    
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  1) 快速添加定时任务(引导式)${RESET}"
    echo -e "${GREEN}  2) 精准删除定时任务(按名称删除)${RESET}"
    echo -e "${GREEN}  3) 深度手动编辑任务(打开编辑器)${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  0) 返回主菜单${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
}

schedule_add() {
    echo -e "${YELLOW}--- 引导式添加 Rclone 同步任务 ---${RESET}"
    read -p "任务唯一标识名 (英文字母): " TASK_NAME
    [ -z "$TASK_NAME" ] && return
    read -p "本地同步目录 (多个用空格隔开): " LOCAL_DIR
    read -p "请输入Rclone创建的网盘名称: " REMOTE_NAME
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
    echo -e "${GREEN}任务 $TASK_NAME 已成功添加并注入 Crontab！${RESET}"
}

schedule_del_one() {
    echo -e "${YELLOW}--- 正在检索本脚本生成的任务... ---${RESET}"
    local count=$(crontab -l 2>/dev/null | grep "$CRON_PREFIX" | wc -l)
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}未发现通过本脚本创建的 Rclone 定时任务。${RESET}"
        return
    fi

    crontab -l 2>/dev/null | grep "$CRON_PREFIX" | awk -F "$CRON_PREFIX" '{print "● 可删除任务名: " $2}'
    echo "---------------------------------------"
    read -p "请输入你想精确删除的任务名称: " TASK_NAME
    [ -z "$TASK_NAME" ] && return

    crontab -l 2>/dev/null | grep -v "$CRON_PREFIX$TASK_NAME" | crontab -
    rm -f "$SCRIPT_DIR/rclone_sync_${TASK_NAME}.sh"
    echo -e "${GREEN}已成功移除任务: $TASK_NAME${RESET}"
}

cron_task_menu() {
    while true; do
        clear
        show_cron_panel
        read -p "$(echo -e ${GREEN}请输入定时任务选项数字: ${RESET})" choice_cron
        echo ""
        case $choice_cron in
            1) schedule_add ;;
            2) schedule_del_one ;;
            3) 
                echo -e "${YELLOW}即将调用系统默认编辑器打开全局 Crontab。${RESET}"
                read -p "按回车键开始编辑..."
                crontab -e 
                ;;
            0) break ;;
            *) echo -e "${RED}❌ 输入错误！${RESET}" ;;
        esac
        read -p "按回车键继续..."
    done
}

# ================== 手动同步功能 ==================
sync_local_to_remote_multi() {
    read -p "请输入本地目录路径（多个用空格分隔）: " local_dirs
    [ -z "$local_dirs" ] && return
    read -p "请输入Rclone创建的网盘名称: " remote
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
    read -p "请输入Rclone创建的网盘名称: " remote
    [ -z "$remote" ] && return
    read -p "请输入远程备份目录 (例如 backup): " remote_dir
    read -p "请输入本地恢复目标目录: " local_dir
    [ -z "$local_dir" ] && return
    
    mkdir -p "$local_dir"
    rclone sync "${remote}:${remote_dir}" "$local_dir" -v -P
}

# ================== 卸载全面清理 ==================
uninstall_rclone() {
    read -p "确定要彻底卸载 Rclone 及所有管理配置吗？(y/N): " SECURE_CONFIRM
    [ "$SECURE_CONFIRM" != "y" ] && return

    echo -e "${YELLOW}正在全面清理 Rclone 环境与组件...${RESET}"
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
        7) show_assets_manifest ;;
        8) unmount_remote_by_name ;;
        9) unmount_all ;;
        10) view_mount_status ;;
        11) view_mount_logs ;;
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
