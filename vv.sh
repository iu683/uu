#!/bin/bash
# ========================================
# qBittorrent-Nox 一键管理脚本 (Alpine Linux OpenRC 专属完美修复版)
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
INIT_FILE="/etc/init.d/qbittorrent"
CONF_FILE="/etc/conf.d/qbittorrent"
LOG_FILE="/var/log/qbittorrent.log"

# GitHub 代理列表
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 获取真实的运行用户
REAL_USER=${SUDO_USER:-$(whoami)}

# 动态获取状态、版本和端口
get_status_info() {
    if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "started"; then
        status="${GREEN}已启动${RESET}"
    else
        status="${RED}未运行${RESET}"
    fi

    if [[ -f "$BIN_PATH" ]]; then
        version=$($BIN_PATH --version 2>/dev/null | awk '{print $2}')
        [[ -z "$version" ]] && version="已安装"
    else
        version="${RED}未安装${RESET}"
    fi

    if [[ -f "$CONF_FILE" ]]; then
        port_show=$(grep -oE 'QB_PORT="[0-9]+"' "$CONF_FILE" | cut -d'"' -f2)
        [[ -z "$port_show" ]] && port_show="8080"
    else
        port_show="N/A"
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
    if command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ":$port "; then
            echo -e "${RED}错误: 端口 $port 已被其他程序占用，请更换端口！${RESET}"
            return 1
        fi
    fi
    return 0
}

