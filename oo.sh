#!/bin/bash
# =================================================================
# Watchtower 自动更新服务 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="watchtower"
BASE_DIR="/opt/watchtower"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器状态、映射和数据目录
get_status_info() {
    # 1. 检查容器状态
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${YELLOW}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    # 2. 如果容器存在，从容器状态中提取信息
    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        img_version=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$img_version" ]] && img_version="已安装"
    else
        img_version="${RED}未安装${RESET}"
    fi
}

# 部署 Watchtower
install_watchtower() {
    check_dependencies
    
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    
    echo -ne "${YELLOW}请输入 Telegram Bot Token [必填]: ${RESET}"
    read -r bot_token
    while [[ -z "$bot_token" ]]; do
        echo -e "${RED}错误: Bot Token 不能为空！${RESET}"
        echo -ne "${YELLOW}请重新输入 Telegram Bot Token: ${RESET}"
        read -r bot_token
    done

    echo -ne "${YELLOW}请输入 Telegram Chat ID [必填]: ${RESET}"
    read -r chat_id
    while [[ -z "$chat_id" ]]; do
        echo -e "${RED}错误: Chat ID 不能为空！${RESET}"
        echo -ne "${YELLOW}请重新输入 Telegram Chat ID: ${RESET}"
        read -r chat_id
    done

    echo -ne "${YELLOW}请输入检查更新的 Cron 定时表达式 [默认: 0 0 0 * * * (每天零点)]: ${RESET}"
    read -r custom_schedule
    [[ -z "$custom_schedule" ]] && custom_schedule="0 0 0 * * *"

    echo -e "${YELLOW}请选择通知策略:${RESET}"
    echo -e "  ${GREEN}1)${RESET} 仅在【发生镜像更新/报错】时通知 (${YELLOW}推荐，防刷屏${RESET})"
    echo -e "  ${GREEN}2)${RESET} 每次检查完都通知 (即使没有更新也会发“一切正常”)"
    echo -ne "${YELLOW}请选择 (默认 1): ${RESET}"
    read -r notify_policy
    if [[ "$notify_policy" == "2" ]]; then
        notification_level="info"
    else
        notification_level="warn" # 设为 warn 时，普通的无更新 info 日志将被过滤
    fi

    # 终极全中文汉化 Telegram Markdown 模板
    # 智能识别底层日志并将核心的 "updated successfully" 翻译为中文并高亮容器名
    tg_template='{{- if . -}}
📢 *Docker 容器自动更新报告*
📅 时间: `{{ (index . 0).Time.Format "2006-01-02 15:04:05" }}`
 
{{ range . -}}
{{- if contains .Message "updated successfully" -}}
🚀 *[更新成功]* ➔ `{{ slice .Message 10 }}`
{{- else if contains .Message "Found new" -}}
🔄 *[发现新镜像]* ➔ `{{ .Message }}`
{{- else if contains .Message "Stopping" -}}
🛑 *[正在停止旧容器]* ➔ `{{ .Message }}`
{{- else if contains .Message "Removing" -}}
🗑️ *[正在清理旧容器]* ➔ `{{ .Message }}`
{{- else if eq .Level "error" -}}
❌ *[更新失败/错误]* ➔ `{{ .Message }}`
{{- else if eq .Level "warn" -}}
⚠️ *[警告]* ➔ `{{ .Message }}`
{{- else -}}
ℹ️ *[状态]* ➔ `{{ .Message }}`
{{- end }}
{{ end -}}
{{- else -}}
✨ 检查完毕，所有容器已是最新。
{{- end -}}'

    # 2. 动态生成符合要求的 docker-compose.yml 配置文件
    echo -e "${YELLOW}正在生成符合要求的 docker-compose.yml 配置文件...${RESET}"
    cat <<EOF > "$COMPOSE_FILE"
services:
  watchtower:
    image: ghcr.io/naiba-forks/watchtower
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      TZ: Asia/Shanghai
      WATCHTOWER_LABEL_ENABLE: "true"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_INCLUDE_RESTARTING: "true"
      WATCHTOWER_NOTIFICATIONS_LEVEL: "${notification_level}"
      WATCHTOWER_NOTIFICATION_URL: "telegram://${bot_token}@telegram?chats=${chat_id}"
      WATCHTOWER_NOTIFICATION_TEMPLATE: '${tg_template}'
    command: --schedule "${custom_schedule}"
EOF

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Watchtower 服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${YELLOW}等待容器初始化 (约3秒)...${RESET}"
    sleep 3

    get_status_info

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Watchtower 部署成功！     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}定时检查规则   : ${custom_schedule}${RESET}"
    echo -e "${YELLOW}通知过滤策略   : $( [ "$notification_level" = "warn" ] && echo "仅更新与错误时通知" || echo "每次检查均通知" )${RESET}"
    echo -e "${YELLOW}运行模式       : 标签过滤模式 (仅更新带特定 label 的容器)${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${CYAN}💡 使用提示:${RESET}"
    echo -e "${GREEN}由于你开启了标签模式，如果需要让 Watchtower 帮你的容器自动更新，${RESET}"
    echo -e "${GREEN}docker run 命令里加一行:${RESET}"
    echo -e "${YELLOW}--label com.centurylinklabs.watchtower.enable=true${RESET}"
    echo -e "${GREEN}你需要在那些容器的${RESET} ${YELLOW}docker-compose.yml${RESET}${GREEN}里加入以下标签：${RESET}"
    echo -e "${YELLOW}    labels:${RESET}"
    echo -e "${YELLOW}      - com.centurylinklabs.watchtower.enable=true${RESET}"
    echo -e "${RED}加完标签并重启该容器后，Watchtower 才能在定时时间识别并帮它更新。${GREEN}"
    echo -e "${GREEN}================================${RESET}"
}

# 更新 Watchtower 镜像
update_watchtower() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在从远端拉取 Watchtower 最新镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！容器已处于最新状态。${RESET}"
}

# 卸载 Watchtower
uninstall_watchtower() {
    echo -ne "${YELLOW}确定要卸载并删除 Watchtower 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            echo -ne "${YELLOW}是否同时删除配置文件？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置目录已彻底清理。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_watchtower() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}容器已启动${RESET}"; }
stop_watchtower() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}容器已停止${RESET}"; }
restart_watchtower() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}容器已重启${RESET}"; }
logs_watchtower() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}镜像名称       : ${img_version}${RESET}"
    echo -e "${YELLOW}运行模式       : 标签过滤自动更新 (WATCHTOWER_LABEL_ENABLE=true)${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Watchtower 管理面板  ◈   ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}模式 :${RESET} ${YELLOW}标签过滤更新${RESET}"
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
        1) install_watchtower ;;
        2) update_watchtower ;;
        3) uninstall_watchtower ;;
        4) start_watchtower ;;
        5) stop_watchtower ;;
        6) restart_watchtower ;;
        7) logs_watchtower ;;
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
