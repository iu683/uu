#!/bin/bash
# ========================================
# Windows Docker 一键管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_NAME="windows"
APP_DIR="/opt/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}未检测到 Docker，正在安装...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version &>/dev/null; then
        echo -e "${RED}未检测到 Docker Compose v2，请升级 Docker${RESET}"
        exit 1
    fi
}

check_kvm() {
    if [ ! -e /dev/kvm ]; then
        echo -e "${RED}未检测到 /dev/kvm，服务器不支持虚拟化${RESET}"
        exit 1
    fi
}

check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        echo -e "${RED}端口 $1 已被占用，请更换端口！${RESET}"
        return 1
    fi
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

menu() {
    while true; do
        clear
        echo -e "${GREEN}=== Windows Docker 管理菜单 ===${RESET}"
        echo -e "${GREEN}1) 安装启动${RESET}"
        echo -e "${GREEN}2) 更新${RESET}"
        echo -e "${GREEN}3) 重启${RESET}"
        echo -e "${GREEN}4) 查看日志${RESET}"
        echo -e "${GREEN}5) 查看状态${RESET}"
        echo -e "${GREEN}6) 卸载(含数据)${RESET}"
        echo -e "${GREEN}0) 退出${RESET}"
        read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

        case $choice in
            1) install_app ;;
            2) update_app ;;
            3) restart_app ;;
            4) view_logs ;;
            5) check_status ;;
            6) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1 ;;
        esac
    done
}

install_app() {

    check_docker
    check_kvm

    mkdir -p "$APP_DIR/storage"

    if [ -f "$COMPOSE_FILE" ]; then
        echo -e "${YELLOW}检测到已安装，是否覆盖安装？(y/n)${RESET}"
        read confirm
        [[ "$confirm" != "y" ]] && return
    fi

    echo
    echo -e "${GREEN}请选择 Windows 系统版本${RESET}"
    echo -e "${GREEN}1) Windows 11${RESET}"
    echo -e "${GREEN}2) Windows 10${RESET}"
    echo -e "${GREEN}3) Windows Server 2022${RESET}"
    echo -e "${GREEN}4) 自定义版本${RESET}"
    read -p "请选择 [默认:1]: " sys_choice

    case $sys_choice in
        2)
            VERSION="10"
            ;;
        3)
            VERSION="2022"
            ;;
        4)
            read -p "请输入 Windows 版本号 (如: 11): " VERSION
            if [ -z "$VERSION" ]; then
                VERSION="11"
            fi
            ;;
        *)
           VERSION="11"
           ;;
    esac

    read -p "请输入 Web 控制台端口 [默认:8006]: " input_port
    PORT=${input_port:-8006}
    check_port "$PORT" || return

    read -p "请输入 RDP 端口 [默认:3389]: " input_rdp
    RDP_PORT=${input_rdp:-3389}
    check_port "$RDP_PORT" || return

    read -p "请输入 Windows 用户名 [默认:bill]: " input_user
    USERNAME=${input_user:-bill}

    read -p "请输入 Windows 密码 [默认:gates]: " input_pass
    PASSWORD=${input_pass:-gates}

    read -p "请输入 CPU 核心数 [默认:4]: " input_cpu
    CPU=${input_cpu:-4}

    read -p "请输入内存大小 [默认:8G]: " input_ram
    RAM=${input_ram:-8G}

    read -p "请输入磁盘大小 [默认:64G]: " input_disk
    DISK=${input_disk:-64G}

    cat > "$COMPOSE_FILE" <<EOF
services:
  windows:
    image: dockurr/windows
    container_name: windows
    restart: unless-stopped
    environment:
      VERSION: "$VERSION"
      USERNAME: "$USERNAME"
      PASSWORD: "$PASSWORD"
      LANGUAGE: "CN"
      RAM_SIZE: "$RAM"
      CPU_CORES: "$CPU"
      DISK_SIZE: "$DISK"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - "${PORT}:8006"
      - "${RDP_PORT}:3389/tcp"
      - "${RDP_PORT}:3389/udp"
    volumes:
      - ./storage:/storage
EOF

    cd "$APP_DIR" || exit
    docker compose up -d

    SERVER_IP=$(get_public_ip)

    echo
    echo -e "${GREEN}✅ Windows 已启动${RESET}"
    echo -e "${YELLOW}🌐 Web 控制台: http://${SERVER_IP}:${PORT}${RESET}"
    echo -e "${YELLOW}🖥 RDP: ${SERVER_IP}:${RDP_PORT}${RESET}"
    echo -e "${GREEN}👤 用户名: $USERNAME${RESET}"
    echo -e "${GREEN}🔑 密码: $PASSWORD${RESET}"
    echo -e "${GREEN}💿 系统版本: Windows $VERSION${RESET}"

    read -p "按回车返回菜单..."
}

update_app() {
    cd "$APP_DIR" || return
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✅ Windows 更新完成${RESET}"
    read -p "按回车返回菜单..."
}

restart_app() {
    docker restart windows
    echo -e "${GREEN}✅ Windows 已重启${RESET}"
    read -p "按回车返回菜单..."
}

view_logs() {
    docker logs -f windows
}

check_status() {
    docker ps | grep windows
    read -p "按回车返回菜单..."
}

uninstall_app() {
    cd "$APP_DIR" || return
    docker compose down -v
    rm -rf "$APP_DIR"
    echo -e "${RED}✅ Windows 已彻底卸载${RESET}"
    read -p "按回车返回菜单..."
}

menu
