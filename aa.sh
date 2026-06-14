#!/bin/bash

# 颜色定义
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
    # 1. 提取 Node 版本
    if command -v node >/dev/null 2>&1; then
        version=$(node -v)
    else
        version="${RED}未安装${RESET}"
    fi

    # 2. 精准判定 PM2（不通过复杂的 JSON 解析，直接看 pm2 status 的纯文本输出，最稳妥）
    if command -v pm2 >/dev/null 2>&1; then
        # 直接用 pm2 status 匹配活跃状态，完全免疫变量和环境带来的干扰
        if pm2 status telebox 2>/dev/null | grep -q "online"; then
            status="${YELLOW}运行中 (PM2 守护)${RESET}"
            port_show="${YELLOW}生产环境活跃 (ID: 0)${RESET}"
            return
        fi
    fi

    # 3. 判定前台（只有当 PM2 确定没在跑时，才去查有没有人偷偷在用普通的 npm start 跑）
    # 我们只抓命令里含有 "npm start" 或 "run-tsx" 且没有被 PM2 托管的纯前台特征
    if ps aux | grep -E "npm start|run-tsx" | grep -v "pm2" | grep -v "grep" >/dev/null 2>&1; then
        status="${YELLOW}前台运行中 (未加入PM2)${RESET}"
        port_show="${YELLOW}有交互式前台进程活跃，请前往处理${RESET}"
    else
        status="${RED}已停止${RESET}"
        port_show="${RED}无${RESET}"
    fi
}

