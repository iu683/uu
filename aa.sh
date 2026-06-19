#!/bin/bash
# =================================================================
# 小雅 TVBox / AList-TVBox 三合一 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/alist-tvbox"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
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

DETECT_IP=$(get_public_ip)


# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 尝试捕获可能存在的两个容器名
    if [ "$(docker ps -q -f name=^/xiaoya-tvbox$)" ] || [ "$(docker ps -q -f name=^/alist-tvbox$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/xiaoya-tvbox$)" ] || [ "$(docker ps -aq -f name=^/alist-tvbox$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 动态抓取当前运行的容器名
    current_container="xiaoya-tvbox"
    if [ "$(docker ps -aq -f name=^/alist-tvbox$)" ]; then
        current_container="alist-tvbox"
    fi

    # 从容器状态提取端口
    if [ "$(docker ps -aq -f name=^/${current_container}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$current_container" 2>/dev/null)
        
        # 检查是否为 Host 模式
        local net_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$current_container" 2>/dev/null)
        if [[ "$net_mode" == "host" ]]; then
            mgt_port="4567 (Host模式)"
            alist_port="5234 (Host模式)"
        else
            # 桥接模式下动态提取管理后台端口 (4567)
            mgt_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "4567/tcp") 0).HostPort}}' "$current_container" 2>/dev/null)
            [[ -z "$mgt_port" ]] && mgt_port="4567"
            
            # 提取 AList 端口
            alist_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{if eq $p "80/tcp"}}{{(index $conf 0).HostPort}}{{end}}{{end}}{{end}}' "$current_container" 2>/dev/null)
            [[ -z "$alist_port" ]] && alist_port="5344"
        fi
    else
        img_version="${RED}未安装${RESET}"
        mgt_port="N/A"
        alist_port="N/A"
    fi
}

# 部署选择与安装流程
install_xiaoya() {
    check_dependencies
    
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    请选择要部署的 小雅/TVBox 版本: ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${CYAN}1. 小雅集成版 (标准网桥模式，默认端口 4567 / 5344)${RESET}"
    echo -e "${CYAN}2. 小雅集成版 (Host 网络模式，性能更佳，固定端口 4567 / 5234)${RESET}"
    echo -e "${CYAN}3. 纯净版 AList-TVBox (无自带小雅，默认端口 4567)${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${YELLOW}请输入版本编号 [1-3]: ${RESET}"
    read -r version_choice

    if [[ "$version_choice" != "1" && "$version_choice" != "2" && "$version_choice" != "3" ]]; then
        echo -e "${RED}输入错误，取消部署。${RESET}"
        return
    fi

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入安装绝对路径 [默认: /opt/alist-tvbox]: ${RESET}"
    read -r custom_dir
    [[ -z "$custom_dir" ]] && custom_dir="/opt/alist-tvbox"
    BASE_DIR="$custom_dir"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

    mkdir -p "$BASE_DIR" "$BASE_DIR/www-static"
    chmod -R 777 "$BASE_DIR"

    # 根据版本渲染不同的 YAML 配置
    case "$version_choice" in
        1)
            echo -ne "${YELLOW}请输入管理网页访问端口 [默认: 4567]: ${RESET}"
            read -r custom_mgt
            [[ -z "$custom_mgt" ]] && custom_mgt="4567"
            
            echo -ne "${YELLOW}请输入 AList 访问端口 [默认: 5344]: ${RESET}"
            read -r custom_alist
            [[ -z "$custom_alist" ]] && custom_alist="5344"

            echo -e "${YELLOW}正在生成 [小雅集成版] 配置文件...${RESET}"
            cat <<EOF > "$COMPOSE_FILE"
services:
  xiaoya-tvbox:
    image: haroldli/xiaoya-tvbox:latest
    container_name: xiaoya-tvbox
    restart: always
    ports:
      - "${custom_mgt}:4567"
      - "${custom_alist}:80"
    environment:
      - ALIST_PORT=${custom_alist}
    volumes:
      - ${BASE_DIR}:/data
      - ${BASE_DIR}/www-static:/www/static
