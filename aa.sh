#!/bin/bash
# ==========================================
# Antigravity Manager 一键管理脚本
# ==========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[36m"
RESET="\033[0m"

APP_NAME="antigravity-manager"
DATA_DIR="$HOME/.antigravity_tools"

# ==============================
# 基础检测
# ==============================

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用！${RESET}"
        return 1
    fi
}

generate_key() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 32
}

SERVER_IP=$(hostname -I | awk '{print $1}')

# ==============================
# 菜单
# ==============================

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Antigravity Manager 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 重启${RESET}"
        echo -e "${GREEN}3) 更新${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看访问信息${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) restart_app ;;
            3) update_app ;;
            4) view_logs ;;
            5) show_info ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

# ==============================
# 功能
# ==============================

install_app() {

    check_docker

    if docker ps -a | grep -q "$APP_NAME"; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
        docker rm -f $APP_NAME
    fi

    read -p "$(echo -e ${GREEN}请输入运行端口 [默认8045]: ${RESET})" PORT
    PORT=${PORT:-8045}
    check_port "$PORT" || return

    read -p "$(echo -e ${GREEN}请输入 API_KEY [留空自动生成]: ${RESET})" input_api
    if [ -z "$input_api" ]; then
        API_KEY=$(generate_key)
        echo -e "${BLUE}自动生成 API_KEY: ${API_KEY}${RESET}"
    else
        API_KEY="$input_api"
    fi

    read -p "$(echo -e ${GREEN}请输入 Web 登录密码 [留空自动生成]: ${RESET})" input_pass
    if [ -z "$input_pass" ]; then
        WEB_PASS=$(generate_key)
        echo -e "${BLUE}自动生成 Web 密码: ${WEB_PASS}${RESET}"
    else
        WEB_PASS="$input_pass"
    fi

    mkdir -p "$DATA_DIR"

    echo -e "${BLUE}正在启动容器...${RESET}"

    docker run -d \
      --name $APP_NAME \
      -p ${PORT}:8045 \
      -e API_KEY=${API_KEY} \
      -e WEB_PASSWORD=${WEB_PASS} \
      -e ABV_MAX_BODY_SIZE=104857600 \
      -v ${DATA_DIR}:/root/.antigravity_tools \
      --restart unless-stopped \
      lbjlaq/antigravity-manager:latest

    sleep 2

    if docker ps | grep -q "$APP_NAME"; then
        echo -e "${GREEN}✅ 启动成功！${RESET}"
        echo "$PORT" > /tmp/${APP_NAME}_port
        echo "$API_KEY" > /tmp/${APP_NAME}_api
        echo "$WEB_PASS" > /tmp/${APP_NAME}_pass
        show_info
    else
        echo -e "${RED}❌ 启动失败，请查看日志${RESET}"
        docker logs $APP_NAME
    fi

    read -p "按回车继续..."
}

restart_app() {
    docker restart $APP_NAME
    echo -e "${GREEN}已重启${RESET}"
    sleep 1
}

update_app() {

    if ! docker ps -a | grep -q "$APP_NAME"; then
        echo -e "${RED}未安装${RESET}"
        sleep 1
        return
    fi

    echo -e "${BLUE}正在拉取新镜像...${RESET}"
    docker pull lbjlaq/antigravity-manager:latest || return

    echo -e "${BLUE}保存当前端口...${RESET}"
    PORT=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8045/tcp") 0).HostPort}}' $APP_NAME)

    echo -e "${BLUE}保存环境变量...${RESET}"
    API_KEY=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $APP_NAME | grep API_KEY= | cut -d= -f2)
    WEB_PASS=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $APP_NAME | grep WEB_PASSWORD= | cut -d= -f2)

    echo -e "${BLUE}停止并删除旧容器...${RESET}"
    docker rm -f $APP_NAME

    echo -e "${BLUE}使用新镜像重新创建容器...${RESET}"
    docker run -d \
      --name $APP_NAME \
      -p ${PORT}:8045 \
      -e API_KEY=${API_KEY} \
      -e WEB_PASSWORD=${WEB_PASS} \
      -e ABV_MAX_BODY_SIZE=104857600 \
      -v ${DATA_DIR}:/root/.antigravity_tools \
      --restart unless-stopped \
      lbjlaq/antigravity-manager:latest

    if docker ps | grep -q "$APP_NAME"; then
        echo -e "${GREEN}✅ 更新成功，数据保留${RESET}"
    else
        echo -e "${RED}❌ 更新失败，请检查日志${RESET}"
    fi

    sleep 2
}

view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出日志${RESET}"
    docker logs -f $APP_NAME
}

show_info() {

    if docker ps | grep -q "$APP_NAME"; then
        PORT=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8045/tcp") 0).HostPort}}' $APP_NAME)
        echo
        echo -e "${GREEN}📌 访问信息:${RESET}"
        echo -e "${YELLOW}访问地址: http://${SERVER_IP}:${PORT}${RESET}"
        echo -e "${YELLOW}数据目录: ${DATA_DIR}${RESET}"
        echo
    else
        echo -e "${RED}未运行${RESET}"
    fi

    read -p "按回车返回..."
}

uninstall_app() {
    docker rm -f $APP_NAME
    rm -rf "$DATA_DIR"
    echo -e "${RED}已卸载并删除数据${RESET}"
    sleep 1
}

menu
