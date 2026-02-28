#!/bin/bash
# ========================================
# GS-Main 官方一键管理脚本 (x86 / ARM)
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="gm-service"
DATA_DIR="/opt/gmssh_data"
PORT_DEFAULT=8090

# ==============================
# 架构检测
# ==============================

detect_arch() {
    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64)
            IMAGE_NAME="docker-rep.gmssh.com/gmssh/gs-main-x86:latest"
            ;;
        aarch64|arm64)
            IMAGE_NAME="docker-rep.gmssh.com/gmssh/gs-main-arm:latest"
            ;;
        *)
            echo -e "${RED}❌ 不支持的架构: $ARCH${RESET}"
            exit 1
            ;;
    esac
}

# ==============================
# Docker检测
# ==============================

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi
}

# ==============================
# 安装
# ==============================

install_app() {

    check_docker
    detect_arch

    read -p "请输入访问端口 [默认:${PORT_DEFAULT}]: " input_port
    PORT=${input_port:-$PORT_DEFAULT}

    echo $PORT > "$DATA_DIR/port.conf"

    mkdir -p "$DATA_DIR/config" "$DATA_DIR/logs"

    echo -e "${GREEN}📦 拉取镜像...${RESET}"
    docker pull $IMAGE_NAME

    # 如果 config.json 不存在则生成
    if [ ! -f "$DATA_DIR/config/config.json" ]; then
        echo -e "${YELLOW}首次运行，正在生成默认配置文件...${RESET}"

        docker run -d --name ${APP_NAME}-latest \
            -p ${PORT}:80 \
            --restart always \
            $IMAGE_NAME

        sleep 3

        docker cp ${APP_NAME}-latest:/app/config/config.json "$DATA_DIR/config"

        docker stop ${APP_NAME}-latest
        docker rm ${APP_NAME}-latest
    fi

    # 删除旧容器
    docker rm -f $APP_NAME 2>/dev/null

    echo -e "${GREEN}🚀 正式启动服务...${RESET}"

    docker run -d \
        --name $APP_NAME \
        -p 127.0.0.1:${PORT}:80 \
        --restart always \
        -v "$DATA_DIR/logs:/gs_logs" \
        -v "$DATA_DIR/config:/app/config" \
        $IMAGE_NAME

    echo
    echo -e "${GREEN}✅ GS-Main 已启动${RESET}"
    echo -e "${YELLOW}📦 使用镜像: $IMAGE_NAME${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 数据目录: $DATA_DIR${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 更新
# ==============================

update_app() {
    detect_arch

    if [ -f "$DATA_DIR/port.conf" ]; then
        PORT=$(cat "$DATA_DIR/port.conf")
    else
        PORT=$PORT_DEFAULT
    fi

    docker pull $IMAGE_NAME
    docker rm -f $APP_NAME

    docker run -d \
        --name $APP_NAME \
        -p 127.0.0.1:${PORT}:80 \
        --restart always \
        -v "$DATA_DIR/logs:/gs_logs" \
        -v "$DATA_DIR/config:/app/config" \
        $IMAGE_NAME

    echo -e "${GREEN}✅ 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 其他功能
# ==============================

restart_app() {
    docker restart $APP_NAME
    echo -e "${GREEN}✅ 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f $APP_NAME
}

check_status() {
    docker ps | grep $APP_NAME
    read -p "按回车返回菜单..."
}

uninstall_app() {
    docker rm -f $APP_NAME 2>/dev/null
    rm -rf "$DATA_DIR"
    echo -e "${RED}✅ 已彻底卸载（含数据）${RESET}"
    read -p "按回车返回菜单..."
}

# ==============================
# 菜单
# ==============================

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== GMSSH 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
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
            *)
                echo -e "${RED}无效选择${RESET}"
                sleep 1
                ;;
        esac
    done
}

menu
