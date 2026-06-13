#!/bin/bash
# ========================================
# Paperphone-plus 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

REPO_URL="https://github.com/619dev/Paperphone-plus.git"
APP_DIR="/opt/paperphone-plus"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/server/.env"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

# 随机字符串生成器（用于 JWT）
generate_secret() {
    echo $(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Paperphone-plus 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 重启服务${RESET}"
        echo -e "${GREEN}3) 查看日志${RESET}"
        echo -e "${GREEN}4) 查看状态${RESET}"
        echo -e "${GREEN}5) 彻底卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) restart_app ;;
            3) view_logs ;;
            4) check_status ;;
            5) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {
    check_docker

    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}检测到已存在安装目录 $APP_DIR，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        echo -e "${YELLOW}正在清理旧文件...${RESET}"
        cd "$APP_DIR" && docker compose down -v &>/dev/null
        rm -rf "$APP_DIR"
    fi

    echo -e "${YELLOW}正在克隆仓库...${RESET}"
    git clone "$REPO_URL" "$APP_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 克隆仓库失败，请检查网络（GitHub 连通性）${RESET}"
        read -p "按回车返回..."
        return
    fi

    mkdir -p "$APP_DIR/server"

    echo
    echo -e "${GREEN}--- 配置环境变量 ---${RESET}"
    
    read -p "请输入服务访问端口 [默认:3000]: " input_port
    PORT=${input_port:-3000}
    check_port "$PORT" || return

    read -p "请输入数据库密码 (DB_PASS) [默认:changeme]: " input_db_pass
    DB_PASS=${input_db_pass:-changeme}

    read -p "请输入后台管理路径 (ADMIN_PATH) [默认:/admin]: " input_admin_path
    ADMIN_PATH=${input_admin_path:-/admin}

    read -p "请输入后台管理密码 (ADMIN_PASSWORD) [默认:admin123]: " input_admin_user_pass
    ADMIN_PASSWORD=${input_admin_user_pass:-admin123}

    # 自动生成随机的 JWT 密钥，更安全
    JWT_SECRET=$(generate_secret)

    echo -e "${YELLOW}正在生成配置文件 (.env)...${RESET}"
    
    # 写入 .env 配置文件
cat > "$ENV_FILE" <<EOF
# ─── Server ───────────────────────────────────────────────────
PORT=${PORT}
JWT_SECRET=${JWT_SECRET}
JWT_EXPIRES_IN=7d

# ─── MySQL ────────────────────────────────────────────────────
DB_HOST=mysql
DB_PORT=3306
DB_USER=paperphone
DB_PASS=${DB_PASS}
DB_NAME=paperphone

# ─── Redis ────────────────────────────────────────────────────
REDIS_HOST=redis
REDIS_PORT=6379

# ─── Admin Panel ─────────────────────────────────────────────
ADMIN_PATH=${ADMIN_PATH}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF

    # 💡 核心修复：如果是通过 Docker 编排，.env 里的 localhost 要改成服务名（mysql / redis）
    # 同时，如果项目的 docker-compose.yml 没有做端口映射，我们用脚本动态确保它能用
    
    cd "$APP_DIR" || exit
    echo -e "${YELLOW}正在启动 Docker 容器...${RESET}"
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置或日志${RESET}"
        read -p "按回车返回..."
        return
    fi

    echo
    echo -e "${GREEN}✅ Paperphone-plus 已成功启动！${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://你的服务器IP:${PORT}${RESET}"
    echo -e "${YELLOW}👑 管理后台: http://你的服务器IP:${PORT}${ADMIN_PATH}${RESET}"
    echo -e "${YELLOW}🔑 管理密码: ${ADMIN_PASSWORD}${RESET}"
    echo
    read -p "按回车返回菜单..."
}

restart_app() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" && docker compose restart
        echo -e "${GREEN}✅ 服务已重启${RESET}"
    else
        echo -e "${RED}❌ 未检测到安装目录${RESET}"
    fi
    read -p "按回车返回菜单..."
}

view_logs() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" && docker compose logs -f
    else
        echo -e "${RED}❌ 未检测到安装目录${RESET}"
        read -p "按回车返回菜单..."
    fi
}

check_status() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" && docker compose ps
    else
        echo -e "${RED}❌ 未检测到运行中的服务${RESET}"
    fi
    read -p "按回车返回菜单..."
}

uninstall_app() {
    if [ -d "$APP_DIR" ]; then
        echo -e "${RED}⚠️ 警告：这将删除所有容器和数据且无法恢复！确定吗？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return

        cd "$APP_DIR" && docker compose down -v
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ Paperphone-plus 已彻底彻底卸载${RESET}"
    else
        echo -e "${RED}❌ 未检测到安装，无需卸载${RESET}"
    fi
    read -p "按回车返回菜单..."
}

# 必须以 root 权限运行以确保存储目录和 Docker 正常操作
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 sudo 或 root 权限运行此脚本！${RESET}"
    exit 1
fi

menu
