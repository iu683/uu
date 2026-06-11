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
echo -e "${GREEN}        ShellCrash 开始安装${RESET}"
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

# 2. 代理前缀列表（第一个留空代表直连尝试）
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
    
    if [ -z "$proxy" ]; then
        echo -e "${YELLOW}正在尝试直连下载...${RESET}"
    else
        echo -e "${YELLOW}直连失败或重试，正在尝试代理: ${proxy}${RESET}"
    fi

    # 使用 curl 尝试下载（设置 10 秒超时），如果成功则直接交给 bash 执行
    # -f 失败时不输出错误内容, -s 静默模式, -S 显示错误, -L 跟随重定向
    if curl -fsSL --connect-timeout 10 "$INSTALL_URL" | bash; then
        SUCCESS=true
        break # 安装成功，跳出循环
    fi

    echo -e "${RED}当前连接失败，准备尝试下一个地址...${RESET}"
    echo -e "${GREEN}----------------------------------------${RESET}"
done

# 4. 判断最终安装结果
if [ "$SUCCESS" = false ]; then
    echo -e "${RED}错误：所有代理节点均尝试失败，请检查网络连接或更换代理后再试。${RESET}"
    exit 1
fi

echo -e "${GREEN}========================================${RESET}"
echo -e "${YELLOW}如果 ShellCrash 安装完成命令未立即生效，请执行：${RESET}"
echo -e "${YELLOW}source /etc/profile${RESET}"
echo -e "${GREEN}========================================${RESET}"
