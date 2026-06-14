#!/bin/bash

# ==============================================================================
# 兼容性转义颜色定义
# ==============================================================================
GREEN='\e[0;32m'
YELLOW='\e[1;33m'
RED='\e[0;31m'
CYAN='\e[0;36m'
RESET='\e[0m'

export PROJECT_DIR="/opt/telebox"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 sudo 或 root 权限运行此脚本！${RESET}"
    exit 1
fi

get_status() {
    # 1. 检查 Node.js 版本
    if command -v node >/dev/null 2>&1; then
        version=$(node -v)
    else
        version="${RED}未安装${RESET}"
    fi

    # 2. 检查 PM2 状态
    if command -v pm2 >/dev/null 2>&1; then
        pm2_status=$(pm2 jlist 2>/dev/null | grep -o '"name":"telebox"[^}]*' | grep -o '"status":"[^"]*"' | head -n1 | cut -d'"' -f4)
        if [ "$pm2_status" = "online" ]; then
            status="${GREEN}运行中 (PM2 守护)${RESET}"
            port_show="${GREEN}生产环境活跃 (ID: 0)${RESET}"
            return
        fi
    fi

    # 3. 精准检测是否有真正的 TeleBox 前台 Node 进程在运行（排除本脚本本身）
    # 通过检查进程的工作目录或执行路径中是否包含 /opt/telebox 且不是 pm2 的进程
    if ps aux | grep "node" | grep "$PROJECT_DIR" | grep -v "pm2" | grep -v "grep" >/dev/null 2>&1; then
        status="${YELLOW}前台运行中 (未加入PM2)${RESET}"
        port_show="${YELLOW}有真实前台进程活跃，请确认是否未关闭登录窗口${RESET}"
    else
        status="${RED}已停止${RESET}"
        port_show="${RED}无${RESET}"
    fi
}

while true; do
    get_status
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  TeleBox 统一管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}路径   :${RESET} ${CYAN}${PROJECT_DIR}${RESET}"
    echo -e "${GREEN}提示   :${RESET} ${port_show}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装基础环境与 Node.js 24.x${RESET}"
    echo -e "${GREEN} 2. 统一克隆项目并安装依赖${RESET}"
    echo -e "${GREEN} 3. 首次启动与配置 (交互登录)${RESET}"
    echo -e "${GREEN} 4. 部署至生产环境 (PM2)${RESET}"
    echo -e "${GREEN} 5. 启动 TeleBox (PM2)${RESET}"
    echo -e "${GREEN} 6. 停止 TeleBox (PM2)${RESET}"
    echo -e "${GREEN} 7. 重启 TeleBox (PM2)${RESET}"
    echo -e "${GREEN} 8. 查看实时运行日志${RESET}"
    echo -e "${GREEN} 9. 强制清理并重构依赖${RESET}"
    echo -e "${GREEN}10. 彻底卸载 TeleBox 服务${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    
    read -p $'\e[32m请输入数字: \e[0m' num

    case "$num" in
        1)
            apt update && apt install -y curl git build-essential python3
            curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
            apt-get install -y nodejs
            read -p "按回车键返回菜单..."
            ;;
        2)
            mkdir -p "$PROJECT_DIR"
            if [ -d "$PROJECT_DIR/.git" ]; then
                cd "$PROJECT_DIR" && git pull
            else
                git clone https://github.com/TeleBoxOrg/TeleBox.git "$PROJECT_DIR"
            fi
            cd "$PROJECT_DIR" && npm install
            read -p "按回车键返回菜单..."
            ;;
        3)
            if [ ! -d "$PROJECT_DIR" ]; then
                echo -e "${RED}错误: 请先执行步骤 2！${RESET}"
            else
                pm2 delete telebox >/dev/null 2>&1
                # 强杀真正的后台残留
                ps aux | grep "node" | grep "$PROJECT_DIR" | grep -v "grep" | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1
                echo -e "${YELLOW}登录成功后，请等待 5 秒让配置写入，再按 CTRL+C 退出。${RESET}"
                read -p "按回车键进入前台登录..."
                cd "$PROJECT_DIR" && npm start
            fi
            read -p "已退出，按回车键返回菜单..."
            ;;
        4)
            if [ ! -d "$PROJECT_DIR" ]; then
                echo -e "${RED}错误: 请先克隆项目！${RESET}"
            else
                npm install -g pm2
                pm2 delete telebox >/dev/null 2>&1
                cd "$PROJECT_DIR"
                pm2 start npm --name "telebox" -- run start
                pm2 save
                pm2 startup systemd
                echo -e "${GREEN}生产环境 PM2 部署完成！${RESET}"
            fi
            read -p "按回车键返回菜单..."
            ;;
        5) pm2 start telebox; read -p "按回车..." ;;
        6) pm2 stop telebox; read -p "按回车..." ;;
        7) pm2 restart telebox; read -p "按回车..." ;;
        8) pm2 logs telebox ;;
        9)
            if [ -d "$PROJECT_DIR" ]; then
                cd "$PROJECT_DIR" && npm cache clean --force && rm -rf node_modules package-lock.json && npm install
            fi
            read -p "按回车键返回菜单..."
            ;;
        10)
            read -p "确定要彻底删除吗？(y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                pm2 delete telebox >/dev/null 2>&1
                pm2 save
                rm -rf "$PROJECT_DIR"
                echo -e "${GREEN}卸载完成！${RESET}"
            fi
            read -p "按回车..."
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入有误！${RESET}"; sleep 1 ;;
    esac
done
