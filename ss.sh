#!/bin/bash
# =================================================================
# Koipy 主控端 Docker Compose 管理面板 
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

BASE_DIR="/opt/koipy-panel"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
CONFIG_FILE="$BASE_DIR/config.yaml"
CONTAINER_NAME="koipy-app"

# 检测依赖
check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
}

# 动态获取容器的状态
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ] || [ "$(docker ps -q -f name=koipy-panel-koipy-1)" ]; then
        status="${GREEN}运行中${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ] || [ "$(docker ps -aq -f name=koipy-panel-koipy-1)" ]; then
        status="${YELLOW}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        bot_token=$(grep "bot-token:" "$CONFIG_FILE" | awk '{print $2}' | sed 's/"//g')
        [[ -z "$bot_token" || "$bot_token" == "null" ]] && bot_token="${RED}未配置 (首次部署需填写)${RESET}"
    else
        bot_token="N/A"
    fi
}

# 部署 Koipy
install_koipy() {
    check_dependencies
    mkdir -p "$BASE_DIR"

    echo -e "${CYAN}====== Koipy 主控参数配置 ======${RESET}"
    
    # 1. 激活码配置
    echo -ne "${YELLOW}请输入 Koipy 激活码 (license): ${RESET}"
    read -r miao_license
    while [[ -z "$miao_license" ]]; do
        echo -ne "${RED}错误: 激活码不能为空，请重新输入: ${RESET}"
        read -r miao_license
    done

    # 2. TG Bot Token 配置
    echo -ne "${YELLOW}请输入 Telegram Bot Token (来自 @BotFather): ${RESET}"
    read -r miao_bot_token
    while [[ -z "$miao_bot_token" ]]; do
        echo -ne "${RED}错误: Bot Token 不能为空，请重新输入: ${RESET}"
        read -r miao_bot_token
    done

    # 3. TG 管理员 ID 配置
    echo -ne "${YELLOW}请输入 Telegram 管理员 UID [默认: 12345678]: ${RESET}"
    read -r miao_admin
    [[ -z "$miao_admin" ]] && miao_admin="12345678"

    # 4. 代理配置
    echo -ne "${YELLOW}请输入 Bot 连接 TG 的 Socks5 代理 [默认: socks5://127.0.0.1:11112]: ${RESET}"
    read -r miao_proxy
    [[ -z "$miao_proxy" ]] && miao_proxy="socks5://127.0.0.1:11112"

    # 5. 内置 Web API 配置
    echo -e "\n${CYAN}--- 内置 Web API 配置 ---${RESET}"
    echo -ne "${YELLOW}是否启用内置 Web 配置 API 服务？(y/n) [默认: n]: ${RESET}"
    read -r use_webapi

    local webapi_enable="false"
    local webapi_addr="127.0.0.1:8899"
    local webapi_pass=""

    if [[ "$use_webapi" == "y" || "$use_webapi" == "Y" ]]; then
        webapi_enable="true"
        echo -ne "${YELLOW}请输入 WebAPI 监听地址和端口 [默认: 127.0.0.1:8899]: ${RESET}"
        read -r webapi_addr
        [[ -z "$webapi_addr" ]] && webapi_addr="127.0.0.1:8899"

        echo -ne "${YELLOW}请输入 WebAPI 访问密码: ${RESET}"
        read -r webapi_pass
        while [[ -z "$webapi_pass" ]]; do
            echo -ne "${RED}错误: 启用 API 必须设置密码，请重新输入: ${RESET}"
            read -r webapi_pass
        done
    fi

    # 6. 订阅转换多后端配置 (新增后端地址自定义)
    echo -e "\n${CYAN}--- 订阅转换 (Subconverter / Sub-Store) 配置 ---${RESET}"
    echo -ne "${YELLOW}是否启用订阅转换服务？(y/n) [默认: n]: ${RESET}"
    read -r use_subcv

    local sub_enable="false"
    local sub_mode="builtin"
    local sub_backend="http://\$Host:\$Port/sub?target=\$Target&new_name=true&url=\$EncodedURL"
    local sub_host="127.0.0.1"
    local sub_port="25500"

    if [[ "$use_subcv" == "y" || "$use_subcv" == "Y" ]]; then
        sub_enable="true"
        echo -e "${YELLOW}请选择订阅转换后端类型:${RESET}"
        echo -e "  ${CYAN}1.${RESET} 内置转换器 (builtin，无需额外填后端地址)"
        echo -e "  ${CYAN}2.${RESET} 经典 Subconverter (subconverter)"
        echo -e "  ${CYAN}3.${RESET} 高级 Sub-Store (substore)"
        echo -ne "${YELLOW}请选择 (1-3) [默认: 1]: ${RESET}"
        read -r sub_choice

        case "$sub_choice" in
            2)
                sub_mode="subconverter"
                sub_backend="http://\$Host:\$Port/sub?target=\$Target&new_name=true&url=\$EncodedURL"
                
                echo -ne "${YELLOW}请输入 Subconverter 后端 IP 或域名 [默认: 127.0.0.1]: ${RESET}"
                read -r input_sub_host
                [[ ! -z "$input_sub_host" ]] && sub_host="$input_sub_host"
                
                echo -ne "${YELLOW}请输入 Subconverter 端口 [默认: 25500]: ${RESET}"
                read -r input_sub_port
                [[ ! -z "$input_sub_port" ]] && sub_port="$input_sub_port"
                ;;
            3)
                sub_mode="substore"
                sub_backend="http://\$Host:\$Port/download/sub?target=\$Target&url=\$EncodedURL&fakeSub=true"
                sub_port="3000" # sub-store 默认推断端口通常为 3000
                
                echo -ne "${YELLOW}请输入 Sub-Store 后端 IP 或域名 [默认: 127.0.0.1]: ${RESET}"
                read -r input_sub_host
                [[ ! -z "$input_sub_host" ]] && sub_host="$input_sub_host"
                
                echo -ne "${YELLOW}请输入 Sub-Store 端口 [默认: 3000]: ${RESET}"
                read -r input_sub_port
                [[ ! -z "$input_sub_port" ]] && sub_port="$input_sub_port"
                ;;
            *)
                sub_mode="builtin"
                sub_backend="http://\$Host:\$Port/sub?target=\$Target&new_name=true&url=\$EncodedURL"
                ;;
        esac
    fi

    # 7. Miaospeed 后端自定义配置
    echo -e "\n${CYAN}--- Miaospeed 测试后端配置 ---${RESET}"
    echo -ne "${YELLOW}是否自定义 Miaospeed 后端连接参数？(y/n) [默认: n，使用本地默认值]: ${RESET}"
    read -r custom_slave

    local slave_id="localmiaospeed"
    local slave_addr="127.0.0.1:8765"
    local slave_token="3R{XBBikNC{Nv01u"
    local slave_path="/miaospeed"
    local slave_comment="本地miaospeed后端"

    if [[ "$custom_slave" == "y" || "$custom_slave" == "Y" ]]; then
        echo -ne "${YELLOW}1. 请输入后端唯一 ID [默认: localmiaospeed]: ${RESET}"
        read -r input_id
        [[ ! -z "$input_id" ]] && slave_id="$input_id"

        echo -ne "${YELLOW}2. 请输入后端连接地址 (host:port) [默认: 127.0.0.1:8765]: ${RESET}"
        read -r input_addr
        [[ ! -z "$input_addr" ]] && slave_addr="$input_addr"

        echo -ne "${YELLOW}3. 请输入后端连接 Token (密码): ${RESET}"
        read -r input_token
        while [[ -z "$input_token" ]]; do
            echo -ne "${RED}错误: Token 不能为空，请重新输入: ${RESET}"
            read -r input_token
        done
        slave_token="$input_token"

        echo -ne "${YELLOW}4. 请输入 WebSocket 连接路径 (Path) [默认: /miaospeed]: ${RESET}"
        read -r input_path
        [[ ! -z "$input_path" ]] && slave_path="$input_path"

        echo -ne "${YELLOW}5. 请输入后端备注名称 [默认: 自定义测试后端]: ${RESET}"
        read -r input_comment
        if [[ -z "$input_comment" ]]; then
            slave_comment="自定义测试后端"
        else
            slave_comment="$input_comment"
        fi
    fi

    # 架构自动选择
    local miao_image="koipy/koipy:latest"
    if [[ "$(uname -m)" == "aarch64" ]]; then
        miao_image="koipy/koipy:arm64"
    fi

    # 动态生成明晰干净的 docker-compose.yml 
    cat <<EOF > "$COMPOSE_FILE"
