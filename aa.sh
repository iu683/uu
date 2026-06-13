#!/bin/bash
# ========================================
# sub2api 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

REPO_URL="https://github.com/Wei-Shaw/sub2api.git"
APP_DIR="/opt/sub2api"
ENV_FILE="$APP_DIR/deploy/.env"
COMPOSE_FILE="docker-compose.local.yml"

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

# 使用原生的 openssl 生成 32 字节高强度密钥
generate_secure_secret() {
    openssl rand -hex 32
}

get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== sub2api 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新服务${RESET}"
        echo -e "${GREEN}3) 重启服务${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载服务${RESET}"
        echo -e "${GREEN}0) 退出脚本${RESET}"
        echo
        read -p "$(echo -e ${GREEN}请选择 [0-6]: ${RESET})" choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择，请重新输入...${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {
    check_docker

    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}检测到已存在安装目录 $APP_DIR，是否覆盖安装？(y/n)${RESET}"
        read -p "请输入: " confirm
        [[ "$confirm" != "y" ]] && return
        echo -e "${YELLOW}正在清理旧文件...${RESET}"
        cd "$APP_DIR/deploy" 2>/dev/null && docker compose -f $COMPOSE_FILE down -v &>/dev/null
        rm -rf "$APP_DIR"
    fi

    echo -e "${YELLOW}正在克隆仓库...${RESET}"
    git clone "$REPO_URL" "$APP_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 克隆仓库失败，请检查网络（GitHub 连通性）${RESET}"
        read -p "按回车返回..."
        return
    fi

    echo
    echo -e "${GREEN}--- 配置环境变量 ---${RESET}"

    # 验证服务端口
    while true; do
        read -p "请输入服务端口 (SERVER_PORT) [默认:8080]: " input_port
        SERVER_PORT=${input_port:-8080}
        check_port "$SERVER_PORT" && break
    done

    read -p "请输入管理员邮箱 (ADMIN_EMAIL) [默认:admin@example.com]: " input_email
    ADMIN_EMAIL=${input_email:-admin@example.com}

    read -p "请输入管理员密码 (ADMIN_PASSWORD) [默认:admin123]: " input_admin_pass
    ADMIN_PASSWORD=${input_admin_pass:-admin123}

    # 自动化生成安全强度的各类 Secret 密钥
    echo -e "${YELLOW}正在生成高强度安全密钥...${RESET}"
    POSTGRES_PASSWORD=$(generate_secure_secret)
    JWT_SECRET=$(generate_secure_secret)
    TOTP_ENCRYPTION_KEY=$(generate_secure_secret)

    echo -e "${YELLOW}正在创建本地持久化数据目录...${RESET}"
    cd "$APP_DIR/deploy" || exit
    mkdir -p data postgres_data redis_data

    echo -e "${YELLOW}正在生成配置文件 (.env)...${RESET}"
    
    # 写入 .env 配置文件
cat > "$ENV_FILE" <<EOF
# ─── Required Secrets ─────────────────────────────────────────
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${JWT_SECRET}
TOTP_ENCRYPTION_KEY=${TOTP_ENCRYPTION_KEY}

# ─── Admin Account ────────────────────────────────────────────
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}

# ─── Port Configuration ───────────────────────────────────────
SERVER_PORT=${SERVER_PORT}
EOF

    echo -e "${YELLOW}正在启动 Docker 容器...${RESET}"
    docker compose -f $COMPOSE_FILE up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置或日志${RESET}"
        read -p "按回车返回..."
        return
    fi

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ sub2api 已成功启动！${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://${SERVER_IP}:${SERVER_PORT}${RESET}"
    echo -e "${YELLOW}👑 管理账号: ${ADMIN_EMAIL}${RESET}"
    echo -e "${YELLOW}🔑 管理密码: ${ADMIN_PASSWORD}${RESET}"
    echo -e "${GREEN}📂 数据目录: ${APP_DIR}/deploy${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    if [ -d "$APP_DIR/deploy" ]; then
        cd "$APP_DIR/deploy" && docker compose -f $COMPOSE_FILE restart
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
    
    git stash &>/dev/null
    git pull

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 代码拉取失败，请检查网络或 GitHub 状态。${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "${YELLOW}正在后台拉取最新镜像并更新...${RESET}"
    cd "$APP_DIR/deploy" || return
    docker compose -f $COMPOSE_FILE pull
    docker compose -f $COMPOSE_FILE up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 更新失败，请查看日志！${RESET}"
    else
        echo -e "${GREEN}✅ sub2api 已完成更新！${RESET}"
    fi
    read -p "按回车返回菜单..."
}

view_logs() {
    if [ -d "$APP_DIR/deploy" ]; then
        cd "$APP_DIR/deploy" && docker compose -f $COMPOSE_FILE logs -f
    else
        echo -e "${RED}❌ 未检测到安装目录${RESET}"
        read -p "按回车返回菜单..."
    fi
}

check_status() {
    if [ -d "$APP_DIR/deploy" ]; then
        cd "$APP_DIR/deploy" && docker compose -f $COMPOSE_FILE ps
    else
        echo -e "${RED}❌ 未检测到运行中的服务${RESET}"
    fi
    read -p "按回车返回菜单..."
}

uninstall_app() {
    if [ -d "$APP_DIR" ]; then
    
        cd "$APP_DIR/deploy" 2>/dev/null && docker compose -f $COMPOSE_FILE down -v
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ sub2api 已彻底卸载${RESET}"
    else
        echo -e "${RED}❌ 未检测到安装，无需卸载${RESET}"
    fi
    read -p "按回车返回菜单..."
}

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 sudo 或 root 权限运行此脚本！${RESET}"
    exit 1
fi

# 启动菜单入口
menu
