#!/bin/bash
# ==========================================
# 哪吒探针 Agent 一键安装脚本
# 自动检测并安装 unzip
# 适配 Debian / Ubuntu / CentOS / Alma / Rocky
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

INSTALL_DIR="/opt/nezha/agent"
SERVICE_FILE="/etc/systemd/system/nezha-agent.service"
AGENT_URL="https://v6.gh-proxy.org/https://github.com/nezhahq/agent/releases/download/v2.0.1/nezha-agent_linux_amd64.zip"
SERVICE_URL="https://v6.gh-proxy.org/https://raw.githubusercontent.com/sistarry/toolbox/refs/heads/main/NEZHA/nezha-agent.service"
CONFIG_URL="https://v6.gh-proxy.org/https://raw.githubusercontent.com/sistarry/toolbox/refs/heads/main/toy/config.yml"
echo -e "${GREEN}==== 哪吒探针 Agent 一键安装 ====${RESET}"

# =============================
# 检测 root
# =============================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本${RESET}"
    exit 1
fi

# =============================
# 自动安装 unzip
# =============================
if ! command -v unzip >/dev/null 2>&1; then
    echo -e "${YELLOW}未检测到 unzip，正在安装...${RESET}"
    
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install unzip -y
    elif command -v dnf >/dev/null 2>&1; then
        dnf install unzip -y
    elif command -v yum >/dev/null 2>&1; then
        yum install unzip -y
    else
        echo -e "${RED}无法识别包管理器，请手动安装 unzip${RESET}"
        exit 1
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        echo -e "${RED}unzip 安装失败${RESET}"
        exit 1
    fi

    echo -e "${GREEN}unzip 安装完成${RESET}"
fi

# =============================
# 创建目录
# =============================
echo -e "${YELLOW}创建安装目录...${RESET}"
mkdir -p ${INSTALL_DIR}
cd ${INSTALL_DIR} || exit

# =============================
# 下载 Agent
# =============================
echo -e "${YELLOW}下载 Agent...${RESET}"
wget -O nezha-agent.zip ${AGENT_URL}

if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败，请检查网络！${RESET}"
    exit 1
fi

echo -e "${YELLOW}解压文件...${RESET}"
unzip -o nezha-agent.zip
rm -f nezha-agent.zip

chmod +x ${INSTALL_DIR}/nezha-agent

# =============================
# 下载 systemd 服务
# =============================
echo -e "${YELLOW}下载 systemd 服务文件...${RESET}"
wget -O ${SERVICE_FILE} ${SERVICE_URL}

# =============================
# 下载配置文件
# =============================
echo -e "${YELLOW}下载默认配置文件...${RESET}"
wget -O ${INSTALL_DIR}/config.yml ${CONFIG_URL}

if [ $? -ne 0 ]; then
    echo -e "${RED}配置文件下载失败！${RESET}"
    exit 1
fi

# =============================
# 写入面板信息
# =============================
echo -e "${GREEN}请输入哪吒面板信息${RESET}"
read -p "请输入 client_secret: " CLIENT_SECRET
read -p "请输入 server (例如 data.example.com:443): " SERVER_ADDR

# 替换配置
sed -i "s|^client_secret:.*|client_secret: ${CLIENT_SECRET}|" ${INSTALL_DIR}/config.yml
sed -i "s|^server:.*|server: ${SERVER_ADDR}|" ${INSTALL_DIR}/config.yml

# 强制开启 TLS
if grep -q "^tls:" ${INSTALL_DIR}/config.yml; then
    sed -i "s|^tls:.*|tls: true|" ${INSTALL_DIR}/config.yml
else
    echo "tls: true" >> ${INSTALL_DIR}/config.yml
fi

echo -e "${GREEN}配置文件已修改完成${RESET}"
# =============================
# 启动服务
# =============================
echo -e "${YELLOW}启动服务...${RESET}"
systemctl daemon-reload
systemctl enable nezha-agent
systemctl restart nezha-agent

echo -e "${GREEN}=====================================${RESET}"
echo -e "${GREEN}安装完成！${RESET}"
echo -e "${GREEN}查看状态： systemctl status nezha-agent${RESET}"
echo -e "${GREEN}查看日志： journalctl -u nezha-agent -f${RESET}"
echo -e "${GREEN}=====================================${RESET}"
