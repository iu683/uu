#!/bin/bash
# ========================================
# 1shell 一键管理
# Docker Compose 部署
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="1shell"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/weidu12123/1shell.git"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本${RESET}"
    exit 1
fi

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null)
            if [[ -n "$ip" ]]; then
                echo "$ip"
                return 0
            fi
        done
    done

    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null)
            if [[ -n "$ip" ]]; then
                echo "$ip"
                return 0
            fi
        done
    done

    echo "127.0.0.1"
    return 0
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&/\]/\\&/g'
}

function menu() {
    clear
    echo -e "${GREEN}=== 1shell 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 查看日志${RESET}"
    echo -e "${GREEN}4) 重启${RESET}"
    echo -e "${GREEN}5) 停止${RESET}"
    echo -e "${GREEN}6) 编辑配置${RESET}"
    echo -e "${GREEN}7) 查看状态${RESET}"
    echo -e "${GREEN}8) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) view_logs ;;
        4) restart_app ;;
        5) stop_app ;;
        6) edit_config ;;
        7) app_status ;;
        8) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

function check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}未检测到 docker compose 插件，请检查 Docker 安装${RESET}"
        exit 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo -e "${RED}未检测到 git，请先安装 git${RESET}"
        exit 1
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${RED}未检测到 openssl，请先安装 openssl${RESET}"
        exit 1
    fi
}

function set_env_value() {
    local key="$1"
    local value="$2"
    local file="$3"
    local escaped_value

    escaped_value=$(escape_sed_replacement "$value")

    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

function install_app() {
    echo -e "${YELLOW}开始安装 1shell...${RESET}"

    check_docker

    mkdir -p "$APP_DIR"

    if [ ! -d "$APP_DIR/.git" ]; then
        git clone "$REPO_URL" "$APP_DIR"
    else
        echo -e "${YELLOW}检测到项目目录已存在，跳过克隆${RESET}"
    fi

    cd "$APP_DIR" || exit 1

    if [ ! -f ".env" ]; then
        cp .env.example .env
    fi

    echo
    echo -e "${GREEN}请填写 1shell 配置${RESET}"

    read -p "OpenAI API Base [默认: https://api.openai.com/v1]: " OPENAI_API_BASE
    read -p "OpenAI API Key: " OPENAI_API_KEY
    read -p "OpenAI Model [默认: gpt-4o]: " OPENAI_MODEL
    read -p "登录用户名 [默认: admin]: " APP_LOGIN_USERNAME
    read -p "登录密码 [默认: admin]: " APP_LOGIN_PASSWORD
    read -p "会话有效期小时 [默认: 12]: " APP_SESSION_TTL_HOURS

    OPENAI_API_BASE=${OPENAI_API_BASE:-https://api.openai.com/v1}
    OPENAI_MODEL=${OPENAI_MODEL:-gpt-4o}
    APP_LOGIN_USERNAME=${APP_LOGIN_USERNAME:-admin}
    APP_LOGIN_PASSWORD=${APP_LOGIN_PASSWORD:-admin}
    APP_SESSION_TTL_HOURS=${APP_SESSION_TTL_HOURS:-12}
    PORT=${PORT:-3301}

    BRIDGE_TOKEN=$(openssl rand -hex 32)
    APP_SECRET=$(openssl rand -hex 32)

    echo -e "${GREEN}已自动生成 Bridge Token${RESET}"
    echo -e "${GREEN}已自动生成 APP_SECRET${RESET}"

    set_env_value "OPENAI_API_BASE" "$OPENAI_API_BASE" ".env"
    set_env_value "OPENAI_API_KEY" "$OPENAI_API_KEY" ".env"
    set_env_value "OPENAI_MODEL" "$OPENAI_MODEL" ".env"
    set_env_value "APP_LOGIN_USERNAME" "$APP_LOGIN_USERNAME" ".env"
    set_env_value "APP_LOGIN_PASSWORD" "$APP_LOGIN_PASSWORD" ".env"
    set_env_value "APP_SESSION_TTL_HOURS" "$APP_SESSION_TTL_HOURS" ".env"
    set_env_value "PORT" "$PORT" ".env"
    set_env_value "BRIDGE_TOKEN" "$BRIDGE_TOKEN" ".env"
    set_env_value "APP_SECRET" "$APP_SECRET" ".env"

    echo -e "${GREEN}启动容器...${RESET}"
    docker compose up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ 1shell 已安装并启动${RESET}"
    echo -e "${YELLOW}访问地址: http://${SERVER_IP}:${PORT}${RESET}"
    echo -e "${YELLOW}登录信息: ${APP_LOGIN_USERNAME} / ${APP_LOGIN_PASSWORD}${RESET}"
    echo -e "${RED}请妥善保存登录密码和密钥信息${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
        sleep 1
        menu
    }

    echo -e "${GREEN}更新程序...${RESET}"
    git pull

    echo -e "${GREEN}重新拉起容器...${RESET}"
    docker compose up -d --build

    echo -e "${GREEN}✅ 1shell 已更新${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    docker compose logs -f

    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    docker compose restart

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function stop_app() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    docker compose down

    echo -e "${GREEN}✅ 已停止${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function edit_config() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    nano .env

    echo -e "${YELLOW}配置已编辑，正在重启容器...${RESET}"
    docker compose up -d --build

    echo -e "${GREEN}✅ 配置已生效${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function app_status() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    local port
    port=$(grep '^PORT=' .env | cut -d= -f2)

    echo -e "${GREEN}容器状态：${RESET}"
    docker compose ps
    echo
    echo -e "${GREEN}端口监听：${RESET}"
    ss -tulnp | grep -E ":${port}" || true
    echo
    echo -e "${GREEN}访问地址：${RESET}http://$(get_public_ip):${port}"

    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" && docker compose down
    fi

    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ 1shell 已卸载（包含数据）${RESET}"

    read -p "按回车返回菜单..."
    menu
}

menu
