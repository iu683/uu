#!/bin/bash
# =================================================================
# ACG-FAKA 发卡系统 (官方原生 Clone + 环境变量 Build) 自动化管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="acg-faka-app"
BASE_DIR="/opt/acg-faka"
# 直接将面板和源码放在一起，完全遵循官方根目录结构
SRC_DIR="$BASE_DIR" 
REPO_URL="https://github.com/lizhipay/acg-faka.git"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    if ! command -v git &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Git，请先安装 Git！${RESET}"
        exit 1
    fi
}

# 动态获取服务端口与运行状态
get_status_info() {
    # 官方默认生成的容器名可能是 acg-faka-app 或 acg-faka_app_1，这里通过 image 标签动态精准抓取
    local container_id=$(docker ps -q -f "ancestor=acg-faka-app" -f "status=running" 2>/dev/null)
    [[ -z "$container_id" ]] && container_id=$(docker ps -q -f "name=app" -f "status=running" 2>/dev/null)

    if [[ -n "$container_id" ]]; then
        status="${GREEN}运行中 (官方集群已就绪)${RESET}"
        webui_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$container_id" 2>/dev/null)
        [[ -z "$webui_port" ]] && webui_port="8080"
    else
        if [ -d "$SRC_DIR/.git" ]; then
            status="${RED}已停止${RESET}"
        else
            status="${RED}未部署${RESET}"
        fi
        webui_port="N/A"
    fi
}

# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://4.ip.sb"; do
        ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
    done
    echo "127.0.0.1" && return 0
}

# 部署核心逻辑
install_translate() {
    check_dependencies

    echo -e "${CYAN}====== 1. 端口配置 ======${RESET}"
    echo -ne "${YELLOW}请输入 ACG-FAKA 映射端口 (对应 ACG_HTTP_PORT) [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"

    # 克隆官方仓库到当前工作目录
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "\n${YELLOW}正在克隆官方 GitHub 仓库...${RESET}"
        # 允许在空目录或仅有本脚本的目录下克隆
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
        echo -e "\n${GREEN}检测到本地已存在官方仓库，正在同步最新代码...${RESET}"
        cd "$SRC_DIR" && git pull
    fi

    # 回到仓库根目录
    cd "$SRC_DIR"

    # 官方提到的赋权逻辑优化（提前预热防止挂载后被锁）
    echo -e "${YELLOW}正在预热修复官方提及的持久化目录写权限...${RESET}"
    mkdir -p assets/cache app/Plugin app/Pay app/View/User/Theme kernel/Install runtime
    chmod -R 777 assets/cache app/Plugin app/Pay app/View/User/Theme kernel/Install runtime

    # 完美对齐官方启动命令：ACG_HTTP_PORT=xxxx docker compose up -d --build
    echo -e "\n${YELLOW}正在执行官方原生编译启动命令...${RESET}"
    ACG_HTTP_PORT=$custom_port docker compose up -d --build

    echo -e "${YELLOW}正在等待容器集群 Build 编译并拉起服务 (约 5 秒)...${RESET}"
    sleep 5

    # 再次调用官方给出的修复（补充跑一次权限，确保万无一失）
    chmod -R 777 assets/cache app/Plugin app/Pay app/View/User/Theme kernel/Install runtime 2>/dev/null

    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        ACG-FAKA 官方原生集群编译并启动成功！        ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}默认访问地址 : http://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}后台管理地址 : http://${DETECT_IP}:${custom_port}/admin${RESET}"
    echo -e "${YELLOW}仓库所在路径 : ${SRC_DIR}${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}📝 首次安装页面填写指南（严格遵照官方）：${RESET}"
    echo -e "   - 数据库地址 : ${GREEN}mysql${RESET}"
    echo -e "   - 数据库名称 : ${GREEN}acg_faka${RESET}"
    echo -e "   - 数据库账号 : ${GREEN}acg${RESET}"
    echo -e "   - 数据库密码 : ${GREEN}acg_password${RESET}"
    echo -e "   - 数据库前缀 : ${GREEN}acg_${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 原生更新：拉取代码 + 重新 Build
update_translate() {
    if [ ! -d "$SRC_DIR/.git" ]; then
        echo -e "${RED}错误: 未检测到克隆的仓库，请先执行选项 1！${RESET}"
        return
    fi
    get_status_info
    local current_port=$webui_port
    [[ "$current_port" == "N/A" ]] && current_port="8080"

    echo -e "${YELLOW}正在同步最新的远程官方代码...${RESET}"
    cd "$SRC_DIR" && git pull
    
    echo -e "${YELLOW}正在使用官方命令重编镜像并热更新...${RESET}"
    ACG_HTTP_PORT=$current_port docker compose up -d --build --remove-orphans
    echo -e "${GREEN}官方集群更新并重编完成！${RESET}"
}

# 彻底卸载
uninstall_translate() {
    echo -ne "${RED}确定要停止并卸载 ACG-FAKA 官方容器集群吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -d "$SRC_DIR/.git" ]; then
            cd "$SRC_DIR" && docker compose down
            echo -e "${GREEN}官方容器与网络已被安全停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同步连根拔除本地克隆的【全部源码、卡密、商品及数据库文件】？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有源码与持久化数据已被彻底清除！${RESET}"
                exit 0
            fi
        else
            echo -e "${YELLOW}未检测到运行中的 compose 环境，跳过物理删除。${RESET}"
        fi
    fi
}

# 基于官方 Compose 文件的生命周期联动
start_translate() { cd "$SRC_DIR" && docker compose start && echo -e "${GREEN}原生集群已全面启动${RESET}"; }
stop_translate() { cd "$SRC_DIR" && docker compose stop && echo -e "${YELLOW}原生集群已安全停止${RESET}"; }
restart_translate() { cd "$SRC_DIR" && docker compose restart && echo -e "${GREEN}原生集群已平滑重启${RESET}"; }
logs_translate() { cd "$SRC_DIR" && docker compose logs -f --tail=100; }

show_info() {
    get_status_info
    local DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}集群运行状态     : $status"
    echo -e "${YELLOW}前端访问地址     : http://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}后台管理地址     : http://${DETECT_IP}:${webui_port}/admin${RESET}"
    echo -e "${YELLOW}部署管理模式     : 官方原生指令驱动 (ACG_HTTP_PORT 注入)${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}   ◈  ACG-FAKA 原生指令面板  ◈     ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}集群状态 :${RESET} $status"
    echo -e "${GREEN}服务端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}1. 部署启动 (Clone + Env Build)${RESET}"
    echo -e "${GREEN}2. 更新集群 (Pull + Env Build)${RESET}"
    echo -e "${GREEN}3. 卸载集群服务${RESET}"
    echo -e "${GREEN}4. 启动集群容器${RESET}"
    echo -e "${GREEN}5. 停止集群容器${RESET}"
    echo -e "${GREEN}6. 重启集群容器${RESET}"
    echo -e "${GREEN}7. 查看原生日志${RESET}"
    echo -e "${GREEN}8. 查看配置状态${RESET}"
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
