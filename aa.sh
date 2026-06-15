#!/bin/bash
# ==========================================
# 哪吒探针 Agent 一键安装脚本 (多代理轮询重试版)
# 自动检测并安装 unzip，支持多 Github 代理轮询下载
# 适配 Debian / Ubuntu / CentOS / Alma / Rocky
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

INSTALL_DIR="/opt/nezha/agent"
SERVICE_FILE="/etc/systemd/system/nezha-agent.service"

# 原始资源相对路径
AGENT_RAW="https://github.com/nezhahq/agent/releases/download/v2.2.2/nezha-agent_linux_amd64.zip"
SERVICE_RAW="https://raw.githubusercontent.com/sistarry/toolbox/refs/heads/main/CN/nezha-agent.service"
CONFIG_RAW="https://raw.githubusercontent.com/sistarry/toolbox/refs/heads/main/CN/config.yml"

# Github 代理列表（首项为空代表直连）
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)
echo -e "${GREEN}=====================================${RESET}"
echo -e "${GREEN}◈  国内VPS哪吒探针  Agent 一键安装  ◈ ${RESET}"
echo -e "${GREEN}=====================================${RESET}"

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
        apt update -y && apt install unzip -y
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
# 核心：多代理轮询下载函数
# =============================
# 参数 1: 原始资源路径 (RAW_URL)
# 参数 2: 保存的目标路径 (OUTPUT_PATH)
download_file() {
    local raw_url="$1"
    local output_path="$2"
    local success=1 # 1表示失败，0表示成功

    for proxy in "${GITHUB_PROXY[@]}"; do
        local final_url="${proxy}${raw_url}"
        
        if [ -z "$proxy" ]; then
            echo -e "${YELLOW}尝试直连下载: ${raw_url}${RESET}"
        else
            echo -e "${YELLOW}尝试通过代理下载: ${proxy}${RESET}"
        fi

        # wget 参数说明：--timeout=8 超时8秒，--tries=1 单节点不重试直接切下一个
        wget --timeout=8 --tries=1 -O "$output_path" "$final_url"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}下载成功！${RESET}"
            success=0
            break
        else
            echo -e "${RED}当前节点下载失败，尝试切换下一个...${RESET}"
        fi
    done

    return $success
}

# =============================
# 创建目录并进入
# =============================
echo -e "${YELLOW}创建安装目录...${RESET}"
mkdir -p ${INSTALL_DIR}
cd ${INSTALL_DIR} || exit

# =============================
# 轮询下载 Agent
# =============================
echo -e "${YELLOW}开始下载 Agent...${RESET}"
download_file "$AGENT_RAW" "nezha-agent.zip"
if [ $? -ne 0 ]; then
    echo -e "${RED}所有代理节点均下载失败，请检查网络或更新代理列表！${RESET}"
    exit 1
fi

echo -e "${YELLOW}解压文件...${RESET}"
unzip -o nezha-agent.zip
rm -f nezha-agent.zip
chmod +x ${INSTALL_DIR}/nezha-agent

# =============================
# 轮询下载 systemd 服务
# =============================
echo -e "${YELLOW}开始下载 systemd 服务文件...${RESET}"
download_file "$SERVICE_RAW" "${SERVICE_FILE}"
if [ $? -ne 0 ]; then
    echo -e "${RED}服务文件下载失败！${RESET}"
    exit 1
fi

# =============================
# 轮询下载配置文件
# =============================
echo -e "${YELLOW}开始下载默认配置文件...${RESET}"
download_file "$CONFIG_RAW" "${INSTALL_DIR}/config.yml"
if [ $? -ne 0 ]; then
    echo -e "${RED}配置文件下载失败！${RESET}"
    exit 1
fi

# =============================
# 写入面板信息
# =============================
echo -e "${GREEN}请输入哪吒面板信息${RESET}"

read -p "请输入 client_secret(密钥): " CLIENT_SECRET
read -p "请输入 server (例如 data.example.com:443): " SERVER_ADDR
read -p "请输入 uuid (留空则自动生成): " UUID

# 如果没输入 UUID 自动生成
if [ -z "$UUID" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo -e "${YELLOW}未输入 UUID，已自动生成: ${UUID}${RESET}"
fi

# 替换配置
sed -i "s|^client_secret:.*|client_secret: ${CLIENT_SECRET}|" ${INSTALL_DIR}/config.yml
sed -i "s|^server:.*|server: ${SERVER_ADDR}|" ${INSTALL_DIR}/config.yml

# 写入 uuid
if grep -q "^uuid:" ${INSTALL_DIR}/config.yml; then
    sed -i "s|^uuid:.*|uuid: ${UUID}|" ${INSTALL_DIR}/config.yml
else
    echo "uuid: ${UUID}" >> ${INSTALL_DIR}/config.yml
fi

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
echo -e "${GREEN}=====================================${RESET}"
