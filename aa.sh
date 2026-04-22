#!/bin/bash

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}🚀 正在安装 BBR V3...${RESET}"

# 1. 远程执行安装脚本
# 使用 -fsSL 确保安静安装，末尾加上时间戳防止缓存
bash <(curl -fsSL "https://raw.githubusercontent.com/Eric86777/vps-tcp-tune/main/install-alias.sh?$(date +%s)")

# 2. 强制刷新当前 Shell 的别名配置
# 探测使用的是 bash 还是 zsh
CONF_FILE=""
if [ -f "$HOME/.bashrc" ]; then
    CONF_FILE="$HOME/.bashrc"
elif [ -f "$HOME/.zshrc" ]; then
    CONF_FILE="$HOME/.zshrc"
fi

if [ -n "$CONF_FILE" ]; then
    echo -e "${YELLOW}🔄 正在重新加载配置: $CONF_FILE ...${RESET}"
    # 在当前脚本进程中加载别名
    # 注意：脚本结束后，当前终端可能仍需手动 source 一次，但脚本内部已经可以使用了
    source "$CONF_FILE"
fi

# 3. 自动打开 BBR 管理界面
echo -e "${GREEN}✅ 安装完成，正在为您打开 BBR 管理工具...${RESET}"

# 直接调用别名对应的指令（通常该别名指向的是安装后的主脚本）
# 如果脚本内 'bbr' 别名尚未生效，我们直接尝试执行它安装后的目标路径
if command -v bbr >/dev/null 2>&1; then
    bbr
else
    # 预防 source 未立即生效的情况，直接运行其安装位置
    /usr/local/bin/bbr || bash <(curl -L "https://raw.githubusercontent.com/Eric86777/vps-tcp-tune/main/tcp.sh")
fi
