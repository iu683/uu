#!/bin/bash
# =================================================================
# Forgejo Git 服务 Docker Compose 管理面板 (含宿主机22端口直通版)
# =================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="forgejo"
BASE_DIR="/opt/forgejo"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
SHELL_PROXY="/usr/local/bin/forgejo-shell"

check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker！${RESET}"
        exit 1
    fi
}

get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="3000"
        ssh_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "22/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$ssh_port" ]] && ssh_port="222"
        data_dir=$(docker inspect -f '{{range .Mounts}}{{.Source}}{{break}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$data_dir" ]] && data_dir="/opt/forgejo/forgejo"
    else
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        ssh_port="N/A"
        data_dir="N/A"
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
# 部署服务
install_forgejo() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    current_uid=$(id -u)
    current_gid=$(id -g)
    [[ "$current_uid" = "0" ]] && current_uid=1000 && current_gid=1000

    echo -ne "${YELLOW}请输入 Forgejo Web 访问端口 [默认: 3000]: ${RESET}"
    read -r custom_web_port
    [[ -z "$custom_web_port" ]] && custom_web_port="3000"

    echo -ne "${YELLOW}请输入 Forgejo 容器独立 SSH 映射端口 [默认: 222]: ${RESET}"
    read -r custom_ssh_port
    [[ -z "$custom_ssh_port" ]] && custom_ssh_port="222"

    echo -ne "${YELLOW}请输入宿主机数据存储绝对路径 [默认: /opt/forgejo/forgejo]: ${RESET}"
    read -r custom_data
    [[ -z "$custom_data" ]] && custom_data="/opt/forgejo/forgejo"

    mkdir -p "$custom_data"
    chmod -R 775 "$custom_data"

    cat <<EOF > "$COMPOSE_FILE"
networks:
  forgejo:
    external: false

services:
  server:
    image: codeberg.org/forgejo/forgejo:15
    container_name: ${CONTAINER_NAME}
    environment:
      - USER_UID=${current_uid}
      - USER_GID=${current_gid}
    restart: always
    networks:
      - forgejo
    volumes:
      - ${custom_data}:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "${custom_web_port}:3000"
      - "${custom_ssh_port}:22"
EOF

    cd "$BASE_DIR" && docker compose up -d --force-recreate
    sleep 3
    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Firefox (jlesage) 部署成功！ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}Web 浏览器访问地址: http://${DETECT_IP}:${custom_web_port}${RESET}"
    echo -e "${YELLOW}VNC 客户端连接地址: ${DETECT_IP}:${custom_vnc_port}${RESET}"
    echo -e "${YELLOW}访问/连接密码     : $vnc_pwd${RESET}"
    echo -e "${YELLOW}宿主机数据路径    : $custom_data${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 🚀 你的踩坑点解决方案：一键配置宿主机 22 端口直通容器
setup_ssh_passthrough() {
    get_status_info
    if [ "$status" != "${YELLOW}运行中${RESET}" ]; then
        echo -e "${RED}错误: Forgejo 容器未运行，请先部署或启动它！${RESET}"
        return
    fi

    echo -e "${CYAN}====== 开始配置宿主机 22 端口 SSH 直通 ======${RESET}"
    
    # 1. 检查或创建宿主机 git 用户
    if ! id "git" &>/dev/null; then
        echo -e "${YELLOW}正在创建宿主机 git 用户...${RESET}"
        sudo useradd -m -s /bin/bash git
    fi

    # 2. 创建 shell 代理脚本
    echo -e "${YELLOW}正在创建 Shell 代理脚本: ${SHELL_PROXY}...${RESET}"
    sudo tee "$SHELL_PROXY" > /dev/null << 'EOF'
#!/bin/sh
/usr/bin/docker exec -i -u git --env SSH_ORIGINAL_COMMAND="$SSH_ORIGINAL_COMMAND" forgejo sh "$@"
EOF
    sudo chmod +x "$SHELL_PROXY"

    # 3. 修改 git 用户的登录 shell
    echo -e "${YELLOW}修改 git 用户的登录 Shell 为代理脚本...${RESET}"
    sudo usermod -s "$SHELL_PROXY" git

    # 4. 修改宿主机 sshd_config
    if ! sudo grep -q "Match User git" /etc/ssh/sshd_config; then
        echo -e "${YELLOW}正在配置宿主机 /etc/ssh/sshd_config...${RESET}"
        sudo tee -a /etc/ssh/sshd_config > /dev/null << EOF

# Forgejo SSH Passthrough
Match User git
    AuthorizedKeysCommandUser git
    AuthorizedKeysCommand /usr/bin/docker exec -i -u git forgejo /usr/local/bin/forgejo keys -c /data/gitea/conf/app.ini -e git -u %u -t %t -k %k
EOF
        echo -e "${YELLOW}正在重启宿主机 sshd 服务...${RESET}"
        sudo systemctl restart sshd
        echo -e "${GREEN}🎉 22 端口 SSH 直通配置完成！${RESET}"
    else
        echo -e "${CYAN}提示: /etc/ssh/sshd_config 中已存在相关配置，跳过修改。${RESET}"
    fi
}

# 更新 Forgejo 镜像
update_forgejo() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Forgejo 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！Forgejo 已处于最新状态。${RESET}"
}

# 卸载 Forgejo
uninstall_forgejo() {
    echo -ne "${YELLOW}确定要卸载并删除 Forgejo 容器及网络吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器与网络已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除代码仓库和所有 Git 数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                rm -rf "$custom_data" 2>/dev/null
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_forgejo() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_forgejo() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_forgejo() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_forgejo() { docker logs -f "$CONTAINER_NAME"; }


show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}Web 访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}SSH 映射端口   : ${ssh_port}${RESET}"
    echo -e "${YELLOW}宿主机数据路径 : ${data_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}


menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  Forgejo 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}Web  :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}SSH  :${RESET} ${YELLOW}${ssh_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}9. 配置宿主机22端口SSH直通${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_forgejo ;;
        2) update_forgejo ;;
        3) uninstall_forgejo ;;
        4) start_forgejo ;;
        5) stop_forgejo ;;
        6) restart_forgejo ;;
        7) logs_forgejo ;;
        8) show_info ;;
        9) setup_ssh_passthrough ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
