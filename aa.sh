#!/bin/bash
# =================================================================
# Nezha Dashboard (哪吒监控面板) Docker Compose 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="nezha-dashboard"
APP_DIR="/opt/nezha-dashboard"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
COMPOSE_CONF="$APP_DIR/data/config.yaml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取哪吒面板容器状态
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取宿主机映射出来的真实 Web 访问端口
        web_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8008/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$web_port" ]] && web_port="未映射"
    else
        web_port="N/A"
    fi
}

# 选项 1：部署核心逻辑
install_dashboard() {
    check_dependencies
    mkdir -p "$APP_DIR"

    echo -e "${CYAN}====== 1. 哪吒面板 Web 端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入哪吒面板在宿主机监听的 Web 端口 [默认: 8008]: ${RESET}"
    read -r PORT
    [[ -z "$PORT" ]] && PORT="8008"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "\n${YELLOW}正在构建符合规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  dashboard:
    image: ghcr.io/nezhahq/nezha
    container_name: ${CONTAINER_NAME}
    restart: always
    ports:
      - "127.0.0.1:${PORT}:8008"
    volumes:
      - ${APP_DIR}/data:/dashboard/data
EOF

    # 提前创建好数据目录
    mkdir -p "$APP_DIR/data"
    CONFIG_FILE="$APP_DIR/data/config.yaml"

    # 如果原有的 config.yaml 已经存在，安全进行局部擦洗，绝不破坏 custom_code 和其他自定义选项
    if [ -f "$CONFIG_FILE" ]; then
        # 移除可能存在的旧 language 配置
        sed -i '/^language:/d' "$CONFIG_FILE" 2>/dev/null
        # 精准切除已有的旧 tsdb 标签块及其全部关联子项/注释（防止多次追加导致配置错位冲突）
        sed -i '/^tsdb:/,/^[a-zA-Z]/ { /^tsdb:/d; /data_path:/d; /min_free_disk_space_gb:/d; /retention_days:/d; /max_memory_mb:/d; /write_buffer_size:/d; /write_buffer_flush_interval:/d; /# 启用/d; /# 保留/d }' "$CONFIG_FILE" 2>/dev/null
    fi

    # 在原文件最末尾直接进行全参数高级 TSDB 配置追加 (已删掉残留的错行)
    echo "language: zh_CN" >> "$CONFIG_FILE"
    cat >> "$CONFIG_FILE" << 'EOF'
# 启用 TSDB 支持，保存保存更长时间的监控历史
tsdb:
  data_path: "data/tsdb"
  retention_days: 30
  min_free_disk_space_gb: 1
  max_memory_mb: 256
  write_buffer_size: 512
  write_buffer_flush_interval: 5
EOF

    # 规范化文件权限
    chmod 644 "$CONFIG_FILE"

    echo -e "\n${YELLOW}正在通过 Docker Compose 启动 哪吒监控面板...${RESET}"
    cd "$APP_DIR" && docker compose up -d

    echo -e "${YELLOW}等待服务引擎拉起 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    echo -e "${GREEN}Nezha Dashboard 面板部署完成！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}          Nezha Dashboard 面板部署成功！            ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}本地面板监听地址 : http://127.0.0.1:${PORT}${RESET}"
    echo -e "${YELLOW}监控语言环境设置 : 简体中文 (zh_CN)${RESET}"
    echo -e "${YELLOW}TSDB数据存储路径 : ${APP_DIR}/data/tsdb${RESET}"
    echo -e "${CYAN}💡 提示：该服务仅监听在 127.0.0.1，请配合 Nginx 反代提供外网 HTTPS 访问。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"

}

# 选项 2：更新服务
update_dashboard() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新版 哪吒面板 镜像...${RESET}"
    cd "$APP_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！哪吒面板已平滑重启。${RESET}"
}


# 选项 2：更新服务
update_dashboard() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新版 哪吒面板 镜像...${RESET}"
    cd "$APP_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！哪吒面板已平滑重启。${RESET}"
}

