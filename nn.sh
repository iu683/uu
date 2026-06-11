#!/bin/bash
# ========================================
# ShellCrash 一键安装脚本 (修复交互冲突版)
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

# 2. 代理前缀列表
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
TMP_SCRIPT="/tmp/sc_install.sh" # 临时保存脚本的路径

# 3. 循环遍历代理进行下载
for proxy in "${GITHUB_PROXY[@]}"; do
    INSTALL_URL="${proxy}${BASE_URL}"
    
    if [ -z "$proxy" ]; then
        echo -e "${YELLOW}正在尝试直连下载安装脚本...${RESET}"
    else
        echo -e "${YELLOW}直连失败或重试，正在尝试代理: ${proxy}${RESET}"
    fi

    # 仅仅执行下载，保存到 /tmp/sc_install.sh
    if curl -fsSL --connect-timeout 10 "$INSTALL_URL" -o "$TMP_SCRIPT"; then
        echo -e "${GREEN}脚本下载成功！开始进入安装交互界面...${RESET}"
        echo -e "${GREEN}----------------------------------------${RESET}"
        
        # 正常执行本地脚本，此时键盘交互完全正常
        if bash "$TMP_SCRIPT"; then
            SUCCESS=true
            rm -f "$TMP_SCRIPT" # 运行完删除临时文件
            break # 真正安装成功，跳出循环
        else
            echo -e "${RED}安装脚本执行过程中出错或被取消。${RESET}"
            rm -f "$TMP_SCRIPT"
            # 如果你是主动取消的，这里也可以决定是否继续尝试其他代理
            # 绝大多数情况下，能下载成功说明网络没问题，不需要再试下一个代理了
            exit 1 
        fi
    fi

    echo -e "${RED}当前网络连接失败，准备尝试下一个地址...${RESET}"
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
