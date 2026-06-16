#!/bin/bash
# ========================================
# qBittorrent-Nox 一键管理脚本 (支持IP绑定版)
# ========================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

SERVICE_NAME="qbittorrent"
APP_DIR="/opt/qbittorrent"
CONFIG_DIR="$APP_DIR/config"
DOWNLOAD_DIR="$APP_DIR/downloads"
BIN_PATH="/usr/local/bin/qbittorrent-nox"
SERVICE_FILE="/etc/systemd/system/qbittorrent.service"

# 获取真实的运行用户（防止 sudo 误判为 root）
REAL_USER=${SUDO_USER:-$(whoami)}

# 动态获取状态、版本、端口和绑定IP
get_status_info() {
    # 1. 检测运行状态
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        status="${GREEN}已启动${RESET}"
    else
        status="${RED}未运行${RESET}"
    fi

    # 2. 检测版本号
    if [[ -f "$BIN_PATH" ]]; then
        version=$($BIN_PATH --version 2>/dev/null | awk '{print $2}')
        [[ -z "$version" ]] && version="已安装"
    else
        version="${RED}未安装${RESET}"
    fi

    # 3. 检测 WebUI 端口和绑定 IP
    if [[ -f "$SERVICE_FILE" ]]; then
        port_show=$(grep -oE -- '--webui-port=[0-9]+' "$SERVICE_FILE" | cut -d= -f2)
        [[ -z "$port_show" ]] && port_show="8080"
        
        ip_show=$(grep -oE -- '--webui-listen-to=[^ ]+' "$SERVICE_FILE" | cut -d= -f2)
        [[ -z "$ip_show" ]] && ip_show="0.0.0.0 (公网)"
    else
        port_show="N/A"
        ip_show="N/A"
    fi
}

# 端口合法性校验函数
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return 1
    fi
    if ((port < 1 || port > 65535)); then
        echo -e "${RED}错误: 端口范围必须在 1-65535 之间！${RESET}"
        return 1
    fi
    return 0
}

# 从日志中自动提取临时密码
get_qb_password() {
    local log_line log_pass
    log_line=$(sudo journalctl -u "$SERVICE_NAME" --no-pager | grep -Ei "temporary password is:|password was randomly generated:|provided for this session:" | tail -n 1)
    
    if [[ -n "$log_line" ]]; then
        log_pass=$(echo "$log_line" | sed -e 's/.*session://I' -e 's/.*is://I' | tr -d '[:space:].:')
    fi
    
    if [[ -n "$log_pass" ]]; then
        echo -e "${GREEN}${log_pass}${RESET}"
    else
        echo -e "${RED}未找到临时密码（可能已在WebUI中修改、日志已清空，或服务未成功启动）${RESET}"
    fi
}

# 获取公网 IP
get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "127.0.0.1"
}

