#!/bin/bash
# =================================================================
# PandaWiki 知识库 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="panda-wiki-server" # 官方 compose 中的核心服务名或容器名关键字
BASE_DIR="/data/pandawiki"
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


# 动态获取容器状态、映射端口和数据目录
get_status_info() {
    # 1. 检查核心服务状态 (通过过滤目录下的 compose 状态或容器名)
    if [ -f "$COMPOSE_FILE" ] && [ "$(cd "$BASE_DIR" && docker compose ps -q 2>/dev/null)" ]; then
        status="${YELLOW}运行中${RESET}"
    else
        # 兜底通过 .env 是否存在来判断是否部署
        if [ -f "$BASE_DIR/.env" ]; then
            status="${RED}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
    fi

    # 2. 从 .env 提取管理后台端口
    if [ -f "$BASE_DIR/.env" ]; then
        webui_port=$(grep "ADMIN_PORT=" "$BASE_DIR/.env" | cut -d'=' -f2)
        [[ -z "$webui_port" ]] && webui_port="2443"
    else
        webui_port="N/A"
    fi
}

# 随机生成纯英数密码（满足长度 > 8位且无特殊字符要求）
generate_middleware_password() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

# 部署 PandaWiki
install_pandawiki() {
    check_dependencies
    
    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 PandaWiki 安装绝对路径 [默认: /data/pandawiki]: ${RESET}"
    read -r custom_dir
    [[ -z "$custom_dir" ]] && custom_dir="/data/pandawiki"
    BASE_DIR="$custom_dir"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

    echo -ne "${YELLOW}请输入 PandaWiki 管理后台访问端口 [默认: 2443]: ${RESET}"
    read -r admin_port
    [[ -z "$admin_port" ]] && admin_port="2443"
    if ! [[ "$admin_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 交互输入管理员密码并进行校验
    while true; do
        echo -ne "${YELLOW}请设置您的 PandaWiki 管理员登录密码 (长度需大于8位): ${RESET}"
        read -r admin_pwd
        if [ ${#admin_pwd} -lt 9 ]; then
            echo -e "${RED}错误: 密码长度必须大于 8 位，请重新输入！${RESET}"
        else
            break
        fi
    done

    # 1. 创建目录并下载官方 compose 文件
    mkdir -p "$BASE_DIR"
    echo -e "${YELLOW}正在从官方源下载最新 Docker Compose 编排文件...${RESET}"
    if ! wget -qO "$COMPOSE_FILE" "https://release.baizhi.cloud/panda-wiki/docker-compose.yml"; then
        echo -e "${RED}错误: 下载编排文件失败，请检查网络或官方链接是否有效！${RESET}"
        return
    fi

    # 2. 自动为各种内部中间件生成不含特殊字符的高强度随机密码
    echo -e "${YELLOW}正在为您自动生成高强度中间件安全密码...${RESET}"
    local pg_pwd=$(generate_middleware_password)
    local nats_pwd=$(generate_middleware_password)
    local jwt_sec=$(generate_middleware_password)
    local s3_sec=$(generate_middleware_password)
    local qdrant_key=$(generate_middleware_password)
    local redis_pwd=$(generate_middleware_password)

    # 3. 写入环境配置文件 .env
    echo -e "${YELLOW}正在写入环境变量配置文件 (.env)...${RESET}"
    cat <<EOF > "$BASE_DIR/.env"
# 时区
TIMEZONE=Asia/Shanghai
# 容器网段
SUBNET_PREFIX=169.254.15
# 中间件密码（自动生成）
POSTGRES_PASSWORD=${pg_pwd}
NATS_PASSWORD=${nats_pwd}
JWT_SECRET=${jwt_sec}
S3_SECRET_KEY=${s3_sec}
QDRANT_API_KEY=${qdrant_key}
REDIS_PASSWORD=${redis_pwd}
# 管理后台登录密码
ADMIN_PASSWORD=${admin_pwd}
# 管理后台访问端口
ADMIN_PORT=${admin_port}
EOF

    chmod -R 777 "$BASE_DIR"

    # 4. 启动集群
    echo -e "${YELLOW}正在通过 Docker Compose 启动 PandaWiki 服务集群 (首次拉取多镜像需要一点时间)...${RESET}"
    cd "$BASE_DIR" && docker compose up -d

    echo -e "${YELLOW}等待服务群初始化 (约8秒)...${RESET}"
    sleep 8

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      PandaWiki 部署成功！      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}管理后台地址   : http://${DETECT_IP}:${admin_port}${RESET}"
    echo -e "${YELLOW}管理员账号     : admin (或参考官方首次登录引导)${RESET}"
    echo -e "${YELLOW}管理员密码     : ${admin_pwd}${RESET}"
    echo -e "${YELLOW}安装绝对路径   : $BASE_DIR${RESET}"
    echo -e "${CYAN}提示: 内部中间件密码已自动配齐，如需查看可在 $BASE_DIR/.env 中查阅。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 PandaWiki 镜像集群
update_pandawiki() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 PandaWiki 组件最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！所有服务已处于最新状态。${RESET}"
}

# 卸载 PandaWiki
uninstall_pandawiki() {
    echo -ne "${RED}确定要完全卸载并删除 PandaWiki 吗？数据将不可恢复！(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}所有相关服务容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地所有知识库、数据库和配置文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            echo -e "${RED}未找到编排文件，请手动通过 Docker 命令清理容器。${RESET}"
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_pandawiki() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务集群已启动${RESET}"; }
stop_pandawiki() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务集群已停止${RESET}"; }
restart_pandawiki() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务集群已重启${RESET}"; }
logs_pandawiki() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}集群状态       : $status"
    echo -e "${YELLOW}管理后台地址   : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}核心数据路径   : ${BASE_DIR}${RESET}"
    if [ -f "$BASE_DIR/.env" ]; then
        local pwd_info=$(grep "ADMIN_PASSWORD=" "$BASE_DIR/.env" | cut -d'=' -f2)
        echo -e "${YELLOW}当前后台密码   : ${pwd_info}${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  PandaWiki  管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动集群${RESET}"
    echo -e "${GREEN}5. 停止集群${RESET}"
    echo -e "${GREEN}6. 重启集群${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_pandawiki ;;
        2) update_pandawiki ;;
        3) uninstall_pandawiki ;;
        4) start_pandawiki ;;
        5) stop_pandawiki ;;
        6) restart_pandawiki ;;
        7) logs_pandawiki ;;
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
