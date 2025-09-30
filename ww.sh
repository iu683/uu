#!/bin/bash

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# ================== 基础信息 ==================
CONTAINER_NAME="3x-ui"
IMAGE_NAME="ghcr.io/mhsanaei/3x-ui:latest"
DB_DIR="/opt/3xui/db"
CERT_DIR="/opt/3xui/cert"
PANEL_PORT=2053

# ================== 函数 ==================

install_3xui() {
    echo -e "${GREEN}🚀 开始安装 3x-ui 官方镜像 ...${RESET}"

    # 检查 root
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}❌ 请用 root 用户运行脚本${RESET}"
        exit 1
    fi

    # 检查 Docker
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}⚙️ 未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    else
        echo -e "${GREEN}✅ Docker 已安装${RESET}"
    fi

    # 创建目录
    mkdir -p "$DB_DIR" "$CERT_DIR"

    # 删除旧容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${YELLOW}⚠️ 已存在容器 ${CONTAINER_NAME}，正在删除...${RESET}"
        docker stop ${CONTAINER_NAME} >/dev/null 2>&1
        docker rm ${CONTAINER_NAME} >/dev/null 2>&1
    fi

    # 运行新容器
    echo -e "${GREEN}📦 拉取镜像并启动容器...${RESET}"
    docker run -itd \
      --name ${CONTAINER_NAME} \
      --restart=always \
      --network=host \
      -e XRAY_VMESS_AEAD_FORCED=false \
      -v ${DB_DIR}:/etc/x-ui/ \
      -v ${CERT_DIR}:/root/cert/ \
      ${IMAGE_NAME}

    echo -e "${GREEN}✅ 安装完成！${RESET}"
    echo -e "👉 管理面板: ${YELLOW}http://$(curl -s ifconfig.me):${PANEL_PORT}${RESET}"
    echo -e "👉 默认用户: ${YELLOW}admin${RESET} / 密码: ${YELLOW}admin${RESET}"
}

update_3xui() {
    echo -e "${GREEN}🔄 更新 3x-ui ...${RESET}"

    # 拉取最新镜像
    docker pull ${IMAGE_NAME}

    # 检查容器是否存在
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${GREEN}🔁 容器已存在，正在重启以应用新镜像...${RESET}"
        docker stop ${CONTAINER_NAME} >/dev/null 2>&1

        # 使用最新镜像重启容器，保留卷和网络模式
        docker commit ${CONTAINER_NAME} temp_image_backup >/dev/null 2>&1
        docker rm ${CONTAINER_NAME} >/dev/null 2>&1
        docker run -itd \
          --name ${CONTAINER_NAME} \
          --restart=always \
          --network=host \
          -e XRAY_VMESS_AEAD_FORCED=false \
          -v ${DB_DIR}:/etc/x-ui/ \
          -v ${CERT_DIR}:/root/cert/ \
          ${IMAGE_NAME}

        echo -e "${GREEN}✅ 更新完成，容器已重启${RESET}"
    else
        echo -e "${RED}❌ 容器不存在，无法更新。请先安装${RESET}"
    fi
}


uninstall_3xui() {
    echo -e "${RED}⚠️ 卸载 3x-ui ...${RESET}"
    docker stop ${CONTAINER_NAME} >/dev/null 2>&1
    docker rm ${CONTAINER_NAME} >/dev/null 2>&1
    rm -rf /opt/3xui
    echo -e "${GREEN}✅ 已卸载容器 ${CONTAINER_NAME}${RESET}"
}

logs_3xui() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${GREEN}📖 正在查看日志，按 Ctrl+C 退出...${RESET}"
        docker logs -f ${CONTAINER_NAME}
    else
        echo -e "${RED}❌ 容器 ${CONTAINER_NAME} 未运行${RESET}"
    fi
}

# ================== 菜单 ==================
while true; do
    clear
    echo -e "${GREEN}========= 3x-ui 管理菜单 =========${RESET}"
    echo -e "${YELLOW}1.安装 3x-ui${RESET}"
    echo -e "${YELLOW}2.更新 3x-ui${RESET}"
    echo -e "${YELLOW}3.卸载 3x-ui${RESET}"
    echo -e "${YELLOW}4.查看日志${RESET}"
    echo -e "${YELLOW}0.退出${RESET}"
    echo -ne "${GREEN}请选择操作 [0-4]: ${RESET}"
    read opt

    case $opt in
        1) install_3xui ;;
        2) update_3xui ;;
        3) uninstall_3xui ;;
        4) logs_3xui ;;
        0) echo -e "${GREEN}退出脚本${RESET}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入${RESET}" ;;
    esac
    echo -e "${YELLOW}按回车键返回菜单...${RESET}"
    read
done
