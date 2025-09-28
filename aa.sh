#!/bin/bash
# ========================================
# OCI Helper 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="oci-helper"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

# 获取公网 IP
get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

function menu() {
    clear
    echo -e "${GREEN}=== OCI Helper 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}=======================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    # 自定义端口
    read -p "请输入 oci-helper 端口 [默认:8818]: " input_oci
    OCI_PORT=${input_oci:-8818}

    read -p "请输入 websockify 端口 [默认:6080]: " input_web
    WEBSOCKIFY_PORT=${input_web:-6080}

    # 创建统一文件夹
    mkdir -p "$APP_DIR/oci-helper" "$APP_DIR/keys"

    # 生成 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF

services:
  watcher:
    image: ghcr.io/yohann0617/oci-helper-watcher:main
    container_name: oci-helper-watcher
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /usr/local/bin/docker-compose:/usr/local/bin/docker-compose
      - $APP_DIR/oci-helper/docker-compose.yml:/app/oci-helper/docker-compose.yml
      - $APP_DIR/oci-helper/update_version_trigger.flag:/app/oci-helper/update_version_trigger.flag
      - $APP_DIR/oci-helper/oci-helper.db:/app/oci-helper/oci-helper.db

  oci-helper:
    image: ghcr.io/yohann0617/oci-helper:master
    container_name: oci-helper
    restart: always
    ports:
      - "127.0.0.1:$OCI_PORT:8818"
    volumes:
      - $APP_DIR/oci-helper/application.yml:/app/oci-helper/application.yml
      - $APP_DIR/oci-helper/oci-helper.db:/app/oci-helper/oci-helper.db
      - $APP_DIR/keys:/app/oci-helper/keys
      - $APP_DIR/oci-helper/update_version_trigger.flag:/app/oci-helper/update_version_trigger.flag
    networks:
      - app-network

  websockify:
    image: ghcr.io/yohann0617/oci-helper-websockify:master
    container_name: websockify
    restart: always
    ports:
      - "127.0.0.1:$WEBSOCKIFY_PORT:6080"
    depends_on:
      - oci-helper
    networks:
      - app-network

networks:
  app-network:
    driver: bridge
EOF

    # 保存配置
    echo "OCI_PORT=$OCI_PORT" > "$CONFIG_FILE"
    echo "WEBSOCKIFY_PORT=$WEBSOCKIFY_PORT" >> "$CONFIG_FILE"

    # 启动容器
    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ OCI Helper 已启动${RESET}"
    echo -e "${GREEN}🌐 OCI Helper 地址: http://127.0.0.1:$OCI_PORT${RESET}"
    echo -e "${GREEN}🌐 Websockify 地址: http://127.0.0.1:$WEBSOCKIFY_PORT${RESET}"
    echo -e "${GREEN}📂 数据目录: $APP_DIR/oci-helper${RESET}"
    echo -e "${GREEN}📂 密钥目录: $APP_DIR/keys${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ OCI Helper 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ OCI Helper 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f oci-helper
    read -p "按回车返回菜单..."
    menu
}

menu
