#!/bin/bash
# =================================================================
# Komari 管理脚本 (统一文件夹 + CF 穿透智能端口锁固+文本绝对隔离版)
# =================================================================

set -e

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_DIR="/opt/komari"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONFIG_FILE="$APP_DIR/komari_config.env"
DATA_DIR="$APP_DIR/data"
CONTAINER_NAME="komari"

# 动态获取容器当前状态
get_status_info() {
    if [ -f "$COMPOSE_FILE" ]; then
        if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
            status="${GREEN}运行中${RESET}"
        elif [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
            status="${YELLOW}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
    else
        status="${RED}未初始化${RESET}"
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # 临时允许出错，防止 source 出错中断脚本
        set +e
        source "$CONFIG_FILE" 2>/dev/null
        set -e
    fi
    # 动态兜底端口变量
    [[ -z "$PORT" ]] && PORT="25774"
}

# 主菜单管理
menu() {
    clear
    get_status_info
    load_config
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}         ◈  Komari 管理面板  ◈        ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 当前状态 :${RESET} $status"
    echo -e "${GREEN} 内部映射 :${RESET} ${YELLOW}127.0.0.1:${PORT}${RESET}"
    if [[ "$KOMARI_ENABLE_CLOUDFLARED" == "true" ]]; then
        echo -e "${GREEN} 穿透状态 :${RESET} ${CYAN}已启用 Cloudflared 隧道 (端口已锁定)${RESET}"
    else
        echo -e "${GREEN} 穿透状态 :${RESET} ${YELLOW}未启用通道${RESET}"
    fi
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN} 1) 安装部署${RESET}"
    echo -e "${GREEN} 2) 升级更新${RESET}"
    echo -e "${GREEN} 3) 彻底卸载${RESET}"
    echo -e "${GREEN} 4) 查看日志${RESET}"
    echo -e "${GREEN} 5) 重启服务${RESET}"
    echo -e "${0} 0) 退出面板${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    read -p "$(echo -e ${GREEN}请选择选项:${RESET} )" choice

    case $choice in
        1) install_komari ;;
        2) update_komari ;;
        3) uninstall_komari ;;
        4) view_logs ;;
        5) restart_komari ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择！${RESET}" && sleep 1 && menu ;;
    esac
}

