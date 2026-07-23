#!/bin/bash
# =================================================================
# VPS-ONE (idc-oneman-V5) 系统 自动化管理面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="vps-one"
BASE_DIR="/opt/vps-one"
SRC_DIR="$BASE_DIR"
REPO_URL="https://github.com/oneman-idc/idc-oneman-V5.git"

# 检测基础依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi
    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}错误: 未检测到 OpenSSL，请先安装 OpenSSL！${RESET}"
        exit 1
    fi
}

# 动态获取服务端口与运行状态
get_status_info() {
    if ! command -v docker &> /dev/null; then
        status="${RED}未安装 Docker${RESET}"
        img_version="${RED}未安装${RESET}"
        webui_port="N/A"
        data_dir="N/A"
        return 0
    fi
    local container_id=$(docker ps -q -f "name=vps-one" -f "status=running" 2>/dev/null)

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中${RESET}"
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "9080/tcp") 0).HostPort}}' "$container_id" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="9080"
    else
        if [ -d "$SRC_DIR/.git" ]; then
            status="${RED}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        webui_port="N/A"
    fi
}

# 获取服务器公网 IP
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

# 修改 docker-compose.yml 映射本地目录
patch_docker_compose() {
    if [ -f "$SRC_DIR/docker-compose.yml" ]; then
        echo -e "${YELLOW}正在修正 docker-compose.yml 将数据卷转换为本地目录映射 (./data:/app/data)...${RESET}"
        
        # 替换挂载路径为本地 ./data
        sed -i 's|- vps_one_data:/app/data|- ./data:/app/data|g' "$SRC_DIR/docker-compose.yml"
        
        # 移除末尾的命名卷声明，防止 Docker Compose 报错
        sed -i '/^volumes:/d' "$SRC_DIR/docker-compose.yml"
        sed -i '/^  vps_one_data:/d' "$SRC_DIR/docker-compose.yml"
    fi
}

# 部署核心逻辑
install_translate() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 1. 基础配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 VPS-ONE 映射端口 (对应 VPS_ONE_PORT) [默认: 9080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="9080"

    echo -ne "${YELLOW}请输入站点公开地址 (对应 BASE_URL，例: https://vps.example.com): ${RESET}"
    read -r custom_base_url
    [[ -z "$custom_base_url" ]] && custom_base_url="http://$(get_public_ip):${custom_port}"

    echo -ne "${YELLOW}是否使用国内镜像源加速拉取? (y/n) [默认: n]: ${RESET}"
    read -r use_china_mirror

    # 克隆官方仓库到当前工作目录
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在克隆 VPS-ONE GitHub 仓库...${RESET}"
        git clone "$REPO_URL" "$SRC_DIR/tmp_repo"
        if [ $? -eq 0 ]; then
            mv "$SRC_DIR/tmp_repo/"* "$SRC_DIR/" 2>/dev/null
            mv "$SRC_DIR/tmp_repo/."* "$SRC_DIR/" 2>/dev/null
            rm -rf "$SRC_DIR/tmp_repo"
        else
            echo -e "${RED}错误: 仓库克隆失败，请检查网络！${RESET}"
            exit 1
        fi
    else
        echo -e "\n${GREEN}检测到本地已存在仓库，正在同步最新代码...${RESET}"
        cd "$SRC_DIR" && git pull
    fi

    cd "$SRC_DIR"

    # 预先创建本地映射目录并补全读写权限
    echo -e "${YELLOW}正在创建并初始化本地数据存储目录 (${SRC_DIR}/data)...${RESET}"
    mkdir -p "$SRC_DIR/data"
    chmod -R 777 "$SRC_DIR/data"

    # 修改 compose 文件为本地目录映射
    patch_docker_compose

    # 生成 64 位随机 Hex 密钥
    echo -e "${YELLOW}正在自动生成安全密钥 (SECRET_KEY & MASTER_KEY)...${RESET}"
    SECRET_KEY_VAL=$(openssl rand -hex 32)
    MASTER_KEY_VAL=$(openssl rand -hex 32)

    # 镜像源选择逻辑
    if [[ "$use_china_mirror" == "y" || "$use_china_mirror" == "Y" ]]; then
        PYTHON_IMG="docker.m.daocloud.io/python:3.12-slim"
        PIP_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
    else
        PYTHON_IMG="python:3.12-slim"
        PIP_URL=""
    fi

    # 写入 .env 配置文件
    echo -e "${YELLOW}正在配置 .env 环境变量...${RESET}"
    cat <<EOF > .env
SECRET_KEY=${SECRET_KEY_VAL}
MASTER_KEY=${MASTER_KEY_VAL}
DATABASE_URL=sqlite+aiosqlite:////app/data/vps-one.sqlite
BASE_URL=${custom_base_url}
DEBUG=false
VPS_ONE_PORT=${custom_port}

PYTHON_IMAGE=${PYTHON_IMG}
PIP_INDEX_URL=${PIP_URL}
EOF

    # 编译并启动容器集群
    echo -e "\n${YELLOW}正在执行 Docker 编译并启动服务...${RESET}"
    docker compose up -d --build

    echo -e "${YELLOW}正在等待容器编译并拉起服务 (约 5 秒)...${RESET}"
    sleep 5

    # 二次对本地数据目录赋权，确保 SQLite 可正常读写
    chmod -R 777 "$SRC_DIR/data" 2>/dev/null

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        VPS-ONE 容器编译并启动成功！        ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}面板访问地址 : http://${DETECT_IP}:${custom_port}/install${RESET}"
    echo -e "${YELLOW}本地数据路径 : ${SRC_DIR}/data${RESET}"
    echo -e "${YELLOW}配置公开地址 : ${custom_base_url}${RESET}/install"
    echo -e "${YELLOW}项目所在路径 : ${SRC_DIR}${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}📝 后续配置提示：${RESET}"
    echo -e "${YELLOW}   - SQLite 数据库及系统文件已保存在本地路径：${SRC_DIR}/data/vps-one.sqlite${RESET}"
    echo -e "${YELLOW}   - 敏感凭据（CLICD、HashPay、SMTP 等）请在登录系统后的“系统配置”页面填写。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 原生更新：拉取代码 + 自动保持本地映射 + 重新 Build
