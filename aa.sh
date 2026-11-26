#!/bin/bash
# =================================================================
# Simple Blog 后端服务 Docker Compose 独立管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="simple-blog"
IMAGE_NAME="ghcr.io/usxs/simple-blog-backend:v3"
BASE_DIR="/opt/simple-blog"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、镜像与映射端口
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="$IMAGE_NAME"

        # 动态抓取映射到容器 33001 端口的宿主机实际端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "33001/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="33001"
        port_display="${webui_port}"

        site_url=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep '^SITE_PUBLIC_URL=' | cut -d'=' -f2-)
        [[ -z "$site_url" ]] && site_url="未设置"
    else
        img_version="${RED}未安装${RESET}"
        port_display="N/A"
        site_url="N/A"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""

    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

# 处理绝对路径与相对路径转换
get_real_path() {
    local input_path="$1"
    local default_path="$2"
    [[ -z "$input_path" ]] && input_path="$default_path"

    if [[ "$input_path" == "./"* ]]; then
        echo "$BASE_DIR/${input_path#./}"
    else
        echo "$input_path"
    fi
}

# 部署 Simple Blog
install_utils() {
    check_dependencies

    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 目录挂载自定义配置 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认采用 ${BASE_DIR} 下的 data、img、file 文件夹。${RESET}"

    echo -ne "${YELLOW}请输入数据(data)本地挂载路径 [默认: ./data]: ${RESET}"
    read -r input_data
    local path_data_raw="${input_data:-./data}"
    local real_path_data
    real_path_data=$(get_real_path "$path_data_raw" "./data")

    echo -ne "${YELLOW}请输入图片(img)本地挂载路径 [默认: ./img]: ${RESET}"
    read -r input_img
    local path_img_raw="${input_img:-./img}"
    local real_path_img
    real_path_img=$(get_real_path "$path_img_raw" "./img")

    echo -ne "${YELLOW}请输入附件(file)本地挂载路径 [默认: ./file]: ${RESET}"
    read -r input_file
    local path_file_raw="${input_file:-./file}"
    local real_path_file
    real_path_file=$(get_real_path "$path_file_raw" "./file")

    # 预创建目录并赋予 1000:1000 权限
    mkdir -p "$real_path_data" "$real_path_img" "$real_path_file"
    chown -R 1000:1000 "$real_path_data" "$real_path_img" "$real_path_file" 2>/dev/null || sudo chown -R 1000:1000 "$real_path_data" "$real_path_img" "$real_path_file"

    echo -e "\n${CYAN}====== 2. 端口、账号与访问地址配置 ======${RESET}"

    echo -ne "${YELLOW}请输入宿主机访问端口 [默认: 33001]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="33001"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]] || [ "$custom_port" -lt 1 ] || [ "$custom_port" -gt 65535 ]; then
        echo -e "${RED}错误: 端口必须是 1-65535 之间的纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入管理员用户名 [默认: admin]: ${RESET}"
    read -r admin_user
    [[ -z "$admin_user" ]] && admin_user="admin"

    echo -ne "${YELLOW}请输入管理员强密码 [默认: ChangeMe_2026!]: ${RESET}"
    read -rs admin_pass
    echo ""
    [[ -z "$admin_pass" ]] && admin_pass="ChangeMe_2026!"

    echo -ne "${YELLOW}请输入站点公网 URL（反代域名或 IP） [默认: http://${DETECT_IP}:${custom_port}]: ${RESET}"
    read -r input_url
    local site_url="${input_url:-http://${DETECT_IP}:${custom_port}}"

    echo -e "${YELLOW}正在生成 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  simple-blog-backend:
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${custom_port}:33001"
    volumes:
      - ${path_data_raw}:/app/data
      - ${path_img_raw}:/app/img
      - ${path_file_raw}:/app/file
    environment:
      - ADMIN_USERNAME=${admin_user}
      - ADMIN_PASSWORD=${admin_pass}
      - SITE_PUBLIC_URL=${site_url}
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Simple Blog...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       Simple Blog 部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}站点公网地址   : ${site_url}${RESET}"
    echo -e "${YELLOW}后台管理地址   : ${site_url}/admin${RESET}"
    echo -e "${YELLOW}管理员账号     : ${admin_user}${RESET}"
    echo -e "${YELLOW}管理员密码     : ${admin_pass}${RESET}"
    echo -e "${YELLOW}数据/图片/附件 : ${real_path_data} | ${real_path_img} | ${real_path_file}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Simple Blog 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Simple Blog 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Simple Blog
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您的文章、图片及附件数据！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除 Simple Blog 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}【高风险】是否同时彻底删除本地全量挂载的博客数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有监控配置及数据已被彻底销毁。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}当前映射端口   : ${port_display}${RESET}"
    echo -e "${YELLOW}站点公网地址   : ${site_url}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Simple Blog 管理面板  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port_display}${RESET}"
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
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
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