# 选项 3：卸载服务
uninstall_dashboard() {
    echo -ne "${RED}确定要卸载并停止哪吒面板服务吗？数据目录将被彻底清理！(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$APP_DIR" && docker compose down
            rm -rf "$APP_DIR"
            echo -e "${GREEN}容器已停止，相关编排配置及数据目录已彻底清理。${RESET}"
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_dashboard() { cd "$APP_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_dashboard() { cd "$APP_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_dashboard() { cd "$APP_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_dashboard() { docker logs -f --tail=100 "$CONTAINER_NAME"; }

# 选项 8：查看当前详细状态
show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态     : $status"
    echo -e "${YELLOW}宿主机映射端口   : ${web_port}${RESET}"
    echo -e "${YELLOW}数据挂载根目录   : ${APP_DIR}/data${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 选项 9：完全同步 1Panel 终极修复方案的自动化 Nginx 反代配置
setup_host_nginx() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}错误: 请先执行选项 1 部署基础服务以确定本地映射端口！${RESET}"
        return
    fi

    local current_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8008/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
    [[ -z "$current_port" ]] && current_port="8008"

    # 清除残留键盘输入缓冲区，彻底封死粘贴时秒回车的 Bug
    read -t 1 -n 10000 discard 2>/dev/null

    echo -e "${CYAN}====== 宿主机独立 Nginx 自动化配置 ======${RESET}"
    echo -ne "${YELLOW}请输入您的反代域名 [默认: nezha.eu.org]: ${RESET}"
    read -r custom_domain
    [[ -z "$custom_domain" ]] && custom_domain="nezha.eu.org"

    local default_cert_path="/etc/letsencrypt/live/${custom_domain}/fullchain.pem"
    local default_key_path="/etc/letsencrypt/live/${custom_domain}/privkey.pem"

    echo -e "\n${CYAN}====== 域名证书自定义路径配置 ======${RESET}"
    echo -e "${YELLOW}请输入证书 (fullchain.pem) 的宿主机绝对路径${RESET}"
    echo -ne "[默认: ${CYAN}${default_cert_path}${RESET}]: "
    read -t 1 -n 10000 discard 2>/dev/null
    read -r cert_path
    [[ -z "$cert_path" ]] && cert_path="$default_cert_path"

    echo -e "${YELLOW}请输入私钥 (privkey.pem) 的宿主机绝对路径${RESET}"
    echo -ne "[默认: ${CYAN}${default_key_path}${RESET}]: "
    read -t 1 -n 10000 discard 2>/dev/null
    read -r key_path
    [[ -z "$key_path" ]] && key_path="$default_key_path"

    local nginx_avail_file="/etc/nginx/sites-available/${custom_domain}"
    local nginx_enabled_file="/etc/nginx/sites-enabled/${custom_domain}"

    if [ ! -d "/etc/nginx/sites-available" ]; then
        echo -e "${RED}错误: 未在本机检测到 /etc/nginx/sites-available 目录！${RESET}"
        return
    fi

    if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
        echo -e "\n${RED}警告: 宿主机未检测到指定的证书或私钥文件！${RESET}"
        echo -ne "${YELLOW}是否强制继续生成 Nginx 站点配置？(y/n): ${RESET}"
        read -t 1 -n 10000 discard 2>/dev/null
        read -r force_confirm
        if [[ "$force_confirm" != "y" && "$force_confirm" != "Y" ]]; then
            return
        fi
    fi

    echo -e "\n${YELLOW}正在准备写入 1Panel 方案级高阶反代到 Nginx 配置文件: ${CYAN}${nginx_avail_file}${RESET}"
    
    local tmp_file=$(mktemp)
    
    # 【核心修正】完全依照 http/server 外层解耦结构，注入 real_ip_header 与 map 关系流
    cat << EOF > "$tmp_file"
# =================================================================
# Nezha Dashboard (1Panel 解耦架构方案) - 本机 Nginx 自动化配置
# =================================================================

# 1. 外层全局解耦控制块 (定义真实 IP 变量)
map \$http_cf_connecting_ip \$real_ip {
    ""      \$remote_addr;
    default \$http_cf_connecting_ip;
}
 
# 允许请求头部包含下划线 (极其关键，否则 nz_realip 会被直接滤除丢弃)
underscores_in_headers on;

# 设置真实 IP 头部映射
real_ip_header nz-realip;
 
# 定义上游高可用负载组 (供 gRPC 路由无缝引用)
upstream dashboard {
    keepalive 512;
    server 127.0.0.1:${current_port};
}

# 2. 基础 80 端口强转 https 块
server {
    listen 80;
    listen [::]:80;
    server_name ${custom_domain};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# 3. 核心 443 安全及反向代理分流块
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    
    server_name ${custom_domain};

    # 证书路径
    ssl_certificate ${cert_path};
    ssl_certificate_key ${key_path};
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    client_max_body_size 20M;

    # ⚙️ A 块：Web 页面基础反代流
    location ^~ / {
        proxy_pass http://127.0.0.1:${current_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header REMOTE-HOST \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header nz-realip \$real_ip;  # 注入动态确定的真实 IP 变量
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 1800s;
        proxy_send_timeout 1800s;
        proxy_buffer_size 128k;
        proxy_buffers 4 128k;
        proxy_busy_buffers_size 256k;
        proxy_max_temp_file_size 0;
        add_header X-Cache \$upstream_cache_status;
        add_header Cache-Control no-cache;
        proxy_ssl_server_name on;
        add_header Strict-Transport-Security "max-age=31536000";
    }
 
    # ⚙️ B 块：gRPC 服务安全路由 (CF 小黄云回源关键点)
    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$real_ip;  # 注入动态确定的真实 IP 变量
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_buffer_size 4m;
        grpc_pass grpc://dashboard;        # 完美呼应上游独立集群
    }
 
    # ⚙️ C 块：WebSocket 精准长连接服务
    location ~* ^/api/v1/ws/(server|terminal|file)(.*)\$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$real_ip;  # 注入动态确定的真实 IP 变量
        proxy_set_header Origin https://\$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 1800s;
        proxy_send_timeout 1800s;
        proxy_pass http://127.0.0.1:${current_port};
    }
}
EOF

    sudo mv "$tmp_file" "$nginx_avail_file"
    sudo chmod 644 "$nginx_avail_file"
    sudo ln -sf "$nginx_avail_file" "$nginx_enabled_file"

    echo -e "${YELLOW}正在测试本机 Nginx 配置语法...${RESET}"
    if sudo nginx -t &>/dev/null; then
        sudo nginx -s reload
        echo -e "${GREEN}====================================================${RESET}"
        echo -e "${GREEN}          Nginx 反代配置并平滑重载成功！   ${RESET}"
        echo -e "${GREEN}====================================================${RESET}"
        echo -e "${YELLOW}外网入口: https://${custom_domain}${RESET}"
        echo -e "${CYAN}💡 提醒:${RESET} 请确保 Cloudflare 后台 [Network] 中的 [gRPC] 开关已保持开启。"
        echo -e "${YELLOW}前端真实 IP 请求头设置为   :  nz-realip${RESET}"
        echo -e "${YELLOW}Agent 真实 IP 请求头设置为 :  nz-realip${RESET}"
        echo -e "${GREEN}====================================================${RESET}"
    else
        echo -e "${RED}错误: Nginx 语法测试失败！真实错误详情如下：${RESET}"
        sudo nginx -t
    fi
}


