#!/bin/bash
# =================================================================
# Transmission Docker Compose 管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="transmission"
BASE_DIR="/opt/transmission"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
WEB_SRC_DIR="$BASE_DIR/web/src"

# GitHub 仓库信息
REPO_API="https://api.github.com/repos/hisproc/transmission-next-ui/releases/latest"

# 代理前缀列表（第一个留空代表直连尝试）
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    
    local missing_deps=()
    ! command -v unzip &> /dev/null && missing_deps+=("unzip")
    ! command -v wget &> /dev/null && missing_deps+=("wget")
    ! command -v curl &> /dev/null && missing_deps+=("curl")
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}提示: 正在安装缺失的工具 (${missing_deps[*]})...${RESET}"
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y wget unzip curl
        elif command -v yum &> /dev/null; then
            sudo yum install -y wget unzip curl
        fi
    fi
}

# 动态获取容器状态、映射端口和数据目录
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
        [[ -z "$img_version" ]] && img_version="已安装"
    else
        img_version="${RED}未安装${RESET}"
    fi

    if [[ -f "$COMPOSE_FILE" ]]; then
        webui_port=$(grep -E "\-[[:space:]]*[\"']?[0-9]+:9091" "$COMPOSE_FILE" | head -n 1 | awk -F ':' '{print $1}' | tr -d '[:space:]"-')
        [[ -z "$webui_port" ]] && webui_port="9091"

        download_dir=$(grep -E -- "- .+/downloads" "$COMPOSE_FILE" | awk -F ':' '{print $1}' | sed 's/- //g' | tr -d '"' | xargs)
        [[ -z "$download_dir" ]] && download_dir="$BASE_DIR/downloads"
    else
        webui_port="N/A"
        download_dir="N/A"
    fi
}

# 提取 Web UI 账号密码
get_transmission_creds() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        local username=$(grep -E "USER=" "$COMPOSE_FILE" | awk -F '=' '{print $2}' | tr -d '[:space:]"')
        local password=$(grep -E "PASS=" "$COMPOSE_FILE" | awk -F '=' '{print $2}' | tr -d '[:space:]"')
        echo -e "${GREEN}用户名: ${username} | 密码: ${password}${RESET}"
    else
        echo -e "${RED}未部署${RESET}"
    fi
}

# 核心下载函数：带代理轮询及重试机制
download_with_proxy_pool() {
    local raw_url="$1"
    local output_path="$2"
    local download_success=false

    for proxy in "${GITHUB_PROXY[@]}"; do
        # 拼接代理前缀
        local final_url="${proxy}${raw_url}"
        
        if [[ -z "$proxy" ]]; then
            echo -e "${YELLOW}正在尝试直连下载...${RESET}"
        else
            echo -e "${YELLOW}直连失败或不可用，正在通过代理 [ ${proxy} ] 尝试下载...${RESET}"
        fi
        
        # 使用 wget 下载，设置5秒超时，1次重试
        if wget --no-check-certificate --timeout=5 --tries=1 -O "$output_path" "$final_url"; then
            echo -e "${GREEN}下载成功！${RESET}"
            download_success=true
            break
        else
            echo -e "${RED}当前下载通道失败，正在切换下一个通道...${RESET}"
        fi
    done

    if [ "$download_success" = true ]; then
        return 0
    else
        return 1
    fi
}

