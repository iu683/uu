#!/bin/bash
# =================================================================
# oci-start 工具箱 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="oci-start"
BASE_DIR="/opt/oci-start-docker"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

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
        # 提取镜像名称/版本
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"

        # 从容器状态提取 WebUI 端口（容器内部默认监听的是 9856 端口）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9856/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        # 兜底获取第一个绑定的端口
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="9856"
    else
        # 容器未安装/未部署时的返回值
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
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

# 部署 oci-start
install_utils() {
    check_dependencies
    
    # 确保基础目录及数据、日志挂载目录存在
    mkdir -p "$BASE_DIR/data" "$BASE_DIR/logs"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 oci-start 访问端口 (宿主机端口) [默认: 9856]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="9856"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 1. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  oci-start:
    pull_policy: always
    container_name: ${CONTAINER_NAME}
    image: lovele/oci-start:latest
    restart: unless-stopped
    ports:
      - "${custom_port}:9856"
    volumes:
      - ${BASE_DIR}/data:/oci-start/data
      - ${BASE_DIR}/logs:/oci-start/logs
    environment:
      - SERVER_PORT=9856
      - DATA_PATH=/oci-start/data
      - LOG_HOME=/oci-start/logs
      - TZ=Asia/Shanghai
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 oci-start 工具箱...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      oci-start 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}配置文件路径   : $COMPOSE_FILE${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 oci-start 镜像
update_utils() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 oci-start 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 oci-start
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载并删除 oci-start 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地配置文件与全部数据（含日志、数据）？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置及数据目录已彻底清理。${RESET}"
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
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# ======================
# 9. Nginx 动态反代配置逻辑
# ======================
setup_nginx_proxy() {
    if ! command -v nginx &> /dev/null; then
        echo -e "\n${RED}❌ 未检测到系统中安装了 Nginx，请先安装 Nginx！${RESET}"
        return
    fi

    echo -e "\n${YELLOW}================================${RESET}"
    echo -e "${YELLOW}   自动提取端口 & 覆盖 Nginx 配置   ${RESET}"
    echo -e "${YELLOW}================================${RESET}"
    
    # 1. 引导输入域名
    read -p "请输入你要覆盖的域名 (例如: oci.666666.xyz): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}❌ 域名不能为空！${RESET}"
        return
    fi

    # 2. 锁定标准的 Ubuntu/Debian 配置文件路径
    local CONF_PATH="/etc/nginx/sites-available/${DOMAIN}"
    local ENABLED_PATH="/etc/nginx/sites-enabled/${DOMAIN}"

    # 3. 核心提示：如果文件存在，触发安全警告与二次确认
    if [[ -f "$CONF_PATH" ]]; then
        echo -e "\n${RED}⚠️  安全警告：检测到该域名的配置文件已存在！${RESET}"
        echo -e "${RED}📂 文件路径: $CONF_PATH${RESET}"
        echo -e "${RED}🕒 最后修改: $(date -r "$CONF_PATH" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "未知")${RESET}"
        echo -e "${YELLOW}👉 继续操作将【彻底清空并覆盖】该文件的所有原配置！${RESET}"
        
        read -p "确定要覆盖吗？(y/N): " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}❌ 操作已安全取消，未修改任何文件。${RESET}"
            return
        fi
    else
        echo -e "\nℹ️ 未检测到已有配置，将直接新建配置文件..."
    fi

    # 4. 自动从 docker-compose.yml 提取主面板对外映射端口
    local oci_port="9856" # 默认兜底端口
    if [[ -f "$COMPOSE_FILE" ]]; then
        # 提取 ports 下形如 XXXX:9856 前面的宿主机实际端口 XXXX
        local port_extract=$(grep -A 2 "ports:" "$COMPOSE_FILE" 2>/dev/null | grep -oE '[0-9]+:9856' | cut -d':' -f1 | head -n 1)
        [[ -n "$port_extract" ]] && oci_port="$port_extract"
    fi
    echo -e "ℹ️ 自动提取到主面板本地映射端口为: ${GREEN}${oci_port}${RESET}"

    echo -e "⏳ 正在覆盖写入配置文件..."

    # 5. 写入包含动态 Websockify 转发的配置模板
    cat << EOF > "$CONF_PATH"
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    # ========================================================
    # 1. 动态核心：VNC 远程桌面控制台 WebSocket 转发
    # ========================================================
    location ~ ^/websockify/(\d+)\$ {
        proxy_pass http://127.0.0.1:\$1;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        # 保持 VNC 桌面长时间不间断连接
        proxy_read_timeout 86400;
    }

    # ========================================================
    # 2. 默认核心：主程序控制面板（自动提取端口）
    # ========================================================
    location / {
        client_max_body_size 200M;
        proxy_pass http://127.0.0.1:${oci_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # 保证主程序中如有局部 WebSocket 也能正常运转
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    # 6. 自动确保激活软链接存在
    if [[ ! -L "$ENABLED_PATH" ]]; then
        ln -s "$CONF_PATH" "$ENABLED_PATH" 2>/dev/null
    fi

    # 7. 测试并重启 Nginx
    echo -e "\n⏳ 正在验证 Nginx 配置并重载服务..."
    if nginx -t &>/dev/null; then
        systemctl reload nginx || systemctl restart nginx
        echo -e "${GREEN}==================================================${RESET}"
        echo -e "${GREEN}🎉 成功！已自动提取双端口并一键覆盖 Nginx 配置！${RESET}"
        echo -e "${YELLOW}🌐 访问域名:${RESET} ${GREEN}https://${DOMAIN}${RESET}"
        echo -e "${GREEN}==================================================${RESET}"
    else
        echo -e "${RED}❌ Nginx 语法测试失败！请检查证书是否已生成，或已有配置是否冲突。${RESET}"
        nginx -t
    fi
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  oci-start 管理面板  ◈    ${RESET}"
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
    echo -e "${GREEN}9. 反向代理${RESET}"
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
        9) setup_nginx_proxy ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
