#!/bin/bash
# ========================================
# STB 本地源码一键管理脚本
# 统一目录 /opt/stb，含源码、日志、Docker MongoDB
# ========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

REPO_URL="https://github.com/setube/stb.git"
BASE_DIR="/opt/stb"
APP_DIR="$BASE_DIR/app"
LOG_FILE="$BASE_DIR/app.log"
MONGO_CONTAINER="stb-mongo"
MONGO_PORT=27017
MONGO_HOST="mongodb://localhost:${MONGO_PORT}/stb"
# 获取公网 IP
    SERVER_IP=$(curl -s https://ifconfig.me)

mkdir -p "$BASE_DIR"

# ================== 菜单 ==================
function show_menu() {
    echo -e "${CYAN}================= STB 管理脚本 =================${RESET}"
    echo -e "${GREEN}1.  下载源码${RESET}"
    echo -e "${GREEN}2.  安装 Node.js / pnpm / 项目依赖${RESET}"
    echo -e "${GREEN}3.  编译项目${RESET}"
    echo -e "${GREEN}4.  安装 MongoDB(Docker)${RESET}"
    echo -e "${GREEN}5.  检测 MongoDB${RESET}"
    echo -e "${GREEN}6.  启动项目${RESET}"
    echo -e "${GREEN}7.  查看日志${RESET}"
    echo -e "${GREEN}8.  停止项目${RESET}"
    echo -e "${GREEN}9.  卸载项目及环境${RESET}"
    echo -e "${GREEN}10. 更新项目${RESET}"
    echo -e "${GREEN}0.  退出${RESET}"
    echo -e "${CYAN}==============================================${RESET}"
}

# ================== 功能 ==================
function clone_repo() {
    if [ -d "$APP_DIR" ]; then
        echo -e "${YELLOW}目录 $APP_DIR 已存在，跳过克隆${RESET}"
    else
        echo -e "${GREEN}正在克隆源码...${RESET}"
        git clone $REPO_URL "$APP_DIR"
    fi
}

function install_dependencies() {
    echo -e "${YELLOW}检查 Node.js 是否安装...${RESET}"
    if ! command -v node >/dev/null 2>&1; then
        echo -e "${GREEN}未检测到 Node.js，开始安装...${RESET}"
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt install -y nodejs
    fi
    echo -e "${GREEN}Node.js 已安装: $(node -v)${RESET}"

    echo -e "${YELLOW}检查 pnpm 是否安装...${RESET}"
    if ! command -v pnpm >/dev/null 2>&1; then
        echo -e "${GREEN}未检测到 pnpm，开始安装...${RESET}"
        npm install -g pnpm
    fi
    echo -e "${GREEN}pnpm 已安装: $(pnpm -v)${RESET}"

    echo -e "${GREEN}安装项目依赖...${RESET}"
    cd "$APP_DIR" || exit
    pnpm install
}

function build_project() {
    echo -e "${GREEN}编译项目...${RESET}"
    cd "$APP_DIR" || exit
    pnpm build
}

function check_mongo() {
    echo -e "${YELLOW}检测 MongoDB 服务...${RESET}"
    nc -z -w 3 localhost $MONGO_PORT
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}MongoDB 可用: $MONGO_HOST${RESET}"
        return 0
    else
        echo -e "${RED}无法连接 MongoDB: $MONGO_HOST${RESET}"
        return 1
    fi
}

function start_project() {
    check_mongo || { echo -e "${RED}请先确保 MongoDB 可用${RESET}"; return; }
    echo -e "${GREEN}启动项目...${RESET}"
    cd "$APP_DIR" || exit
    export MONGO_URL=$MONGO_HOST
    nohup pnpm start > "$LOG_FILE" 2>&1 &
    echo -e "${YELLOW}项目已启动，日志输出到 $LOG_FILE${RESET}"
    echo -e "${YELLOW}访问地址 http://${SERVER_IP}:25519${RESET}"

}

function view_logs() {
    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        echo -e "${RED}日志文件不存在，请先启动项目${RESET}"
    fi
}

function stop_project() {
    echo -e "${YELLOW}停止项目...${RESET}"
    PID=$(pgrep -f "pnpm start")
    if [ "$PID" ]; then
        kill -9 $PID
        echo -e "${GREEN}项目已停止${RESET}"
    else
        echo -e "${RED}项目未运行${RESET}"
    fi
}

function install_mongo() {
    echo -e "${YELLOW}使用 Docker 安装 MongoDB...${RESET}"
    docker pull mongo:6
    docker run -d --name $MONGO_CONTAINER -p $MONGO_PORT:27017 -v "$BASE_DIR/mongo_data:/data/db" mongo:6
    echo -e "${GREEN}MongoDB Docker 容器已启动，端口 $MONGO_PORT${RESET}"
}

function uninstall_all() {
    echo -e "${YELLOW}停止项目...${RESET}"
    stop_project

    echo -e "${YELLOW}删除 STB 项目目录...${RESET}"
    rm -rf "$APP_DIR" "$LOG_FILE"
    echo -e "${GREEN}STB 项目目录已删除${RESET}"

    echo -e "${YELLOW}删除 MongoDB Docker 容器...${RESET}"
    if docker ps -a | grep $MONGO_CONTAINER >/dev/null; then
        docker stop $MONGO_CONTAINER
        docker rm $MONGO_CONTAINER
        rm -rf "$BASE_DIR/mongo_data"
        rm -rf "$BASE_DIR"
        echo -e "${GREEN}MongoDB Docker 容器及数据已删除${RESET}"
    fi

    echo -e "${YELLOW}是否卸载 Node.js 和 pnpm? (y/N)${RESET}"
    read -p "请输入: " yn
    if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
        sudo apt purge -y nodejs
        sudo npm uninstall -g pnpm
        sudo apt autoremove -y
        echo -e "${GREEN}Node.js 和 pnpm 已卸载${RESET}"
    fi

    echo -e "${GREEN}卸载完成${RESET}"
}

function update_project() {
    echo -e "${YELLOW}停止项目以便更新...${RESET}"
    stop_project

    if [ -d "$APP_DIR" ]; then
        echo -e "${GREEN}进入项目目录更新源码...${RESET}"
        cd "$APP_DIR" || exit
        git fetch --all
        git reset --hard origin/main
    else
        echo -e "${RED}项目目录不存在，先下载源码${RESET}"
        clone_repo
    fi

    echo -e "${GREEN}更新依赖并编译...${RESET}"
    cd "$APP_DIR" || exit
    pnpm install
    pnpm build

    echo -e "${YELLOW}更新完成。是否立即启动项目? (y/N)${RESET}"
    read -p "请输入: " yn
    if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
        start_project
    fi
}

# ================== 主循环 ==================
while true; do
    show_menu
    read -p "请输入选项: " choice
    case $choice in
        1) clone_repo ;;
        2) install_dependencies ;;
        3) build_project ;;
        4) install_mongo ;;
        5) check_mongo ;;
        6) start_project ;;
        7) view_logs ;;
        8) stop_project ;;
        9) uninstall_all ;;
        10) update_project ;;
        0) echo -e "${GREEN}退出脚本${RESET}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入${RESET}" ;;
    esac
done
