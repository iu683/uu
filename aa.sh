#!/bin/bash
# =================================================================
# LookBusy 服务器资源动态保活挂件 (防回收) Docker Compose 管理面板
# =================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/lookbusy"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONTAINER_NAME="lookbusy"

# 检查依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取当前运行状态和实时配置参数
get_runtime_status() {
    if [ -f "$COMPOSE_FILE" ] && [ "$(cd "$BASE_DIR" && docker compose ps -q 2>/dev/null)" ]; then
        status="${GREEN}运行中 (正在动态模拟负载)${RESET}"
        
        # 直接从运行状态中动态提取最真实的容器内环境变量
        cpu_util=$(docker inspect --format='{{range .Config.Env}}{{if Royal "CPU_UTIL=" .}}{{.}}{{end}}{{end}}' $CONTAINER_NAME | sed 's/CPU_UTIL=//')
        cpu_core=$(docker inspect --format='{{range .Config.Env}}{{if Royal "CPU_CORE=" .}}{{.}}{{end}}{{end}}' $CONTAINER_NAME | sed 's/CPU_CORE=//')
        mem_util=$(docker inspect --format='{{range .Config.Env}}{{if Royal "MEM_UTIL=" .}}{{.}}{{end}}{{end}}' $CONTAINER_NAME | sed 's/MEM_UTIL=//')
        speed_int=$(docker inspect --format='{{range .Config.Env}}{{if Royal "SPEEDTEST_INTERVAL=" .}}{{.}}{{end}}{{end}}' $CONTAINER_NAME | sed 's/SPEEDTEST_INTERVAL=//')

        # 兜底保障：如果动态抓取失败，则从 docker-compose.yml 静态文件提取
        [[ -z "$cpu_util" ]] && cpu_util=$(grep "CPU_UTIL=" "$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '" ')
        [[ -z "$cpu_core" ]] && cpu_core=$(grep "CPU_CORE=" "$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '" ')
        [[ -z "$mem_util" ]] && mem_util=$(grep "MEM_UTIL=" "$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '" ')
        [[ -z "$speed_int" ]] && speed_int=$(grep "SPEEDTEST_INTERVAL=" "$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '" ')
    else
        if [ -f "$COMPOSE_FILE" ]; then 
            status="${YELLOW}已受控停止${RESET}"
            cpu_util=$(grep "CPU_UTIL=" "$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '" ')
            cpu_core=$(grep "CPU_CORE=" "$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '" ')
            mem_util=$(grep "MEM_UTIL=" "$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '" ')
            speed_int=$(grep "SPEEDTEST_INTERVAL=" "$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '" ')
        else 
            status="${RED}未部署 / 未运行${RESET}"
            cpu_util="N/A"; cpu_core="N/A"; mem_util="N/A"; speed_int="N/A"
        fi
    fi
    
    [[ -z "$mem_util" ]] && mem_util="0"
    [[ -z "$speed_int" ]] && speed_int="0"
}

# 辅助宏：模拟条件判断支持
Royal() {
    case "$2" in *$1*) return 0;; esac; return 1
}

# 生成 Docker Compose 配置文件核心逻辑
generate_compose_file() {
    local cpu_ut=$1
    local cpu_co=$2
    local mem_ut=$3
    local speed_in=$4

    mkdir -p "$BASE_DIR"
    
    cat <<EOF > "$COMPOSE_FILE"
services:
  lookbusy:
    image: fogforest/lookbusy:latest
    container_name: lookbusy
    hostname: lookbusy
    restart: always
    environment:
      - TZ=Asia/Shanghai
      - CPU_UTIL=$cpu_ut
      - CPU_CORE=$cpu_co
EOF

    if [ "$mem_ut" != "0" ] && [ -n "$mem_ut" ]; then
        echo "      - MEM_UTIL=$mem_ut" >> "$COMPOSE_FILE"
    fi
    if [ "$speed_in" != "0" ] && [ -n "$speed_in" ]; then
        echo "      - SPEEDTEST_INTERVAL=$speed_in" >> "$COMPOSE_FILE"
    fi
}

# 1. 部署启动
deploy_lookbusy() {
    check_dependencies
    clear
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}      Docker Compose 部署启动 LookBusy    ${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
    
    echo -ne "${YELLOW}1. 请设置 CPU 期望占用百分比 [默认: 10-20] (支持固定值如15或范围): ${RESET}"
    read -r input_cpu_util
    [[ -z "$input_cpu_util" ]] && input_cpu_util="10-20"

    echo -ne "${YELLOW}2. 请设置 参与负载的 CPU 核心数 [默认: 1] (打满请填全部核心数): ${RESET}"
    read -r input_cpu_core
    [[ -z "$input_cpu_core" ]] && input_cpu_core="1"

    echo -ne "${YELLOW}3. 请设置 内存占用百分比 [默认: 15] (不跑内存填0): ${RESET}"
    read -r input_mem_util
    [[ -z "$input_mem_util" ]] && input_mem_util="15"

    echo -ne "${YELLOW}4. 请设置 网络测速波动的间隔时间 (单位: 分钟) [默认: 120]: ${RESET}"
    read -r input_speed_int
    [[ -z "$input_speed_int" ]] && input_speed_int="120"

    echo -e "${GREEN}-----------------------------------------${RESET}"
    echo -e "${CYAN}正在配置并写入 docker-compose.yml ...${RESET}"
    generate_compose_file "$input_cpu_util" "$input_cpu_core" "$input_mem_util" "$input_speed_int"

    echo -e "${CYAN}正在通过 Docker Compose 启动容器集群...${RESET}"
    cd "$BASE_DIR" && docker compose up -d

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✔ LookBusy Compose 部署并启动成功！${RESET}"
    else
        echo -e "${RED}❌ 启动失败，请检查 Docker Compose 环境。${RESET}"
    fi
}

# 2. 更新容器
update_lookbusy() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在拉取最新 fogforest/lookbusy 镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    echo -e "${YELLOW}正在无损重启并重建容器...${RESET}"
    docker compose up -d --remove-orphans
    echo -e "${GREEN}✔ 容器更新完成！${RESET}"
}

# 3. 卸载容器
uninstall_lookbusy() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}提示: 未检测到任何部署文件。${RESET}"
        return
    fi
    echo -ne "${RED}危险警告：确定要完全卸载并删除 LookBusy 容器及配置文件吗？(y/n): ${RESET}"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        cd "$BASE_DIR" && docker compose down
        rm -rf "$BASE_DIR"
        echo -e "${GREEN}✔ 容器已销毁，且本地工作目录已彻底抹除。${RESET}"
    else
        echo -e "${YELLOW}操作已取消。${RESET}"
    fi
}

# 4. 启动容器
start_lookbusy() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到部署集群，请先部署。${RESET}"
        return
    fi
    cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}✔ 容器集群已恢复启动${RESET}"
}

# 5. 停止容器
stop_lookbusy() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到部署集群。${RESET}"
        return
    fi
    cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}✔ 容器集群已受控停止${RESET}"
}

