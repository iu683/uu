#!/bin/bash
# ========================================
# EmbyProxy 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="embyproxy"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"

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

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== EmbyProxy 管理菜单 ===${RESET}"
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
    mkdir -p "$APP_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已存在配置文件，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo
    echo -e "${GREEN}--- 配置基础参数 ---${RESET}"
    
    # 1. 配置端口
    read -p "请输入 EmbyProxy 监听端口 [默认:8787]: " input_port
    PORT=${input_port:-8787}
    check_port "$PORT" || return

    # 2. 配置 Admin Token
    read -p "请输入管理员 Token (建议设置复杂密码): " input_token
    while [ -z "$input_token" ]; do
        echo -e "${RED}管理员 Token 不能为空！${RESET}"
        read -p "请重新输入管理员 Token: " input_token
    done
    ADMIN_TOKEN="$input_token"

    # 3. 创建宿主机数据挂载目录
    mkdir -p "$APP_DIR/data"

    # 4. 生成 .env 配置文件
    echo -e "${YELLOW}正在生成 .env 配置文件...${RESET}"
    cat > "$ENV_FILE" <<EOF
# 管理员 Token
ADMIN_TOKEN=${ADMIN_TOKEN}

# 监听端口
PORT=${PORT}

# SQLite 数据库路径（容器内部绝对路径）
DB_PATH=/app/data/proxy.db

# 系统显示时区
TZ=Asia/Shanghai
EOF

    # 5. 生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成 docker-compose.yml...${RESET}"
    cat > "$COMPOSE_FILE" <<EOF
services:
  app:
    image: \${EMBYPROXY_IMAGE:-ghcr.io/hkfires/embyproxy:latest}
    container_name: embyproxy
    restart: unless-stopped
    ports:
      - "127.0.0.1:\${PORT:-8787}:\${PORT:-8787}"
    volumes:
      - ./data:/app/data
    environment:
      PORT: "\${PORT:-8787}"
      DB_PATH: "\${DB_PATH:-/app/data/proxy.db}"
      TZ: "\${TZ:-Asia/Shanghai}"
    env_file:
      - .env
EOF

    cd "$APP_DIR" || exit
    echo -e "${YELLOW}正在启动 Docker 容器...${RESET}"
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 启动失败，请检查配置或日志${RESET}"
        read -p "按回车返回..."
        return
    fi

    echo
    echo -e "${GREEN}✅ EmbyProxy 已成功启动！${RESET}"
    echo -e "${YELLOW}🌐 Web 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}🔑 管理员 Token: ${ADMIN_TOKEN}${RESET}"
    echo -e "${GREEN}📂 安装目录: ${APP_DIR}${RESET}"
    read -p "按回车返回菜单..."
}

update_app() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}❌ 未检测到配置文件，无法更新！${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    cd "$APP_DIR" || return
    echo -e "${YELLOW}正在后台拉取最新镜像...${RESET}"
    docker compose pull

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 镜像拉取失败，请检查网络状况。${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "${YELLOW}正在热更新服务...${RESET}"
    docker compose up -d

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 更新启动失败，请查看日志！${RESET}"
    else
        echo -e "${GREEN}✅ EmbyProxy 已完成更新！${RESET}"
    fi
    read -p "按回车返回菜单..."
}

restart_app() {
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$APP_DIR" && docker compose restart
        echo -e "${GREEN}✅ EmbyProxy 服务已重启${RESET}"
    else
        echo -e "${RED}❌ 未检测到服务，无法重启${RESET}"
    fi
    read -p "按回车返回菜单..."
}

view_logs() {
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$APP_DIR" && docker compose logs -f
    else
        echo -e "${RED}❌ 未检测到服务，无法查看日志${RESET}"
        read -p "按回车返回菜单..."
    fi
}

check_status() {
    if [ -f "$COMPOSE_FILE" ]; then
        cd "$APP_DIR" && docker compose ps
    else
        echo -e "${RED}❌ 未检测到运行中的服务${RESET}"
    fi
    read -p "按回车返回菜单..."
}

uninstall_app() {
    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}正在卸载 EmbyProxy 并清理数据...${RESET}"
        cd "$APP_DIR" && docker compose down
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ EmbyProxy 已彻底卸载完成${RESET}"
    else
        echo -e "${RED}❌ 未检测到安装，无需卸载${RESET}"
    fi
    read -p "按回车返回菜单..."
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 sudo 或 root 权限运行此脚本！${RESET}"
    exit 1
fi

menu
