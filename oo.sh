#!/bin/bash
# =================================================================
# 思源笔记 (SiYuan) 双链知识库 Docker Compose 独立管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="siyuan-notebook"
BASE_DIR="/opt/siyuan"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态与映射端口
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中 (多端安全同步中)${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="b3log/siyuan:latest"
        
        # 动态抓取映射到容器 6806 端口的宿主机实际端口
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "6806/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="6806"
        port_display="${webui_port}"
    else
        img_version="${RED}未安装${RESET}"
        port_display="N/A"
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


# 处理绝对路径与相对路径转换
get_real_path() {
    local input_path="$1"
    local default_path="$2"
    [[ -z "$input_path" ]] && input_path="$default_path"

    if [[ "$input_path" == "./"* ]]; then
        echo "$BASE_DIR/${input_path#./}"
    else
        echo "$input_path"
    fi
}

# 一键部署思源笔记
install_siyuan() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    echo -e "${CYAN}====== 1. 知识库数据挂载路径 ======${RESET}"
    echo -e "${YELLOW}提示: 直接回车将默认采用脚本同级路径下的 workspace 文件夹。${RESET}"
    
    echo -ne "${YELLOW}请输入笔记数据存放路径 [默认: ./workspace]: ${RESET}"
    read -r input_data
    local path_data_raw="${input_data:-./workspace}"
    local real_path_data=$(get_real_path "$path_data_raw" "./workspace")

    echo -e "\n${CYAN}====== 2. 安全访问与网络端口 ======${RESET}"
    
    # 交互式设定 AuthCode
    echo -e "${YELLOW}提示: 思源笔记必须设置访问授权码，用于网页端及 APP 端同步校验。${RESET}"
    echo -ne "${YELLOW}请设置您的安全访问密码 (AuthCode) [留空则随机生成]: ${RESET}"
    read -r custom_auth
    if [[ -z "$custom_auth" ]]; then
        # 随机生成一个 8 位高强度口令
        custom_auth=$(head -c 4 /dev/urandom | xxd -p | tr -d '[:space:]')
    fi

    # 允许自定义宿主机端口
    echo -ne "${YELLOW}请输入思源笔记宿主机外部访问端口 [默认: 6806]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="6806"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    # 智能提取当前宿主执行用户的专属 PUID/PGID，彻底解决 Docker 挂载写入挂掉的通病
    local current_puid=$(id -u)
    local current_pgid=$(id -g)

    # 预先构建物理目录、将所有权无缝转换给思源运行用户组并穿透赋权
    echo -e "${YELLOW}正在对宿主机进行物理知识库目录预建与降权赋权安全对齐...${RESET}"
    mkdir -p "$real_path_data"
    chown -R "$current_puid:$current_pgid" "$real_path_data"
    chmod -R 777 "$real_path_data"

    # 生成环境配置文件 .env
    cat <<EOF > "$ENV_FILE"
AuthCode=${custom_auth}
YOUR_TIME_ZONE=Asia/Shanghai
YOUR_USER_PUID=${current_puid}
YOUR_USER_PGID=${current_pgid}
HOST_PORT=${custom_port}
EOF

    # 生成标准的解耦版 docker-compose.yml 结构体
    cat <<EOF > "$COMPOSE_FILE"
services:
  main:
    image: b3log/siyuan:latest
    container_name: ${CONTAINER_NAME}
    command: ['--workspace=/siyuan/workspace/', '--accessAuthCode=\${AuthCode}']
    ports:
      - "\${HOST_PORT:-6806}:6806"
    volumes:
      - ${path_data_raw}:/siyuan/workspace
    restart: unless-stopped
    environment:
      - TZ=\${YOUR_TIME_ZONE}
      - PUID=\${YOUR_USER_PUID}
      - PGID=\${YOUR_USER_PGID}
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 拉起思源笔记引擎...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器安全建立块级索引 (约3秒)...${RESET}"
    sleep 3

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}         🎉 思源笔记 (SiYuan) 部署成功！             ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}服务面板访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${GREEN}安全访问授权密码 : ${custom_auth}${RESET}"
    echo -e "${YELLOW}宿主机数据存储夹 : ${real_path_data}${RESET}"
    echo -e "${YELLOW}宿主机底座所有权 : UID=${current_puid} | GID=${current_pgid} (已完美融合)${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}💡 使用指南: 打开网页或在桌面/手机端 SiYuan APP 中连接此地址，输入上述密码即可开始无网本地优先的块级双链笔记之旅！${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新思源内核
update_siyuan() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从官方远端仓库获取最新版思源内核镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！思源笔记引擎已经安全升级。${RESET}"
}

# 彻底销毁组件
uninstall_siyuan() {
    echo -e "${RED}警告: 销毁笔记数据是不可逆行为！${RESET}"
    echo -ne "${YELLOW}确定要停用并卸载思源笔记容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${RED}【极度危险】是否同时彻底删除本地全量挂载的知识库数据文件夹（包含所有笔记、历史资产）？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有思源笔记历史资产、块索引数据库已被彻底灰飞烟灭。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}思源引擎已复苏启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}思源引擎已安全挂起${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}思源引擎已执行重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

# 状态与凭证查看补丁
show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    local cur_auth="未知 (请在选项1中重新配置)"
    if [ -f "$ENV_FILE" ]; then
        # 提取当前有效的登录口令
        cur_auth=$(grep "AuthCode=" "$ENV_FILE" | cut -d'=' -f2)
    fi
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前内核状态   : $status"
    echo -e "${YELLOW}服务网络入口   : http://${DETECT_IP}:${port_display}"
    echo -e "${GREEN}安全访问密码   : ${cur_auth}${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  思源笔记 管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port_display}${RESET}"
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
        1) install_siyuan ;;
        2) update_siyuan ;;
        3) uninstall_siyuan ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
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
