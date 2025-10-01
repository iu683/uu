#!/bin/bash
# ========================================
# Jellyfin 一键管理脚本 (Docker Compose)
# ========================================

GREEN="\033[32m"
RESET="\033[0m"
APP_NAME="jellyfin"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/config.env"

function menu() {
    clear
    echo -e "${GREEN}=== Jellyfin 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 卸载(含数据)${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}5) 重启${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        5) restart_app ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

function install_app() {
    read -p "请输入 Web 端口 [默认:8096]: " input_port
    PORT=${input_port:-8096}

    read -p "请输入宿主机媒体目录路径 [默认:/opt/jellyfin/media]: " input_media
    MEDIA_DIR=${input_media:-/opt/jellyfin/media}

    echo -e "是否启用硬件转码? (y/n) 默认 n"
    read -p "选择: " enable_hw
    ENABLE_HW=${enable_hw:-n}

    echo -e "是否以 root 用户运行 Jellyfin? (y/n) 默认 y"
    read -p "选择: " run_as_root
    RUN_AS_ROOT=${run_as_root:-y}

    # 默认 UID/GID=1000，只有当用户不选 root 时才用
    if [[ "$RUN_AS_ROOT" =~ [nN] ]]; then
        read -p "请输入运行用户 UID [默认:1000]: " input_uid
        PUID=${input_uid:-1000}
        read -p "请输入运行用户 GID [默认:1000]: " input_gid
        PGID=${input_gid:-1000}
    fi

    mkdir -p "$APP_DIR"

    # 写 docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: always
EOF

    if [[ "$RUN_AS_ROOT" =~ [yY] ]]; then
        echo "    user: root" >> "$COMPOSE_FILE"
    fi

    cat >> "$COMPOSE_FILE" <<EOF
    ports:
      - "127.0.0.1:$PORT:8096"
      - "127.0.0.1:8910:8910"
    environment:
      - TZ=Asia/Shanghai
EOF

    if [[ "$RUN_AS_ROOT" =~ [nN] ]]; then
        cat >> "$COMPOSE_FILE" <<EOF
      - PUID=$PUID
      - PGID=$PGID
EOF
    fi

    cat >> "$COMPOSE_FILE" <<EOF
    volumes:
      - ./config:/config
      - ./cache:/cache
      - $MEDIA_DIR:/media
EOF

    if [[ "$ENABLE_HW" =~ [yY] ]]; then
        cat >> "$COMPOSE_FILE" <<EOF
    devices:
      - /dev/dri:/dev/dri
EOF
    fi

    # 保存配置
    {
        echo "PORT=$PORT"
        echo "MEDIA_DIR=$MEDIA_DIR"
        echo "ENABLE_HW=$ENABLE_HW"
        echo "RUN_AS_ROOT=$RUN_AS_ROOT"
        [[ "$RUN_AS_ROOT" =~ [nN] ]] && {
            echo "PUID=$PUID"
            echo "PGID=$PGID"
        }
    } > "$CONFIG_FILE"

    cd "$APP_DIR"
    docker compose up -d

    echo -e "${GREEN}✅ Jellyfin 已启动${RESET}"
    echo -e "${GREEN}🌐 Web UI 地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${GREEN}📂 配置目录: $APP_DIR/config${RESET}"
    echo -e "${GREEN}🎬 媒体目录: $MEDIA_DIR${RESET}"
    [[ "$ENABLE_HW" =~ [yY] ]] && echo -e "${GREEN}⚡ 已启用硬件转码支持${RESET}"
    [[ "$RUN_AS_ROOT" =~ [yY] ]] && echo -e "${GREEN}👑 已以 root 用户运行${RESET}" || echo -e "${GREEN}👤 以 UID=$PUID, GID=$PGID 运行${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function update_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录，请先安装"; sleep 1; menu; }
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Jellyfin 已更新并重启完成${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${GREEN}✅ Jellyfin 已卸载，数据已删除${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    cd "$APP_DIR" || { echo "未检测到安装目录"; sleep 1; menu; }
    docker compose restart
    echo -e "${GREEN}✅ Jellyfin 已重启${RESET}"
    read -p "按回车返回菜单..."
    menu
}

function view_logs() {
    docker logs -f jellyfin
    read -p "按回车返回菜单..."
    menu
}

menu
