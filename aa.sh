#!/bin/bash
# =================================================================
# 长亭雷池 WAF (SafeLine) Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="safeline-mgt"
BASE_DIR="/data/safeline"
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
    # 1. 检查核心管理容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从环境或容器中提取控制台端口
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 提取控制台管理端口（雷池 mgt 内部默认是 9443）
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9443/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="9443"
    else
        webui_port="N/A"
    fi
}

# 随机生成纯英数密码（雷池 WAF 数据库要求勿使用特殊字符）
generate_password() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

# 部署长亭雷池
install_safeline() {
    check_dependencies
    
    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入雷池安装绝对路径 [默认: /data/safeline]: ${RESET}"
    read -r custom_dir
    [[ -z "$custom_dir" ]] && custom_dir="/data/safeline"
    BASE_DIR="$custom_dir"
    COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

    echo -ne "${YELLOW}请输入雷池控制台 (MGT) 访问端口 [默认: 9443]: ${RESET}"
    read -r mgt_port
    [[ -z "$mgt_port" ]] && mgt_port="9443"

    echo -ne "${YELLOW}是否使用 LTS (长期支持) 版本通道？(y/n) [默认: n]: ${RESET}"
    read -r is_lts
    local release_channel=""
    [[ "$is_lts" == "y" || "$is_lts" == "Y" ]] && release_channel="-lts"

    echo -ne "${YELLOW}您的服务器在 [1. 中国大陆] 还是 [2. 海外/中国香港]？输入数字 [默认: 1]: ${RESET}"
    read -r geo_choice
    local img_prefix="swr.cn-east-3.myhuaweicloud.com/chaitin-safeline"
    [[ "$geo_choice" == "2" ]] && img_prefix="chaitin"

    # 自动识别系统架构 (x86_64 vs arm64)
    local arch_suffix=""
    local sys_arch=$(uname -m)
    if [[ "$sys_arch" == "arm*" || "$sys_arch" == "aarch64" ]]; then
        arch_suffix="-arm"
        echo -e "${YELLOW}检测到当前服务器为 ARM 架构，已自动启用架构适配。${RESET}"
    fi

    # 1. 创建目录并下载编排脚本
    mkdir -p "$BASE_DIR"
    echo -e "${YELLOW}正在从官方源下载最新 Compose 编排脚本...${RESET}"
    if ! wget -qO "$COMPOSE_FILE" "https://waf-ce.chaitin.cn/release/latest/compose.yaml"; then
        echo -e "${RED}错误: 下载编排脚本失败，请检查网络或链接是否有效！${RESET}"
        return
    fi

    # 2. 生成随机高强度数据库密码
    local pg_pwd=$(generate_password)

    # 3. 写入 .env 配置文件
    echo -e "${YELLOW}正在写入环境变量配置文件 (.env)...${RESET}"
    cat <<EOF > "$BASE_DIR/.env"
SAFELINE_DIR=${BASE_DIR}
IMAGE_TAG=latest
MGT_PORT=${mgt_port}
POSTGRES_PASSWORD=${pg_pwd}
SUBNET_PREFIX=172.22.222
IMAGE_PREFIX=${img_prefix}
ARCH_SUFFIX=${arch_suffix}
RELEASE=${release_channel}
REGION=
MGT_PROXY=0
EOF

    chmod -R 777 "$BASE_DIR"

    # 4. 启动服务
    echo -e "${YELLOW}正在启动雷池服务集群 (首次拉取镜像时间可能较长)...${RESET}"
    cd "$BASE_DIR" && docker compose up -d

    echo -e "${YELLOW}等待雷池各微服务初始化完成 (约8秒)...${RESET}"
    sleep 8

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       雷池 WAF 部署命令提交！   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}控制台访问地址 : https://127.0.0.1:${mgt_port}${RESET} (请使用 https 访问)"
    echo -e "${YELLOW}安装绝对路径   : $BASE_DIR${RESET}"
    echo -e "${CYAN}提示: 如果首次登录需要初始密码，请在主菜单选择 [9] 初始化管理员账户。${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

# 重置/初始化雷池管理员账户
reset_admin_pwd() {
    get_status_info
    if [[ "$status" != *"运行中"* ]]; then
        echo -e "${RED}错误: 雷池管理服务未运行，无法执行重置！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在请求雷池内部模块安全重置管理员账户...${RESET}"
    docker exec "$CONTAINER_NAME" resetadmin
}

# 更新雷池
update_safeline() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取雷池 WAF 最新容器镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！雷池集群已升至最新状态。${RESET}"
}

# 卸载雷池
uninstall_safeline() {
    echo -ne "${RED}确定要完全卸载长亭雷池 WAF 吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}所有雷池防火墙容器已停止并清除。${RESET}"
            echo -ne "${YELLOW}是否同时彻底清除所有防护拦截日志、站点配置和数据库数据？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}雷池数据目录已完全清理。${RESET}"
            fi
        else
            docker rm -f safeline-mgt safeline-pg safeline-detector safeline-tengine safeline-farter 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_safeline() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}雷池集群已启动${RESET}"; }
stop_safeline() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}雷池集群已停止${RESET}"; }
restart_safeline() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}雷池集群已重启${RESET}"; }
logs_safeline() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}核心状态       : $status"
    echo -e "${YELLOW}控制台访问地址 : https://127.0.0.1:${webui_port}${RESET}"
    echo -e "${YELLOW}数据存储路径   : ${BASE_DIR}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  长亭雷池 WAF 管理面板  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新雷池${RESET}"
    echo -e "${GREEN}3. 卸载雷池${RESET}"
    echo -e "${GREEN}4. 启动集群${RESET}"
    echo -e "${GREEN}5. 停止集群${RESET}"
    echo -e "${GREEN}6. 重启集群${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}9. 初始化/重置管理员账户密码${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_safeline ;;
        2) update_safeline ;;
        3) uninstall_safeline ;;
        4) start_safeline ;;
        5) stop_safeline ;;
        6) restart_safeline ;;
        7) logs_safeline ;;
        8) show_info ;;
        9) reset_admin_pwd ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
