#!/bin/bash
# =================================================================
# microwarp 工具箱 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="microwarp"
BASE_DIR="/opt/microwarp"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

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

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        socks5_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "1080/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$socks5_port" ]] && socks5_port="1080"
    else
        img_version="${RED}未安装${RESET}"
        socks5_port="N/A"
    fi

    # 3. 检查本地 gost 转发状态
    if pgrep -f "gost -F=socks5" > /dev/null; then
        gost_status="${GREEN}已启用${RESET}"
        http_port=$(ps -ef | grep "gost -F=socks5" | grep -oE "\-L=http://[^ ]+" | cut -d':' -f3)
        [[ -z "$http_port" ]] && http_port="未知"
    else
        gost_status="${RED}未启用${RESET}"
        http_port="N/A"
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

# 1. 部署 microwarp
install_utils() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    echo -e "${RED}注意: 该容器需要宿主机 NET_ADMIN 特权以管理网络设备${RESET}"
    
    echo -ne "${YELLOW}请输入 SOCKS5 监听端口 [默认: 1080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="1080"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入 SOCKS5 用户名 (留空则为无密码模式): ${RESET}"
    read -r socks_user
    socks_pass=""
    if [[ -n "$socks_user" ]]; then
        echo -ne "${YELLOW}请输入 SOCKS5 密码: ${RESET}"
        read -r socks_pass
        while [[ -z "$socks_pass" ]]; do
            echo -e "${RED}错误: 密码不能为空！${RESET}"
            echo -ne "${YELLOW}请输入 SOCKS5 密码: ${RESET}"
            read -r socks_pass
        done
    fi

    echo -ne "${YELLOW}是否配置自定义 WARP 节点 Endpoint IP? (y/N): ${RESET}"
    read -r set_endpoint
    endpoint_ip=""
    if [[ "$set_endpoint" == "y" || "$set_endpoint" == "Y" ]]; then
        echo -ne "${YELLOW}请输入 Endpoint IP (例如 162.159.192.1:4500): ${RESET}"
        read -r endpoint_ip
    fi

    # 写入 .env
    cat <<EOF > "$ENV_FILE"
BIND_PORT=${custom_port}
SOCKS_USER=${socks_user}
SOCKS_PASS=${socks_pass}
ENDPOINT_IP=${endpoint_ip}
EOF

    # 动态组装环境变数列表
    local env_block=""
    [[ -n "$socks_user" ]] && env_block="${env_block}\n      - SOCKS_USER=\Professional_SOCKS_USER\n      - SOCKS_PASS=\${SOCKS_PASS}"
    [[ -n "$socks_user" ]] && env_block=$(echo -e "    environment:\n      - SOCKS_USER=\${SOCKS_USER}\n      - SOCKS_PASS=\${SOCKS_PASS}")
    if [[ -n "$endpoint_ip" ]]; then
        if [[ -z "$env_block" ]]; then
            env_block=$(echo -e "    environment:\n      - ENDPOINT_IP=\${ENDPOINT_IP}")
        else
            env_block=$(echo -e "${env_block}\n      - ENDPOINT_IP=\${ENDPOINT_IP}")
        fi
    fi

    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  microwarp:
    image: ghcr.io/ccbkkb/microwarp:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    ports:
      - "127.0.0.1:\${BIND_PORT}:1080"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
$(if [[ -n "$env_block" ]]; then echo "$env_block"; fi)
    logging:
      driver: "json-file"
      options:
        max-size: "3m"
        max-file: "3"
    volumes:
      - warp-data:/etc/wireguard

volumes:
  warp-data:
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 microwarp...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}      microwarp 部署成功 (仅限本地 127.0.0.1 访问)！${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW}SOCKS5 代理地址 : 127.0.0.1:${custom_port}${RESET}"
    [[ -n "$socks_user" ]] && echo -e "${YELLOW}SOCKS5 认证账号 : ${socks_user} / ${socks_pass}${RESET}"
    echo -e "${YELLOW}配置文件路径    : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================================${RESET}"
}

# 2. 更新 microwarp 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 microwarp 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 3. 卸载 microwarp 
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 microwarp 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        # 顺便强制清理相关的 gost 进程
        pkill -f "gost -F=socks5" 2>/dev/null
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down -v
            echo -e "${GREEN}容器及数据卷已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地配置文件目录？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_utils() { 
    cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"
}
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}"
    echo -e "${YELLOW}SOCKS5 端口    : 127.0.0.1:${socks5_port}"
    echo -e "${GREEN}================================${RESET}"
}

# 8. GOST 转换管理独立菜单
manage_gost() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  GOST HTTP 代理转换管理  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}当前 gost 状态 :${RESET} ${gost_status}"
    [[ "$http_port" != "N/A" ]] && echo -e "${GREEN}当前 HTTP 端口 :${RESET} ${YELLOW}${http_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 开启/重构 HTTP 代理转换${RESET}"
    echo -e "${GREEN}2. 关闭 HTTP 代理转换${RESET}"
    echo -e "${GREEN}0. 返回主菜单${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r gost_choice

    case "$gost_choice" in
        1)
            if [[ ! -f "$ENV_FILE" ]]; then
                echo -e "${RED}错误: 未检测到环境配置文件，请先执行主菜单的 1 进行部署！${RESET}"
                return
            fi
            if ! command -v gost &> /dev/null; then
                echo -e "${RED}错误: 系统未安装 gost 环境，请先安装 gost (例如: apt/yum install gost 或自行下载二进制)${RESET}"
                return
            fi
            
            # 读取部署时保存的端口与认证信息
            source "$ENV_FILE"

            echo -ne "${YELLOW}请输入需要转换成的本地 HTTP 监听端口 [默认: 8081]: ${RESET}"
            read -r custom_http_port
            [[ -z "$custom_http_port" ]] && custom_http_port="8081"
            if ! [[ "$custom_http_port" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
                return
            fi

            # 清理旧的 gost 转换进程
            pkill -f "gost -F=socks5" 2>/dev/null

            # 组装认证链
            local auth_str=""
            [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]] && auth_str="${SOCKS_USER}:${SOCKS_PASS}@"

            # 启动命令
            nohup gost -F=socks5://${auth_str}127.0.0.1:${BIND_PORT} -L=http://127.0.0.1:${custom_http_port} > /dev/null 2>&1 &
            
            echo -e "${GREEN}HTTP 代理转换成功！转发地址: 127.0.0.1:${custom_http_port}${RESET}"
            ;;
        2)
            pkill -f "gost -F=socks5" 2>/dev/null
            echo -e "${GREEN}gost 转换进程已成功关闭。${RESET}"
            ;;
        *)
            return
            ;;
    esac
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} ◈ microwarp (WARP) 管理面板 ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${socks5_port}${RESET}"
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
