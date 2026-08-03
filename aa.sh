#!/bin/bash

GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
YELLOW="\033[33m"
RED="\033[31m"
NC='\033[0;0m' # 无颜色

# 监控脚本路径
MONITOR_PATH="/root/warp_monitor.sh"

# 菜单主循环
while true; do
    clear
    # 检测安装状态（通过判断脚本文件是否存在）
    if [ -f "$MONITOR_PATH" ]; then
        STATUS="${YELLOW}[已安装]${NC}"
    else
        STATUS="${RED}[未安装]${NC}"
    fi

    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}  ◈ WARP 监控与自动修复管理菜单 ◈  ${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} 当前状态: ${STATUS}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} 1. 安装 / 更新 WARP 监控${NC}"
    echo -e "${GREEN} 2. 检查 WARP 监控状态${NC}"
    echo -e "${GREEN} 3. 卸载 WARP 监控${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e -n "${GREEN} 请输入选项: ${NC}"
    read -r opt

    case $opt in
        1)
            echo -e "\n${GREEN}正在安装 WARP 监控...${NC}\n"
            wget -O "$MONITOR_PATH" "https://raw.githubusercontent.com/Michaol/warp_monitor/main/warp_monitor.sh" && chmod +x "$MONITOR_PATH" && sudo "$MONITOR_PATH"
            echo -e "\n${GREEN}安装/配置完成${NC}"
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        2)
            echo -e "\n${GREEN}正在检查 WARP 监控状态与日志...${NC}\n"
            if [ -f "$MONITOR_PATH" ]; then
                "$MONITOR_PATH" -v
                echo -e "\n---------------------------------"
                if [ -f "/var/log/warp_monitor.log" ]; then
                    echo -e "${LIGHT_GREEN}最近的日志内容：${NC}"
                    tail -n 10 /var/log/warp_monitor.log
                else
                    echo -e "${YELLOW}暂无运行日志文件${NC}"
                fi
            else
                echo -e "${RED}WARP 监控脚本未安装！${NC}"
            fi
            echo -e -n "\n${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        3)
            echo -e "\n${GREEN}开始卸载 WARP 监控相关组件...${NC}\n"
            # 1. 移除定时任务
            crontab -l 2>/dev/null | grep -v "WARP_MONITOR_CRON" | crontab -
            # 2. 删除脚本文件
            rm -f "$MONITOR_PATH"
            # 3. 删除 logrotate 配置
            rm -f /etc/logrotate.d/warp_monitor
            # 4. 删除配置文件
            rm -f /etc/warp_monitor.conf
            # 5. 删除日志文件
            rm -f /var/log/warp_monitor.log*
            
            echo -e "\n${GREEN}卸载完成${NC}"
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "\n${RED}无效选项，请重新输入${NC}"
            sleep 2
            ;;
    esac
done
