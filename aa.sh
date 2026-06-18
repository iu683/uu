#!/bin/bash

clear

# 定义颜色
YELLOW='\033[33m'
GREEN='\033[32m'
RED='\033[31m'
BLUE='\033[34m'
RESET='\033[0m'

# 设置目标目录
TARGET_DIR="/opt/oci-helper"
KEYS_DIR="$TARGET_DIR/keys"

# ======================
# 卸载逻辑
# ======================
uninstall() {
    echo "🛑 开始卸载 oci-helper ..."

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
    # 创建目录并进入
    mkdir -p "$KEYS_DIR" && cd "$TARGET_DIR" || { echo "❌ 无法进入目录：$TARGET_DIR，请检查权限或路径是否正确。"; exit 1; }

    # 创建或清空版本更新触发标志文件
    rm -rf update_version_trigger.flag
    : > update_version_trigger.flag

    # 公共下载URL前缀
    BASE_URL="https://github.com/Yohann0617/oci-helper/releases/download/deploy"

    # 文件列表
    FILES=("application.yml" "oci-helper.db" "docker-compose.yml")

    # 下载文件
    echo "🔍 检查所需文件..."
    for file in "${FILES[@]}"; do
        if [[ -f "$TARGET_DIR/$file" ]]; then
            echo "✔ 文件 '$file' 已存在，跳过下载。"
        else
            echo "⬇️ 正在下载 '$file' ..."
            curl -LO "$BASE_URL/$file" || { echo "❌ 下载文件 '$file' 失败，请检查网络连接或 URL。"; exit 1; }
        fi
    done

    # 检查并移除 /usr/bin/docker 挂载
    COMPOSE_FILE="$TARGET_DIR/docker-compose.yml"
    BAD_MOUNT="/usr/bin/docker:/usr/bin/docker"

    if grep -- "$BAD_MOUNT" "$COMPOSE_FILE" > /dev/null 2>&1; then
        echo "⚠️ 检测到 docker-compose.yml 中存在不兼容挂载 '$BAD_MOUNT'，正在移除..."
        sed -i "\|$BAD_MOUNT|d" "$COMPOSE_FILE" || {
            echo "❌ 移除挂载失败，请手动检查 docker-compose.yml 文件。"
            exit 1
        }
        echo "✅ 不兼容挂载已移除。"
    fi

    # 检查并安装 Docker
    echo "🔍 检查 Docker 安装状态..."
    if ! command -v docker &> /dev/null; then
        echo "⚠️ Docker 未安装，开始安装中..."
        curl -fsSL https://get.docker.com | sh || {
            echo "❌ Docker 安装失败，请检查网络或手动安装。"
            exit 1
        }
        
        systemctl start docker
        systemctl enable docker
        echo "✅ Docker 安装并启动完成。"
    else
        echo "✅ Docker 已安装。"
    fi

    # 检查并安装 docker-compose
    echo "🔍 检查 docker-compose 安装状态..."
    if ! command -v docker-compose &> /dev/null; then
        echo "⚠️ docker-compose 未安装，开始下载安装..."
        if ! curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose; then
            echo "❌ 下载 docker-compose 失败，请检查网络或手动安装。"
            exit 1
        fi
        chmod +x /usr/local/bin/docker-compose
        echo "✅ docker-compose 安装完成。"
    else
        echo "✅ docker-compose 已安装。"
    fi

    # 获取 docker 和 docker-compose 实际路径
    DOCKER_BIN=$(command -v docker)
    DOCKER_COMPOSE_BIN=$(command -v docker-compose)

    if [[ -z "$DOCKER_BIN" || -z "$DOCKER_COMPOSE_BIN" ]]; then
        echo "❌ docker 或 docker-compose 未正确安装，请确认安装状态。"
        exit 1
    fi

    # 软链接到标准路径（如果不存在）
    if [[ -d /usr/bin/docker ]]; then
        echo "❌ 目标路径 /usr/bin/docker 是一个目录，无法创建软链接。请手动处理。"
        exit 1
    fi

    if [[ "$DOCKER_BIN" != "/usr/bin/docker" ]]; then
        echo "🔗 创建 /usr/bin/docker 的软链接..."
        ln -sf "$DOCKER_BIN" /usr/bin/docker
    fi

    if [[ -d /usr/local/bin/docker-compose ]]; then
        echo "❌ 目标路径 /usr/local/bin/docker-compose 是一个目录，无法创建软链接。请手动处理。"
        exit 1
    fi

    if [[ "$DOCKER_COMPOSE_BIN" != "/usr/local/bin/docker-compose" ]]; then
        echo "🔗 创建 /usr/local/bin/docker-compose 的软链接..."
        ln -sf "$DOCKER_COMPOSE_BIN" /usr/local/bin/docker-compose
    fi

    # 删除旧的容器和镜像
    clean_container() {
        local name="$1"
        local image_prefix="$2"

        echo "🔍 检查名为 '$name' 的运行中容器..."
        if docker ps --filter "name=$name" -q | grep -q .; then
            echo "🛑 发现运行中的容器 '$name'，正在删除..."
            docker rm -f "$name" || { echo "❌ 停止容器 '$name' 失败"; exit 1; }
            echo "🧹 删除 '$name' 相关旧镜像..."
            docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | grep "$image_prefix" | awk '{print $2}' | sort -u | xargs -r docker rmi -f || { echo "❌ 删除镜像失败"; exit 1; }
            echo "✅ 容器和镜像已清理。"
        else
            echo "ℹ️ 没有运行中的容器 '$name'。"
        fi
    }

    clean_container "oci-helper-watcher" "oci-helper-watcher"
    clean_container "websockify" "oci-helper-websockify"
    clean_container "oci-helper" "oci-helper"

    # 检查并安装 SQLite
    echo "🔍 检查 SQLite 安装状态..."
    if ! command -v sqlite3 &> /dev/null; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            echo "🖥️ 检测到系统: $ID"
            
            case "$ID" in
                ubuntu|debian|kali|linuxmint|pop|neon)
                    apt update && apt install -y sqlite3 ;;
                centos|rhel|rocky|almalinux|ol|ancient)
                    [ -x "$(command -v dnf)" ] && dnf install -y sqlite || yum install -y sqlite ;;
                fedora|korora)
                    dnf install -y sqlite ;;
                alpine)
                    apk add --no-cache sqlite ;;
                arch|manjaro|endeavouros)
                    pacman -Sy --noconfirm sqlite ;;
                opensuse*|sled|leap|tumbleweed)
                    zypper install -y sqlite3 ;;
                gentoo)
                    emerge --ask n dev-db/sqlite ;;
                slackware)
                    slackpkg install sqlite ;;
                void)
                    xbps-install -S sqlite ;;
                nixos)
                    echo "ℹ️ NixOS 请使用 nix-env -i sqlite" ;;
                *)
                    case "$ID_LIKE" in
                        *debian*)
                            apt update && apt install -y sqlite3 ;;
                        *rhel*|*fedora*)
                            [ -x "$(command -v dnf)" ] && dnf install -y sqlite || yum install -y sqlite ;;
                        *)
                            echo "❌ 未直接支持的发行版: $ID"
                            exit 1
                            ;;
                    esac
                    ;;
            esac
        else
            echo "❌ 无法识别系统，请手动安装SQLite"
            exit 1
        fi
    fi

    # 获取 GitHub 项目最新 release tag
    echo "🌐 获取最新发布版本号..."
    LATEST_TAG=$(curl -s https://api.github.com/repos/Yohann0617/oci-helper/releases/latest | grep '"tag_name":' | awk -F '"' '{print $4}')
    if [[ -z "$LATEST_TAG" ]]; then
        echo "❌ 无法获取最新的发布版本号，请检查网络连接。"
        exit 1
    fi
    echo "🏷 最新发布版本：$LATEST_TAG"

    # 更新 SQLite 数据库
    echo "🗃 更新本地数据库版本号记录..."
    DB_FILE="$TARGET_DIR/oci-helper.db"
    if [[ -f "$DB_FILE" ]]; then
        RECORD_EXISTS=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM oci_kv WHERE code = 'Y106' AND type = 'Y003';")
        if [[ "$RECORD_EXISTS" -gt 0 ]]; then
            sqlite3 "$DB_FILE" "UPDATE oci_kv SET value = '$LATEST_TAG' WHERE code = 'Y106' AND type = 'Y003';"
            echo "✅ 数据库版本号更新成功。"
        fi
    else
        echo "❌ 数据库文件 $DB_FILE 不存在，无法更新版本号。"
        exit 1
    fi

    # 设置账号和密码
    APP_YML="$TARGET_DIR/application.yml"
    echo -e "${RESET}"
    echo -e "${YELLOW}请选择账号密码设置方式：${RESET}"
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
        if [[ -z "$NEW_ACC" || -z "$NEW_PASS" ]]; then
            echo "❌ 账号和密码不能为空"
            exit 1
        fi
        sed -i "s|^.*account:.*|  account: $NEW_ACC|" "$APP_YML"
        sed -i "s|^.*password:.*|  password: $NEW_PASS|" "$APP_YML"
    fi

    # 启动服务
    echo "🚀 启动 docker-compose 服务..."
    cd "$TARGET_DIR" || exit 1
    docker-compose pull && docker-compose up -d
    echo "🎉 oci-helper 部署/更新完成！"
}