# 1. 部署 qBittorrent-Nox (支持绑定端口与IP)
install_qbittorrent() {
    if [[ -f "$BIN_PATH" ]]; then
        echo -e "${YELLOW}提示: qBittorrent 已安装在 $BIN_PATH，请勿重复安装。${RESET}"
        return
    fi

    # 输入端口
    echo -ne "${YELLOW}请输入你想要设置的 WebUI 端口号 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"
    if ! validate_port "$custom_port"; then return; fi

    # 输入绑定 IP
    echo -e "${YELLOW}请选择 WebUI 绑定的 IP 地址:${RESET}"
    echo -e "  1) 0.0.0.0   (默认：允许公网/局域网外网访问)"
    echo -e "  2) 127.0.0.1 (安全：仅限本地服务器或反向代理/SSH隧道访问)"
    echo -ne "${YELLOW}请选择选项或直接输入自定义IP [默认: 1]: ${RESET}"
    read -r ip_choice
    
    local listen_ip="0.0.0.0"
    case "$ip_choice" in
        2) listen_ip="127.0.0.1" ;;
        "") listen_ip="0.0.0.0" ;;
        *) [[ -n "$ip_choice" && "$ip_choice" != "1" ]] && listen_ip="$ip_choice" ;;
    esac

    # 检测系统架构决定下载哪个文件
    local arch url_file
    arch=$(uname -m)
    case "$arch" in
        x86_64)      url_file="x86_64-qbittorrent-nox" ;;
        aarch64)     url_file="aarch64-qbittorrent-nox" ;;
        armv7l)      url_file="armv7-qbittorrent-nox" ;;
        armhf)       url_file="armhf-qbittorrent-nox" ;;
        riscv64)     url_file="riscv64-qbittorrent-nox" ;;
        i386|i686)   url_file="x86-qbittorrent-nox" ;;
        *) echo -e "${RED}错误: 暂不支持您的系统架构 ($arch)！${RESET}" && return ;;
    esac

    sudo apt update && sudo apt install -y curl wget

    echo -e "${YELLOW}正在检索 GitHub 最新版本信息...${RESET}"
    local release_json latest_tag expected_sha
    release_json=$(curl -s https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases/latest)
    latest_tag=$(echo "$release_json" | grep -oP '"tag_name": "\K[^"]+')

    if [[ -z "$latest_tag" ]]; then
        echo -e "${RED}错误: 无法获取最新版本号，请稍后再试。${RESET}"
        return
    fi
    echo -e "${GREEN}检测到最新版本标签: ${latest_tag}${RESET}"

    expected_sha=$(echo "$release_json" | grep -A 2 "$url_file" | grep -oP '"body": "sha256:\K[a-f0-9]{64}' || echo "$release_json" | grep -oP "sha256:${url_file}\s+\K[a-f0-9]{64}" || echo "$release_json" | sed -n "/${url_file}/,/^$/p" | grep -oP '[a-f0-9]{64}')
    
    local download_url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${latest_tag}/${url_file}"
    echo -e "${YELLOW}正在从 GitHub 下载最新二进制文件...${RESET}"
    sudo wget -q --show-progress -O "$BIN_PATH" "$download_url"
    if [[ $? -ne 0 || ! -s "$BIN_PATH" ]]; then
        echo -e "${RED}错误: 下载失败！${RESET}" && sudo rm -f "$BIN_PATH" && return
    fi

    if [[ -n "$expected_sha" && ${#expected_sha} -eq 64 ]]; then
        local calculated_sha
        calculated_sha=$(sha256sum "$BIN_PATH" | awk '{print $1}')
        if [[ "$calculated_sha" != "$expected_sha" ]]; then
            echo -e "${RED}错误: SHA256 校验失败！${RESET}" && sudo rm -f "$BIN_PATH" && return
        fi
    fi

    sudo chmod +x "$BIN_PATH"
    sudo mkdir -p "$CONFIG_DIR" "$DOWNLOAD_DIR"
    sudo chown -R "$REAL_USER":"$REAL_USER" "$APP_DIR"
    sudo chmod -R 755 "$APP_DIR"

    echo -e "${YELLOW}创建 systemd 服务文件...${RESET}"
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=qBittorrent Command Line Client (Static Latest)
After=network.target

[Service]
ExecStart=$BIN_PATH --webui-port=${custom_port} --webui-listen-to=${listen_ip} --profile=$CONFIG_DIR
User=$REAL_USER
Restart=on-failure
WorkingDirectory=$DOWNLOAD_DIR

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl start qbittorrent
    sudo systemctl enable qbittorrent

    echo -e "${YELLOW}等待服务启动并生成密码...${RESET}"
    sleep 4

    local display_ip="$listen_ip"
    [[ "$listen_ip" == "0.0.0.0" ]] && display_ip=$(get_public_ip)

    echo -e "\n${GREEN}qBittorrent-Nox 静态版安装完成并已启动!${RESET}"
    echo -e "${YELLOW}WebUI 访问地址: http://${display_ip}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认用户名: admin${RESET}"
    echo -ne "${YELLOW}初始密码: ${RESET}"
    get_qb_password
}

# 2. 自动检查并更新到最新版 (保留历史端口和绑定IP设置)
update_qbittorrent() {
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "${RED}错误: 未检测到已安装的 qBittorrent，请先选择 1 进行安装！${RESET}"
        return
    fi

    local current_port="8080"
    local current_ip="0.0.0.0"
    if [[ -f "$SERVICE_FILE" ]]; then
        current_port=$(grep -oE -- '--webui-port=[0-9]+' "$SERVICE_FILE" | cut -d= -f2)
        [[ -z "$current_port" ]] && current_port="8080"
        current_ip=$(grep -oE -- '--webui-listen-to=[^ ]+' "$SERVICE_FILE" | cut -d= -f2)
        [[ -z "$current_ip" ]] && current_ip="0.0.0.0"
    fi

    echo -e "${YELLOW}正在检测系统架构并获取最新版本...${RESET}"
    local arch url_file
    arch=$(uname -m)
    case "$arch" in
        x86_64)      url_file="x86_64-qbittorrent-nox" ;;
        aarch64)     url_file="aarch64-qbittorrent-nox" ;;
        armv7l)      url_file="armv7-qbittorrent-nox" ;;
        armhf)       url_file="armhf-qbittorrent-nox" ;;
        riscv64)     url_file="riscv64-qbittorrent-nox" ;;
        i386|i686)   url_file="x86-qbittorrent-nox" ;;
        *) echo -e "${RED}错误: 暂不支持您的系统架构 ($arch)！${RESET}" && return ;;
    esac

    local release_json latest_tag expected_sha
    release_json=$(curl -s https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases/latest)
    latest_tag=$(echo "$release_json" | grep -oP '"tag_name": "\K[^"]+')

    if [[ -z "$latest_tag" ]]; then
        echo -e "${RED}错误: 无法获取最新版本号，请稍后再试。${RESET}"
        return
    fi
    echo -e "${GREEN}检测到最新版本标签: ${latest_tag}${RESET}"

    expected_sha=$(echo "$release_json" | grep -A 2 "$url_file" | grep -oP '"body": "sha256:\K[a-f0-9]{64}' || echo "$release_json" | grep -oP "sha256:${url_file}\s+\K[a-f0-9]{64}" || echo "$release_json" | sed -n "/${url_file}/,/^$/p" | grep -oP '[a-f0-9]{64}')

    local tmp_bin="/tmp/qbittorrent-nox.tmp"
    local download_url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${latest_tag}/${url_file}"
    echo -e "${YELLOW}正在下载新版本二进制文件...${RESET}"
    
    sudo wget -q --show-progress -O "$tmp_bin" "$download_url"
    if [[ $? -ne 0 || ! -s "$tmp_bin" ]]; then
        echo -e "${RED}错误: 下载失败，放弃更新。${RESET}" && sudo rm -f "$tmp_bin" && return
    fi

    if [[ -n "$expected_sha" && ${#expected_sha} -eq 64 ]]; then
        local calculated_sha
        calculated_sha=$(sha256sum "$tmp_bin" | awk '{print $1}')
        if [[ "$calculated_sha" != "$expected_sha" ]]; then
            echo -e "${RED}错误: SHA256 校验失败！放弃更新。${RESET}" && sudo rm -f "$tmp_bin" && return
        fi
    fi

    echo -e "${YELLOW}正在应用更新并重启服务...${RESET}"
    sudo systemctl stop qbittorrent
    sudo mv -f "$tmp_bin" "$BIN_PATH"
    sudo chmod +x "$BIN_PATH"
    
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=qBittorrent Command Line Client (Static Latest)
After=network.target

[Service]
ExecStart=$BIN_PATH --webui-port=${current_port} --webui-listen-to=${current_ip} --profile=$CONFIG_DIR
User=$REAL_USER
Restart=on-failure
WorkingDirectory=$DOWNLOAD_DIR

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl start qbittorrent
    
    get_status_info
    echo -e "\n${GREEN}qBittorrent 已成功无缝更新至最新版！${RESET}"
}

# 3. 卸载服务
uninstall_qbittorrent() {
    echo -e "${RED}警告: 正在卸载 qBittorrent 并清除所有配置数据...${RESET}"
    sudo systemctl stop ${SERVICE_NAME} 2>/dev/null
    sudo systemctl disable ${SERVICE_NAME} 2>/dev/null
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload
    sudo rm -f "$BIN_PATH"
    sudo rm -rf "$APP_DIR"
    echo -e "${GREEN}qBittorrent 已彻底卸载，数据已清理完毕。${RESET}"
}

# 4. 修改端口和绑定配置
edit_config() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "${RED}错误: 未检测到服务文件，请先安装 qBittorrent！${RESET}"
        return
    fi

    get_status_info
    echo -e "${CYAN}当前 WebUI 端口为 : ${port_show}${RESET}"
    echo -e "${CYAN}当前 WebUI 绑定 IP: ${ip_show}${RESET}"
    echo "---"
    
    echo -ne "${YELLOW}请输入新的 WebUI 端口号 (直接回车保持不变): ${RESET}"
    read -r new_port
    [[ -z "$new_port" ]] && new_port=$(grep -oE -- '--webui-port=[0-9]+' "$SERVICE_FILE" | cut -d= -f2)
    if ! validate_port "$new_port"; then return; fi

    echo -e "${YELLOW}请选择新的 WebUI 绑定 IP:${RESET}"
    echo -e "  1) 0.0.0.0   (公网/局域网外网访问)"
    echo -e "  2) 127.0.0.1 (本地回环/绝对安全)"
    echo -ne "${YELLOW}请输入选项或输入自定义IP (直接回车保持不变): ${RESET}"
    read -r ip_choice
    
    local new_ip
    new_ip=$(grep -oE -- '--webui-listen-to=[^ ]+' "$SERVICE_FILE" | cut -d= -f2)
    [[ -z "$new_ip" ]] && new_ip="0.0.0.0"

    case "$ip_choice" in
        1) new_ip="0.0.0.0" ;;
        2) new_ip="127.0.0.1" ;;
        "") ;; # 保持不变
        *) [[ -n "$ip_choice" ]] && new_ip="$ip_choice" ;;
    esac

    echo -e "${YELLOW}正在应用新配置 (端口: ${new_port} | IP: ${new_ip})...${RESET}"
    sudo sed -i "s/--webui-port=[0-9]*/--webui-port=${new_port}/g" "$SERVICE_FILE"
    
    # 兼容老服务文件中可能没有 --webui-listen-to 的情况
    if grep -q -- "--webui-listen-to" "$SERVICE_FILE"; then
        sudo sed -i "s/--webui-listen-to=[^ ]*/--webui-listen-to=${new_ip}/g" "$SERVICE_FILE"
    else
        sudo sed -i "s|--webui-port=${new_port}|--webui-port=${new_port} --webui-listen-to=${new_ip}|g" "$SERVICE_FILE"
    fi
    
    sudo systemctl daemon-reload
    sudo systemctl restart "$SERVICE_NAME"
    echo -e "${GREEN}配置修改成功并已重启服务！${RESET}"
}

