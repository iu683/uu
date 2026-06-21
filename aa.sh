#!/bin/bash
# =================================================================
# Docker Windows 虚拟机服务 Compose 独立管理面板 (全参数定制版)
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

CONTAINER_NAME="windows"
BASE_DIR="/opt/docker-windows"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
ENV_FILE="$BASE_DIR/.env"

# 检测依赖与 KVM 硬件加速
check_environment() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}错误: 未检测到 Docker，请先安装 Docker！${RESET}"
        exit 1
    fi
    # 核心硬校验：KVM 是否可用
    if [ ! -e /dev/kvm ]; then
        echo -e "${RED}⚠️ 严重警告: 宿主机未检测到 /dev/kvm 设备！${RESET}"
        echo -e "${YELLOW}Windows 虚拟机将无法获得硬件加速，启动会极其缓慢甚至失败。${RESET}"
        echo -e "${YELLOW}请确保您的 VPS 开启了嵌套虚拟化 (Nested Virtualization)。${RESET}"
        echo -ne "${RED}是否仍然强制继续部署？(y/n): ${RESET}"
        read -r force_kvm
        if [[ "$force_kvm" != "y" && "$force_kvm" != "Y" ]]; then
            exit 1
        fi
    fi
}

# 动态获取容器状态与映射端口
get_status_info() {
    if [ "$(docker ps -q -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${GREEN}运行中 (正在提供虚拟化集群服务)${RESET}"
    elif [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        status="${RED}已停止${RESET}"
    else
        status="${RED}未部署${RESET}"
    fi

    if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
        # 动态抓取映射到容器 8006(WebVNC) 和 3389(RDP) 的实际端口
        web_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8006/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        rdp_port=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "3389/tcp") 0).HostPort}}' "$CONTAINER_NAME" 2>/dev/null)
        [[ -z "$web_port" ]] && web_port="8006"
        [[ -z "$rdp_port" ]] && rdp_port="3389"
        port_display="WebVNC: ${web_port} | RDP: ${rdp_port}"
    else
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

# 部署 Windows 虚拟机
install_windows() {
    check_environment
    mkdir -p "$BASE_DIR"
    DETECT_IP=$(get_public_ip)

    clear
    echo -e "${CYAN}====================================================${RESET}"
    echo -e "${CYAN}          欢迎使用 Windows 容器配置向导               ${RESET}"
    echo -e "${CYAN}====================================================${RESET}"

    # 1. 选择版本
    echo -e "\n${YELLOW}💡 可选版本列表:${RESET}"
    echo -e "   [11]  Win 11 专业版 (默认)    [11l] Win 11 LTSC 精简版"
    echo -e "   [10]  Win 10 专业版           [10l] Win 10 LTSC 精简版"
    echo -e "   [7u]  Win 7 终极版            [xp]  Win XP 专业版"
    echo -e "   [2025] Windows Server 2025   [2022] Windows Server 2022"
    echo -ne "${GREEN}请选择或输入要下载的 Windows 版本代号 [默认: 11]: ${RESET}"
    read -r win_version
    [[ -z "$win_version" ]] && win_version="11"

    # 2. 选择语言
    echo -ne "${GREEN}请输入语言代号 (CN:中文 | US:英文) [默认: CN]: ${RESET}"
    read -r win_lang
    [[ -z "$win_lang" ]] && win_lang="CN"

    # 3. 配置硬件参数
    echo -ne "${GREEN}配给 CPU 核心数 (宿主机当前可用核心内) [默认: 2]: ${RESET}"
    read -r win_cores
    [[ -z "$win_cores" ]] && win_cores="2"

    echo -ne "${GREEN}配给内存大小 (例如 4G, 8G) [默认: 4G]: ${RESET}"
    read -r win_ram
    [[ -z "$win_ram" ]] && win_ram="4G"

    echo -ne "${GREEN}规划虚拟磁盘大小 (例如 64G, 128G, 256G) [默认: 64G]: ${RESET}"
    read -r win_disk
    [[ -z "$win_disk" ]] && win_disk="64G"

    # 4. 账户安全凭证
    echo -ne "${GREEN}设置 Windows 登录用户名 [默认: admin]: ${RESET}"
    read -r win_user
    [[ -z "$win_user" ]] && win_user="admin"

    echo -ne "${GREEN}设置 Windows 登录密码 [默认: admin123]: ${RESET}"
    read -r win_pass
    [[ -z "$win_pass" ]] && win_pass="admin123"

    # 5. 网络端口定制
    echo -ne "${GREEN}自定义宿主机 Web 浏览器控制台端口 [默认: 8006]: ${RESET}"
    read -r port_web
    [[ -z "$port_web" ]] && port_web="8006"

    echo -ne "${GREEN}自定义宿主机 远程桌面(RDP) 访问端口 [默认: 3389]: ${RESET}"
    read -r port_rdp
    [[ -z "$port_rdp" ]] && port_rdp="3389"

    # 6. 持久化数据路径与宿主机交换文件夹
    mkdir -p "$BASE_DIR/storage" "$BASE_DIR/shared"
    chmod -R 777 "$BASE_DIR/storage" "$BASE_DIR/shared"

    # 写入环境变量文件 .env
    cat <<EOF > "$ENV_FILE"
VERSION=$win_version
LANGUAGE=$win_lang
CPU_CORES=$win_cores
RAM_SIZE=$win_ram
DISK_SIZE=$win_disk
USERNAME=$win_user
PASSWORD=$win_pass
HOST_WEB_PORT=$port_web
HOST_RDP_PORT=$port_rdp
EOF

    # 生成 docker-compose.yml 结构体
    cat <<EOF > "$COMPOSE_FILE"
services:
  windows:
    image: dockurr/windows
    container_name: ${CONTAINER_NAME}
    restart: always
    stop_grace_period: 2m
    ports:
      - "\${HOST_WEB_PORT:-8006}:8006"
      - "\${HOST_RDP_PORT:-3389}:3389/tcp"
      - "\${HOST_RDP_PORT:-3389}:3389/udp"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    environment:
      VERSION: "\${VERSION}"
      LANGUAGE: "\${LANGUAGE}"
      CPU_CORES: "\${CPU_CORES}"
      RAM_SIZE: "\${RAM_SIZE}"
      DISK_SIZE: "\${DISK_SIZE}"
      USERNAME: "\${USERNAME}"
      PASSWORD: "\${PASSWORD}"
    volumes:
      - ./storage:/storage
      - ./shared:/shared
EOF

    echo -e "\n${YELLOW}正在通过 Docker Compose 协同拉起 Windows 容器...${RESET}"
    cd "$BASE_DIR" && docker compose up -d --force-recreate

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}         🎉 Windows 虚拟化容器部署向导完成！          ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}1️⃣ 网页监控地址(WebVNC) : http://${DETECT_IP}:${port_web}${RESET}"
    echo -e "${YELLOW}2️⃣ 微软远程桌面(RDP)    : ${DETECT_IP}:${port_rdp}${RESET}"
    echo -e "${YELLOW}3️⃣ 系统登录用户凭证     : 用户名: ${win_user} | 密码: ${win_pass}${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${CYAN}📂 宿主机文件交互共享夹 : ${BASE_DIR}/shared${RESET}"
    echo -e "   (在 Windows 虚拟机内双击桌面 [Shared] 快捷方式即可看到此文件夹)${RESET}"
    echo -e "${CYAN}💾 虚拟机底层磁盘镜态夹 : ${BASE_DIR}/storage${RESET}"
    echo -e "${RED}💡 提示: 首次启动需要全自动下载 ISO 并进行无人值守安装，需要 10-30 分钟，请点击网页查看下载进度或执行选项 7 查看实时滚动日志。${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 更新虚拟机核心基础设施镜像
