```bash
#!/bin/bash
# =========================================
# EasyImage 一键管理脚本
# 支持安装 / 更新 / 启动 / 停止 / 卸载 / 查看日志
# =========================================

APP_NAME="easyimage"
COMPOSE_DIR="/root/easyimage/$APP_NAME"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
CONFIG_FILE="$COMPOSE_DIR/$APP_NAME.conf"

GREEN="\033[32m"
RESET="\033[0m"
YELLOW="\033[33m"
RED="\033[31m"

# ---------- 初始化配置 ----------
init_config() {
    mkdir -p "$COMPOSE_DIR"

    if [ ! -f "$CONFIG_FILE" ]; then
        read -p "请输入映射端口 (默认 8080): " input_port
        APP_PORT=${input_port:-8080}
        echo "APP_PORT=$APP_PORT" > "$CONFIG_FILE"
    else
        source "$CONFIG_FILE"
    fi
}

# ---------- 生成 docker-compose ----------
gen_compose() {
    cat > "$COMPOSE_FILE" <<EOF
version: '3.3'
services:
  $APP_NAME:
    image: ddsderek/easyimage:latest
    container_name: $APP_NAME
    restart: unless-stopped
    ports:
      - "127.0.0.1:\${APP_PORT}:80"
    volumes:
      - "\${COMPOSE_DIR}/config:/app/web/config"
      - "\${COMPOSE_DIR}/i:/app/web/i"
    environment:
      - TZ=Asia/Shanghai
      - PUID=1000
      - PGID=1000
      - DEBUG=false
EOF
}

# ---------- 操作 ----------
install_app() {
    init_config
    gen_compose
    docker compose -f "$COMPOSE_FILE" up -d
    echo -e "${GREEN}安装完成，访问地址: http://127.0.0.1:${APP_PORT}${RESET}"
}

update_app() {
    source "$CONFIG_FILE"
    docker compose -f "$COMPOSE_FILE" pull
    docker compose -f "$COMPOSE_FILE" up -d
    echo -e "${GREEN}更新完成${RESET}"
}

start_app() {
    docker compose -f "$COMPOSE_FILE" start
    echo -e "${GREEN}已启动${RESET}"
}

stop_app() {
    docker compose -f "$COMPOSE_FILE" stop
    echo -e "${YELLOW}已停止${RESET}"
}

uninstall_app() {
    docker compose -f "$COMPOSE_FILE" down
    read -p "是否删除数据文件夹 $COMPOSE_DIR? (y/n): " rmdata
    if [ "$rmdata" == "y" ]; then
        rm -rf "$COMPOSE_DIR"
        echo -e "${RED}数据已删除${RESET}"
    fi
    echo -e "${RED}已卸载${RESET}"
}

logs_app() {
    docker compose -f "$COMPOSE_FILE" logs -f
}

menu() {
    clear
    echo -e "${GREEN}===============================${RESET}"
    echo -e "${GREEN}    EasyImage 管理脚本          ${RESET}"
    echo -e "${GREEN}===============================${RESET}"
    echo -e "${GREEN}1. 安装并启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 启动容器${RESET}"
    echo -e "${GREEN}4. 停止容器${RESET}"
    echo -e "${GREEN}5. 卸载容器${RESET}"
    echo -e "${GREEN}6. 查看日志${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===============================${RESET}"
    read -p "请输入操作编号: " num
    case "$num" in
        1) install_app ;;
        2) update_app ;;
        3) start_app ;;
        4) stop_app ;;
        5) uninstall_app ;;
        6) logs_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${RESET}" ;;
    esac
}

menu
```
