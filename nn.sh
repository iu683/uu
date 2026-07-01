#!/bin/bash

# 颜色定义
G='\033[0;32m' # 绿
Y='\033[1;33m' # 黄
R='\033[0;31m' # 红
NC='\033[0m'   # 无色

CONFIG_PATH="/opt/nezha/agent/config.yml"

# 1. 检查配置文件是否存在
if [ ! -f "$CONFIG_PATH" ]; then
    echo -e "${R}❌ 错误: 未找到哪吒 Agent 配置文件 ($CONFIG_PATH)${NC}"
    exit 1
fi

# 2. 修改配置（禁用命令执行）
echo -e "${Y}⏳ 正在修改配置文件，禁用哪吒 Agent 远程命令执行...${NC}"
sed -i 's/disable_command_execute: false/disable_command_execute: true/' "$CONFIG_PATH"

# 3. 智能判断系统环境并重启服务
if command -v systemctl &>/dev/null; then
    # 标准 Linux (Systemd)
    echo -e "${Y}⚙️ 检测到 Systemd 环境，正在重启哪吒服务...${NC}"
    if systemctl restart nezha-agent; then
        echo -e "${G}✅ 成功：配置已生效并已通过 systemctl 重启服务！${NC}"
    else
        echo -e "${R}❌ 失败：systemctl 重启哪吒服务失败。${NC}"
    fi

elif command -v rc-service &>/dev/null; then
    # Alpine Linux (OpenRC)
    echo -e "${Y}⚙️ 检测到 Alpine (OpenRC) 环境，正在重启哪吒服务...${NC}"
    if rc-service nezha-agent restart; then
        echo -e "${G}✅ 成功：配置已生效并已通过 OpenRC 重启服务！${NC}"
    else
        echo -e "${R}❌ 失败：OpenRC 重启哪吒服务失败。${NC}"
    fi

else
    # 兜底方案：无服务管理器时直接重载进程
    echo -e "${Y}⚠️ 未检测到标准服务管理器，正在尝试通过强制重启进程激活配置...${NC}"
    killall nezha-agent 2>/dev/null
    sleep 1
    if [ -x "/opt/nezha/agent/nezha-agent" ]; then
        /opt/nezha/agent/nezha-agent &>/dev/null &
        echo -e "${G}✅ 成功：哪吒 Agent 进程已重新拉起！${NC}"
    else
        echo -e "${R}❌ 失败：找不到哪吒 Agent 可执行程序，请手动重启。${NC}"
    fi
fi
