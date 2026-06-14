#!/bin/bash

# ==============================================================================
# 颜色与全局变量定义
# ==============================================================================
GREEN='\033;0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 统一安装根目录
export PROJECT_DIR="/opt/telebox"

# 严格检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 sudo 或 root 权限运行此脚本！${RESET}"
    exit 1
fi

# ==============================================================================
# 动态状态获取函数（全部统一使用全局 root 环境）
# ==============================================================================
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
            
            # 获取实际运行的 PID 数量，防止双进程冲突
            proc_count=$(pm2 jlist 2>/dev/null | grep -o '"name":"telebox"' | wc -l)
            if [ "$proc_count" -gt 1 ]; then
                port_show="${RED}检测到 $proc_count 个异常重复进程！${RESET}"
            else
                port_show="${GREEN}生产环境活跃 (ID: 0)${RESET}"
            fi
        else
            if pgrep -f "node.*telebox" >/dev/null; then
                status="${YELLOW}前台运行中 (未加入PM2)${RESET}"
                port_show="${YELLOW}前台活跃${RESET}"
            else
                status="${RED}已停止${RESET}"
                port_show="${RED}无${RESET}"
            fi
        fi
    else
        if pgrep -f "node.*telebox" >/dev/null; then
            status="${YELLOW}前台运行中 (PM2未安装)${RESET}"
            port_show="${YELLOW}前台活跃${RESET}"
        else
            status="${RED}已停止 (PM2未安装)${RESET}"
            port_show="${RED}无${RESET}"
        fi
    fi
}

# ==============================================================================
# 主菜单循环
# ==============================================================================
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
            echo -e "${CYAN}开始更新系统并安装基础工具...${RESET}"
            apt update && apt install -y curl git build-essential python3
            echo -e "${CYAN}开始安装 Node.js 24.x...${RESET}"
            curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
            apt-get install -y nodejs
            echo -e "${GREEN}基础环境安装完成！${RESET}"
            read -p "按回车键返回菜单..."
            ;;
        2)
            echo -e "${CYAN}正在初始化统一目录: ${PROJECT_DIR}...${RESET}"
            mkdir -p "$PROJECT_DIR"
            
            if [ -d "$PROJECT_DIR/.git" ]; then
                echo -e "${YELLOW}目录已存在 Git 仓库，尝试同步最新代码...${RESET}"
                cd "$PROJECT_DIR" && git pull
            else
                echo -e "${CYAN}正在克隆官方仓库...${RESET}"
                git clone https://github.com/TeleBoxOrg/TeleBox.git "$PROJECT_DIR"
            fi
            
            echo -e "${CYAN}正在安装项目依赖，请稍候...${RESET}"
            cd "$PROJECT_DIR" && npm install
            echo -e "${GREEN}项目依赖安装成功！${RESET}"
            read -p "按回车键返回菜单..."
            ;;
        3)
            if [ ! -d "$PROJECT_DIR" ] || [ ! -f "$PROJECT_DIR/package.json" ]; then
                echo -e "${RED}错误: 统一目录尚未初始化，请先执行步骤 2！${RESET}"
            else
                # 先尝试清理可能残存的后台进程，防止端口/Session被占
                pm2 delete telebox >/dev/null 2>&1
                kill -9 $(pgrep -f "node.*telebox") >/dev/null 2>&1
                
                echo -e "${YELLOW}提示: 登录成功并看到成功日志后，请等待 5 秒让配置写入，再按 CTRL+C 退出。${RESET}"
                read -p "准备就绪，按回车键进入前台登录..."
                cd "$PROJECT_DIR" && npm start
            fi
            read -p "已退出登录界面，按回车键返回菜单..."
            ;;
        4)
            if [ ! -d "$PROJECT_DIR" ]; then
                echo -e "${RED}错误: 项目目录不存在！${RESET}"
            else
                echo -e "${CYAN}全局安装/检查 PM2 进程管理器...${RESET}"
                npm install -g pm2
                
                echo -e "${CYAN}彻底清理旧进程，防止双开冲突...${RESET}"
                pm2 delete telebox >/dev/null 2>&1
                
                echo -e "${CYAN}通过 PM2 载入 TeleBox 服务...${RESET}"
                cd "$PROJECT_DIR"
                pm2 start npm --name "telebox" -- run start
                pm2 save
                
                echo -e "${CYAN}配置 PM2 开机自启服务...${RESET}"
                pm2 startup systemd
                echo -e "${GREEN}生产环境 PM2 部署完成！${RESET}"
            fi
            read -p "按回车键返回菜单..."
            ;;
        5)
            echo -e "${CYAN}命令：启动 TeleBox...${RESET}"
            pm2 start telebox
            read -p "按回车键返回菜单..."
            ;;
        6)
            echo -e "${CYAN}命令：停止 TeleBox...${RESET}"
            pm2 stop telebox
            read -p "按回车键返回菜单..."
            ;;
        7)
            echo -e "${CYAN}命令：重启 TeleBox...${RESET}"
            pm2 restart telebox
            read -p "按回车键返回菜单..."
            ;;
        8)
            echo -e "${CYAN}正在追踪实时日志 (退出查看请按 CTRL+C)...${RESET}"
            pm2 logs telebox
            ;;
        9)
            if [ ! -d "$PROJECT_DIR" ]; then
                echo -e "${RED}错误: 目录不存在！${RESET}"
            else
                echo -e "${YELLOW}清理旧缓存，准备彻底重构...${RESET}"
                cd "$PROJECT_DIR"
                npm cache clean --force
                rm -rf node_modules package-lock.json
                npm install
                echo -e "${GREEN}统一目录依赖重构成功！${RESET}"
            fi
            read -p "按回车键返回菜单..."
            ;;
        10)
            read -p $'\e[31m⚠️ 危险操作：确定要彻底清除 TeleBox 目录及所有服务吗？(y/N): \e[0m' confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${RED}清除 PM2 守护进程...${RESET}"
                pm2 delete telebox 2>/dev/null
                pm2 save
                echo -e "${RED}清空统一安装目录 ${PROJECT_DIR}...${RESET}"
                rm -rf "$PROJECT_DIR"
                echo -e "${GREEN}卸载彻底完成！${RESET}"
            else
                echo -e "${YELLOW}操作已取消。${RESET}"
            fi
            read -p "按回车键返回菜单..."
            ;;
        0)
            echo -e "${GREEN}已安全退出管理面板。${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}输入有误，请输入菜单对应的有效数字！${RESET}"
            sleep 1.2
            ;;
    esac
done