update_windows() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在更新 dockurr/windows 核心虚拟化组件镜像...${RESET}"
    cd "$BASE_DIR" && docker compose pull
    docker compose up -d --remove-orphans
    echo -e "${GREEN}虚拟化引擎更新完成！您的虚拟机磁盘数据不受任何影响。${RESET}"
}

# 彻底销毁
uninstall_windows() {
    echo -e "${RED}警告: 卸载如果清理数据，将永久销毁 Windows 内所有的系统盘、C/D盘及全部桌面文件！${RESET}"
    echo -ne "${YELLOW}确定要停用并删除 Windows 容器吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$COMPOSE_FILE" ]; then
            echo -e "${YELLOW}正在安全通知 Windows 进行系统关机下线 (2分钟内宽限期保护)...${RESET}"
            cd "$BASE_DIR" && docker compose down
            echo -e "${GREEN}容器已优雅退出销毁。${RESET}"
            echo -ne "${RED}【高级毁灭风险】是否同时彻底删除本地全量虚拟机磁盘和共享文件夹？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}本地所有 Windows 虚拟磁盘及数据已彻底抹除。${RESET}"
            fi
        else
            docker rm -f "$CONTAINER_NAME" 2>/dev/null
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

start_utils() { cd "$BASE_DIR" && docker compose start && echo -e "${GREEN}虚拟机已开始加电自检启动${RESET}"; }
stop_utils() { cd "$BASE_DIR" && echo -e "${YELLOW}正在向 Windows 发送 ACPI 关机信号并安全保存状态...${RESET}" && docker compose stop && echo -e "${YELLOW}虚拟机已安全关闭断电${RESET}"; }
restart_utils() { cd "$BASE_DIR" && docker compose restart && echo -e "${GREEN}虚拟机已执行冷重置重启${RESET}"; }
logs_utils() { docker logs -f "$CONTAINER_NAME"; }

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW}当前运行状态 : $status"
    echo -e "${YELLOW}配置连接总线 : $port_display"
    echo -e "${YELLOW}当前定制规格 : 核心数:${CPU_CORES:-2}核 | 物理内存:${RAM_SIZE:-4G} | 磁盘:${DISK_SIZE:-64G}"
    echo -e "${YELLOW}对外访问入口 : 管理网页: http://${DETECT_IP}:${HOST_WEB_PORT:-8006}"
    echo -e "${GREEN}====================================================${RESET}"
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}        ◈  Dockurr Windows 虚拟机集群管理面板  ◈     ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${port_display}${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新虚拟化组件镜像${RESET}"
    echo -e "${GREEN}3. 卸载并清空虚拟机${RESET}"
    echo -e "${GREEN}4. 开启虚拟机 (加电)${RESET}"
    echo -e "${GREEN}5. 关闭虚拟机 (ACPI 安全关机)${RESET}"
    echo -e "${GREEN}6. 重启虚拟机 (硬重置)${RESET}"
    echo -e "${GREEN}7. 查看 ISO 下载或安装控制台日志${RESET}"
    echo -e "${GREEN}8. 检查虚拟机硬件配置状态${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_windows ;;
        2) update_windows ;;
        3) uninstall_windows ;;
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
