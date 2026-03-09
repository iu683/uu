#!/bin/bash
# ========================================
# Sakura_embyboss 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="Sakura_embyboss"
APP_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/berry8838/Sakura_embyboss.git"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.json"
CONFIG_TEMPLATE="$APP_DIR/config_example.json"

# ==============================
# 基础检测
# ==============================

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

check_python() {
    if ! command -v python3 &>/dev/null; then
        echo -e "${YELLOW}未检测到 Python3，正在安装...${RESET}"
        sudo apt update && sudo apt install -y python3 python3-pip
    fi
}

# ==============================
# 菜单
# ==============================

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Sakura_embyboss 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 拉取代码 / 安装依赖${RESET}"
        echo -e "${GREEN}2) 初始化配置文件${RESET}"
        echo -e "${GREEN}3) 一键启动${RESET}"
        echo -e "${GREEN}4) 更新${RESET}"
        echo -e "${GREEN}5) 查看日志${RESET}"
        echo -e "${GREEN}6) 查看状态${RESET}"
        echo -e "${GREEN}7) 卸载（含数据）${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) pull_code ;;
            2) init_config ;;
            3) start_app ;;
            4) update_app ;;
            5) view_logs ;;
            6) check_status ;;
            7) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

# ==============================
# 拉取代码 / 安装依赖
# ==============================

pull_code() {
    check_python
    check_docker

    mkdir -p "$APP_DIR"
    if [ -d "$APP_DIR/.git" ]; then
        echo -e "${YELLOW}检测到已拉取仓库，是否拉取最新代码？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        cd "$APP_DIR" && git pull
    else
        git clone "$REPO_URL" "$APP_DIR" && cd "$APP_DIR"
        chmod +x main.py
    fi

    echo -e "${GREEN}✅ 代码拉取完成${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 初始化配置
# ==============================

init_config() {
    if [ ! -f "$CONFIG_TEMPLATE" ]; then
        echo -e "${RED}config_example.json 模板不存在，请先拉取代码${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    cp -n "$CONFIG_TEMPLATE" "$CONFIG_FILE"
    echo -e "${GREEN}✅ 已生成 config.json，编辑完成必填项后再启动${RESET}"
    echo -e "${YELLOW}请使用编辑器修改: $CONFIG_FILE${RESET}"
    read -p "按回车打开编辑器(vi)..."
    vi "$CONFIG_FILE"
}

# ==============================
# 启动
# ==============================

start_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose up -d
    echo -e "${GREEN}✅ Sakura_embyboss 已启动${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 更新
# ==============================

update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose down
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Sakura_embyboss 已更新${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 日志
# ==============================

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f embyboss
}

# ==============================
# 状态
# ==============================

check_status() {
    docker ps | grep embyboss
    read -p "按回车返回菜单..."
}

# ==============================
# 卸载
# ==============================

uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; return; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Sakura_embyboss 已彻底卸载（含数据）${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 启动菜单
# ==============================

menu