update_translate() {
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "${RED}错误: 未检测到克隆的仓库，请先执行选项 1！${RESET}"
        return
    fi

    echo -e "${YELLOW}正在同步最新的远程官方代码...${RESET}"
    cd "$SRC_DIR" && git pull
    
    # 重新应用本地目录映射修正
    patch_docker_compose

    echo -e "${YELLOW}正在使用 docker compose 重编镜像并热更新...${RESET}"
    docker compose up -d --build --remove-orphans
    
    chmod -R 777 "$SRC_DIR/data" 2>/dev/null
    echo -e "${GREEN}VPS-ONE 镜像更新并重编完成！${RESET}"
}

# 彻底卸载
uninstall_translate() {
    echo -ne "${RED}确定要停止并卸载 VPS-ONE 容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$SRC_DIR/.git" ]; then
            cd "$SRC_DIR" && docker compose down
            echo -e "${GREEN}容器已安全停止并移除。${RESET}"
            echo -ne "${YELLOW}是否彻底删除本地目录【源码、配置文件及 ./data 数据库数据】？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有源码与持久化数据已被彻底清除！${RESET}"
            fi
        else
            echo -e "${YELLOW}未检测到运行中的 compose 环境，跳过物理删除。${RESET}"
        fi
    fi
}

# 基于 Compose 文件的生命周期联动
start_translate() { cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}VPS-ONE 服务已启动${RESET}"; }
stop_translate() { cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}VPS-ONE 服务已停止${RESET}"; }
restart_translate() { cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}VPS-ONE 服务已重启${RESET}"; }
logs_translate() { cd "$SRC_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}集群运行状态     : $status"
    echo -e "${YELLOW}面板访问地址     : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}本地数据存储     : ${SRC_DIR}/data${RESET}"
    if [ -f "$SRC_DIR/.env" ]; then
        local base_url_val=$(grep "^BASE_URL=" "$SRC_DIR/.env" | cut -d '=' -f2-)
        echo -e "${YELLOW}站点公开地址     : ${base_url_val}${RESET}"
    fi
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}   ◈  VPS-ONE 自动化管理面板  ◈    ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}服务状态 :${RESET} $status"
    echo -e "${GREEN}映射端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}===================================${RESET}"
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
