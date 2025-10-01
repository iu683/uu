#!/bin/bash
# ===========================
# TinyAuth 管理脚本 (Run 版)
# - 直接 docker run
# - 手动输入 bcrypt 用户
# - 自动转义 $ 符号
# ===========================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

CONTAINER_NAME="tinyauth"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}未检测到 Docker，请先安装 Docker${RESET}"
        exit 1
    fi
}

menu() {
    clear
    echo -e "${GREEN}=== TinyAuth 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装/启动${RESET}"
    echo -e "${GREEN}2) 更新/重启${RESET}"
    echo -e "${GREEN}3) 卸载${RESET}"
    echo -e "${GREEN}4) 查看日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -rp "请选择: " choice
    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

install_app() {
    read -rp "请输入访问端口 [默认 2082]: " port
    port=${port:-2082}

    read -rp "请输入 APP_URL (例如 https://tinyauth.laosu.tech): " appurl
    appurl=${appurl:-http://127.0.0.1:$port}

    read -rp "请输入 SECRET (推荐 32 位随机字符串，回车自动生成): " secret
    secret=${secret:-$(openssl rand -hex 16)}

    echo -e "${YELLOW}请输入用户配置 (格式 user:bcrypt_hash)${RESET}"
    read -rp "用户配置: " USERS_STRING

    # 转义 $
    USERS_STRING_ESCAPED=$(echo "$USERS_STRING" | sed 's/\$/\\$/g')

    # 检查容器是否存在
    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        echo -e "${YELLOW}检测到容器已存在，正在删除旧容器...${RESET}"
        docker rm -f $CONTAINER_NAME
    fi

    docker run -d \
      --restart unless-stopped \
      --name $CONTAINER_NAME \
      -p $port:3000 \
      -e SECRET="$secret" \
      -e APP_URL="$appurl" \
      -e USERS="$USERS_STRING_ESCAPED" \
      ghcr.io/steveiliop56/tinyauth

    echo -e "${GREEN}✅ TinyAuth 已启动${RESET}"
    echo -e "${YELLOW}🌐 访问地址: $appurl${RESET}"
    echo -e "${GREEN}🔑 SECRET: $secret${RESET}"

    read -rp "按回车返回菜单..."
    menu
}

update_app() {
    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        echo -e "${YELLOW}正在重启 TinyAuth...${RESET}"
        docker restart $CONTAINER_NAME
        echo -e "${GREEN}✅ TinyAuth 已重启${RESET}"
    else
        echo -e "${RED}容器不存在，请先安装启动${RESET}"
    fi
    read -rp "按回车返回菜单..."
    menu
}

uninstall_app() {
    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        docker rm -f $CONTAINER_NAME
        echo -e "${RED}✅ TinyAuth 已卸载${RESET}"
    else
        echo -e "${RED}容器不存在${RESET}"
    fi
    read -rp "按回车返回菜单..."
    menu
}

view_logs() {
    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        docker logs -f $CONTAINER_NAME
    else
        echo -e "${RED}容器不存在${RESET}"
    fi
    read -rp "按回车返回菜单..."
    menu
}

check_docker
menu
