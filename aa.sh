#!/bin/bash

# 定义颜色
YELLOW='\033[33m'
GREEN='\033[32m'
RED='\033[31m'
BLUE='\033[34m'
RESET='\033[0m'

# 设置目标目录
TARGET_DIR="/app/oci-helper"
KEYS_DIR="$TARGET_DIR/keys"
COMPOSE_FILE="$TARGET_DIR/docker-compose.yml"
APP_YML="$TARGET_DIR/application.yml"

# ======================
# 获取服务器IP与展示面板信息
# ======================
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


show_success_info() {
    local acc=$(grep "account:" "$APP_YML" 2>/dev/null | awk '{print $2}')
    local pass=$(grep "password:" "$APP_YML" 2>/dev/null | awk '{print $2}')
    local ip=$(get_public_ip)
    local port=$(grep -A 2 "ports:" "$COMPOSE_FILE" 2>/dev/null | grep -oE '[0-9]+:8818' | cut -d':' -f1)
    [[ -z "$port" ]] && port="8818"

    echo -e "\n${GREEN}==================================================${RESET}"
    echo -e "${GREEN}🎉 oci-helper 服务运行成功！${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${YELLOW}🌐 访问地址:${RESET} ${YELLOW}http://${ip}:${port}${RESET}"
    echo -e "${YELLOW}👤 登录账号:${RESET} ${YELLOW}${acc:-未知}${RESET}"
    echo -e "${YELLOW}🔑 登录密码:${RESET} ${YELLOW}${pass:-未知}${RESET}"
    echo -e "${YELLOW}📂 安装目录: $TARGET_DIR${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
}

# ======================
# 1. 部署启动逻辑 (初次安装/重置)
# ======================
deploy() {
    echo -e "\n⏳ 开始准备环境并下载核心文件..."
    mkdir -p "$KEYS_DIR" && cd "$TARGET_DIR" || { echo "❌ 无法进入目录：$TARGET_DIR"; return; }

    rm -rf update_version_trigger.flag && : > update_version_trigger.flag

    BASE_URL="https://github.com/Yohann0617/oci-helper/releases/download/deploy"
    FILES=("application.yml" "oci-helper.db" "docker-compose.yml")

    for file in "${FILES[@]}"; do
        if [[ -f "$TARGET_DIR/$file" ]]; then
            echo "✔ 文件 '$file' 已存在，跳过下载。"
        else
            echo "⬇️ 正在下载 '$file' ..."
            curl -LO "$BASE_URL/$file" || { echo "❌ 下载文件 '$file' 失败。"; return; }
        fi
    done

    # 路径纠正与移除不兼容挂载
    [[ -f "$COMPOSE_FILE" ]] && sed -i 's|/opt/oci-helper|/app/oci-helper|g' "$COMPOSE_FILE"
    sed -i "\|/usr/bin/docker:/usr/bin/docker|d" "$COMPOSE_FILE" 2>/dev/null

    # 环境依赖检查
    if ! command -v docker &> /dev/null; then
        echo "Docker 未安装，开始安装中..."
        curl -fsSL https://get.docker.com | sh && systemctl start docker && systemctl enable docker
    fi
    if ! command -v docker-compose &> /dev/null; then
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi

    chmod 777 "$TARGET_DIR/oci-helper.db"

    # 凭据配置
    echo -e "\n${YELLOW}请选择账号密码设置方式：${RESET}"
    echo "1) 自动生成随机账号和密码"
    echo "2) 手动输入账号和密码"
    read -p "输入选项: " ACC_MODE

    if [[ "$ACC_MODE" == "1" ]]; then
        local new_acc="user_$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
        local new_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)
        sed -i "s|^.*account:.*|  account: $new_acc|" "$APP_YML"
        sed -i "s|^.*password:.*|  password: $new_pass|" "$APP_YML"
    elif [[ "$ACC_MODE" == "2" ]]; then
        read -p "请输入账号: " new_acc
        read -p "请输入密码: " new_pass
        if [[ -n "$new_acc" && -n "$new_pass" ]]; then
            sed -i "s|^.*account:.*|  account: $new_acc|" "$APP_YML"
            sed -i "s|^.*password:.*|  password: $new_pass|" "$APP_YML"
        fi
    fi

    echo -e "\n🚀 正在拉取镜像并部署容器服务..."
    docker-compose pull && docker-compose up -d
    show_success_info
}

# ======================
# 2. 纯净更新逻辑
# ======================
update_containers() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "\n❌ 未检测到 $COMPOSE_FILE ，请先选择选项 1 进行部署启动。"
        return
    fi
    echo -e "\n🔄 正在执行更新..."
    cd "$TARGET_DIR" || return
    
    # 纯净的两行更新核心命令
    docker-compose pull && docker-compose up -d
    
    show_success_info
}

# ======================
# 3. 卸载逻辑
# ======================
uninstall() {
    echo -e "开始卸载 oci-helper ..."
    cd "$TARGET_DIR" 2>/dev/null && docker-compose down 2>/dev/null
    
    for name in "oci-helper-watcher" "websockify" "oci-helper"; do
        docker rm -f "$name" &>/dev/null
    done

    docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | grep "oci-helper" | awk '{print $2}' | sort -u | xargs -r docker rmi -f &>/dev/null
    echo "✅ 容器与镜像清理完成"

    read -p "是否清空所有数据并删除 $TARGET_DIR 目录？(y/N): " DEL_DIR
    if [[ "$DEL_DIR" =~ ^[Yy]$ ]]; then
        rm -rf "$TARGET_DIR"
        echo "✅ 已删除目录 $TARGET_DIR"
    fi
    echo "oci-helper 卸载完成~"
}

