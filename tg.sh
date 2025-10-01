#!/bin/bash
# ======================================
# Stb 图床 一键部署脚本 (自动下载源码+构建)
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="stb"
APP_DIR="/opt/stb"
IMAGE_NAME="stb:latest"
REPO_URL="https://github.com/setube/stb.git"

# 检查 Docker
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

# 随机生成 JWT_SECRET
gen_secret() {
    openssl rand -hex 32
}

# 下载源码
download_source() {
    echo -e "${YELLOW}📥 正在下载 Stb 源码...${RESET}"
    rm -rf $APP_DIR
    git clone $REPO_URL $APP_DIR
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}❌ 下载失败，请检查网络或 Git 是否可用${RESET}"
        exit 1
    fi
}

# 构建并启动
install_app() {
    read -rp "请输入 Web 端口 [默认:25519]: " PORT
    PORT=${PORT:-25519}

    download_source
    cd $APP_DIR || exit

    echo -e "${YELLOW}📦 正在构建镜像...${RESET}"
    docker build -t $IMAGE_NAME .

    echo -e "${YELLOW}🚀 正在启动容器...${RESET}"
    mkdir -p "$APP_DIR/uploads"
    JWT_SECRET=$(gen_secret)

    docker run -d \
        --name $APP_NAME \
        -p ${PORT}:25519 \
        -e JWT_SECRET=$JWT_SECRET \
        -e VITE_APP_TITLE="Stb 图床" \
        -v $APP_DIR/uploads:/app/uploads \
        $IMAGE_NAME

    echo -e "${GREEN}✅ Stb 图床已启动${RESET}"
    echo -e "本地访问地址: ${YELLOW}http://127.0.0.1:${PORT}${RESET}"
    echo -e "JWT_SECRET: ${GREEN}${JWT_SECRET}${RESET}"
    echo -e "上传目录: ${GREEN}$APP_DIR/uploads${RESET}"

    read -rp "按回车返回菜单..."
    menu
}

# 更新
update_app() {
    echo -e "${YELLOW}🔄 更新源码并重新构建...${RESET}"
    docker stop $APP_NAME && docker rm $APP_NAME
    install_app
}

# 卸载
uninstall_app() {
    docker stop $APP_NAME && docker rm $APP_NAME
    docker rmi $IMAGE_NAME
    rm -rf $APP_DIR
    echo -e "${RED}✅ 已卸载 Stb 图床${RESET}"
    read -rp "按回车返回菜单..."
    menu
}

# 查看日志
view_logs() {
    docker logs -f $APP_NAME
    read -rp "按回车返回菜单..."
    menu
}

menu() {
    clear
    echo -e "${GREEN}=== Stb 图床 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

check_docker
menu