# 5. 启动服务
start_qbittorrent() {
    sudo systemctl start ${SERVICE_NAME}
    echo -e "${GREEN}qBittorrent 已启动${RESET}"
}

# 6. 停止服务
stop_qbittorrent() {
    sudo systemctl stop ${SERVICE_NAME}
    echo -e "${YELLOW}qBittorrent 已停止${RESET}"
}

# 7. 重启服务
restart_qbittorrent() {
    sudo systemctl restart ${SERVICE_NAME}
    echo -e "${GREEN}qBittorrent 已重启${RESET}"
}

# 8. 查看日志
logs_qbittorrent() {
    echo -e "${CYAN}正在实时查看日志 (按 Ctrl+C 退出)...${RESET}"
    sudo journalctl -u ${SERVICE_NAME} -n 50 -f
}

# 9. 查看节点配置
show_node_info() {
    get_status_info
    local current_ip=$(grep -oE -- '--webui-listen-to=[^ ]+' "$SERVICE_FILE" | cut -d= -f2)
    [[ -z "$current_ip" ]] && current_ip="0.0.0.0"
    
    local display_ip="$current_ip"
    [[ "$current_ip" == "0.0.0.0" ]] && display_ip=$(get_public_ip)

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    qBittorrent 访问与配置信息    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 地址 : http://${display_ip}:${port_show}${RESET}"
    echo -e "${YELLOW}当前绑定 IP: ${current_ip}${RESET}"
    echo -e "${YELLOW}默认用户名 : admin${RESET}"
    echo -ne "${YELLOW}初始密码   : ${RESET}"
    get_qb_password
    echo -e "${GREEN}================================${RESET}"
}

# 菜单
menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     qBittorrent 自动管理面板     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}绑定IP :${RESET} ${YELLOW}${ip_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 qBittorrent${RESET}"
    echo -e "${GREEN}2. 更新 qBittorrent${RESET}"
    echo -e "${GREEN}3. 卸载 qBittorrent${RESET}"
    echo -e "${GREEN}4. 修改配置${RESET}"
    echo -e "${GREEN}5. 启动 qBittorrent${RESET}"
    echo -e "${GREEN}6. 停止 qBittorrent${RESET}"
    echo -e "${GREEN}7. 重启 qBittorrent${RESET}"
    echo -e "${GREEN}8. 查看日志${RESET}"
    echo -e "${GREEN}9. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_qbittorrent ;;
        2) update_qbittorrent ;;
        3) uninstall_qbittorrent ;;
        4) edit_config ;;
        5) start_qbittorrent ;;
        6) stop_qbittorrent ;;
        7) restart_qbittorrent ;;
        8) logs_qbittorrent ;;
        9) show_node_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done
