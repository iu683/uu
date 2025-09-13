#!/bin/bash

GREEN="\033[32m"
RESET="\033[0m"

APP_NAME="music-tag-web"
YML_FILE="music-tag-compose.yml"

# 存储上次安装时的目录（便于卸载时清理）
CONF_FILE=".music_tag_dirs"

show_menu() {
    clear
    echo -e "${GREEN}=== Music Tag 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动 Music Tag${RESET}"
    echo -e "${GREEN}2) 更新 Music Tag${RESET}"
    echo -e "${GREEN}3) 卸载 Music Tag${RESET}"
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
    read -p "请输入音乐目录路径 (默认 /mnt/nas/music): " music_dir
    music_dir=${music_dir:-/mnt/nas/music}

    read -p "请输入配置文件目录路径 (默认 /opt/music-tag/config): " config_dir
    config_dir=${config_dir:-/opt/music-tag/config}

    read -p "请输入下载目录路径 (默认 /opt/music-tag/download): " download_dir
    download_dir=${download_dir:-/opt/music-tag/download}

    read -p "请输入访问端口 (默认 8002): " port
    port=${port:-8002}

    mkdir -p "$music_dir" "$config_dir" "$download_dir"

    cat > $YML_FILE <<EOF
version: '3'

services:
  music-tag:
    image: xhongc/music_tag_web:latest
    container_name: $APP_NAME
    ports:
      - "${port}:8002"
    volumes:
      - ${music_dir}:/app/media
      - ${config_dir}:/app/data
      - ${download_dir}:/app/download
    restart: always
EOF

    # 保存目录信息和端口
    echo "$config_dir" > $CONF_FILE
    echo "$download_dir" >> $CONF_FILE
    echo "$port" >> $CONF_FILE

    docker compose -f $YML_FILE up -d
    echo -e "${GREEN}✅ $APP_NAME 已启动，访问地址: http://$(hostname -I | awk '{print $1}'):${port}${RESET}"
    read -p "按回车键返回菜单..."
    show_menu
}

update_app() {
    docker compose -f $YML_FILE pull
    docker compose -f $YML_FILE up -d
    echo -e "${GREEN}✅ $APP_NAME 已更新${RESET}"
    read -p "按回车键返回菜单..."
    show_menu
}

uninstall_app() {
    read -p "⚠️ 确认要卸载 $APP_NAME 吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker compose -f $YML_FILE down
        rm -f $YML_FILE
        echo -e "${GREEN}✅ $APP_NAME 已卸载${RESET}"

        if [[ -f $CONF_FILE ]]; then
            config_dir=$(sed -n '1p' $CONF_FILE)
            download_dir=$(sed -n '2p' $CONF_FILE)
            port=$(sed -n '3p' $CONF_FILE)

            read -p "是否同时删除配置目录 [$config_dir] 和下载目录 [$download_dir]？(y/N): " del_confirm
            if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                rm -rf "$config_dir" "$download_dir"
                echo -e "${GREEN}✅ 配置目录和下载目录已删除${RESET}"
            else
                echo "❌ 已保留配置目录和下载目录"
            fi
            rm -f $CONF_FILE
        fi
    else
        echo "❌ 已取消"
    fi
    read -p "按回车键返回菜单..."
    show_menu
}

logs_app() {
    docker logs -f $APP_NAME
    read -p "按回车键返回菜单..."
    show_menu
}

show_menu
