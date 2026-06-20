#!/bin/bash
# =================================================================
# Kavita (Manga/Comics/Books) 多类目电子书库全自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="kavita"
BASE_DIR="/opt/kavita"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态及多个独立书架的真实物理挂载路径
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
        [[ -z "$img_version" ]] && img_version="latest"

        # 提取 Web 访问端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "5000/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="5000"

        # 提取本地多类别挂载物理路径
        path_config_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/kavita/config"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_manga_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/manga"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_comics_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/comics"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        path_books_show=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/books"}}{{.Source}}{{break}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)
        
        [[ -z "$path_config_show" ]] && path_config_show="$BASE_DIR/config"
        [[ -z "$path_manga_show" ]] && path_manga_show="$BASE_DIR/manga"
        [[ -z "$path_comics_show" ]] && path_comics_show="$BASE_DIR/comics"
        [[ -z "$path_books_show" ]] && path_books_show="$BASE_DIR/books"
    else
        img_version="N/A"
        webui_port="N/A"
        path_config_show="N/A"
        path_manga_show="N/A"
        path_comics_show="N/A"
        path_books_show="N/A"
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

# 部署并配置多目录核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 网络访问端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 Kavita 网页访问映射端口 (宿主机) [默认: 5000]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="5000"

    echo -e "\n${CYAN}====== 2. 分类书架数据挂载自定义 (绝对路径) ======${RESET}"
    echo -ne "${YELLOW}1. 请输入【程序系统配置 ./config】保存路径 [默认: $BASE_DIR/config]: ${RESET}"
    read -r path_config
    [[ -z "$path_config" ]] && path_config="$BASE_DIR/config"

    echo -ne "${YELLOW}2. 请输入【日漫/韩漫本地仓 ./manga】保存路径 [默认: $BASE_DIR/manga]: ${RESET}"
    read -r path_manga
    [[ -z "$path_manga" ]] && path_manga="$BASE_DIR/manga"

    echo -ne "${YELLOW}3. 请输入【美漫/港漫本地仓 ./comics】保存路径 [默认: $BASE_DIR/comics]: ${RESET}"
    read -r path_comics
    [[ -z "$path_comics" ]] && path_comics="$BASE_DIR/comics"

    echo -ne "${YELLOW}4. 请输入【文学电子书本地仓 ./books】保存路径 [默认: $BASE_DIR/books]: ${RESET}"
    read -r path_books
    [[ -z "$path_books" ]] && path_books="$BASE_DIR/books"

    # 批量创建本地分类目录并赋予高兼容读写权限
    echo -e "\n${YELLOW}正在批量初始化 Kavita 分类物理仓所有权及读写权限...${RESET}"
    mkdir -p "$path_config" "$path_manga" "$path_comics" "$path_books"
    chmod -R 777 "$path_config" "$path_manga" "$path_comics" "$path_books"

    # 生成规范化 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在构建符合 Kavita 图书规范的 docker-compose.yml...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  kavita:
    image: jvmilazz0/kavita:latest
    container_name: ${CONTAINER_NAME}
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - "${path_config}:/kavita/config"
      - "${path_manga}:/manga"
      - "${path_comics}:/comics"
      - "${path_books}:/books"
    ports:
      - "${custom_port}:5000"
    restart: unless-stopped
EOF

    # 启动容器
    echo -e "\n${YELLOW}正在通过 Docker Compose 部署 Kavita 数字化书房...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待 Kavita 核心扫描本地磁盘文件结构 (约 3 秒)...${RESET}"
    sleep 3

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}              Kavita 媒体库部署成功！                ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}Web 阅读器访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}元数据配置本地路径 : ${path_config}${RESET}"
    echo -e "${YELLOW}Manga 漫画本地路径 : ${path_manga}${RESET}"
    echo -e "${YELLOW}Comics美漫本地路径 : ${path_comics}${RESET}"
    echo -e "${YELLOW}Books 电子书主路径 : ${path_books}${RESET}"
    echo -e "${CYAN}💡 进阶提示：请将对应种类的电子书分别放入主机的上述物理路径中。${RESET}"
    echo -e "${CYAN}   在 Kavita 后台新建媒体库时，直接关联容器内的【 /manga 】、【 /comics 】或【 /books 】即可！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新服务
update_translate() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 Kavita 官方发布版镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！数字化阅读服务已平滑重启。${RESET}"
}

# 卸载服务
uninstall_translate() {
    echo -ne "${YELLOW}确定要卸载并删除 Kavita 图书容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并安全移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地保存的书架刮削海报、阅读记录及索引数据库？(⚠️绝不会动你的书籍漫画原文件)(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                get_status_info
                rm -rf "$BASE_DIR"
                [[ "$path_config_show" != "$BASE_DIR"* && -d "$path_config_show" ]] && rm -rf "$path_config_show"
                echo -e "${GREEN}所有本地的 Kavita 账户信息、页码缓存、元数据已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_translate() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}服务已启动${RESET}"; }
stop_translate() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}服务已停止${RESET}"; }
restart_translate() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}服务已重启${RESET}"; }
logs_translate() { docker logs -f --tail=100 "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态     : $status"
    echo -e "${YELLOW}核心镜像版本     : ${img_version}${RESET}"
    echo -e "${YELLOW}Web 后台访问地址 : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}配置存储本地路径 : ${path_config_show}${RESET}"
    echo -e "${YELLOW}Manga 漫画本地路径 : ${path_manga_show}${RESET}"
    echo -e "${YELLOW}Comics美漫本地路径 : ${path_comics_show}${RESET}"
    echo -e "${YELLOW}Books 电子书本地路 : ${path_books_show}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Kavita  漫画管理面板  ◈  ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $status"
    echo -e "${GREEN}端口    :${RESET} ${YELLOW}${webui_port}${RESET}"
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
        1) install_translate ;;
        2) update_translate ;;
        3) uninstall_translate ;;
        4) start_translate ;;
        5) stop_translate ;;
        6) restart_translate ;;
        7) logs_translate ;;
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
