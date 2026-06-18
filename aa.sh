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
    echo -e "${GREEN}🎉 oci-helper 服务运行/更新成功！${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${YELLOW}🌐 访问地址:${RESET} http://${ip}:${port}"
    echo -e "${YELLOW}👤 登录账号:${RESET} ${YELLOW}${acc:-未知}${RESET}"
    echo -e "${YELLOW}🔑 登录密码:${RESET} ${YELLOW}${pass:-未知}${RESET}"
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
    echo -e "\n🔄 正在执行更新 (docker-compose pull && up -d)..."
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
        0)  exit 0 ;;
        *)  echo -e "\n❌ 无效的选项，请重新选择。" ;;
    esac

    echo -ne "\n${YELLOW}按回车键返回主菜单...${RESET}"
    read -r
done
