#!/bin/bash

# ================== 颜色定义 ==================
green="\033[1;32m"
red="\033[1;31m"
yellow="\033[1;33m"
purple "\033[1;35m"
skyblue="\033[1;36m"
re="\033[0m"

# ================== 基础环境变量 ==================
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
export SECRET=${SECRET:-$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32)}
WORKDIR="$HOME/mtp"

# ================== 工具函数 ==================
red_echo() { echo -e "${red}$1${re}"; }
green_echo() { echo -e "${green}$1${re}"; }
yellow_echo() { echo -e "${yellow}$1${re}"; }
purple_echo() { echo -e "${purple}$1${re}"; }

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://ip6.n0at.com" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP"
}

random_port() {
    shuf -i 2000-65000 -n 1
}

# 针对普通 VPS 的端口检查
check_vps_port() {
    local port=$1
    while [[ -n $(lsof -i :$port 2>/dev/null) ]]; do
        red_echo "${port} 端口已经被其他程序占用，请更换端口重试。"
        read -p "请输入新端口（直接回车使用随机端口）: " port
        [[ -z $port ]] && port=$(random_port) && green_echo "使用随机端口: $port"
    done
    echo "$port"
}

# 针对 Devil (Serv00) 环境的端口检查与申请
check_devil_port () {
    port_list=$(devil port list)
    tcp_ports=$(echo "$port_list" | grep -c "tcp")
    udp_ports=$(echo "$port_list" | grep -c "udp")

    if [[ $tcp_ports -lt 1 ]]; then
        yellow_echo "没有可用的 TCP 端口，正在尝试自动调整..."
        if [[ $udp_ports -ge 3 ]]; then
            udp_port_to_delete=$(echo "$port_list" | awk '/udp/ {print $1}' | head -n 1)
            devil port del udp "$udp_port_to_delete" >/dev/null 2>&1
            green_echo "已自动释放无用 UDP 端口: $udp_port_to_delete"
        fi

        while true; do
            local rand_p=$(shuf -i 10000-65535 -n 1)
            result=$(devil port add tcp "$rand_p" 2>&1)
            if [[ $result == *"Ok"* ]]; then
                green_echo "成功申请 TCP 端口: $rand_p"
                MTP_PORT=$rand_p
                break
            fi
        done
    else
        MTP_PORT=$(echo "$port_list" | awk '/tcp/ {print $1}' | sed -n '1p')
    fi
    devil binexec on >/dev/null 2>&1
}

install_lsof() {
    if ! command -v lsof &>/dev/null; then
        if [ -f "/etc/debian_version" ]; then
            apt update && apt install -y lsof
        elif [ -f "/etc/alpine-release" ]; then
            apk add lsof
        fi
    fi
}

# ================== 安装逻辑 ==================
download_and_run_mtg() {
    local arch="amd64"
    cmd=$(uname -m)
    if [ "$cmd" == "386" ]; then arch="386"; fi
    if [ "$cmd" == "arm" ]; then arch="arm"; fi
    if [ "$cmd" == "aarch64" ]; then arch="arm64"; fi

    mkdir -p "$WORKDIR"
    pkill -9 mtg >/dev/null 2>&1

    # 下载 whunt1 编译的 mtg 二进制文件
    yellow_echo "正在下载 mtg 核心组件..."
    wget -q -O "${WORKDIR}/mtg" "https://github.com/whunt1/onekeymakemtg/raw/master/builds/ccbuilds/mtg-linux-$arch"
    
    if [ ! -s "${WORKDIR}/mtg" ]; then
        red_echo "下载核心失败，请检查网络！"
        return 1
    fi
    
    chmod +x "${WORKDIR}/mtg"
    cd "$WORKDIR" || return

    # 运行服务
    nohup ./mtg run -b 0.0.0.0:$MTP_PORT "$SECRET" --stats-bind=127.0.0.1:$((MTP_PORT + 1)) >/dev/null 2>&1 &
    
    # 创建守护/重启脚本
    cat > "${WORKDIR}/restart.sh" <<EOF
#!/bin/bash
pkill mtg
cd ${WORKDIR}
nohup ./mtg run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:$((MTP_PORT + 1)) >/dev/null 2>&1 &
EOF
    chmod +x "${WORKDIR}/restart.sh"
    return 0
}

core_install() {
    purple_echo "正在安装 MTProto 代理...\n"
    
    # 区分是否为特制的 mtp/Devil 环境
    if [[ "$HOSTNAME" =~ mtp ]] || command -v devil &>/dev/null; then
        check_devil_port
        IP_LIST=($(devil vhost list | awk '/^[0-9]+/ {print $1}'))
        IP1=${IP_LIST[0]:-$(get_public_ip)}
    else
        install_lsof
        read -p "请输入 MTProto 代理端口 (回车使用随机端口): " user_port
        [[ -z $user_port ]] && user_port=$(random_port)
        MTP_PORT=$(check_vps_port "$user_port")
        IP1=$(get_public_ip)
    fi

    if download_and_run_mtg; then
        purple_echo "\n🎉 TG 分享链接:"
        LINKS="tg://proxy?server=$IP1&port=$MTP_PORT&secret=$SECRET"
        green_echo "$LINKS\n"
        echo -e "$LINKS" > "${WORKDIR}/link.txt"
        purple_echo "一键卸载命令: rm -rf $WORKDIR && pkill mtg"
    fi
}

# ================== 主菜单循环 ==================
while true; do
    clear
    echo -e "${green}==== MTProto 管理菜单 ====${re}"
    echo -e "${green}1. 安装 MTProto${re}"
    echo -e "${green}2. 卸载 MTProto${re}"
    echo -e "${green}0. 退出${re}"
    read -p "$(echo -e ${green}请选择:${re}) " choice

    case $choice in
        1)
            clear
            core_install
            read -p "按回车返回菜单..."
            ;;
        2)
            clear
            pkill -9 mtg >/dev/null 2>&1
            rm -rf "$WORKDIR"
            red_echo "MTProto 已彻底从系统中卸载！"
            read -p "按回车返回菜单..."
            ;;
        0)
            exit 0
            ;;
        *)
            red_echo "无效输入！"
            sleep 1
            ;;
    esac
done
