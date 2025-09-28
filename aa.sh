```bash
#!/bin/bash
# =========================================
# File Transfer Go 一键管理脚本
# 支持安装 / 更新 / 重启 / 停止 / 卸载 / 查看日志
# =========================================

APP_NAME="file-transfer-go"
IMAGE_NAME="matrixseven/file-transfer-go:latest"
INSTALL_DIR="/opt/$APP_NAME"
CONFIG_FILE="$INSTALL_DIR/config.env"

GREEN="\033[32m"
RESET="\033[0m"

# 获取公网 IP
function get_ip() {
    curl -s ifconfig.me || curl -s ip.sb || echo "your-ip"
}

# 读取保存的端口
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    PORT=8080
fi

function save_config() {
    mkdir -p "$INSTALL_DIR"
    echo "PORT=$PORT" > "$CONFIG_FILE"
}

function install_app() {
    read -p "请输入访问端口 [默认:8080]: " input_port
    PORT=${input_port:-8080}
    save_config

    echo -e "${GREEN}开始安装 ${APP_NAME}，端口: $PORT${RESET}"
    docker pull $IMAGE_NAME
    docker rm -f $APP_NAME 2>/dev/null
    docker run -d \
        --name=$APP_NAME \
        --restart=unless-stopped \
        -p 127.0.0.1:$PORT:8080 \
        $IMAGE_NAME
    IP=$(get_ip)
    echo -e "${GREEN}安装完成！访问: http://127.0.0.1:$PORT${RESET}"
    read -p "按回车返回菜单..."
}

function update_app() {
    echo -e "${GREEN}开始更新 ${APP_NAME}...${RESET}"
    docker pull $IMAGE_NAME
    docker rm -f $APP_NAME 2>/dev/null
    docker run -d \
        --name=$APP_NAME \
        --restart=unless-stopped \
        -p 127.0.0.1:$PORT:8080 \
        $IMAGE_NAME
    echo -e "${GREEN}更新完成${RESET}"
    read -p "按回车返回菜单..."
}

function restart_app() {
    echo -e "${GREEN}正在重启 ${APP_NAME}...${RESET}"
    docker restart $APP_NAME
    echo -e "${GREEN}重启完成${RESET}"
    read -p "按回车返回菜单..."
}

function stop_app() {
    echo -e "${GREEN}正在停止 ${APP_NAME}...${RESET}"
    docker stop $APP_NAME
    echo -e "${GREEN}停止完成！${RESET}"
    read -p "按回车返回菜单..."
}

function uninstall_app() {
    echo -e "${GREEN}正在卸载 ${APP_NAME}...${RESET}"
    docker rm -f $APP_NAME 2>/dev/null
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}已卸载 ${APP_NAME}，数据已删除${RESET}"
    read -p "按回车返回菜单..."
}

function view_logs() {
    echo -e "${GREEN}正在查看 ${APP_NAME} 日志 (Ctrl+C 退出)...${RESET}"
    docker logs -f $APP_NAME
}

while true; do
    clear
    echo -e "\n${GREEN}=== File Transfer Go 管理菜单 ===${RESET}"
    echo -e "${GREEN}1. 安装${RESET}"
    echo -e "${GREEN}2. 更新${RESET}"
    echo -e "${GREEN}3. 重启${RESET}"
    echo -e "${GREEN}4. 停止${RESET}"
    echo -e "${GREEN}5. 卸载${RESET}"
    echo -e "${GREEN}6. 查看日志${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    read -p "请选择操作: " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) restart_app ;;
        4) stop_app ;;
        5) uninstall_app ;;
        6) view_logs ;;
        0) exit ;;
        *) echo -e "${GREEN}无效选择${RESET}" ; sleep 1 ;;
    esac
done
```