# 部署 Komari
install_komari() {
    echo -e "\n${CYAN}====== 开始安装部署 Komari ======${RESET}"

    mkdir -p "$APP_DIR" "$DATA_DIR"

    read -p "请输入管理员用户名 (默认: admin): " ADMIN_USERNAME
    ADMIN_USERNAME=${ADMIN_USERNAME:-admin}

    read -p "请输入管理员密码 (默认: admin123): " ADMIN_PASSWORD
    ADMIN_PASSWORD=${ADMIN_PASSWORD:-admin123}

    # Cloudflared 穿透向导分流逻辑
    local enable_cf="false"
    local cf_token=""
    local PORT="25774"
    
    echo -e "\n${CYAN}====== Cloudflared Tunnels 配置向导 ======${RESET}"
    read -p "是否需要启用 Cloudflared 隧道进行公网穿透? (y/N): " choice_cf
    if [[ "$choice_cf" == "y" || "$choice_cf" == "Y" ]]; then
        enable_cf="true"
        while [[ -z "$cf_token" ]]; do
            read -p "请输入您的 Cloudflared Tunnel Token (例如 eyJxxxxx): " cf_token
            if [[ -z "$cf_token" ]]; then
                echo -e "${RED}错误: Token 不能为空，请重新输入。${RESET}"
            fi
        done
        echo -e "${GREEN} 💡 已启用 Cloudflared 穿透，自动锁定官方默认端口: 25774${RESET}"
    else
        read -p "请输入 Komari 本地绑定端口 (默认: 25774): " custom_port
        PORT=${custom_port:-25774}
    fi

    # 【核心修复】直接使用 echo 写入，绕开 cat EOF 在线执行时的符号吞噬问题
    echo "ADMIN_USERNAME=\"${ADMIN_USERNAME}\"" > "$CONFIG_FILE"
    echo "ADMIN_PASSWORD=\"${ADMIN_PASSWORD}\"" >> "$CONFIG_FILE"
    echo "PORT=\"${PORT}\"" >> "$CONFIG_FILE"
    echo "KOMARI_ENABLE_CLOUDFLARED=\"${enable_cf}\"" >> "$CONFIG_FILE"
    echo "KOMARI_CLOUDFLARED_TOKEN=\"${cf_token}\"" >> "$CONFIG_FILE"

    # 生成结构化的 docker-compose.yml 
    echo -e "${YELLOW}正在生成规范化 Docker Compose 配置文件...${RESET}"
    cat << EOF > "$COMPOSE_FILE"
services:
  komari:
    image: ghcr.io/komari-monitor/komari:latest
    container_name: $CONTAINER_NAME
    ports:
      - "127.0.0.1:$PORT:25774"
    volumes:
      - $DATA_DIR:/app/data
    env_file:
      - $CONFIG_FILE
    restart: unless-stopped
EOF

    echo -e "${YELLOW}正在拉起 Docker 容器架构...${RESET}"
    (cd "$APP_DIR" && docker compose down 2>/dev/null && docker compose up -d)

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}             Komari 系统部署/应用成功！               ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}本地内部访问地址: http://127.0.0.1:$PORT${RESET}"
    echo -e "${YELLOW}默认面板账号    : $ADMIN_USERNAME${RESET}"
    echo -e "${YELLOW}默认面板密码    : $ADMIN_PASSWORD${RESET}"
    echo -e "----------------------------------------------------"
    if [[ "$enable_cf" == "true" ]]; then
        echo -e "${YELLOW}Cloudflared 状态: ${GREEN}已启用穿透 (端口锁死为 25774)${RESET}"
        echo -e "${YELLOW}穿透隧道 Token  : ${CYAN}${cf_token:0:15}...${RESET}"
    else
        echo -e "${YELLOW}Cloudflared 状态: ${RED}未启用穿透${RESET}"
    fi
    echo -e "----------------------------------------------------"
    echo -e "${GREEN}📂 持久化工作目录: $APP_DIR${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    read -p "按回车返回菜单..." && menu
}

# 更新系统
update_komari() {
    load_config
    echo -e "\n${YELLOW}=== 正在检测并升级最新 Komari 镜像 ===${RESET}"
    (cd "$APP_DIR" && docker compose pull && docker compose up -d --remove-orphans)
    echo -e "${GREEN}✅ 升级完成，服务已重启运行！${RESET}"
    read -p "按回车返回菜单..." && menu
}

# 重举系统
restart_komari() {
    load_config
    echo -e "\n${GREEN}=== 正在冷重启 Komari 容器拓扑 ===${RESET}"
    (cd "$APP_DIR" && docker compose restart)
    echo -e "${GREEN}✅ Komari 重启成功！${RESET}"
    read -p "按回车返回菜单..." && menu
}

# 彻底卸载
uninstall_komari() {
    echo -e "\n${RED}警告: 即将完全卸载 Komari，这会抹除掉所有监控配置与穿透凭据！${RESET}"
    read -p "确认卸载? (y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if [ -f "$COMPOSE_FILE" ]; then
            (cd "$APP_DIR" && docker compose down -v)
        fi
        rm -rf "$APP_DIR"
        echo -e "${GREEN}✅ 整个工作区卸载完毕，数据已彻底清理干净。${RESET}"
    else
        echo -e "${YELLOW}操作已取消。${RESET}"
    fi
    read -p "按回车返回菜单..." && menu
}

# 查看日志
view_logs() {
    echo -e "\n${CYAN}=== 正在追踪 Komari 实时运行日志 (Ctrl+C 退出追踪) ===${RESET}"
    docker logs -f $CONTAINER_NAME
    read -p "按回车返回菜单..." && menu
}

# 持续循环面板
while true; do
    menu
done