services:
  koipy:
    stdin_open: true
    tty: true
    container_name: ${CONTAINER_NAME}
    network_mode: host
    restart: always
    volumes:
      - ${CONFIG_FILE}:/app/config.yaml
    image: ${miao_image}
EOF

    # 自动组装精简高可读的 config.yaml
    cat <<EOF > "$CONFIG_FILE"
license: "${miao_license}"
admin:
- ${miao_admin}
network:
  httpProxy: ""
  socks5Proxy: ""
  userAgent: "ClashMetaForAndroid/2.8.9.Meta Mihomo/0.16"
subscription:
  age:
    enable: false
    secretKey: ""
    publicKey: ""
    publicKeyHeader: X-Age-Public-Key
webapi:
  enable: ${webapi_enable}
  address: ${webapi_addr}
  password: "${webapi_pass}"
  tls: false
  tlsCertFile: ""
  tlsKeyFile: ""
  allowOrigins:
  - http://127.0.0.1:8899
  - http://localhost:8899
bot:
  bot-token: "${miao_bot_token}"
  api-id: null
  api-hash: null
  proxy: ${miao_proxy}
  ipv6: false
  antiGroup: false
  strictMode: false
  bypassMode: false
  parseMode: MARKDOWN
  inviteGroup: []
  cacheTime: 60
  echoLimit: 0.8