# ======================
# 控制逻辑 (启动/停止/重启)
# ======================
start_containers() {
    echo "▶️ 正在启动容器..."
    docker start oci-helper-watcher oci-helper websockify && echo "✅ 容器已成功启动"
}

stop_containers() {
    echo "⏹️ 正在停止容器..."
    docker stop oci-helper-watcher oci-helper websockify && echo "✅ 容器已停用"
}

restart_containers() {
    echo "🔄 正在重启容器..."
    docker restart oci-helper-watcher oci-helper websockify && echo "✅ 容器已成功重启"
}

# ======================
# 状态与配置获取
# ======================
get_status_info() {
    # 1. 检查容器整体状态
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

    # 2. 尝试从 compose 提取端口，默认为 8818
    webui_port="8818"
    if [[ -f "$TARGET_DIR/docker-compose.yml" ]]; then
        local port_extract=$(grep -A 2 "ports:" "$TARGET_DIR/docker-compose.yml" | grep -oE '[0-9]+:8818' | cut -d':' -f1)
        [[ -n "$port_extract" ]] && webui_port="$port_extract"
    fi
}

show_config() {
    APP_YML="$TARGET_DIR/application.yml"
    if [[ -f "$APP_YML" ]]; then
        echo -e "${BLUE}📋 当前网页配置凭据：${RESET}"
        grep -E "account:|password:" "$APP_YML"
    else
        echo "❌ 未找到配置文件 $APP_YML"
    fi
}

# ======================
# 新菜单入口交互
# ======================
clear
get_status_info

echo -e "${GREEN}================================${RESET}"
echo -e "${GREEN}    ◈   Y 探长 管理面板   ◈     ${RESET}"
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
        docker logs -f oci-helper
        ;;
    8)
        show_config
        ;;
    0)
        exit 0
        ;;
    *)
        echo "❌ 无效的选项"
        exit 1
        ;;
esac
