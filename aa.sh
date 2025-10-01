#!/bin/bash
# ======================================
# Stb 图床 一键部署脚本
# - 支持自定义端口
# - 自动随机生成 JWT_SECRET
# - 自动挂载数据目录 /opt/stb/uploads
# - 自动拉取官方镜像
# ======================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

APP_NAME="stb"
APP_DIR="/opt/$APP_NAME"
UPLOAD_DIR="$APP_DIR/uploads"
IMAGE_NAME="ghcr.io/setube/stb:latest"

# 检查 Docker 是否安装
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}❌ 未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

# 生成随机 JWT_SECRET
gen_secret() {
    openssl rand -hex 32
}

# 部署 Stb
install_stb() {
    echo -ne "请输入 Web 端口 [默认:25519]: "
    read -r PORT
    PORT=${PORT:-25519}

    echo -e "${GREEN}📦 正在拉取官方镜像...${RESET}"
    if ! docker pull "$IMAGE_NAME"; then
        echo -e "${YELLOW}⚠️ 拉取 GHCR 失败，尝试 Docker Hub...${RESET}"
        IMAGE_NAME="setube/stb:latest"
        docker pull "$IMAGE_NAME" || { echo "❌ 镜像拉取失败"; exit 1; }
    fi

    mkdir -p "$UPLOAD_DIR"

    JWT_SECRET=$(gen_secret)

    echo -e "${GREEN}🚀 正在启动容器...${RESET}"
    docker run -d \
        --name $APP_NAME \
        -p ${PORT}:25519 \
        -e JWT_SECRET=$JWT_SECRET \
        -e VITE_APP_TITLE="Stb 图床" \
        -v $UPLOAD_DIR:/app/uploads \
        $IMAGE_NAME

    echo -e "${GREEN}✅ Stb 图床已启动${RESET}"
    echo -e "🌐 本地访问地址: ${YELLOW}http://127.0.0.1:${PORT}${RESET}"
    echo -e "🔑 JWT_SECRET: ${YELLOW}${JWT_SECRET}${RESET}"
    echo -e "📂 上传目录: ${YELLOW}$UPLOAD_DIR${RESET}"
}

# 卸载 Stb
uninstall_stb() {
    docker rm -f $APP_NAME 2>/dev/null
    echo -e "${GREEN}✅ Stb 图床容器已卸载${RESET}"
}

# 主菜单
while true; do
    clear
    echo -e "${GREEN}===== Stb 图床 管理脚本 =====${RESET}"
    echo -e "1. 安装/启动"
    echo -e "2. 卸载"
    echo -e "0. 退出"
    echo
    read -rp "请输入选项: " num
    case "$num" in
        1) install_stb ;;
        2) uninstall_stb ;;
        0) exit 0 ;;
        *) echo -e "${YELLOW}无效选项${RESET}" ;;
    esac
    echo
    read -rp "按回车返回菜单..."
done
