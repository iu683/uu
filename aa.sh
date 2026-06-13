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


get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Paperphone-plus 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
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
PORT=3000
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


    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ Paperphone-plus 已成功启动！${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://${SERVER_IP}:80${RESET}"
    echo -e "${YELLOW}👑 管理后台: http://${SERVER_IP}:80${ADMIN_PATH}${RESET}"
    echo -e "${YELLOW}👑 后端地址: http://${SERVER_IP}:3000${RESET}"
    echo -e "${YELLOW}🔑 管理密码: ${ADMIN_PASSWORD}${RESET}"
    echo -e "${GREEN}📂 数据目录: ${APP_DIR}${RESET}"
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


update_app() {
    if [ ! -d "$APP_DIR" ]; then
        echo -e "${RED}❌ 未检测到安装目录，无法更新！${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    cd "$APP_DIR" || return
    echo -e "${YELLOW}正在从 GitHub 拉取最新源码...${RESET}"
    
    # 暂存本地可能产生的临时变动，确保 pull 成功
    git stash &>/dev/null
    git pull

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 代码拉取失败，请检查网络或 GitHub 状态。${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "${YELLOW}正在后台拉取镜像并更新...${RESET}"
    
    docker compose pull
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 更新失败，请查看日志！${RESET}"
    else
        echo -e "${GREEN}✅ Paperphone-plus 已完成更新！${RESET}"
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

        cd "$APP_DIR" && docker compose down -v
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ Paperphone-plus 已彻底卸载${RESET}"
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
