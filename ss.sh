=#!/bin/bash
# =================================================================
# AdGuard Home 广告拦截/DNS 服务 Docker Compose 独立管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="adguardhome"
BASE_DIR="/opt/adguardhome"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态与映射端口
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
        [[ -z "$img_version" ]] && img_version="adguard/adguardhome:latest"
        
        # 动态抓取映射到容器内 80 端口的宿主机实际 Web 管理端口
        local check_web_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$check_web_port" ]] && check_web_port="801"
        port_display="${check_web_port} (管理端口)"
    else
        img_version="${RED}未安装${RESET}"
        port_display="N/A"
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

# 部署 AdGuard Home
install_utils() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 目录挂载自定义配置 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认采用脚本同级路径下的各功能文件夹。${RESET}"
    
    echo -ne "${YELLOW}请输入数据根挂载路径 [默认: ./]: ${RESET}"
    read -r input_data
    local path_root_raw="${input_data:-./}"
    
    # 动态计算绝对路径
    local real_work_path=$(get_real_path "${path_root_raw%/}/workdir" "./workdir")
    local real_conf_path=$(get_real_path "${path_root_raw%/}/confdir" "./confdir")

    # 预创建目录并赋权
    echo -e "${YELLOW}正在宿主机预构建并赋权对应物理目录...${RESET}"
    mkdir -p "$real_work_path" "$real_conf_path"
    chmod -R 777 "$real_work_path" "$real_conf_path"

    echo -e "\n${CYAN}====== 2. 自定义端口配置 (Bridge 模式) ======${RESET}"
    
    echo -ne "${YELLOW}请输入初始化向导端口 (映射容器内 3000) [默认: 3000]: ${RESET}"
    read -r port_init
    [[ -z "$port_init" ]] && port_init="3000"

    echo -ne "${YELLOW}请输入 Web 管理端口 (映射容器内 80) [默认: 801]: ${RESET}"
    read -r port_web
    [[ -z "$port_web" ]] && port_web="801"

    echo -ne "${YELLOW}请输入 HTTPS 访问端口 (映射容器内 443) [默认: 4431]: ${RESET}"
    read -r port_https
    [[ -z "$port_https" ]] && port_https="4431"

    # 动态生成纯净版 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成原生直挂版 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  adguardhome:
    image: adguard/adguardhome:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "${port_init}:3000/tcp"
      - "${port_init}:3000/udp"
      - "${port_web}:80/tcp"
      - "${port_web}:80/udp"
      - "${port_https}:443/tcp"
      - "${port_https}:443/udp"
      - "853:853/tcp"
      - "853:853/udp"
    volumes:
      - ${path_root_raw%/}/workdir:/opt/adguardhome/work
      - ${path_root_raw%/}/confdir:/opt/adguardhome/conf
EOF

    # 检查宿主机 53 端口冲突提示
    if [ "$(ss -ulnm | grep -w 53)" ]; then
        echo -e "${RED}警告: 宿主机 53 端口已被占用（可能是 systemd-resolved 或 dnsmasq）。${RESET}"
        echo -e "${RED}请确保您已关闭本地 DNS 监听，否则 AdGuard 容器会启动失败。${RESET}"
        echo -ne "${YELLOW}按回车尝试启动...${RESET}"
        read -r
    fi

    echo -e "${YELLOW}正在通过 Docker Compose 启动 AdGuard Home...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        AdGuard Home 部署成功！  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}首次配置/初始化向导 : http://${DETECT_IP}:${port_init}${RESET}"
    echo -e "${YELLOW}本地工作挂载路径   : ${real_work_path}${RESET}"
    echo -e "${YELLOW}本地配置挂载路径   : ${real_conf_path}${RESET}"
    echo -e "${YELLOW}配置文件路径       : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${CYAN}💡 提示: 进入初始化向导后，请将 [Web 界面端口] 修改为你刚刚指定的: ${port_web}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 AdGuard Home 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 AdGuard Home 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 AdGuard Home
uninstall_utils() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久丢失您配置的所有 DNS 过滤规则与白名单！${RESET}"
    echo -ne "${YELLOW}确定要卸载并删除 AdGuard Home 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}【高风险】是否同时彻底删除本地挂载的全量规则与配置文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有 AdGuard 历史配置数据已被彻底销毁。${RESET}"
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
    echo -e "${YELLOW}当前映射状态   : ${port_display}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  AdGuard Home 管理面板  ◈  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}映射 :${RESET} ${YELLOW}${port_display}${RESET}"
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
