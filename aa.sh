#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' 

echo -e "${GREEN} ====老王工具箱==== ${NC}"
echo -e "${GREEN} 1. 安装 老王工具箱${NC}"
echo -e "${GREEN} 2. 卸载 老王工具箱${NC}"
echo -e "${GREEN} 3. 退出${NC}"

read -p "$(echo -e "${GREEN}请输入数字 [1-3]: ${NC}")" num

case "$num" in
    1)
        echo -e "${GREEN}正在安装老王工具箱...${NC}"
        curl -fsSL https://raw.githubusercontent.com/eooce/ssh_tool/main/ssh_tool.sh -o ssh_tool.sh && chmod +x ssh_tool.sh && ./ssh_tool.sh
        ;;
    2)
        echo -e "${RED}正在完全卸载老王工具箱...${NC}"
        rm -f /usr/local/bin/ssh_tool.sh
        rm -f /root/ssh_tool.sh
        echo -e "${GREEN}卸载完成！${NC}"
        ;;
    3)
        echo "已退出。"
        exit 0
        ;;
    *)
        echo -e "${RED}输入错误，请输入 1、2 或 3${NC}"
        ;;
esac