# 6. 重启容器
restart_lookbusy() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到部署集群。${RESET}"
        return
    fi
    cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}✔ 容器集群已完成重启${RESET}"
}

# 7. 查看日志
view_logs() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到部署集群，无法提取日志。${RESET}"
        return
    fi
    echo -e "${CYAN}正在精准追踪 Docker Compose 实时模拟日志 (按 Ctrl+C 退出追踪):${RESET}"
    cd "$BASE_DIR" && docker compose logs -f
}

# 8. 查看配置
show_config() {
    get_runtime_status
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${GREEN}          LookBusy    配置         ${RESET}"
    echo -e "${GREEN}===================================${RESET}"
    echo -e "${YELLOW}本地工作路径 : ${BASE_DIR}"
    echo -e "${YELLOW}配置实际状态 : $status"
    echo -e "${YELLOW}分配 CPU 核心 : ${cpu_core} 核"
    echo -e "${YELLOW}目标 CPU 负载 : ${cpu_util}%"
    echo -e "${YELLOW}分配内存占用 : ${mem_util}%"
    echo -e "${YELLOW}网络测速频率 : ${speed_int} 分钟/次${RESET}"
    echo -e "${GREEN}===================================${RESET}"
}

# 主菜单逻辑
while true; do
    clear
    get_runtime_status
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}       ◈   LookBusy 防回收保活管理面板   ◈      ${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    # 状态栏拆分，严格每行一个指标
    echo -e "${CYAN}容器状态:${RESET} $status"
    if [ "$cpu_util" != "N/A" ]; then
    echo -e "${CYAN}CPU核心 :${RESET} ${YELLOW}${cpu_core}核${RESET}"
    echo -e "${CYAN}目标负载:${RESET} ${YELLOW}${cpu_util}%${RESET}"
    echo -e "${CYAN}内存占用:${RESET} ${YELLOW}${mem_util}%${RESET}"
    echo -e "${CYAN}测速频率:${RESET} ${YELLOW}${speed_int}分钟/次${RESET}"
    fi
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新容器${RESET}"
    echo -e "${GREEN}3. 卸载容器${RESET}"
    echo -e "${GREEN}4. 启动容器${RESET}"
    echo -e "${GREEN}5. 停止容器${RESET}"
    echo -e "${GREEN}6. 重启容器${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}9. 修改配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice

    case "$choice" in
        1) deploy_lookbusy ;;
        2) update_lookbusy ;;
        3) uninstall_lookbusy ;;
        4) start_lookbusy ;;
        5) stop_lookbusy ;;
        6) restart_lookbusy ;;
        7) view_logs ;;
        8) show_config ;;
        9) deploy_lookbusy ;; 
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请输入 0-9 之间的数字。${RESET}" ;;
    esac

    echo ""
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
