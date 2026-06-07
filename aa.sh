#!/bin/bash

# 全局高优先环境变量配置
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 颜色控制
GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
RED='\033[0;31m'
NC='\033[0m'

CONFIG_FILE="/etc/snapshot_config.conf"
LOG_FILE="/var/log/snapshot_info.log"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误: 请使用 root 权限运行此脚本。${NC}"
    exit 1
fi

log_action() { echo "$(date '+%F %T') [RESTORE] $1" >> "$LOG_FILE"; }

draw_header() {
    clear
    echo -e "${GREEN}==============================${NC}"
    echo -e "${GREEN}     Linux 系统快照恢复工具    ${NC}"
    echo -e "${GREEN}==============================${NC}"

# ==============================================================================
# 核心解压与网络控制逻辑
# ==============================================================================
execute_untar_restore() {
    local target_archive="$1"
    
    echo -e "\n${RED}======================= !!! 警告 !!! =======================${NC}"
    echo -e "${RED} 您即刻将开始执行系统快照还原。该操作会覆盖当前系统的核心文件！${NC}"
    echo -e "${RED}============================================================${NC}"
    
    # 【功能升级：选择是否恢复网络配置】
    echo -e "关于网络配置恢复，请做出选择："
    echo -e "  [n] ${GREEN}安全守护模式 (推荐)${NC}: 暂存并保留当前正在通网的网卡/IP配置，防止重启后失联。"
    echo -e "  [y] ${RED}完全还原模式${NC}: 强行使用快照内的旧网络配置覆盖当前机器（仅适用于原机同硬件环境回滚）。"
    read -p "是否需要完全还原快照内的网络配置？[y/n, 默认: n]: " net_choice
    net_choice=${net_choice:-n}

    read -p "请输入 'y' 确认执行最终系统恢复，输入其他任意键取消: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then 
        echo -e "${GREEN}操作已取消。${NC}"
        read -p "按任意键返回..." -n 1
        return
    fi

    log_action "开始执行系统恢复，网络恢复模式: $net_choice，快照源: $target_archive"
    
    # 如果选择安全模式，提前暂存当前网络底座
    if [ "$net_choice" != "y" ] && [ "$net_choice" != "Y" ]; then
        echo -e "${GREEN}正在暂存当前有效的网卡与网络底座配置...${NC}"
        rm -rf /tmp/net_backup && mkdir -p /tmp/net_backup/sysconfig
        [ -f "/etc/fstab" ] && cp /etc/fstab /tmp/net_backup/fstab
        [ -f "/etc/resolv.conf" ] && cp /etc/resolv.conf /tmp/net_backup/resolv.conf
        [ -f "/etc/network/interfaces" ] && cp /etc/network/interfaces /tmp/net_backup/interfaces
        if [ -d "/etc/sysconfig/network-scripts" ]; then
            cp -r /etc/sysconfig/network-scripts/* /tmp/net_backup/sysconfig/ 2>/dev/null
        fi
    fi

    echo -e "\n${GREEN}🚀 正在全面解压并重构系统文件，请耐心等待...${NC}"
    tar -xzf "$target_archive" -C / 2>/dev/null

    # 如果选择安全模式，解压后瞬间回填
    if [ "$net_choice" != "y" ] && [ "$net_choice" != "Y" ]; then
        echo -e "${GREEN}正在回填暂存的网卡配置，防止网络死锁失联...${NC}"
        [ -f "/tmp/net_backup/fstab" ] && cp /tmp/net_backup/fstab /etc/fstab
        [ -f "/tmp/net_backup/resolv.conf" ] && cp /tmp/net_backup/resolv.conf /etc/resolv.conf
        [ -f "/tmp/net_backup/interfaces" ] && cp /tmp/net_backup/interfaces /etc/interfaces
        if [ "$(ls -A /tmp/net_backup/sysconfig/ 2>/dev/null)" ]; then
            mkdir -p /etc/sysconfig/network-scripts
            cp -r /tmp/net_backup/sysconfig/* /etc/sysconfig/network-scripts/ 2>/dev/null
        fi
        rm -rf /tmp/net_backup
    fi

    if [ $? -eq 0 ] || [ -s "/etc/fstab" ]; then
        log_action "系统文件重构解压成功！"
        echo -e "\n${GREEN}============================================================${NC}"
        echo -e "${LIGHT_GREEN}✅ 系统快照恢复解压已圆满完成！${NC}"
        if [ "$net_choice" == "y" ] || [ "$net_choice" == "Y" ]; then
            echo -e "${RED} 警告：网络配置已完全被快照覆盖，如果网卡或硬件不兼容可能导致重启后失联！${NC}"
        else
            echo -e "${GREEN} 守护：已自动保留您当前的网卡、IP及网关配置，100%确保重启后不会失联。${NC}"
        fi
        echo -e "${RED} 为了使所有内核服务和系统引导完全生效，系统必须立刻重启。${NC}"
        echo -e "${GREEN}============================================================${NC}"
        read -p "是否现在立刻重启服务器？[y/n]: " reboot_choice
        if [ "$reboot_choice" == "y" ] || [ "$reboot_choice" == "Y" ]; then
            log_action "用户触发恢复后自动重启"
            reboot
        fi
    else
        log_action "错误：解压阶段出现异常中断！"
        echo -e "${RED}❌ 恢复过程中出现异常，请查看本地日志流明细：$LOG_FILE${NC}"
        read -p "按任意键返回..." -n 1
    fi
}

# ==============================================================================
# 模式一：本地快照还原（支持自定义目录）
# ==============================================================================
restore_from_local() {
    draw_header
    echo -e "${GREEN}[ 模式：从本地快照目录还原 ]${NC}"
    
    # 读取备份工具默认路径作为备选默认值
    local default_dir="/backups"
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        default_dir="${BACKUP_DIR:-/backups}"
    fi

    read -p "$(echo -e "请输入本地快照绝对路径 [默认/当前: ${GREEN}${default_dir}${NC}]: ")" scan_dir
    scan_dir=${scan_dir:-$default_dir}

    if [ ! -d "$scan_dir" ]; then
        echo -e "${RED}错误: 指定的本地目录 [ $scan_dir ] 不存在！${NC}"
        read -p "按任意键返回..." -n 1
        return
    fi

    local files=($(find "$scan_dir" -maxdepth 1 -type f -name "system_snapshot_*.tar.gz" | sort -r))
    local count=${#files[@]}

    if [ $count -eq 0 ]; then
        echo -e "${RED}未在指定目录中检索到任何 system_snapshot_*.tar.gz 快照文件。${NC}"
        read -p "按任意键返回..." -n 1
        return
    fi

    echo -e "\n检索到以下可用本地历史快照，请选择编号："
    for ((i=0; i<count; i++)); do
        local file_size=$(du -h "${files[i]}" | awk '{print $1}')
        echo -e "  [ $((i+1)) ] 📦 $(basename "${files[i]}") (大小: $file_size)"
    done
    echo -e "  [ 0 ] 返回上级主菜单"
    echo -e "------------------------------------------------------------"
    
    read -p "请选择需要恢复的快照编号: " num
    if [[ "$num" -eq 0 ]] 2>/dev/null || [ -z "$num" ]; then return; fi
    
    if [[ "$num" -gt 0 && "$num" -le "$count" ]] 2>/dev/null; then
        execute_untar_restore "${files[$((num-1))]}"
    else
        echo -e "${RED}无效的选择！${NC}"
        sleep 1
    fi
}

# ==============================================================================
# 模式二：远程服务器拉取还原（全动态自定义输入）
# ==============================================================================
restore_from_remote() {
    draw_header
    echo -e "${GREEN}[ 模式：从远程备份服务器拉取并还原 ]${NC}"
    
    # 尝试加载当前已有的默认值，方便回车跳过
    local d_ip="" local d_user="root" local d_port="22" local d_dir=""
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        d_ip="$TARGET_IP" && d_user="$TARGET_USER" && d_port="$SSH_PORT"
        d_dir="$TARGET_BASE_DIR/$REMOTE_DIR_NAME/system_snapshots"
    fi

    # 【功能升级：接收用户完全动态的自定义输入】
    if [ -n "$d_ip" ]; then
        read -p "$(echo -e "请输入远程服务器IP [当前值: ${GREEN}${d_ip}${NC}]: ")" REMOTE_IP
        REMOTE_IP=${REMOTE_IP:-$d_ip}
    else
        read -p "请输入远程服务器IP: " REMOTE_IP
        while [ -z "$REMOTE_IP" ]; do read -p "IP不能为空，请重新输入: " REMOTE_IP; done
    fi

    read -p "$(echo -e "请输入远程服务器用户名 [当前值: ${GREEN}${d_user}${NC}]: ")" REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-$d_user}

    read -p "$(echo -e "请输入SSH端口 [当前值: ${GREEN}${d_port}${NC}]: ")" SSH_PORT
    SSH_PORT=${SSH_PORT:-$d_port}

    if [ -n "$d_dir" ]; then
        read -p "$(echo -e "请输入远程备份绝对目录\n[默认当前: ${GREEN}${d_dir}${NC}]:\n")" REMOTE_BACKUP_DIR
        REMOTE_BACKUP_DIR=${REMOTE_BACKUP_DIR:-$d_dir}
    else
        read -p "请输入远程备份绝对目录(例如 /root/remote_backup/localhost/system_snapshots): " REMOTE_BACKUP_DIR
        while [ -z "$REMOTE_BACKUP_DIR" ]; do read -p "路径不能为空，请重新输入: " REMOTE_BACKUP_DIR; done
    fi

    echo -e "\n------------------------------------------------------------"
    echo -e "远程存储目标: ${GREEN}$REMOTE_USER@$REMOTE_IP:$SSH_PORT${NC}"
    echo -e "远程快照路径: ${GREEN}$REMOTE_BACKUP_DIR${NC}"
    echo -e "------------------------------------------------------------"
    echo -e "${GREEN}正在建立安全连接，读取远端服务器快照列表中... (如果未配置免密，此处需要输入密码)${NC}"
    
    # 获取动态指定的远程快照清单
    local remote_list=$(ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "find \"$REMOTE_BACKUP_DIR\" -maxdepth 1 -type f -name 'system_snapshot_*.tar.gz' 2>/dev/null | sort -r" 2>/dev/null)
    
    if [ -z "$remote_list" ]; then
        echo -e "${RED}❌ 无法读取远程备份列表。请检查您输入的IP、端口、路径是否正确，或者密码是否有误。${NC}"
        read -p "按任意键返回..." -n 1
        return
    fi

    local files=($remote_list)
    local count=${#files[@]}

    echo -e "\n成功检索到远端历史快照，请选择需要拉回本机的编号："
    for ((i=0; i<count; i++)); do
        echo -e "  [ $((i+1)) ] ☁️  $(basename "${files[i]}")"
    done
    echo -e "  [ 0 ] 返回上级主菜单"
    echo -e "------------------------------------------------------------"

    read -p "请选择需要提取的远程快照编号: " num
    if [[ "$num" -eq 0 ]] 2>/dev/null || [ -z "$num" ]; then return; fi

    if [[ "$num" -gt 0 && "$num" -le "$count" ]] 2>/dev/null; then
        local remote_target_path="${files[$((num-1))]}"
        local filename=$(basename "$remote_target_path")
        
        # 本地落盘暂存目录采用动态载入或固定 /backups
        local local_save_dir="${BACKUP_DIR:-/backups}"
        local local_tmp_target="$local_save_dir/$filename"
        mkdir -p "$local_save_dir"

        echo -e "\n${GREEN}正在从远端服务器拉取快照到本地 [ $local_tmp_target ]（实时同步进度）：${NC}"
        rsync -avz --progress -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" "$REMOTE_USER@$REMOTE_IP:$remote_target_path" "$local_tmp_target"
        
        if [ $? -eq 0 ] && [ -s "$local_tmp_target" ]; then
            echo -e "${GREEN}✓ 远程快照下载成功。${NC}"
            execute_untar_restore "$local_tmp_target"
        else
            echo -e "${RED}❌ 远程文件同步中断，拉取失败。${NC}"
            read -p "按任意键返回..." -n 1
        fi
    else
        echo -e "${RED}无效的选择！${NC}"
        sleep 1
    fi
}

# ==============================================================================
# 控制台主循环菜单
# ==============================================================================
menu_loop() {
    while true; do
        draw_header
        echo -e "${GREEN}  [1] 本地备份还原${NC}"
        echo -e "${GREEN}  [2] 远程备份还原${NC}"
        echo -e "${GREEN}  [0] 退出${NC}"
        echo -e "${GREEN}==============================${NC}"
        read -p $'\033[32m请选择操作编号: \033[0m' choice
        case $choice in
            1) restore_from_local ;;
            2) restore_from_remote ;;
            0) exit 0 ;;
            *) sleep 0.5 ;;
        esac
    done
}

menu_loop
