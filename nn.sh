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

# ======================
# 获取服务器IP
# ======================
get_server_ip() {
    local ip=$(curl -s https://apiip.net/api/check?accessKey= 2>/dev/null | grep -oE '"ip":"[^"]+"' | cut -d'"' -f4)
    if [[ -z "$ip" ]]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    fi
    [[ -z "$ip" ]] && echo "your_server_ip" || echo "$ip"
}

# ======================
# 卸载逻辑
# ======================
uninstall() {
    echo -e "\n🛑 开始卸载 oci-helper ..."

    # 停止并删除容器
    echo "🔍 停止并删除相关容器..."
    for name in "oci-helper-watcher" "websockify" "oci-helper"; do
        if docker ps -a --filter "name=$name" -q | grep -q .; then
            docker rm -f "$name"
            echo "✅ 已删除容器 $name"
        else
            echo "ℹ️ 未找到容器 $name"
        fi
    done

    # 删除相关镜像
    echo "🧹 删除相关镜像..."
    docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | grep "oci-helper" | awk '{print $2}' | sort -u | xargs -r docker rmi -f
    echo "✅ 镜像清理完成"

    # 询问是否删除目录
    read -p "是否清空所有数据并删除 $TARGET_DIR 目录？(y/N): " DEL_DIR
    if [[ "$DEL_DIR" =~ ^[Yy]$ ]]; then
        rm -rf "$TARGET_DIR"
        echo "✅ 已删除目录 $TARGET_DIR"
    else
        echo "ℹ️ 保留目录 $TARGET_DIR"
    fi

    echo "😢 oci-helper 卸载完成~"
    exit 0
}

# ======================
# 部署/更新逻辑
# ======================
deploy() {
    echo -e "\n⏳ 开始准备环境并下载核心文件..."
    mkdir -p "$KEYS_DIR" && cd "$TARGET_DIR" || { echo "❌ 无法进入目录：$TARGET_DIR"; return; }

    rm -rf update_version_trigger.flag
    : > update_version_trigger.flag

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

    # 路径纠正
    COMPOSE_FILE="$TARGET_DIR/docker-compose.yml"
    if [[ -f "$COMPOSE_FILE" ]]; then
        sed -i 's|/opt/oci-helper|/app/oci-helper|g' "$COMPOSE_FILE"
    fi

    BAD_MOUNT="/usr/bin/docker:/usr/bin/docker"
    if grep -- "$BAD_MOUNT" "$COMPOSE_FILE" > /dev/null 2>&1; then
        sed -i "\|$BAD_MOUNT|d" "$COMPOSE_FILE"
    fi

    # Docker 环境检查
    if ! command -v docker &> /dev/null; then
        echo "⚠️ Docker 未安装，开始安装中..."
        curl -fsSL https://get.docker.com | sh
        systemctl start docker && systemctl enable docker
    fi

    if ! command -v docker-compose &> /dev/null; then
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi

    DOCKER_BIN=$(command -v docker)
    DOCKER_COMPOSE_BIN=$(command -v docker-compose)
    [[ "$DOCKER_BIN" != "/usr/bin/docker" && ! -d /usr/bin/docker ]] && ln -sf "$DOCKER_BIN" /usr/bin/docker
    [[ "$DOCKER_COMPOSE_BIN" != "/usr/local/bin/docker-compose" && ! -d /usr/local/bin/docker-compose ]] && ln -sf "$DOCKER_COMPOSE_BIN" /usr/local/bin/docker-compose

    # 提前给高权限防锁死
    chmod 777 "$TARGET_DIR/oci-helper.db"

    # 同步版本号
    LATEST_TAG=$(curl -s https://api.github.com/repos/Yohann0617/oci-helper/releases/latest | grep '"tag_name":' | awk -F '"' '{print $4}')
    DB_FILE="$TARGET_DIR/oci-helper.db"
    if [[ -n "$LATEST_TAG" && -f "$DB_FILE" ]]; then
        if ! command -v sqlite3 &> /dev/null; then
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                [[ "$ID" =~ ^(ubuntu|debian)$ ]] && apt update && apt install -y sqlite3 &>/dev/null
                [[ "$ID" =~ ^(centos|rhel|rocky|almalinux)$ ]] && yum install -y sqlite &>/dev/null
            fi
        fi
        if command -v sqlite3 &> /dev/null; then
            sqlite3 "$DB_FILE" "UPDATE oci_kv SET value = '$LATEST_TAG' WHERE code = 'Y106' AND type = 'Y003';" 2>/dev/null
        fi
    fi

    # 凭据配置
    APP_YML="$TARGET_DIR/application.yml"
    echo -e "\n${YELLOW}请选择账号密码设置方式：${RESET}"
    echo "1) 自动生成随机账号和密码"
    echo "2) 手动输入账号和密码"
    echo "3) 保留当前账号和密码，不作修改"
    read -p "输入选项 (1/2/3): " ACC_MODE

    if [[ "$ACC_MODE" == "1" ]]; then
        NEW_ACC="user_$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
        NEW_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)
        sed -i "s|^.*account:.*|  account: $NEW_ACC|" "$APP_YML"
        sed -i "s|^.*password:.*|  password: $NEW_PASS|" "$APP_YML"
    elif [[ "$ACC_MODE" == "2" ]]; then
        read -p "请输入账号: " NEW_ACC
        read -p "请输入密码: " NEW_PASS
        if [[ -n "$NEW_ACC" && -n "$NEW_PASS" ]]; then
            sed -i "s|^.*account:.*|  account: $NEW_ACC|" "$APP_YML"
            sed -i "s|^.*password:.*|  password: $NEW_PASS|" "$APP_YML"
        fi
    fi

    # 拉取并上载
    echo -e "\n🚀 正在拉取镜像并部署容器服务..."
    cd "$TARGET_DIR" || return
    docker-compose pull && docker-compose up -d

    # 获取部署后的账号密码用于显式通知
    FINAL_ACC=$(grep "account:" "$APP_YML" | awk '{print $2}')
    FINAL_PASS=$(grep "password:" "$APP_YML" | awk '{print $2}')
    SERVER_IP=$(get_server_ip)
    WEB_PORT=$(grep -A 2 "ports:" "$COMPOSE_FILE" | grep -oE '[0-9]+:8818' | cut -d':' -f1)
    [[ -z "$WEB_PORT" ]] && WEB_PORT="8818"

    echo -e "\n${GREEN}==================================================${RESET}"
    echo -e "${GREEN}🎉 oci-helper 容器服务部署/更新成功！${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
    echo -e "${BLUE}🌐 访问地址:${RESET} http://${SERVER_IP}:${WEB_PORT}"
    echo -e "${BLUE}👤 登录账号:${RESET} ${YELLOW}${FINAL_ACC}${RESET}"
    echo -e "${BLUE}🔑 登录密码:${RESET} ${YELLOW}${FINAL_PASS}${RESET}"
    echo -e "${GREEN}==================================================${RESET}"
}

# ======================
# 控制逻辑
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

# ======================
# 状态与配置获取
# ======================
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
    if [[ -f "$TARGET_DIR/docker-compose.yml" ]]; then
        local port_extract=$(grep -A 2 "ports:" "$TARGET_DIR/docker-compose.yml" | grep -oE '[0-9]+:8818' | cut -d':' -f1)
        [[ -n "$port_extract" ]] && webui_port="$port_extract"
    fi
}

show_config() {
    APP_YML="$TARGET_DIR/application.yml"
    if [[ -f "$APP_YML" ]]; then
        echo -e "\n${BLUE}📋 当前网页配置凭据：${RESET}"
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
    echo -e "${GREEN}    ◈  Y探长 管理面板  ◈   ${RESET}"
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
        1|2)
            deploy
            ;;
        3)
            uninstall
            ;;
        4)
            start_containers
            ;;
        5)
            stop_containers
            ;;
        6)
            restart_containers
            ;;
        7)
            echo -e "\n📋 正在追踪实时日志 (按 Ctrl+C 退出日志流)..."
            docker logs -f oci-helper
            ;;
        8)
            show_config
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "\n❌ 无效的选项，请重新选择。"
            ;;
    esac

    echo -ne "\n${YELLOW}按回车键返回主菜单...${RESET}"
    read -r
done