image:
  speedFormat: "byte/decimal"
  compress: false
  emoji:
    enable: true
    source: TwemojiLocalSource
  font: ./resources/alibaba-Regular.otf
  pixelThreshold: 2500x3500
  title: 节点测试机器人
  logo: true
  showUnsafeTips: true
  watermark:
    enable: true
    text: koipy
    size: 64
    alpha: 32
runtime:
  entrance: true
  duration: 10
  ipstack: true
  pingURL: https://www.gstatic.com/generate_204
  speedFiles:
  - https://dl.google.com/dl/android/studio/install/3.4.1.0/android-studio-ide-183.5522156-windows.exe
  speedNodes: 300
  speedThreads: 4
  output: image
  realtime: false
slaveConfig:
  healthCheck:
    numSamples: 10
    showStatusStyle: "default"
    autoHideOnFailure: false
  showID: true
  speedScheduling: pipeline
  geoClustering: true
  slaves:
    - type: miaospeed
      id: "${slave_id}"
      token: "${slave_token}"
      address: "${slave_addr}"
      path: "${slave_path}"
      skipCertVerify: true
      tls: true
      comment: "${slave_comment}"
      hidden: false
      option:
        downloadDuration: 8
        downloadThreading: 4
        downloadURL: https://dl.google.com/dl/android/studio/install/3.4.1.0/android-studio-ide-183.5522156-windows.exe
        pingAddress: https://cp.cloudflare.com/generate_204
        pingAverageOver: 3
        stunURL: udp://stun.ideasip.com:3478
        taskRetry: 3
subconverter:
  enable: ${sub_enable}
  mode: ${sub_mode}
  template:
    backend: "${sub_backend}"
  defaults:
    target: ClashMeta
    host: "${sub_host}"
    port: ${sub_port}
EOF

    # 防呆：建立文件并授权
    touch "$CONFIG_FILE"
    chmod -R 777 "$BASE_DIR"

    echo -e "${YELLOW}正在通过 Docker Compose 启动 Koipy 主控服务...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${GREEN}=============================================${RESET}"
    echo -e "${GREEN}      Koipy 主控部署成功！                    ${RESET}"
    echo -e "${GREEN}=============================================${RESET}"
    echo -e "${YELLOW}配置文件路径 : ${CONFIG_FILE}${RESET}"
    echo -e "${YELLOW}当前转换模式 : ${sub_mode}${RESET}"
    [[ "$sub_enable" == "true" && "$sub_mode" != "builtin" ]] && echo -e "${YELLOW}转换后端地址 : ${sub_host}:${sub_port}${RESET}"
    echo -e "${YELLOW}已绑定后端 ID : ${slave_id} (${slave_comment})${RESET}"
    echo -e "${GREEN}=============================================${RESET}"
}

# 更新服务
update_koipy() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件！${RESET}"
        return
    fi
    cd "$BASE_DIR" && docker compose pull && docker compose up -d --remove-orphans
    echo -e "${GREEN}更新完成！${RESET}"
}

# 卸载服务
uninstall_koipy() {
    get_status_info
    echo -ne "${YELLOW}确定要卸载并删除 Koipy 主控容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已停止并移除。${RESET}"
            
            # 第二层确认
            echo -ne "${YELLOW}是否同时删除主控配置文件目录 [${BASE_DIR}]？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}所有配置及文件已彻底清理干净。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_koipy() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}主控已启动${RESET}"; }
stop_koipy() { cd "$BASE_DIR" && docker compose stop && echo -e "${YELLOW}主控已停止${RESET}"; }
restart_koipy() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}主控已重启${RESET}"; }
logs_koipy() { cd "$BASE_DIR" && docker compose logs -f; }

show_info() {
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}Koipy 主控状态       : ${status}"
    echo -e "${YELLOW}Bot Token 密文       : ${bot_token}"
    echo -e "${YELLOW}主控环境绝对路径     : ${BASE_DIR}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    ◈  Koipy 主控管理面板  ◈    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}Koipy 主控状态  : ${status}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新服务${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动服务${RESET}"
    echo -e "${GREEN}5. 停止服务${RESET}"
    echo -e "${GREEN}6. 重启服务${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_koipy ;;
        2) update_koipy ;;
        3) uninstall_koipy ;;
        4) start_koipy ;;
        5) stop_koipy ;;
        6) restart_koipy ;;
        7) logs_koipy ;;
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
