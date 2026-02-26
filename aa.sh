#!/bin/bash
# =========================================
# 企业级系统清理脚本（兼容容器 + Docker + 自动处理 GRUB）
# =========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 必须 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本！${RESET}"
    exit 1
fi

# 等待 apt/dnf/yum 锁
wait_for_lock() {
    local cmd=$1
    local lock_file=$2
    while fuser $lock_file >/dev/null 2>&1; do
        echo -e "${YELLOW}等待其他 $cmd 进程完成...${RESET}"
        sleep 2
    done
}

# 检查容器环境
IS_CONTAINER=0
if systemd-detect-virt --quiet; then
    IS_CONTAINER=1
fi

# 显示磁盘空间
df -h / | tail -n +2 | while read fs size used avail usep mount; do
    use_percent=${usep%\%}
    if [ "$use_percent" -lt 60 ]; then
        color=$GREEN
    elif [ "$use_percent" -lt 80 ]; then
        color=$YELLOW
    else
        color=$RED
    fi
    echo -e "${YELLOW}磁盘空间:${RESET} ${color}$usep${RESET} ${YELLOW}已使用 (挂载点: $mount, 总大小: $size, 可用: $avail)${RESET}"
done

# ===============================
# 系统清理
# ===============================
clean_system() {
    # 避免 grub-pc 弹出交互界面
    export DEBIAN_FRONTEND=noninteractive

    if command -v apt &>/dev/null; then
        echo -e "${GREEN}检测到 APT 系统${RESET}"
        wait_for_lock "APT" /var/lib/dpkg/lock-frontend
        apt update -y
        wait_for_lock "APT" /var/lib/dpkg/lock-frontend
        apt autoremove --purge -y
        apt clean
        apt autoclean
        # 删除残留配置文件
        dpkg -l | awk '/^rc/ {print $2}' | xargs -r apt purge -y
        if [ "$IS_CONTAINER" -eq 0 ]; then
            # 安全删除旧内核
            CURRENT_KERNEL=$(uname -r)
            dpkg --list | awk '/linux-image-[0-9]/ {print $2}' | grep -v "$CURRENT_KERNEL" | xargs -r apt purge -y
        fi
    elif command -v yum &>/dev/null; then
        echo -e "${GREEN}检测到 YUM 系统${RESET}"
        wait_for_lock "YUM" /var/run/yum.pid
        yum autoremove -y
        yum clean all
        if [ "$IS_CONTAINER" -eq 0 ] && command -v package-cleanup &>/dev/null; then
            package-cleanup --oldkernels --count=2 -y
        fi
    elif command -v dnf &>/dev/null; then
        echo -e "${GREEN}检测到 DNF 系统${RESET}"
        wait_for_lock "DNF" /var/run/dnf.pid
        dnf autoremove -y
        dnf clean all
        if [ "$IS_CONTAINER" -eq 0 ]; then
            dnf remove $(dnf repoquery --installonly --latest-limit=-2 -q) -y 2>/dev/null
        fi
    elif command -v apk &>/dev/null; then
        echo -e "${GREEN}检测到 APK 系统${RESET}"
        apk cache clean
    else
        echo -e "${RED}暂不支持你的系统！${RESET}"
        exit 1
    fi

    # 清理日志（保留最近 7 天）
    echo -e "${GREEN}清理日志文件（保留最近 7 天）...${RESET}"
    journalctl --vacuum-time=7d

    echo -e "${GREEN}系统清理完成！${RESET}"
}

# ===============================
# Docker 清理
# ===============================
clean_docker() {
    if command -v docker &>/dev/null; then
        echo -e "${GREEN}清理 Docker 无用数据...${RESET}"
        docker system prune -af --volumes
    else
        echo -e "${YELLOW}未检测到 Docker，跳过${RESET}"
    fi
}

# ===============================
# 菜单
# ===============================
while true; do
    echo -e "${GREEN}===== 系统清理菜单 =====${RESET}"
    echo -e "${GREEN}1) 普通系统清理${RESET}"
    echo -e "${GREEN}2) 系统+Docker 清理${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN}选择操作: ${RESET})" choice
    case $choice in
        1)
            clean_system
            ;;
        2)
            clean_system
            clean_docker
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择${RESET}"
            ;;
    esac
done
