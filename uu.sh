#!/bin/bash
# =================================================================
# Filebrowser Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="filebrowser"
BASE_DIR="/opt/filebrowser"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
JSON_FILE="$BASE_DIR/config/.filebrowser.json"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在（不论运行还是停止），从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 【优化：从容器状态提取 WebUI 端口】
        # 优先获取容器绑定的宿主机端口（假设容器内监听的是 80 端口，请根据实际情况修改，比如 Filebrowser 默认通常是 80）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 如果上面指定内部端口没获取到，则兜底获取容器暴露出来的第一个宿主机端口
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        # 如果容器停止了或没映射端口，则给个默认值
        [[ -z "$webui_port" ]] && webui_port="8089"

        # 【优化：从容器状态提取下载目录（挂载路径）】
        # 精准查找容器内挂载到 /srv 的宿主机绝对路径
        download_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/srv"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        # 如果没挂载到 /srv，查找包含 filebrowser 的挂载，或者任意第一个挂载作为兜底
        [[ -z "$download_dir" ]] && download_dir=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{break}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        # 终极兜底默认值
        [[ -z "$download_dir" ]] && download_dir="/opt/filebrowser/file"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        download_dir="N/A"
    fi
}

# 提取 Filebrowser 容器内的初始临时密码
get_fb_password() {
    if [ ! "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        echo -e "${RED}容器未部署${RESET}"
        return
    fi
    
    local log_pass
    log_pass=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -i "randomly generated password:" | tail -n 1 | awk -F 'randomly generated password:' '{print $2}' | tr -d '[:space:].')
    
    if [[ -n "$log_pass" ]]; then
        echo -e "${GREEN}${log_pass}${RESET}"
    else
        echo -e "${YELLOW}未探测到初始密码（可能已被你修改，或日志已被冲刷）${RESET}"
    fi
}

get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}

install_filebrowser() {
    check_dependencies
    
    # 彻底清理之前由于报错导致 Docker 自动生成的错误“文件夹”
    if [[ -d "$JSON_FILE" ]]; then
        rm -rf "$JSON_FILE"
    fi
    mkdir -p "$BASE_DIR/config"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 Filebrowser 访问端口 (宿主机端口) [默认: 8089]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8089"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入宿主机网盘文件存储绝对路径 [默认: /opt/filebrowser/file]: ${RESET}"
    read -r custom_download
    [[ -z "$custom_download" ]] && custom_download="/opt/filebrowser/file"

    # 1. 动态创建所需的宿主机目录与空数据库文件
    mkdir -p "$custom_download"
    touch "$BASE_DIR/config/filebrowser.db"

    # 2. 核心联动：动态生成对应的 .filebrowser.json 配置文件
    echo -e "${YELLOW}正在生成对应的 .filebrowser.json 配置文件...${RESET}"
    cat <<EOF > "$JSON_FILE"
{
  "port": 80,
  "baseURL": "",
  "address": "",
  "log": "stdout",
  "database": "/database.db",
  "root": "/srv"
}
EOF
    chmod -R 777 "$BASE_DIR" "$custom_download"

    # 3. 移除过时的 version 声明，修正 JSON_FILE 路径挂载 Bug
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  filebrowser:
    image: filebrowser/filebrowser:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    user: "$(id -u):$(id -g)"
    ports:
      - "127.0.0.1:${custom_port}:80/tcp"
    networks:
      - net
    volumes:
      - ${custom_download}:/srv
      - ${BASE_DIR}/config/filebrowser.db:/database.db
      - ${JSON_FILE}:/.filebrowser.json
      - /etc/localtime:/etc/localtime:ro

networks:
  net:
    driver: bridge
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Filebrowser...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化并同步密码日志 (约5秒)...${RESET}"
    sleep 5

    SHOW_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Filebrowser 部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}网盘访问地址   : http://127.0.0.1:${custom_port}${RESET}"
    echo -e "${YELLOW}默认用户名     : admin${RESET}"
    echo -ne "${YELLOW}初始随机密码   : ${RESET}"
    get_fb_password
    echo -e "${YELLOW}宿主机配置路径 : $BASE_DIR/config${RESET}"
    echo -e "${YELLOW}宿主机网盘路径 : $custom_download${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

update_filebrowser() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Filebrowser 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

uninstall_filebrowser() {
    echo -ne "${YELLOW}确定要卸载并删除 Filebrowser 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和网盘内的数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_fb() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_fb() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_fb() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_fb() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    SHOW_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}网盘访问地址   : http://127.0.0.1:${webui_port}${RESET}"
    echo -e "${YELLOW}宿主机网盘路径 : ${download_dir}${RESET}"
    echo -ne "${YELLOW}初始密码探测   : ${RESET}"
    get_fb_password
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Filebrowser 管理面板  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
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
        1) install_filebrowser ;;
        2) update_filebrowser ;;
        3) uninstall_filebrowser ;;
        4) start_fb ;;
        5) stop_fb ;;
        6) restart_fb ;;
        7) logs_fb ;;
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