while true; do
    get_status
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  TeleBox 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}路径   :${RESET} ${YELLOW}${PROJECT_DIR}${RESET}"
    echo -e "${GREEN}提示   :${RESET} ${port_show}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装基础环境与Node.js${RESET}"
    echo -e "${GREEN} 2. 克隆项目安装依赖${RESET}"
    echo -e "${GREEN} 3. 首次启动与配置(交互登录)${RESET}"
    echo -e "${GREEN} 4. 部署至生产环境 (PM2)${RESET}"
    echo -e "${GREEN} 5. 启动 TeleBox (PM2)${RESET}"
    echo -e "${GREEN} 6. 停止 TeleBox (PM2)${RESET}"
    echo -e "${GREEN} 7. 重启 TeleBox (PM2)${RESET}"
    echo -e "${GREEN} 8. 查看实时运行日志${RESET}"
    echo -e "${GREEN} 9. 强制清理并重构依赖${RESET}"
    echo -e "${GREEN}10. 卸载 TeleBox${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    
    read -p $'\e[32m请输入选项: \e[0m' num

    case "$num" in
         1)
            echo -e "${YELLOW}开始安装基础工具...${RESET}"
            apt update && apt install -y curl git build-essential python3
            echo -e "${YELLOW}开始安装 Node.js 24.x...${RESET}"
            curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
            apt-get install -y nodejs
            echo -e "${GREEN}基础环境安装完成！${RESET}"
            echo -e "${YELLOW}请选 2 克隆项目并安装依赖！${RESET}"
            read -p "按回车键返回菜单..."
            ;;
        2)
            echo -e "${YELLOW}正在初始化统一目录: ${PROJECT_DIR}...${RESET}"
            mkdir -p "$PROJECT_DIR"
            
            if [ -d "$PROJECT_DIR/.git" ]; then
                echo -e "${YELLOW}目录已存在 Git 仓库，尝试同步最新代码...${RESET}"
                cd "$PROJECT_DIR" && git pull
            else
                echo -e "${YELLOW}正在克隆官方仓库...${RESET}"
                git clone https://github.com/TeleBoxOrg/TeleBox.git "$PROJECT_DIR"
            fi
            
            echo -e "${YELLOW}统一目录权限纠正 [用户: ${REAL_USER}]...${RESET}"
            chown -R $REAL_USER:$REAL_USER "$PROJECT_DIR"
            
            echo -e "${YELLOW}正在安装项目依赖，请稍候...${RESET}"
            cd "$PROJECT_DIR" && sudo -u $REAL_USER HOME=$REAL_HOME npm install
            echo -e "${GREEN}项目依赖安装成功！${RESET}"
            echo -e "${YELLOW}请选 3 首次启动与配置！${RESET}"
            read -p "按回车键返回菜单..."
            ;;
        3)
            if [ ! -d "$PROJECT_DIR" ] || [ ! -f "$PROJECT_DIR/package.json" ]; then
                echo -e "${RED}错误: 统一目录尚未初始化，请先执行步骤 2！${RESET}"
            else
                echo -e "${YELLOW}提示: 登录成功并看到成功日志后，请等待 5 秒让配置写入，再按 CTRL+C 退出。${RESET}"
                read -p "准备就绪，按回车键进入前台登录..."
                cd "$PROJECT_DIR" && sudo -u $REAL_USER HOME=$REAL_HOME npm start
            fi
            read -p "已退出登录界面，请选 4 部署至生产环境!按回车键返回菜单..."
            ;;
        4)
            if [ ! -d "$PROJECT_DIR" ]; then
                echo -e "${RED}错误: 项目目录不存在！${RESET}"
            else
                echo -e "${YELLOW}全局安装 PM2 进程管理器...${RESET}"
                npm install -g pm2
                
                echo -e "${YELLOW}通过 PM2 载入 TeleBox 服务...${RESET}"
                cd "$PROJECT_DIR"
                sudo -u $REAL_USER HOME=$REAL_HOME pm2 start npm --name "telebox" -- run start
                sudo -u $REAL_USER HOME=$REAL_HOME pm2 save
                
                echo -e "${YELLOW}配置 PM2 开机自启服务...${RESET}"
                pm2 startup systemd -u $REAL_USER --hp $REAL_HOME | grep -v "[PM2]"
                echo -e "${GREEN}生产环境 PM2 部署完成！${RESET}"
            fi
            read -p "按回车键返回菜单..."
            ;;
        5)
            echo -e "${YELLOW}命令：启动 TeleBox...${RESET}"
            sudo -u $REAL_USER HOME=$REAL_HOME pm2 start telebox
            read -p "按回车键返回菜单..."
            ;;
        6)
            echo -e "${YELLOW}命令：停止 TeleBox...${RESET}"
            sudo -u $REAL_USER HOME=$REAL_HOME pm2 stop telebox
            read -p "按回车键返回菜单..."
            ;;
        7)
            echo -e "${YELLOW}命令：重启 TeleBox...${RESET}"
            sudo -u $REAL_USER HOME=$REAL_HOME pm2 restart telebox
            read -p "按回车键返回菜单..."
            ;;
        8)
            echo -e "${YELLOW}正在追踪实时日志 (退出查看请按 CTRL+C)...${RESET}"
            sudo -u $REAL_USER HOME=$REAL_HOME pm2 logs telebox
            ;;
        9)
            if [ ! -d "$PROJECT_DIR" ]; then
                echo -e "${RED}错误: 目录不存在！${RESET}"
            else
                echo -e "${YELLOW}清理旧缓存，准备彻底重构...${RESET}"
                cd "$PROJECT_DIR"
                sudo -u $REAL_USER HOME=$REAL_HOME npm cache clean --force
                rm -rf node_modules package-lock.json
                chown -R $REAL_USER:$REAL_USER "$PROJECT_DIR"
                sudo -u $REAL_USER HOME=$REAL_HOME npm install
                echo -e "${GREEN}统一目录依赖重构成功！${RESET}"
            fi
            read -p "按回车键返回菜单..."
            ;;
        10)
            read -p $'\e[31m危险操作：确定要彻底清除 TeleBox 目录及所有服务吗？(y/N): \e[0m' confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                echo -e "${RED}清除 PM2 守护进程...${RESET}"
                sudo -u $REAL_USER HOME=$REAL_HOME pm2 delete telebox 2>/dev/null
                sudo -u $REAL_USER HOME=$REAL_HOME pm2 save
                echo -e "${RED}清空统一安装目录 ${PROJECT_DIR}...${RESET}"
                rm -rf "$PROJECT_DIR"
                echo -e "${GREEN}卸载彻底完成！${RESET}"
            else
                echo -e "${YELLOW}操作已取消。${RESET}"
            fi
            read -p "按回车键返回菜单..."
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}输入有误，请输入菜单对应的有效数字！${RESET}"
            sleep 1.2
            ;;
    esac
done