EOF
            local show_msg="${YELLOW}管理后台地址 : http://${DETECT_IP}:${custom_mgt}\nAList 访问地址: http://${DETECT_IP}:${custom_alist}${RESET}"
            ;;
        2)
            echo -e "${YELLOW}正在生成 [小雅 Host网络版] 配置文件 (注意：Host模式下端口由容器本身决定)...${RESET}"
            cat <<EOF > "$COMPOSE_FILE"
services:
  xiaoya-tvbox:
    image: haroldli/xiaoya-tvbox:hostmode
    container_name: xiaoya-tvbox
    restart: always
    network_mode: host
    volumes:
      - ${BASE_DIR}:/data
      - ${BASE_DIR}/www-static:/www/static
EOF
            local show_msg="${YELLOW}管理后台地址 : http://${DETECT_IP}:4567\nAList 访问地址: http://${DETECT_IP}:5234${RESET}"
            ;;
        3)
            echo -ne "${YELLOW}请输入管理网页访问端口 [默认: 4567]: ${RESET}"
            read -r custom_mgt
            [[ -z "$custom_mgt" ]] && custom_mgt="4567"

            echo -ne "${YELLOW}请输入内置 AList 访问端口 [默认: 5244]: ${RESET}"
            read -r custom_alist
            [[ -z "$custom_alist" ]] && custom_alist="5244"

            echo -e "${YELLOW}正在生成 [纯净版 AList-TVBox] 配置文件...${RESET}"
            cat <<EOF > "$COMPOSE_FILE"
services:
  alist-tvbox:
    image: haroldli/alist-tvbox:latest
    container_name: alist-tvbox
    restart: always
    ports:
      - "${custom_mgt}:4567"
      - "${custom_alist}:5244"
    environment:
      - ALIST_PORT=${custom_alist}
    volumes:
      - ${BASE_DIR}:/data
      - ${BASE_DIR}/www-static:/www/static
EOF
            local show_msg="${YELLOW}管理后台地址 : http://${DETECT_IP}:${custom_mgt}\nAList 访问地址: http://${DETECT_IP}:${custom_alist}${RESET}"
            ;;
    esac

    echo -e "${YELLOW}正在通过 Docker Compose 启动服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待服务初始化并生成密码凭据 (约5秒)...${RESET}"
    sleep 5

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     AList-TvBox  部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "$show_msg"
    echo -e "${YELLOW}持久化目录   : $BASE_DIR${RESET}"
    
    # 动态判断并打印安装后的密码
    if [ -f "$BASE_DIR/initial_admin_credentials.txt" ]; then
        echo -e "${GREEN}====== 检测到系统自动生成的安全凭据 ======${RESET}"
        cat "$BASE_DIR/initial_admin_credentials.txt"
    else
        echo -e "${YELLOW}默认用户名: admin${RESET}"
        cat "$BASE_DIR/initial_admin_credentials.txt"
    fi
    echo -e "${GREEN}================================${RESET}"

}

# 更新镜像
update_xiaoya() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器组件已处于最新状态。${RESET}"
}

# 卸载服务
uninstall_xiaoya() {
    echo -ne "${YELLOW}确定要卸载并删除 TVBox 相关容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时彻底删除本地缓存数据、小雅配置及静态文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}持久化数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f xiaoya-tvbox alist-tvbox 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_xiaoya() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_xiaoya() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_xiaoya() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_xiaoya() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}配置管理端口   : ${mgt_port}${RESET}"
    if [[ "$alist_port" != "N/A" ]]; then
        echo -e "${YELLOW}AList 端口     : ${alist_port}${RESET}"
    fi
    echo -e "${YELLOW}数据存储目录   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}◈  小雅/AList-TVBox  管理面板 ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态     :${RESET} $status"
    echo -e "${GREEN}管理端口 :${RESET} ${YELLOW}${mgt_port}${RESET}"  
    echo -e "${GREEN}AList端口:${RESET} ${YELLOW}${alist_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新服务${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
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
        1) install_xiaoya ;;
        2) update_xiaoya ;;
        3) uninstall_xiaoya ;;
        4) start_xiaoya ;;
        5) stop_xiaoya ;;
        6) restart_xiaoya ;;
        7) logs_xiaoya ;;
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
