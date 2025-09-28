#!/bin/bash
# ========================================
# Navidrome 一键管理脚本 (Docker Compose)
# 统一安装目录 /opt/navidrome
# ========================================

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="navidrome"
APP_DIR="/opt/$APP_NAME"
YML_FILE="$APP_DIR/docker-compose.yml"
CONF_FILE="$APP_DIR/.navidrome_dirs"

mkdir -p "$APP_DIR"

show_menu() {
    clear
    echo -e "${GREEN}=== Navidrome 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动 Navidrome${RESET}"
    echo -e "${GREEN}2) 更新 Navidrome${RESET}"
    echo -e "${GREEN}3) 卸载 Navidrome${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}===========================${RESET}"
    read -p "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) logs_app ;;
        0) exit ;;
        *) echo "❌ 无效选择"; sleep 1; show_menu ;;
    esac
}

install_app() {
    read -p "请输入音乐目录路径 (默认 /opt/navidrome/music): " music_dir
    music_dir=${music_dir:-/opt/navidrome/music}

    read -p "请输入数据目录路径 (默认 /opt/navidrome/data): " data_dir
    data_dir=${data_dir:-/opt/navidrome/data}

    read -p "请输入映射端口 (默认 4533): " port
    port=${port:-4533}

    mkdir -p "$music_dir" "$data_dir"

    uid=$(id -u)
    gid=$(id -g)

    cat > "$YML_FILE" <<EOF
services:
  navidrome:
    image: deluan/navidrome:latest
    container_name: navidrome
    user: "${uid}:${gid}"
    ports:
      - "127.0.0.1:${port}:4533"
    restart: unless-stopped
    environment:
      ND_LOGLEVEL: info
      ND_SESSIONTIMEOUT: 24h
      ND_SCANSCHEDULE: 1h
    volumes:
      - "${data_dir}:/data"
      - "${music_dir}:/music:ro"
EOF

    echo "$data_dir" > "$CONF_FILE"

    cd "$APP_DIR"
    docker compose up -d
    echo -e "${GREEN}✅ Navidrome 已启动，访问地址: http://127.0.0.1:${port}${RESET}"
    read -p "按回车键返回菜单..."
    show_menu
}

update_app() {
    cd "$APP_DIR" || { echo "❌ 未检测到安装目录"; sleep 1; show_menu; }
    docker compose -f "$YML_FILE" pull
    docker compose -f "$YML_FILE" up -d
    echo -e "${GREEN}✅ Navidrome 已更新${RESET}"
    read -p "按回车键返回菜单..."
    show_menu
}

uninstall_app() {
    read -p "⚠️ 确认要卸载 Navidrome 吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cd "$APP_DIR" || return
        docker compose -f "$YML_FILE" down
        rm -f "$YML_FILE"
        echo -e "${GREEN}✅ Navidrome 已卸载${RESET}"

        if [[ -f $CONF_FILE ]]; then
            data_dir=$(cat "$CONF_FILE")
            read -p "是否同时删除数据目录 [$data_dir]？(y/N): " del_confirm
            if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                rm -rf "$data_dir"
                echo -e "${GREEN}✅ 数据目录已删除${RESET}"
            else
                echo "❌ 已保留数据目录"
            fi
            rm -f "$CONF_FILE"
        fi
    else
        echo "❌ 已取消"
    fi
    read -p "按回车键返回菜单..."
    show_menu
}

logs_app() {
    docker logs -f "$APP_NAME"
    read -p "按回车键返回菜单..."
    show_menu
}

show_menu
