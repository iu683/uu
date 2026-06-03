#!/bin/bash
# =========================================================
# 系统清理工具（全面适配 Alpine / Ubuntu / Debian / CentOS）
# =========================================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# =========================================================
# root 检测
# =========================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 权限运行此脚本${RESET}"
    exit 1
fi

# =========================================================
# 健壮性容器检测 (兼容 Alpine / 传统系统)
# =========================================================
check_container() {
    IS_CONTAINER=0
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
        IS_CONTAINER=1
    elif [ -f /proc/1/cgroup ] && grep -qaE '(docker|lxc|kubepods)' /proc/1/cgroup; then
        IS_CONTAINER=1
    elif command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt --quiet; then
            IS_CONTAINER=1
        fi
    fi
}

# =========================================================
# 动态获取当前系统状态
# =========================================================
get_system_status() {
    # 1. 检测容器状态
    check_container
    if [ "$IS_CONTAINER" -eq 1 ]; then
        ENV_STATUS="${YELLOW}容器环境 (🔒 自动跳过内核清理)${RESET}"
    else
        ENV_STATUS="${GREEN}物理机 / 独立VPS${RESET}"
    fi

    # 2. 检测包管理器
    if command -v apk >/dev/null 2>&1; then
        PM_STATUS="APK (Alpine)"
    elif command -v apt >/dev/null 2>&1; then
        PM_STATUS="APT (Debian/Ubuntu)"
    elif command -v dnf >/dev/null 2>&1; then
        PM_STATUS="DNF (RHEL/Fedora)"
    elif command -v yum >/dev/null 2>&1; then
        PM_STATUS="YUM (CentOS)"
    else
        PM_STATUS="${RED}未知/不支持${RESET}"
    fi

    # 3. 获取根分区磁盘占用情况 (兼容 BusyBox df)
    local use_percent=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    # 备用兼容方案：如果有些系统输出在第3行
    [ -z "$use_percent" ] && use_percent=$(df -h / | awk 'END{print $5}' | sed 's/%//')
    
    if [ -z "$use_percent" ]; then
        DISK_STATUS="获取失败"
    elif [ "$use_percent" -lt 60 ]; then
        DISK_STATUS="${GREEN}${use_percent}%已用${RESET}"
    elif [ "$use_percent" -lt 80 ]; then
        DISK_STATUS="${YELLOW}${use_percent}%已用 (建议清理)${RESET}"
    else
        DISK_STATUS="${RED}${use_percent}%已用 (极度紧张!)${RESET}"
    fi
}

# =========================================================
# 等待包管理器锁 (防止脚本冲突)
# =========================================================
wait_for_lock() {
    local cmd=$1
    local lock_file=$2
    if command -v fuser >/dev/null 2>&1; then
        while fuser "$lock_file" >/dev/null 2>&1; do
            echo -e "${YELLOW}等待其他 $cmd 进程释放锁...${RESET}"
            sleep 2
        done
    fi
}

# =========================================================
# 执行系统垃圾清理
# =========================================================
clean_system() {
    echo -e "${YELLOW}正在开始系统垃圾清理...${RESET}"
    export DEBIAN_FRONTEND=noninteractive

    if command -v apk >/dev/null 2>&1; then
        echo -e "${GREEN}[1/2] 正在清理 APK 缓存...${RESET}"
        apk cache clean
        rm -rf /var/cache/apk/*
    elif command -v apt >/dev/null 2>&1; then
        echo -e "${GREEN}[1/2] 正在清理 APT 缓存与孤立包...${RESET}"
        wait_for_lock "APT" /var/lib/dpkg/lock-frontend
        apt update -y
        wait_for_lock "APT" /var/lib/dpkg/lock-frontend
        apt autoremove --purge -y
        apt clean
        apt autoclean
        dpkg -l | awk '/^rc/ {print $2}' | xargs -r apt purge -y
        if [ "$IS_CONTAINER" -eq 0 ]; then
            CURRENT_KERNEL=$(uname -r)
            dpkg --list | awk '/linux-image-[0-9]/ {print $2}' | grep -v "$CURRENT_KERNEL" | xargs -r apt purge -y
        fi
    elif command -v dnf >/dev/null 2>&1; then
        echo -e "${GREEN}[1/2] 正在清理 DNF 垃圾...${RESET}"
        wait_for_lock "DNF" /var/run/dnf.pid
        dnf autoremove -y
        dnf clean all
        if [ "$IS_CONTAINER" -eq 0 ]; then
            dnf remove $(dnf repoquery --installonly --latest-limit=-2 -q) -y 2>/dev/null || true
        fi
    elif command -v yum >/dev/null 2>&1; then
        echo -e "${GREEN}[1/2] 正在清理 YUM 垃圾...${RESET}"
        wait_for_lock "YUM" /var/run/yum.pid
        yum autoremove -y
        yum clean all
        if [ "$IS_CONTAINER" -eq 0 ] && command -v package-cleanup >/dev/null 2>&1; then
            package-cleanup --oldkernels --count=2 -y
        fi
    fi

    # 清理日志
    echo -e "${GREEN}[2/2] 正在清理系统日志...${RESET}"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-time=7d
    else
        # 兼容 Alpine 等无 journalctl 的系统
        find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
        echo -e "${YELLOW}提示: 当前系统未使用 systemd-journald，已对 /var/log/*.log 进行截断清空${RESET}"
    fi

    echo -e "${GREEN}系统垃圾清理完成！${RESET}"
}

# =========================================================
# 执行 Docker 垃圾清理
# =========================================================
clean_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}正在清理 Docker 未使用的镜像、容器与卷...${RESET}"
        docker system prune -af --volumes
        echo -e "${GREEN}Docker 数据清理完成！${RESET}"
    else
        echo -e "${YELLOW}未检测到 Docker 环境，跳过清理${RESET}"
    fi
}

# =========================================================
# 主视觉面板菜单
# =========================================================
system_clean_menu() {
    while true; do
        # 每次循环动态读取系统状态
        get_system_status

        clear
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN}     ◈    Linux 系统清理面板    ◈     ${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN} 当前环境   : ${ENV_STATUS}"
        echo -e "${GREEN} 包管理器   : ${YELLOW}${PM_STATUS}${RESET}"
        echo -e "${GREEN} 磁盘状态   : ${DISK_STATUS}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN}  1. 清理系统垃圾 (缓存/日志/旧包)${RESET}"
        echo -e "${GREEN}  2. 一键全面清理 (系统垃圾 + Docker)${RESET}"
        echo -e "${GREEN}  3. 安装运行定时自动清理任务${RESET}"
        echo -e "${GREEN}  0. 退出面板${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -ne "${GREEN} 请选择操作: ${RESET}"
        
        read -r choice

        case $choice in
            1)
                clean_system
                ;;
            2)
                clean_system
                clean_docker
                ;;
            3)
                echo -e "${YELLOW}正在从远程获取自动清理并执行...${RESET}"
                bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/clean-server.sh) || true
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入...${RESET}"
                sleep 1
                continue
                ;;
        esac

        echo -ne "\n${GREEN}按回车返回面板...${RESET}"
        read -r
    done
}

# 启动菜单
system_clean_menu