# 智能动态在线获取最新版 Web UI
setup_custom_webui() {
    echo -ne "${YELLOW}是否自动获取并安装最新版 Next-UI 界面？(y/n) [默认: y]: ${RESET}"
    read -r enable_ui
    [[ -z "$enable_ui" ]] && enable_ui="y"

    if [[ "$enable_ui" == "y" || "$enable_ui" == "Y" ]]; then
        echo -e "${CYAN}--- 正在通过 GitHub API 获取最新版本 ---${RESET}"
        
        # 1. 动态获取最新 Release 信息（带代理兜底，防止 API 本身被墙）
        local api_response=""
        # 尝试通过代理或者直连获取 API 信息 (API 一般不走普通 GH 代理，通过增加超时重试防挂)
        api_response=$(curl -s --connect-timeout 5 "$REPO_API")
        
        local raw_download_url=""
        local version_tag=""

        if [[ -z "$api_response" || "$api_response" == *"message"* ]]; then
            echo -e "${RED}⚠️ 警告: 无法连接到 GitHub API 或触发限制。将启用本地备用静态解析方案。${RESET}"
            raw_download_url="https://github.com/hisproc/transmission-next-ui/releases/download/v0.3.1/release.zip"
            version_tag="v0.3.1 (备用)"
        else
            raw_download_url=$(echo "$api_response" | grep -E '"browser_download_url":' | grep -i '\.zip' | head -n 1 | awk -F '"' '{print $4}')
            version_tag=$(echo "$api_response" | grep -E '"tag_name":' | head -n 1 | awk -F '"' '{print $4}')
        fi

        if [[ -z "$raw_download_url" ]]; then
            echo -e "${RED}❌ 错误: 无法解析到 zip 压缩包下载地址！将回滚使用原生界面。${RESET}"
            return 1
        fi

        echo -e "${GREEN}发现最新版本: ${version_tag}${RESET}"
        
        # 2. 清理并创建本地目录
        echo -e "${YELLOW}正在清理旧的 Web 目录...${RESET}"
        rm -rf "$WEB_SRC_DIR"
        mkdir -p "$WEB_SRC_DIR"

        # 3. 调用带代理轮询的下载函数
        if download_with_proxy_pool "$raw_download_url" "$BASE_DIR/web_ui.zip"; then
            echo -e "${YELLOW}正在智能解压...${RESET}"
            mkdir -p "$BASE_DIR/web_tmp"
            unzip -q "$BASE_DIR/web_ui.zip" -d "$BASE_DIR/web_tmp"
            
            # 兼容性处理：判断解压后是直接含 index.html 还是包裹了一层目录
            if [ $(ls -A "$BASE_DIR/web_tmp" | wc -l) -eq 1 ] && [ -d "$BASE_DIR/web_tmp/$(ls -A $BASE_DIR/web_tmp)" ]; then
                mv "$BASE_DIR/web_tmp/$(ls -A $BASE_DIR/web_tmp)"/* "$WEB_SRC_DIR/"
            else
                mv "$BASE_DIR/web_tmp"/* "$WEB_SRC_DIR/"
            fi

            # 清理临时文件
            rm -rf "$BASE_DIR/web_ui.zip" "$BASE_DIR/web_tmp"
            echo -e "${GREEN}✨ Next-UI (${version_tag}) 静态文件已成功部署！${RESET}"
            return 0
        else
            echo -e "${RED}❌ 严重错误: 所有下载代理通道全部沦陷！将自动回滚为 Transmission 原生界面。${RESET}"
            return 1
        fi
    fi
    return 1
}

install_transmission() {
    check_dependencies
    
    mkdir -p "$BASE_DIR/config" "$BASE_DIR/watch"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 Transmission WebUI 访问端口 [默认: 9091]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="9091"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入 Transmission Peer 传入端口 [默认: 51413]: ${RESET}"
    read -r peer_port
    [[ -z "$peer_port" ]] && peer_port="51413"

    echo -ne "${YELLOW}请输入宿主机下载文件存储绝对路径 [默认: $BASE_DIR/downloads]: ${RESET}"
    read -r custom_download
    [[ -z "$custom_download" ]] && custom_download="$BASE_DIR/downloads"

    echo -ne "${YELLOW}请设置 WebUI 登录用户名 [默认: transmission]: ${RESET}"
    read -r ui_user
    [[ -z "$ui_user" ]] && ui_user="transmission"

    echo -ne "${YELLOW}请设置 WebUI 登录密码 [默认: transmission]: ${RESET}"
    read -r ui_pass
    [[ -z "$ui_pass" ]] && ui_pass="transmission"

    # 执行智能化 UI 部署
    setup_custom_webui
    has_custom_ui=$?

    # 获取执行脚本用户的 UID/GID 并创建存储目录
    CURRENT_UID=$(id -u)
    CURRENT_GID=$(id -g)
    mkdir -p "$custom_download"
    
    # 生成标准的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合官方标准的 docker-compose.yml 配置文件...${RESET}"
    
    local env_web_home=""
    local volume_web_src=""
    
    if [ $has_custom_ui -eq 0 ]; then
        env_web_home="- TRANSMISSION_WEB_HOME=/src"
        volume_web_src="- ${WEB_SRC_DIR}:/src"
    fi

    cat <<EOF > "$COMPOSE_FILE"
services:
  transmission:
    image: linuxserver/transmission:4.0.0
    container_name: ${CONTAINER_NAME}
    environment:
      - PUID=${CURRENT_UID}
      - PGID=${CURRENT_GID}
      - UMASK=022
      ${env_web_home}
      - TZ=Asia/Shanghai
      - USER=${ui_user}
      - PASS=${ui_pass}
    volumes:
      ${volume_web_src}
      - ${BASE_DIR}/config:/config
      - ${custom_download}:/downloads
      - ${BASE_DIR}/watch:/watch
    ports:
      - "${custom_port}:9091"
      - "${peer_port}:51413"
      - "${peer_port}:51413/udp"
    restart: unless-stopped
EOF

    chmod -R 777 "$BASE_DIR" "$custom_download"

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Transmission...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    Transmission 部署成功！    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://127.0.0.1:${custom_port}${RESET}"
    get_transmission_creds
    echo -e "${YELLOW}宿主机配置路径 : $BASE_DIR/config${RESET}"
    echo -e "${YELLOW}宿主机下载路径 : $custom_download${RESET}"
    echo -e "${YELLOW}Peer 传入端口  : $peer_port (请记得在路由器做端口映射)${RESET}"
    if [ $has_custom_ui -eq 0 ]; then
        echo -e "${GREEN}自定义 Web UI  : 已成功启用并自动挂载最新版${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
}

update_transmission() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    
    # 更新时同时检测是否有更高级的 WebUI
    echo -e "${YELLOW}正在检查并更新 WebUI 与核心镜像...${RESET}"
    if grep -q "TRANSMISSION_WEB_HOME" "$COMPOSE_FILE"; then
        setup_custom_webui
    fi

    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器与组件已处于最新状态。${RESET}"
}

uninstall_transmission() {
    echo -ne "${YELLOW}确定要卸载并删除 Transmission 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除所有配置文件和下载的种子文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}数据目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_trans() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_trans() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_trans() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_trans() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}WebUI 访问地址 : http://127.0.0.1:${webui_port}${RESET}"
    echo -ne "${YELLOW}当前认证凭据   : ${RESET}"
    get_transmission_creds
    echo -e "${YELLOW}宿主机下载路径 : ${download_dir}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}   ◈  Transmission 管理面板  ◈   ${RESET}"
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
        1) install_transmission ;;
        2) update_transmission ;;
        3) uninstall_transmission ;;
        4) start_trans ;;
        5) stop_trans ;;
        6) restart_trans ;;
        7) logs_trans ;;
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
