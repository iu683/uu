#!/bin/bash
# ========================================
# Backrest 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="backrest"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

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

check_port() {
    if ss -tuln | grep -qE "[:.]$1\b"; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Backrest 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载${RESET}"
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
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {
    check_docker
    mkdir -p "$APP_DIR/data" "$APP_DIR/config" "$APP_DIR/cache" "$APP_DIR/tmp"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    read -p "请输入访问端口 [默认:9898]: " input_port
    PORT=${input_port:-9898}
    check_port "$PORT" || return

    echo
    echo -e "${GREEN}请输入需要备份的目录（多个用空格分隔）${RESET}"
    echo -e "${YELLOW}示例: /root /data/apps /etc/caddy${RESET}"
    read -p "默认:/opt → " input_backup

    if [ -z "$input_backup" ]; then
        BACKUP_DIRS="/opt"
    else
        BACKUP_DIRS="$input_backup"
    fi

    echo
    read -p "请输入 rclone 配置目录 [默认:$APP_DIR/rclone]: " input_rclone
    RCLONE_DIR=${input_rclone:-$APP_DIR/rclone}
    mkdir -p "$RCLONE_DIR"

    # 构建多目录挂载
    VOLUME_MOUNTS=""
    for dir in $BACKUP_DIRS; do
        if [ ! -d "$dir" ]; then
            echo -e "${YELLOW}目录 $dir 不存在，自动创建...${RESET}"
            mkdir -p "$dir"
        fi
        name=$(basename "$dir")
        VOLUME_MOUNTS+="      - $dir:/userdata/$name:ro"$'\n'
    done

    cat > "$COMPOSE_FILE" <<EOF
services:
  backrest:
    image: garethgeorge/backrest:latest
    container_name: backrest
    hostname: backrest
    volumes:
      - ./data:/data
      - ./config:/config
      - ./cache:/cache
      - ./tmp:/tmp
      - $RCLONE_DIR:/root/.config/rclone
$VOLUME_MOUNTS
    environment:
      - BACKREST_DATA=/data
      - BACKREST_CONFIG=/config/config.json
      - XDG_CACHE_HOME=/cache
      - TMPDIR=/tmp
      - TZ=Asia/Shanghai
    ports:
      - "127.0.0.1:${PORT}:9898"
    restart: unless-stopped
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    echo
    echo -e "${GREEN}✅ Backrest 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: http://127.0.0.1:${PORT}${RESET}"
    echo -e "${GREEN}📂 容器内备份路径统一为: /userdata${RESET}"
    echo -e "${GREEN}📂 安装目录: $APP_DIR${RESET}"
    echo -e "${YELLOW}在Backrest中添加Source时填写: /userdata${RESET}"
    read -p "按回车返回菜单..."
}
update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d --remove-orphans
    docker image prune -f
    echo -e "${GREEN}✅ Backrest 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart backrest
    echo -e "${GREEN}✅ Backrest 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f backrest
}

check_status() {
    if docker ps --format '{{.Names}}' | grep -q "^backrest$"; then
        echo -e "${GREEN}Backrest 运行中${RESET}"
    else
        echo -e "${RED}Backrest 未运行${RESET}"
    fi
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Backrest 已卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
