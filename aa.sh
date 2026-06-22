#!/bin/bash
# =================================================================
# EasyImage 图床服务 Docker Compose 管理面板 (支持子目录自定义)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="easyimage"
# 默认主配置目录
DEFAULT_BASE_DIR="/opt/easyimage"

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

    # 2. 如果容器存在，从容器状态中动态提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取 WebUI 端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="5589"

        # 动态提取挂载路径
        custom_config_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/web/config"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        custom_i_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/web/i"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        
        # 通过 config 所在目录来定位 docker-compose.yml 的存放位置
        if [[ -n "$custom_config_dir" ]]; then
            BASE_DIR=$(dirname "$custom_config_dir")
        fi
    fi
    
    # 兜底路径
    [[ -z "$BASE_DIR" || "$BASE_DIR" == "." ]] && BASE_DIR="$DEFAULT_BASE_DIR"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
    [[ -z "$custom_config_dir" ]] && custom_config_dir="$BASE_DIR/config"
    [[ -z "$custom_i_dir" ]] && custom_i_dir="$BASE_DIR/i"
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

# 部署 EasyImage
install_easyimage() {
    check_dependencies
    
    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    # 1. 端口配置
    echo -ne "${YELLOW}请输入 EasyImage 访问端口 [默认: 5589]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="5589"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 2. 主脚本与 Compose 存放目录
    echo -ne "${YELLOW}请输入面板配置文件存放路径 [默认: $DEFAULT_BASE_DIR]: ${RESET}"
    read -r input_base
    [[ -z "$input_base" ]] && input_base="$DEFAULT_BASE_DIR"
    BASE_DIR="$input_base"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

    # 3. 自定义 Config 目录
    echo -ne "${YELLOW}请输入【配置文件(config)】宿主机存储绝对路径 [默认: $BASE_DIR/config]: ${RESET}"
    read -r input_config
    [[ -z "$input_config" ]] && input_config="$BASE_DIR/config"
    custom_config_dir="$input_config"

    # 4. 自定义 图片 目录
    echo -ne "${YELLOW}请输入【图片数据(i)】宿主机存储绝对路径 [默认: $BASE_DIR/i]: ${RESET}"
    read -r input_i
    [[ -z "$input_i" ]] && input_i="$BASE_DIR/i"
    custom_i_dir="$input_i"
    
    # 创建所有用户自定义的目录并赋权
    mkdir -p "$BASE_DIR"
    mkdir -p "$custom_config_dir"
    mkdir -p "$custom_i_dir"
    chmod -R 777 "$BASE_DIR" "$custom_config_dir" "$custom_i_dir"

    # 生成 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
version: '3.8'

services:
  easyimage:
    image: ddsderek/easyimage:latest
    container_name: ${CONTAINER_NAME}
    ports:
      - "${custom_port}:80"
    environment:
      - TZ=Asia/Shanghai
      - PUID=1000
      - PGID=1000
      - DEBUG=false
    volumes:
      - ${custom_config_dir}:/app/web/config
      - ${custom_i_dir}:/app/web/i
    restart: unless-stopped
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 EasyImage 图床服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     EasyImage 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}Config 挂载路径: $custom_config_dir${RESET}"
    echo -e "${YELLOW}图片 i 挂载路径 : $custom_i_dir${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 EasyImage 镜像
update_easyimage() {
    get_status_info
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 EasyImage 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 EasyImage
uninstall_easyimage() {
    get_status_info
    echo -ne "${YELLOW}确定要卸载并删除 EasyImage 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有自定义的配置文件和图片数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                rm -rf "$custom_config_dir"
                rm -rf "$custom_i_dir"
                echo -e "${GREEN}所有自定义数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_easyimage() { get_status_info && cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_easyimage() { get_status_info && cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_easyimage() { get_status_info && cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_easyimage() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}Config 挂载路径: ${custom_config_dir}"
    echo -e "${YELLOW}图片 i 挂载路径 : ${custom_i_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  EasyImage 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}配置 :${RESET} ${CYAN}${custom_config_dir}${RESET}"
    echo -e "${GREEN}图片 :${RESET} ${CYAN}${custom_i_dir}${RESET}"
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
        1) install_easyimage ;;
        2) update_easyimage ;;
        3) uninstall_easyimage ;;
        4) start_easyimage ;;
        5) stop_easyimage ;;
        6) restart_easyimage ;;
        7) logs_easyimage ;;
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
