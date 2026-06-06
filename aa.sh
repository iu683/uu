#!/bin/bash
# ========================================
# 安全版 fNOS 重装执行器
# 功能: 下载远程重装脚本，一键重装为 fNOS
# ========================================

GITHUB_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
CNB_URL="https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh"
SCRIPT_NAME="reinstall.sh"

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}警告: 此操作将会完全重装系统为 fnos，磁盘上所有数据将丢失！${RESET}"
echo -e "${YELLOW}请确保已备份重要数据！${RESET}"

# 用户确认
read -p $'\033[31m你确定要继续吗？(y/n): \033[0m' CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    exit 1
fi

# 线路选择
echo -e "  ${YELLOW}--------------------------------------${RESET}"
echo -e "  ${GREEN}1) 国内机专用镜像${RESET}"
echo -e "  ${GREEN}2) GitHub 镜像代理${RESET}"
echo -e "  ${GREEN}3) GitHub 直连(默认)${RESET}"
echo -e "${YELLOW}--------------------------------------${RESET}"
read -p $'\033[36m👉 请输入编号: \033[0m' LINE_CHOICE
LINE_CHOICE=${LINE_CHOICE:-3}

# 根据选择下载脚本
echo -e "${GREEN}正在下载重装...${RESET}"
DOWNLOAD_SUCCESS=1

case "$LINE_CHOICE" in
    1)
        echo -e "${GREEN}使用国内 CNB 镜像源下载...${RESET}"
        curl -fsSL -o "$SCRIPT_NAME" "$CNB_URL" || wget -O "$SCRIPT_NAME" "$CNB_URL"
        [ $? -eq 0 ] && DOWNLOAD_SUCCESS=0
        ;;
    2)
        echo -e "${GREEN}使用 GitHub 代理下载...${RESET}"
        wget -q "https://v6.gh-proxy.org/${GITHUB_URL}" -O "$SCRIPT_NAME" && DOWNLOAD_SUCCESS=0
        ;;
    3)
        echo -e "${GREEN}使用 GitHub 直连下载...${RESET}"
        wget -q "$GITHUB_URL" -O "$SCRIPT_NAME" && DOWNLOAD_SUCCESS=0
        ;;
    *)
        echo -e "${RED}输入错误，默认使用 GitHub 直连...${RESET}"
        wget -q "$GITHUB_URL" -O "$SCRIPT_NAME" && DOWNLOAD_SUCCESS=0
        ;;
esac

if [ $DOWNLOAD_SUCCESS -ne 0 ]; then
    echo -e "${RED}❌ 下载失败，请检查网络或更换线路。${RESET}"
    exit 1
fi

chmod +x "$SCRIPT_NAME"

# 执行重装脚本 (不再传递任何额外参数，仅指定系统为 fnos)
echo -e "${GREEN}🔧 正在执行 fNOS 重装配置...${RESET}"
./"$SCRIPT_NAME" fnos

# 绿色重启提示
echo -e "${GREEN}✔ 重装环境已配置完成。${RESET}"
read -p "按 Enter 确认重启并开始重装进程..." dummy

echo -e "${GREEN}>>> 正在重启系统，请稍后通过浏览器访问 fNOS 后台进行初始化...${RESET}"
reboot
