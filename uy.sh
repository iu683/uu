#!/bin/bash
# SaveAny-Bot Docker 管理脚本（自定义挂载路径版）

CONTAINER_NAME="saveany-bot"
IMAGE_NAME="ghcr.io/krau/saveany-bot:latest"
CONFIG_FILE_NAME="config.toml"
CONFIG_PATH_FILE="$HOME/.saveany_path"

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# ======== 公共路径变量 ========
BASE_DIR=""
DATA_DIR=""
DOWNLOADS_DIR=""
CACHE_DIR=""
CONFIG_FILE=""

# ======== 初始化挂载路径 ========
init_paths() {
    if [ -f "$CONFIG_PATH_FILE" ]; then
        BASE_DIR=$(cat "$CONFIG_PATH_FILE")
    else
        echo -e "${GREEN}请输入挂载路径 (默认: /opt/saveany):${RESET}"
        read -p ">>> " USER_PATH
        BASE_DIR=${USER_PATH:-/opt/saveany}
        echo "$BASE_DIR" > "$CONFIG_PATH_FILE"
    fi
    DATA_DIR="$BASE_DIR/data"
    DOWNLOADS_DIR="$BASE_DIR/downloads"
    CACHE_DIR="$BASE_DIR/cache"
    CONFIG_FILE="$BASE_DIR/$CONFIG_FILE_NAME"
    mkdir -p "$DATA_DIR" "$DOWNLOADS_DIR" "$CACHE_DIR"
}

# ======== 检查容器是否存在 ========
check_container() {
    docker ps -a --format '{{.Names}}' | grep -w "$CONTAINER_NAME" >/dev/null 2>&1
}

# ======== 启动容器 ========
start_bot() {
    init_paths

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${GREEN}首次启动，请输入配置：${RESET}"
        read -p "Telegram Bot Token: " BOT_TOKEN
        read -p "Telegram 用户 ID: " TELEGRAM_ID

        cat > "$CONFIG_FILE" <<EOF
# SaveAny-Bot 最简配置
workers = 4
retry = 3
threads = 4
stream = false

[telegram]
token = "$BOT_TOKEN"

[[storages]]
name = "本机存储"
type = "local"
enable = true
base_path = "./downloads"

[[users]]
id = $TELEGRAM_ID
storages = []
blacklist = true
EOF

        echo -e "${GREEN}已生成配置文件: $CONFIG_FILE${RESET}"
    fi

    if check_container; then
        echo -e "${GREEN}>>> 启动 $CONTAINER_NAME ...${RESET}"
        docker start "$CONTAINER_NAME"
    else
        echo -e "${GREEN}>>> 创建并启动容器 ...${RESET}"
        docker run -d \
            --name $CONTAINER_NAME \
            --restart unless-stopped \
            --network host \
            -v "$DATA_DIR:/app/data" \
            -v "$CONFIG_FILE:/app/config.toml" \
            -v "$DOWNLOADS_DIR:/app/downloads" \
            -v "$CACHE_DIR:/app/cache" \
            $IMAGE_NAME
    fi
}

stop_bot() { docker stop $CONTAINER_NAME; }
restart_bot() { docker restart $CONTAINER_NAME; }
logs_bot() { docker logs -f $CONTAINER_NAME; }
remove_bot() { docker rm -f $CONTAINER_NAME; }
edit_config() { nano "$CONFIG_FILE"; }

# ======== 卸载 ========
uninstall_bot() {
    init_paths
    echo -e "${RED}警告: 该操作会删除容器和所有数据，无法恢复！${RESET}"
    read -p "确定要继续吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker rm -f $CONTAINER_NAME >/dev/null 2>&1
        rm -rf "$BASE_DIR"
        rm -f "$CONFIG_PATH_FILE"
        echo -e "${GREEN}卸载完成，所有数据已清理。${RESET}"
        exit 0
    else
        echo "已取消卸载。"
    fi
}

# ======== 更新容器 ========
update_bot() {
    init_paths
    echo -e "${GREEN}>>> 拉取最新镜像...${RESET}"
    docker pull $IMAGE_NAME
    docker rm -f $CONTAINER_NAME >/dev/null 2>&1 || true
    echo -e "${GREEN}>>> 使用最新镜像重新创建并启动容器...${RESET}"
    docker run -d \
        --name $CONTAINER_NAME \
        --restart unless-stopped \
        --network host \
        -v "$DATA_DIR:/app/data" \
        -v "$CONFIG_FILE:/app/config.toml" \
        -v "$DOWNLOADS_DIR:/app/downloads" \
        -v "$CACHE_DIR:/app/cache" \
        $IMAGE_NAME
    echo -e "${GREEN}更新完成，容器已使用最新镜像运行！${RESET}"
}

# ======== 菜单 ========
while true; do
    clear
    echo -e "${GREEN}====== SaveAny-Bot 管理菜单 ======${RESET}"
    echo -e "${GREEN}1. 启动容器${RESET}"
    echo -e "${GREEN}2. 停止容器${RESET}"
    echo -e "${GREEN}3. 重启容器${RESET}"
    echo -e "${GREEN}4. 查看日志${RESET}"
    echo -e "${GREEN}5. 编辑配置文件${RESET}"
    echo -e "${GREEN}6. 更新容器${RESET}"
    echo -e "${GREEN}7. 卸载并删除所有数据${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    read -p "请选择操作: " choice
    case $choice in
        1) start_bot ;;
        2) stop_bot ;;
        3) restart_bot ;;
        4) logs_bot ;;
        5) edit_config ;;
        6) update_bot ;;
        7) uninstall_bot ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    echo -e "\n按回车返回菜单..."
    read -r
done
