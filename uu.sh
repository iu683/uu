#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 必须 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本！${RESET}"
    exit 1
fi

clean_system() {

    echo -e "${GREEN}开始系统自动清理...${RESET}"

    # 判断是否容器
    if systemd-detect-virt --quiet; then
        echo -e "${YELLOW}检测到容器环境，跳过内核与日志清理${RESET}"
        IS_CONTAINER=1
    else
        IS_CONTAINER=0
    fi

    # ===============================
    # APT 系统
    # ===============================
    if command -v apt &>/dev/null; then
        echo -e "${GREEN}检测到 APT 系统${RESET}"

        apt update -y
        apt autoremove --purge -y
        apt clean
        apt autoclean

        # 清理残留 rc 包
        dpkg -l | awk '/^rc/ {print $2}' | xargs -r apt purge -y

        # 安全清理旧内核（仅物理机）
        if [ "$IS_CONTAINER" -eq 0 ]; then
            echo -e "${GREEN}正在安全检查旧内核...${RESET}"
            CURRENT_KERNEL=$(uname -r)
            dpkg --list | awk '/linux-image-[0-9]/ {print $2}' | grep -v "$CURRENT_KERNEL" | xargs -r apt purge -y
        fi

    # ===============================
    # YUM 系统
    # ===============================
    elif command -v yum &>/dev/null; then
        echo -e "${GREEN}检测到 YUM 系统${RESET}"

        yum autoremove -y
        yum clean all

        if [ "$IS_CONTAINER" -eq 0 ] && command -v package-cleanup &>/dev/null; then
            package-cleanup --oldkernels --count=2 -y
        fi

    # ===============================
    # DNF 系统
    # ===============================
    elif command -v dnf &>/dev/null; then
        echo -e "${GREEN}检测到 DNF 系统${RESET}"

        dnf autoremove -y
        dnf clean all

        if [ "$IS_CONTAINER" -eq 0 ]; then
            dnf remove $(dnf repoquery --installonly --latest-limit=-2 -q) -y 2>/dev/null
        fi

    # ===============================
    # Alpine
    # ===============================
    elif command -v apk &>/dev/null; then
        echo -e "${GREEN}检测到 APK 系统${RESET}"
        apk cache clean

    else
        echo -e "${RED}暂不支持你的系统！${RESET}"
        exit 1
    fi

    # ===============================
    # 清理日志
    # ===============================
    if [ "$IS_CONTAINER" -eq 0 ] && command -v journalctl &>/dev/null; then
        echo -e "${GREEN}清理日志文件（保留最近 7 天）...${RESET}"
        journalctl --vacuum-time=7d
    fi

    echo -e "${GREEN}系统清理完成！${RESET}"
}

clean_system
