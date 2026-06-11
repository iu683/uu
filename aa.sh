#!/bin/bash
# ========================================
# ShellCrash 一键安装脚本 (带 GitHub 代理重试)
# 自动刷新环境变量
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

clear

echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}       ShellCrash 开始安装${RESET}"
echo -e "${GREEN}========================================${RESET}"

# 1. 检查并安装 curl
if ! command -v curl &>/dev/null; then
    echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"

    if command -v apt &>/dev/null; then
        apt update -y && apt install -y curl
    elif command -v yum &>/dev/null; then
        yum install -y curl
    elif command -v dnf &>/dev/null; then
        dnf install -y curl
    elif command -v apk &>/dev/null; then
        apk add curl
    else
        echo -e "${RED}无法自动安装 curl，请手动安装${RESET}"
        exit 1
    fi
fi

# 2. 定义代理数组
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

BASE_URL="raw.githubusercontent.com/juewuy/ShellCrash/master/install.sh"
SUCCESS=false

# 3. 循环遍历代理进行下载安装
for proxy in "${GITHUB_PROXY[@]}"; do
    INSTALL_URL="${proxy}${BASE_URL}"
    echo -e "${YELLOW}正在尝试通过代理下载: ${INSTALL_URL:-直连}${RESET}"
    
    # 尝试下载并执行 (设置 10 秒超时防止卡死)
    if bash -c "$(curl -fsSL --connect-timeout 10 "$INSTALL_URL")"; then
        SUCCESS=true
        break
    else
        echo -e "${RED}当前节点连接失败，尝试下一个...${RESET}"
    fi
done

# 4. 判断最终安装状态
if [ "$SUCCESS" = false ]; then
    echo -e "${RED}========================================${RESET}"
    echo -e "${RED}错误: 所有代理节点及直连均尝试失败，请检查网络！${RESET}"
    echo -e "${RED}========================================${RESET}"
    exit 1
fi

echo -e "${GREEN}========================================${RESET}"
echo -e "${YELLOW}如果 crash 命令未立即生效，请执行：${RESET}"
echo -e "${GREEN}source /etc/profile${RESET}"
echo -e "${GREEN}========================================${RESET}"
