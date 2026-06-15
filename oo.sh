#!/bin/bash
# ========================================
# 安全版 Debian 重装执行器
# 功能: 下载远程重装脚本，执行前安全确认
# ========================================

GITHUB_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
CNB_URL="https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh"
SCRIPT_NAME="reinstall.sh"

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}警告: 此操作将会完全重装系统，磁盘上所有数据将丢失！${RESET}"
echo -e "${YELLOW}请确保已备份重要数据！${RESET}"

# 用户确认
read -p $'\033[31m你确定要继续吗？(y/n): \033[0m' CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo -e "${RED}已取消操作${RESET}"
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

# 用户名（默认 root）
read -p "请输入用户名 (默认 root): " USERNAME
USERNAME=${USERNAME:-root}

# SSH 公钥输入
echo -e "${YELLOW}提示: 密钥支持 公钥字符串、URL、github:用户名、gitlab:用户名${RESET}"
echo -e "${YELLOW}例如: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPYYSr25hwiXYTbVBlSzNNiYHl6vCD8CJWG70rTU+6qj2T root@localhost${RESET}"
read -p "请输入 SSH 登录公钥 (留空则使用密码登录): " SSH_KEY

# 密码输入与随机生成逻辑
ROOT_PASS=""
if [[ -z "$SSH_KEY" ]]; then
    read -p "请输入 ${USERNAME} 密码 (留空则自动生成随机密码): " ROOT_PASS
    if [[ -z "$ROOT_PASS" ]]; then
        # 生成 16 位随机密码（包含大小写字母、数字）
        ROOT_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        echo -e "${YELLOW}==================================================${RESET}"
        echo -e "${YELLOW}🔑 未输入密码，已自动为您生成随机强密码：${RESET}"
        echo -e "${RED}${ROOT_PASS}${RESET}"
        echo -e "${YELLOW}请务必复制并妥善保存此密码！${RESET}"
        echo -e "${YELLOW}==================================================${RESET}"
        read -p "请按 Enter 键确认已保存密码并继续..."
    fi
else
    echo -e "${GREEN}检测到已提供 SSH 公钥，将跳过密码设置。${RESET}"
fi

# SSH 端口
read -p "请输入 SSH 端口 (默认 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

# 根据选择下载脚本
echo -e "${GREEN}正在下载重装...${RESET}"
DOWNLOAD_SUCCESS=1

case "$LINE_CHOICE" in
    1)
        # 国内机线路：采用 curl || wget 容错写法
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
        echo -e "${RED}输入错误，默认使用GitHub 直连...${RESET}"
        curl -fsSL -o "$SCRIPT_NAME" "$CNB_URL" || wget -O "$SCRIPT_NAME" "$CNB_URL"
        [ $? -eq 0 ] && DOWNLOAD_SUCCESS=0
        ;;
esac

if [ $DOWNLOAD_SUCCESS -ne 0 ]; then
    echo -e "${RED}❌ 下载失败，请检查网络或更换线路。${RESET}"
    exit 1
fi

chmod +x "$SCRIPT_NAME"

# 组装执行参数
CMD=("./$SCRIPT_NAME" "debian" "13" --username "$USERNAME" --ssh-port "$SSH_PORT")

# 根据输入动态添加密码或密钥
if [[ -n "$SSH_KEY" ]]; then
    CMD+=(--ssh-key "$SSH_KEY")
else
    CMD+=(--password "$ROOT_PASS")
fi

# 执行重装脚本
echo -e "${GREEN}🔧 正在执行重装...${RESET}"
"${CMD[@]}"

# 绿色重启提示
echo -e "${GREEN}✔ 系统将在完成后重启。${RESET}"
read -p "按 Enter 确认重启..." dummy

echo -e "${GREEN}>>> 正在重启系统...${RESET}"
reboot