# 选项 10：单独的 OAuth 2.0 绑定菜单逻辑
setup_oauth2() {
    if [ ! -f "$COMPOSE_CONF" ]; then
        echo -e "${RED}错误: 未检测到 config.yaml 配置文件，请先执行选项 1 部署面板！${RESET}"
        return
    fi

    # 清除键盘输入缓冲区，防止秒回车
    read -t 1 -n 10000 discard 2>/dev/null

    echo -e "${CYAN}====== 独立 OAuth 2.0 登录配置管理 ======${RESET}"
    echo -e "${YELLOW}1. 绑定/更新 GitHub OAuth 2.0 配置${RESET}"
    echo -e "${RED}2. 清除已有的 OAuth 2.0 配置${RESET}"
    echo -ne "${GREEN}请选择操作 (1/2): ${RESET}"
    read -r oauth_choice

    if [ "$oauth_choice" = "1" ]; then
        echo -ne "${YELLOW}请输入 GitHub Client ID: ${RESET}"
        read -r GITHUB_ID
        echo -ne "${YELLOW}请输入 GitHub Client Secret: ${RESET}"
        read -r GITHUB_SECRET

        if [[ -z "$GITHUB_ID" || -z "$GITHUB_SECRET" ]]; then
            echo -e "${RED}错误: Client ID 和 Secret 不能为空！配置未写入。${RESET}"
            return
        fi

        # 擦除旧的 oauth2 块
        sed -i '/^oauth2:/,/^[a-zA-Z]/ { /^oauth2:/d; /GitHub:/d; /client_id:/d; /client_secret:/d; /endpoint:/d; /auth_url:/d; /token_url:/d; /user_info_url:/d; /user_id_path:/d }' "$CONFIG_FILE" 2>/dev/null

        # 追加新配置
        cat >> "$COMPOSE_CONF" << EOF
oauth2:
  GitHub:
    client_id: "${GITHUB_ID}"
    client_secret: "${GITHUB_SECRET}"
    endpoint:
      auth_url: "https://github.com/login/oauth/authorize"
      token_url: "https://github.com/login/oauth/access_token"
    user_info_url: "https://api.github.com/user"
    user_id_path: "id"
EOF
        echo -e "${GREEN}GitHub OAuth 2.0 规则已成功写入配置文件！${RESET}"
        
        # 提示用户重启面板使配置生效
        echo -ne "${YELLOW}是否立即重启哪吒面板容器使配置生效？(y/n): ${RESET}"
        read -r restart_confirm
        if [[ "$restart_confirm" = "y" || "$restart_confirm" = "Y" ]]; then
            restart_dashboard
        else
            echo -e "${YELLOW}提示: 配置已保存，但需手动重启容器后才能在后台生效。${RESET}"
        fi

    elif [ "$oauth_choice" = "2" ]; then
        # 仅仅执行擦除
        sed -i '/^oauth2:/,/^[a-zA-Z]/ { /^oauth2:/d; /GitHub:/d; /client_id:/d; /client_secret:/d; /endpoint:/d; /auth_url:/d; /token_url:/d; /user_info_url:/d; /user_id_path:/d }' "$CONFIG_FILE" 2>/dev/null
        echo -e "${GREEN}已成功从 config.yaml 中移除了 OAuth 2.0 配置块。${RESET}"
        
        echo -ne "${YELLOW}是否立即重启哪吒面板容器使配置生效？(y/n): ${RESET}"
        read -r restart_confirm
        if [[ "$restart_confirm" = "y" || "$restart_confirm" = "Y" ]]; then
            restart_dashboard
        fi
    else
        echo -e "${RED}无效选项，已退出。${RESET}"
    fi
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}  ◈  Nezha Dashboard 管理面板 ◈ ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态  :${RESET} $status"
    echo -e "${GREEN}端口  :${RESET} ${YELLOW}${web_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 部署启动${RESET}"
    echo -e "${GREEN} 2. 更新容器${RESET}"
    echo -e "${GREEN} 3. 卸载容器${RESET}"
    echo -e "${GREEN} 4. 启动容器${RESET}"
    echo -e "${GREEN} 5. 停止容器${RESET}"
    echo -e "${GREEN} 6. 重启容器${RESET}"
    echo -e "${GREEN} 7. 查看日志${RESET}"
    echo -e "${GREEN} 8. 查看配置${RESET}"
    echo -e "${GREEN} 9. 反向代理${RESET}"
    echo -e "${GREEN}10. 配置OAuth2登录${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_dashboard ;;
        2) update_dashboard ;;
        3) uninstall_dashboard ;;
        4) start_dashboard ;;
        5) stop_dashboard ;;
        6) restart_dashboard ;;
        7) logs_dashboard ;;
        8) show_info ;;
        9) setup_host_nginx ;;
        10) setup_oauth2 ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
