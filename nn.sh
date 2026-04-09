#!/bin/bash
# ========================================
# LuckyLilliaBot 一键管理脚本
# Debian / Ubuntu 兼容
# 基于官方 Docker 安装脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

APP_NAME="LuckyLilliaBot"
APP_DIR="/opt/llbot"
INSTALL_SCRIPT_URL="https://gh-proxy.com/https://raw.githubusercontent.com/LLOneBot/LuckyLilliaBot/refs/heads/main/script/install-llbot-docker.sh"
INSTALL_SCRIPT_NAME="llbot-docker.sh"
COMPOSE_FILE_YML="$APP_DIR/docker-compose.yml"
COMPOSE_FILE_YAML="$APP_DIR/docker-compose.yaml"
DEFAULT_PORT="3080"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本${RESET}"
    exit 1
fi

get_public_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
        ip=$(curl -4s --max-time 5 "$url" 2>/dev/null)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo "127.0.0.1"
}

get_compose_file() {
    if [ -f "$COMPOSE_FILE_YML" ]; then
        echo "$COMPOSE_FILE_YML"
    elif [ -f "$COMPOSE_FILE_YAML" ]; then
        echo "$COMPOSE_FILE_YAML"
    else
        echo ""
    fi
}

compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== LuckyLilliaBot 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 查看日志${RESET}"
    echo -e "${GREEN}4) 重启${RESET}"
    echo -e "${GREEN}5) 停止${RESET}"
    echo -e "${GREEN}6) 编辑配置${RESET}"
    echo -e "${GREEN}7) 设置自动登录QQ${RESET}"
    echo -e "${GREEN}8) 查看状态${RESET}"
    echo -e "${GREEN}9) 卸载(含数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) view_logs ;;
        4) restart_app ;;
        5) stop_app ;;
        6) edit_config ;;
        7) set_auto_login_qq ;;
        8) app_status ;;
        9) uninstall_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

check_requirements() {
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
        apt update
        apt install -y curl
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        echo -e "${RED}未检测到 docker compose / docker-compose，请先安装${RESET}"
        exit 1
    fi
}

install_app() {
    check_requirements

    mkdir -p "$APP_DIR"
    cd "$APP_DIR" || exit 1

    echo -e "${GREEN}下载官方安装脚本...${RESET}"
    curl -fsSL "$INSTALL_SCRIPT_URL" -o "$INSTALL_SCRIPT_NAME"

    chmod u+x "./$INSTALL_SCRIPT_NAME"

    echo -e "${GREEN}执行官方安装脚本...${RESET}"
    "./$INSTALL_SCRIPT_NAME"

    local compose_file
    compose_file=$(get_compose_file)

    if [ -z "$compose_file" ]; then
        echo -e "${RED}未检测到 docker-compose.yml 或 docker-compose.yaml，请检查安装脚本是否执行成功${RESET}"
        read -p "按回车返回菜单..."
        menu
        return
    fi

    echo -e "${GREEN}启动容器...${RESET}"
    compose_cmd up -d

    local SERVER_IP
    SERVER_IP=$(get_public_ip)

    cat > "$APP_DIR/install-info.txt" <<EOF
WebUI 地址: http://${SERVER_IP}:${DEFAULT_PORT}
本地访问: http://localhost:${DEFAULT_PORT}
安装目录: ${APP_DIR}
Compose 文件: ${compose_file}
说明: 首次请按日志提示扫码登录 QQ
EOF

    echo
    echo -e "${GREEN}✅ LuckyLilliaBot 已安装并启动${RESET}"
    echo -e "${YELLOW}WebUI 地址: http://${SERVER_IP}:${DEFAULT_PORT}${RESET}"
    echo -e "${YELLOW}本地访问: http://localhost:${DEFAULT_PORT}${RESET}"
    echo -e "${YELLOW}首次请查看日志，按提示扫码登录 QQ${RESET}"

    read -p "按回车返回菜单..."
    menu
}

update_app() {
    check_requirements

    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录，请先安装${RESET}"
        sleep 1
        menu
    }

    docker compose pull
    docker compose up -d

    echo -e "${GREEN}✅ LuckyLilliaBot 已更新${RESET}"

    read -p "按回车返回菜单..."
    menu
}

view_logs() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    compose_cmd logs -f

    read -p "按回车返回菜单..."
    menu
}

restart_app() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    compose_cmd restart

    echo -e "${GREEN}✅ 已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

stop_app() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    compose_cmd down

    echo -e "${GREEN}✅ 已停止${RESET}"

    read -p "按回车返回菜单..."
    menu
}

edit_config() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    local compose_file
    compose_file=$(get_compose_file)

    if [ -z "$compose_file" ]; then
        echo -e "${RED}未找到 compose 配置文件${RESET}"
        sleep 1
        menu
    fi

    nano "$compose_file"

    echo -e "${YELLOW}配置已编辑，正在重新部署...${RESET}"
    compose_cmd up -d

    echo -e "${GREEN}✅ 配置已生效${RESET}"

    read -p "按回车返回菜单..."
    menu
}

set_auto_login_qq() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    local compose_file
    compose_file=$(get_compose_file)

    if [ -z "$compose_file" ]; then
        echo -e "${RED}未找到 compose 配置文件${RESET}"
        sleep 1
        menu
    fi

    read -p "请输入要自动登录的 QQ 号: " AUTO_LOGIN_QQ

    if [[ -z "$AUTO_LOGIN_QQ" ]]; then
        echo -e "${RED}QQ 号不能为空${RESET}"
        sleep 1
        menu
    fi

    if grep -q "AUTO_LOGIN_QQ=" "$compose_file"; then
        sed -i "s|AUTO_LOGIN_QQ=.*|AUTO_LOGIN_QQ=${AUTO_LOGIN_QQ}|g" "$compose_file"
    else
        echo -e "${YELLOW}未检测到 AUTO_LOGIN_QQ，正在尝试插入到 environment 中...${RESET}"
        sed -i "/pmhq:/,/^[^[:space:]]/ s/\(\s*environment:\)/\1\n      - AUTO_LOGIN_QQ=${AUTO_LOGIN_QQ}/" "$compose_file"
    fi

    echo -e "${YELLOW}正在重新部署容器...${RESET}"
    compose_cmd up -d

    echo -e "${GREEN}✅ AUTO_LOGIN_QQ 已设置为 ${AUTO_LOGIN_QQ}${RESET}"
    echo -e "${YELLOW}提示：首次扫码登录成功后，下次启动才会自动登录${RESET}"

    read -p "按回车返回菜单..."
    menu
}

app_status() {
    cd "$APP_DIR" || {
        echo -e "${RED}未检测到安装目录${RESET}"
        sleep 1
        menu
    }

    echo -e "${GREEN}容器状态：${RESET}"
    compose_cmd ps
    echo
    echo -e "${GREEN}端口监听：${RESET}"
    ss -tulnp | grep -E ":${DEFAULT_PORT}" || true
    echo
    if [ -f "$APP_DIR/install-info.txt" ]; then
        echo -e "${GREEN}安装信息：${RESET}"
        cat "$APP_DIR/install-info.txt"
    fi

    read -p "按回车返回菜单..."
    menu
}

uninstall_app() {
    if [ -d "$APP_DIR" ]; then
        cd "$APP_DIR" && compose_cmd down
    fi

    rm -rf "$APP_DIR"

    echo -e "${GREEN}✅ LuckyLilliaBot 已卸载（包含数据）${RESET}"
    read -p "按回车返回菜单..."
    menu
}

menu
