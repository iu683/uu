#!/bin/bash
# =================================================================
# Nezha Dashboard (哪吒监控面板) Docker Compose 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="nezha-dashboard"
APP_DIR="/opt/nezha-dashboard"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取哪吒面板容器状态
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取宿主机映射出来的真实 Web 访问端口
        web_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8008/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$web_port" ]] && web_port="未映射"
    else
        web_port="N/A"
    fi
}

# 选项 1：部署核心逻辑
install_dashboard() {
    check_dependencies
    mkdir -p "$APP_DIR"

    echo -e "${CYAN}====== 1. 哪吒面板 Web 端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入哪吒面板在宿主机监听的 Web 端口 [默认: 8008]: ${RESET}"
    read -r PORT
    [[ -z "$PORT" ]] && PORT="8008"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "\n${YELLOW}正在构建符合规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  dashboard:
    image: ghcr.io/nezhahq/nezha
    container_name: ${CONTAINER_NAME}
    restart: always
    ports:
      - "127.0.0.1:${PORT}:8008"
    volumes:
      - ${APP_DIR}/data:/dashboard/data
EOF

    # 提前创建好数据目录
    mkdir -p "$APP_DIR/data"
    CONFIG_FILE="$APP_DIR/data/config.yaml"

    # 【核心修改逻辑】：如果原有的 config.yaml 已经存在，安全进行局部擦洗，绝不破坏 custom_code 和其他自定义选项
    if [ -f "$CONFIG_FILE" ]; then
        # 移除可能存在的旧 language 配置
        sed -i '/^language:/d' "$CONFIG_FILE" 2>/dev/null
        # 精准切除已有的旧 tsdb 标签块，防止多次追加导致配置错位损坏
        sed -i '/^tsdb:/,/^[a-zA-Z]/ { /^tsdb:/d; /data_path:/d }' "$CONFIG_FILE" 2>/dev/null
    fi

    # 在原文件最末尾直接进行干净利落的追加 (带单引号 'EOF'，100% 保证不破坏里面的特殊美化符号)
    echo "language: zh_CN" >> "$CONFIG_FILE"
    cat >> "$CONFIG_FILE" << 'EOF'
tsdb:
  data_path: data/tsdb
EOF

    # 修复并规范化文件权限
    chmod 644 "$CONFIG_FILE"

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 启动 哪吒监控面板...${RESET}"
    cd "$APP_DIR" && docker compose up -d

    echo -e "${YELLOW}等待服务引擎拉起 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}          Nezha Dashboard 面板部署成功！            ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}本地面板监听地址 : http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}监控语言环境设置 : 简体中文 (zh_CN)${RESET}"
    echo -e "${YELLOW}TSDB数据存储路径 : ${APP_DIR}/data/tsdb${RESET}"
    echo -e "${CYAN}💡 提示：该服务仅监听在 127.0.0.1，请配合 Nginx 反代提供外网 HTTPS 访问。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 选项 2：更新服务
update_dashboard() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新版 哪吒面板 镜像...${RESET}"
    cd "$APP_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！哪吒面板已平滑重启。${RESET}"
}

# 选项 3：卸载服务
uninstall_dashboard() {
    echo -ne "${RED}确定要卸载并停止哪吒面板服务吗？数据目录将被彻底清理！(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$APP_DIR" && docker compose down
            rm -rf "$APP_DIR"
            echo -e "${GREEN}容器已停止，相关编排配置及数据目录已彻底清理。${RESET}"
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_dashboard() { cd "$APP_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_dashboard() { cd "$APP_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_dashboard() { cd "$APP_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_dashboard() { docker logs -f --tail=100 "$CONTAINER_NAME"; }

# 选项 8：查看当前详细状态
show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态     : $status"
    echo -e "${YELLOW}宿主机映射端口   : ${web_port}${RESET}"
    echo -e "${YELLOW}数据挂载根目录   : ${APP_DIR}/data${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  Nezha Dashboard 管理面板 ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态  :${RESET} $status"
    echo -e "${GREEN}端口  :${RESET} ${YELLOW}${web_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_dashboard ;;
        2) update_dashboard ;;
        3) uninstall_dashboard ;;
        4) start_dashboard ;;
        5) stop_dashboard ;;
        6) restart_dashboard ;;
        7) logs_dashboard ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
