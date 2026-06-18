#!/bin/bash

# ================== 颜色定义 ==================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ================== 脚本路径 ==================
SCRIPT_PATH="/root/vps-toolbox.sh"
SCRIPT_URL_SUFFIX="raw.githubusercontent.com/iu683/uu/main/zz.sh"
BIN_LINK_DIR="/usr/local/bin"

# ================== 代理列表 ==================
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# ================== 首次运行自动安装 ==================
if [ ! -f "$SCRIPT_PATH" ]; then
    SUCCESS=false
    
    # 循环尝试每个代理（包括第一个空代理，即直连）
    for proxy in "${GITHUB_PROXY[@]}"; do
        FULL_URL="${proxy}${SCRIPT_URL_SUFFIX}"
        
        if [ -n "$proxy" ]; then
            echo -e "${YELLOW}🔄 正在通过代理安装...${RESET}"
        else
            echo -e "${YELLOW}🔄 正在通过直连安装...${RESET}"
        fi
        
        # 执行下载，设置 5 秒超时防止卡死
        curl -fsSL --connect-timeout 5 -o "$SCRIPT_PATH" "$FULL_URL"
        
        if [ $? -eq 0 ] && [ -s "$SCRIPT_PATH" ]; then
            SUCCESS=true
            break
        else
            echo -e "${YELLOW}当前节点连接失败，准备尝试下一个...${RESET}"
        fi
    done

    # 判断最终是否下载成功
    if [ "$SUCCESS" = false ]; then
        echo -e "${RED}❌ 所有代理节点均安装失败，请检查网络或 URL${RESET}"
        exit 1
    fi

    # 配置权限与软链接
    chmod +x "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/m"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/M"
    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${GREEN}✅ 你可以输入 ${RED}m${RESET}${GREEN} 或 ${RED}M${RESET}${GREEN} 运行 Toolbox 工具箱${RESET}"
fi

# ================== 执行脚本 (带参数透传) ==================
exec "$SCRIPT_PATH" "$@"