# ======================
# 其它控制命令
# ======================
start_containers() {
    echo -e "\n▶️ 正在启动容器..."
    docker start oci-helper-watcher oci-helper websockify && echo "✅ 容器已成功启动"
}

stop_containers() {
    echo -e "\n⏹️ 正在停止容器..."
    docker stop oci-helper-watcher oci-helper websockify && echo "✅ 容器已停用"
}

restart_containers() {
    echo -e "\n🔄 正在重启容器..."
    docker restart oci-helper-watcher oci-helper websockify && echo "✅ 容器已成功重启"
}

get_status_info() {
    local active_count=0
    for name in "oci-helper-watcher" "oci-helper" "websockify"; do
        if [[ $(docker ps --filter "name=^/${name}$" --format "{{.Status}}") == Up* ]]; then
            ((active_count++))
        fi
    done

    if [[ $active_count -eq 3 ]]; then
        status="${GREEN}运行中 (3/3)${RESET}"
    elif [[ $active_count -gt 0 ]]; then
        status="${YELLOW}部分运行 ($active_count/3)${RESET}"
    else
        status="${RED}已停止${RESET}"
    fi

    webui_port="8818"
    if [[ -f "$COMPOSE_FILE" ]]; then
        local port_extract=$(grep -A 2 "ports:" "$COMPOSE_FILE" | grep -oE '[0-9]+:8818' | cut -d':' -f1)
        [[ -n "$port_extract" ]] && webui_port="$port_extract"
    fi
}

show_config() {
    if [[ -f "$APP_YML" ]]; then
        echo -e "\n${YELLOW}📋 当前网页配置凭据：${RESET}"
        grep -E "account:|password:" "$APP_YML"
    else
        echo -e "\n❌ 未找到配置文件 $APP_YML"
    fi
}

# ======================
# 9. Nginx 自动提取双端口并覆盖配置（带二次确认提示）
# ======================
setup_nginx_proxy() {
    if ! command -v nginx &> /dev/null; then
        echo -e "\n❌ 未检测到系统中安装了 Nginx，请先安装 Nginx！"
        return
    fi

    echo -e "\n${YELLOW}================================${RESET}"
    echo -e "${YELLOW}  自动提取双端口 & 覆盖 Nginx 配置  ${RESET}"
    echo -e "${YELLOW}================================${RESET}"
    
    # 1. 引导输入域名
    read -p "请输入你要覆盖的域名 (例如: ocie.012512.xyz): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo "❌ 域名不能为空！"
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

    # 4. 自动从 docker-compose.yml 提取主面板与 VNC 的实际外部映射端口
    local oci_port="8818" # 主面板默认兜底端口
    local vnc_port="6080" # VNC默认兜底端口
    
    if [[ -f "$COMPOSE_FILE" ]]; then
        # 提取主面板映射端口（通常对应容器内的 8818 或 5285）
        local oci_extract=$(grep -A 2 "ports:" "$COMPOSE_FILE" 2>/dev/null | grep -oE '[0-9]+:8818|[0-9]+:5285' | cut -d':' -f1 | head -n 1)
        [[ -n "$oci_extract" ]] && oci_port="$oci_extract"

        # 提取 VNC 映射端口（通常对应容器内的 6080）
        local vnc_extract=$(grep -A 2 "ports:" "$COMPOSE_FILE" 2>/dev/null | grep -oE '[0-9]+:6080' | cut -d':' -f1 | head -n 1)
        [[ -n "$vnc_extract" ]] && vnc_port="$vnc_extract"
    fi
    
    echo -e "ℹ️ 自动提取主面板映射端口为: ${GREEN}${oci_port}${RESET}"
    echo -e "ℹ️ 自动提取 VNC 桌面映射端口为: ${GREEN}${vnc_port}${RESET}"

    echo -e "⏳ 正在覆盖写入配置文件..."

    # 5. 写入配置模板（两个 proxy_pass 全部采用动态提取的端口变量）
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
    # 1. 独立代理 VNC 远程桌面组件（自动提取端口）
    # ========================================================
    location /myvnc/ {
        proxy_pass http://127.0.0.1:${vnc_port}/; # 动态提取的 VNC 宿主机端口
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        
        # 延长 VNC 桌面连接超时时间（3小时），防止桌面频繁断开
        send_timeout 10800;
        proxy_read_timeout 10800;
        proxy_send_timeout 10800;
    }

    # ========================================================
    # 2. 默认代理主程序面板（自动提取端口）
    # ========================================================
    location / {
        client_max_body_size 200M;
        add_header Cache-Control no-cache; # 禁用浏览器缓存，确保面板状态实时刷新

        proxy_pass http://127.0.0.1:${oci_port}; # 动态提取的主面板宿主机端口
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # 保持 WebSocket 握手配置，用于实时查看容器日志流
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade"; 

        # 延长主面板连接超时时间（3小时），防止看实时日志时被 Nginx 掐断
        send_timeout 10800;
        proxy_read_timeout 10800;
        proxy_send_timeout 10800;
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

# ======================
# 主循环体面板
# ======================
while true; do
    clear
    get_status_info

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈   Y探长 管理面板   ◈    ${RESET}"
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
        1)  deploy ;;
        2)  update_containers ;;
        3)  uninstall ;;
        4)  start_containers ;;
        5)  stop_containers ;;
        6)  restart_containers ;;
        7)
            echo -e "\n📋 正在追踪实时日志 (按 Ctrl+C 退出日志流)..."
            docker logs -f oci-helper
            ;;
        8)  show_config ;;
        9)  setup_nginx_proxy ;;
        0)  exit 0 ;;
        *)  echo -e "\n❌ 无效的选项，请重新选择。" ;;
    esac

    echo -ne "\n${YELLOW}按回车键返回主菜单...${RESET}"
    read -r
done