# 从日志中自动提取临时密码
get_qb_password() {
    local log_line log_pass
    if [[ -f "$LOG_FILE" ]]; then
        log_line=$(grep -Ei "temporary password is:|password was randomly generated:|provided for this session:" "$LOG_FILE" | tail -n 1)
    fi
    
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

# 高可用获取 GitHub 最新 Release JSON 数据
fetch_release_json() {
    local api_url="https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases/latest"
    local json_data=""
    
    for proxy in "${GITHUB_PROXY[@]}"; do
        if [[ -z "$proxy" ]]; then
            echo -e "${YELLOW}正在尝试直连检索 GitHub 最新版本信息...${RESET}"
            json_data=$(curl -s --connect-timeout 6 "$api_url")
        else
            echo -e "${YELLOW}正在尝试通过代理 [ ${proxy} ] 检索版本信息...${RESET}"
            json_data=$(curl -s --connect-timeout 6 "${proxy}${api_url}")
        fi
        
        # 只要包含 tag_name，就证明拿到 JSON 了
        if echo "$json_data" | grep -q "tag_name"; then
            echo "$json_data"
            return 0
        fi
    done
    return 1
}

# 高可用下载函数
download_file_with_proxy() {
    local raw_url=$1
    local save_path=$2
    
    for proxy in "${GITHUB_PROXY[@]}"; do
        local final_url="${proxy}${raw_url}"
        if [[ -z "$proxy" ]]; then
            echo -e "${YELLOW}正在尝试直连下载...${RESET}"
        else
            echo -e "${YELLOW}正在通过代理下载: ${proxy}${RESET}"
        fi
        echo -e "${CYAN}URL: $final_url${RESET}"
        
        sudo wget -q --show-progress --timeout=15 --tries=2 -O "$save_path" "$final_url"
        if [[ $? -eq 0 && -s "$save_path" ]]; then
            return 0
        fi
        echo -e "${RED}当前节点下载失败，正在尝试下一个...${RESET}"
        sudo rm -f "$save_path"
    done
    return 1
}

# 1. 部署 qBittorrent-Nox
install_qbittorrent() {
    if [[ -f "$BIN_PATH" ]]; then
        echo -e "${YELLOW}提示: qBittorrent 已安装在 $BIN_PATH，请勿重复安装。${RESET}"
        return
    fi

    echo -ne "${YELLOW}请输入你想要设置的 WebUI 端口号 [默认: 8080]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="8080"

    if ! validate_port "$custom_port"; then
        return
    fi

    # 检测系统架构
    local arch url_file
    arch=$(uname -m)
    case "$arch" in
        x86_64)      url_file="x86_64-qbittorrent-nox" ;;
        aarch64)     url_file="aarch64-qbittorrent-nox" ;;
        armv7l)      url_file="armv7-qbittorrent-nox" ;;
        armhf)       url_file="armhf-qbittorrent-nox" ;;
        riscv64)     url_file="riscv64-qbittorrent-nox" ;;
        i386|i686)   url_file="x86-qbittorrent-nox" ;;
        *)
            echo -e "${RED}错误: 暂不支持您的系统架构 ($arch)！${RESET}"
            return
            ;;
    esac

    # 安装基础依赖
    echo -e "${YELLOW}检查并安装必要工具 (curl, wget, bash, sudo)...${RESET}"
    sudo apk update && sudo apk add curl wget bash sudo

    # 动态抓取 GitHub 最新 Release 信息
    local release_json latest_tag expected_sha
    release_json=$(fetch_release_json)
    
    if [[ $? -ne 0 || -z "$release_json" ]]; then
        echo -e "${RED}错误: 无法获取最新版本号。可能触发了 GitHub API 限制，或所有代理节点均不可用。${RESET}"
        return
    fi
    
    # 【修复核心】使用 awk 和 tr 代替 grep -P，完美兼容 Alpine BusyBox
    latest_tag=$(echo "$release_json" | awk -F'"tag_name":' '{print $2}' | awk -F'"' '{print $2}' | tr -d '[:space:]')
    
    if [[ -z "$latest_tag" ]]; then
        echo -e "${RED}错误: 文本解析失败，未能提取到有效的版本 Tag！${RESET}"
        return
    fi
    echo -e "${GREEN}检测到最新版本标签: ${latest_tag}${RESET}"

    # 【修复核心】提取 SHA256，利用两段式 awk 进行准确定位
    expected_sha=$(echo "$release_json" | awk -v file="$url_file" '$0 ~ file {gsub(/.*sha256:/,""); print $1}' | tr -d '"' | grep -oE '[a-f0-9]{64}' | head -n1)
    
    # 原始下载 URL 
    local download_url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${latest_tag}/${url_file}"
    
    # 调用代理下载
    if ! download_file_with_proxy "$download_url" "$BIN_PATH"; then
        echo -e "${RED}错误: 所有代理及直连节点均下载失败，请检查网络！${RESET}"
        return
    fi

    # 安全完整性哈希校验
    if [[ -n "$expected_sha" && ${#expected_sha} -eq 64 ]]; then
        echo -e "${YELLOW}正在验证文件完整性 (SHA256)...${RESET}"
        local calculated_sha
        calculated_sha=$(sha256sum "$BIN_PATH" | awk '{print $1}')
        if [[ "$calculated_sha" != "$expected_sha" ]]; then
            echo -e "${RED}错误: SHA256 校验失败！下载的文件可能已损坏。${RESET}"
            echo "官方预期值: $expected_sha"
            echo "本地计算值: $calculated_sha"
            sudo rm -f "$BIN_PATH"
            return
        fi
        echo -e "${GREEN}安全校验通过！${RESET}"
    else
        echo -e "${YELLOW}提示: 未能匹配到该版本的精准官方 SHA256，跳过哈希校验。${RESET}"
    fi

    # 赋予执行权限
    sudo chmod +x "$BIN_PATH"

    # 创建目录并赋权
    sudo mkdir -p "$CONFIG_DIR" "$DOWNLOAD_DIR"
    sudo touch "$LOG_FILE"
    sudo chown -R "$REAL_USER":"$REAL_USER" "$APP_DIR" "$LOG_FILE"
    sudo chmod -R 755 "$APP_DIR"

    # 创建 OpenRC 环境配置文件
    echo -e "${YELLOW}创建 OpenRC 配置文件...${RESET}"
    sudo tee "$CONF_FILE" > /dev/null <<EOF
QB_USER="$REAL_USER"
QB_PORT="$custom_port"
QB_CONFIG="$CONFIG_DIR"
QB_DOWNLOAD="$DOWNLOAD_DIR"
QB_LOG="$LOG_FILE"
EOF

    # 创建 OpenRC 服务脚本
    echo -e "${YELLOW}创建 OpenRC 服务脚本...${RESET}"
    sudo tee "$INIT_FILE" > /dev/null << 'EOF'
#!/sbin/openrc-run

description="qBittorrent Command Line Client (Static Latest)"

command="/usr/local/bin/qbittorrent-nox"
command_args="--webui-port=${QB_PORT:-8080} --profile=${QB_CONFIG}"
command_background="yes"
directory="${QB_DOWNLOAD}"

pidfile="/run/${RC_SVCNAME}.pid"
output_log="${QB_LOG:-/dev/null}"
error_log="${QB_LOG:-/dev/null}"

start_user="${QB_USER:-root}"

depend() {
    need net
    after firewall
}
EOF

    sudo chmod +x "$INIT_FILE"
    sudo rc-update add qbittorrent default
    sudo rc-service qbittorrent start

    echo -e "${YELLOW}等待服务启动并生成密码...${RESET}"
    sleep 4

    SERVER_IP=$(get_public_ip)
    echo -e "\n${GREEN}qBittorrent-Nox 静态版安装完成并已启动!${RESET}"
    echo -e "${YELLOW}WebUI 访问地址: http://${SERVER_IP}:${custom_port}${RESET}"
    echo -e "${YELLOW}默认用户名: admin${RESET}"
    echo -ne "${YELLOW}初始密码: ${RESET}"
    get_qb_password
    echo -e "${YELLOW}配置目录: $CONFIG_DIR${RESET}"
    echo -e "${YELLOW}下载目录: $DOWNLOAD_DIR${RESET}"
}

# 2. 自动检查并更新到最新版
update_qbittorrent() {
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "${RED}错误: 未检测到已安装的 qBittorrent，请先选择 1 进行安装！${RESET}"
        return
    fi

    local current_port="8080"
    if [[ -f "$CONF_FILE" ]]; then
        current_port=$(grep -oE 'QB_PORT="[0-9]+"' "$CONF_FILE" | cut -d'"' -f2)
        [[ -z "$current_port" ]] && current_port="8080"
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

    # 动态抓取 GitHub 最新 Release 信息
    local release_json latest_tag expected_sha
    release_json=$(fetch_release_json)
    
    if [[ $? -ne 0 || -z "$release_json" ]]; then
        echo -e "${RED}错误: 无法获取最新版本号。更新终止，原系统未受影响。${RESET}"
        return
    fi
    
    # 【修复核心】同样换用高兼容性的 awk 提取
    latest_tag=$(echo "$release_json" | awk -F'"tag_name":' '{print $2}' | awk -F'"' '{print $2}' | tr -d '[:space:]')
    echo -e "${GREEN}检测到最新版本标签: ${latest_tag}${RESET}"

    # 提取最新 SHA256 校验码
    expected_sha=$(echo "$release_json" | awk -v file="$url_file" '$0 ~ file {gsub(/.*sha256:/,""); print $1}' | tr -d '"' | grep -oE '[a-f0-9]{64}' | head -n1)

    # 先下载到临时文件
    local tmp_bin="/tmp/qbittorrent-nox.tmp"
    local download_url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${latest_tag}/${url_file}"
    
    if ! download_file_with_proxy "$download_url" "$tmp_bin"; then
        echo -e "${RED}错误: 下载失败，放弃更新，原系统未受影响。${RESET}"
        return
    fi

    # 安全完整性哈希校验
    if [[ -n "$expected_sha" && ${#expected_sha} -eq 64 ]]; then
        echo -e "${YELLOW}正在验证新文件完整性 (SHA256)...${RESET}"
        local calculated_sha
        calculated_sha=$(sha256sum "$tmp_bin" | awk '{print $1}')
        if [[ "$calculated_sha" != "$expected_sha" ]]; then
            echo -e "${RED}错误: SHA256 校验失败！下载的文件可能不完整，放弃更新。${RESET}"
            sudo rm -f "$tmp_bin"
            return
        fi
        echo -e "${GREEN}安全校验通过！${RESET}"
    fi

    # 原子替换
    echo -e "${YELLOW}正在应用更新并重启服务...${RESET}"
    sudo rc-service qbittorrent stop
    
    sudo mv -f "$tmp_bin" "$BIN_PATH"
    sudo chmod +x "$BIN_PATH"
    
    sudo rc-service qbittorrent start
    
    get_status_info
    SERVER_IP=$(get_public_ip)
    echo -e "\n${GREEN}qBittorrent 已成功无缝更新至最新版！${RESET}"
    echo -e "${YELLOW}当前版本 : ${version}${RESET}"
    echo -e "${YELLOW}访问地址 : http://${SERVER_IP}:${current_port}${RESET}"
    echo -e "${CYAN}提示: 您的原有账号、密码、配置和种子下载进度已全部完好保留。${RESET}"
}

# 3. 卸载服务
uninstall_qbittorrent() {
    echo -e "${RED}警告: 正在卸载 qBittorrent 并清除所有配置数据...${RESET}"
    sudo rc-service ${SERVICE_NAME} stop 2>/dev/null
    sudo rc-update del ${SERVICE_NAME} default 2>/dev/null
    sudo rm -f "$INIT_FILE" "$CONF_FILE" "$LOG_FILE"
    
    sudo rm -f "$BIN_PATH"
    sudo rm -rf "$APP_DIR"
    echo -e "${GREEN}qBittorrent 已彻底卸载，数据已清理完毕。${RESET}"
}

# 4. 修改端口配置
edit_config() {
    if [[ ! -f "$CONF_FILE" ]]; then
        echo -e "${RED}错误: 未检测到配置文件，请先安装 qBittorrent！${RESET}"
        return
    fi

    get_status_info
    echo -e "${CYAN}当前 WebUI 端口为: ${port_show}${RESET}"
    echo -ne "${YELLOW}请输入新的 WebUI 端口号: ${RESET}"
    read -r new_port

    if ! validate_port "$new_port"; then
        return
    fi

    echo -e "${YELLOW}正在修改端口为 ${new_port}...${RESET}"
    sudo sed -i "s/QB_PORT=\"[0-9]*\"/QB_PORT=\"${new_port}\"/g" "$CONF_FILE"
    
    echo -e "${YELLOW}正在重启服务...${RESET}"
    sudo rc-service "$SERVICE_NAME" restart
    
    echo -e "${GREEN}端口修改成功！当前新端口为: ${new_port}${RESET}"
}

# 5. 启动服务
start_qbittorrent() {
    sudo rc-service ${SERVICE_NAME} start
    echo -e "${GREEN}qBittorrent 已启动${RESET}"
}

# 6. 停止服务
stop_qbittorrent() {
    sudo rc-service ${SERVICE_NAME} stop
    echo -e "${YELLOW}qBittorrent 已停止${RESET}"
}

# 7. 重启服务
restart_qbittorrent() {
    sudo rc-service ${SERVICE_NAME} restart
    echo -e "${GREEN}qBittorrent 已重启${RESET}"
}

# 8. 查看日志
logs_qbittorrent() {
    if [[ -f "$LOG_FILE" ]]; then
        echo -e "${CYAN}正在实时查看日志 (按 Ctrl+C 退出)...${RESET}"
        tail -n 50 -f "$LOG_FILE"
    else
        echo -e "${RED}日志文件不存在！${RESET}"
    fi
}

# 9. 查看节点配置
show_node_info() {
    SERVER_IP=$(get_public_ip)
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}    qBittorrent 访问与配置信息    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}WebUI 地址 : http://${SERVER_IP}:${port_show}${RESET}"
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
    echo -e "${GREEN}  qBittorrent 自动管理面板(Alpine) ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 安装 qBittorrent (国内加速版)${RESET}"
    echo -e "${GREEN}2. 检查并更新 qBittorrent${RESET}"
    echo -e "${GREEN}3. 卸载 qBittorrent${RESET}"
    echo -e "${GREEN}4. 修改端口配置${RESET}"
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
