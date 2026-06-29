#!/bin/bash

# --- 脚本配置 ---
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)


GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
NC="\033[0m"
BLUE="\033[36m"
RESET="\033[0m"


INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/easytier"
CONFIG_FILE="${CONFIG_DIR}/easytier.toml"
CORE_BINARY_NAME="easytier-core"
CLI_BINARY_NAME="easytier-cli"
ALIAS_PATH="/usr/local/bin/et"

OS_TYPE=""
SERVICE_FILE=""
SERVICE_LABEL="com.easytier.core"
SERVICE_NAME="easytier"
LOG_FILE="/var/log/easytier.log"

GITHUB_API_URL="https://api.github.com/repos/EasyTier/EasyTier/releases/latest"

# --- 辅助函数 ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本必须以 root 或 sudo 权限运行。${NC}"; exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    for cmd in curl jq unzip; do
        if ! command -v "$cmd" &> /dev/null; then missing_deps+=("$cmd"); fi
    done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${YELLOW}检测到缺失的依赖: ${missing_deps[*]}${NC}"
        if [[ "$OS_TYPE" == "linux" || "$OS_TYPE" == "alpine"  ]]; then
            read -p "是否尝试自动安装? (y/n): " choice
            if [[ "$choice" != "y" && "$choice" != "Y" ]]; then echo -e "${RED}操作中止。${NC}"; exit 1; fi
            if [[ "$OS_TYPE" == "linux" ]]; then
                if command -v apt-get &>/dev/null; then apt-get update && apt-get install -y "${missing_deps[@]}";
                elif command -v yum &>/dev/null; then yum install -y "${missing_deps[@]}";
                elif command -v dnf &>/dev/null; then dnf install -y "${missing_deps[@]}";
                else echo -e "${RED}无法确定包管理器。请手动安装。${NC}"; exit 1; fi
            elif [[ "$OS_TYPE" == "alpine" ]]; then apk add --no-cache "${missing_deps[@]}"; fi
        elif [[ "$OS_TYPE" == "macos" ]]; then
            echo -e "${YELLOW}请使用 Homebrew 手动安装: brew install ${missing_deps[*]}${NC}"; exit 1
        fi
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;; aarch64|arm64) echo "aarch64" ;;
        *) echo -e "${RED}错误: 不支持的架构: $(uname -m)${NC}"; exit 1 ;;
    esac
}

check_installed() {
    if [ ! -f "${INSTALL_DIR}/${CORE_BINARY_NAME}" ]; then
        echo -e "${YELLOW}EasyTier 尚未安装。请先选择选项 1。${NC}"; return 1
    fi; return 0
}

get_runtime_status() {
    if [ ! -f "${INSTALL_DIR}/${CORE_BINARY_NAME}" ]; then
        echo -e "${RED}未安装${RESET}"
    elif [[ "$OS_TYPE" == "linux" ]]; then
        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then echo -e "${GREEN}运行中 (systemd)${RESET}"; else echo -e "${RED}已停止${RESET}"; fi
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        if rc-service "${SERVICE_NAME}" status 2>/dev/null | grep -q "started"; then echo -e "${GREEN}运行中 (openrc)${RESET}"; else echo -e "${RED}已停止${RESET}"; fi
    elif [[ "$OS_TYPE" == "macos" ]]; then
        if launchctl list | grep -q "${SERVICE_LABEL}"; then echo -e "${GREEN}运行中 (launchd)${RESET}"; else echo -e "${RED}已停止${RESET}"; fi
    else
        echo -e "${RED}未知${RESET}"
    fi
}

get_version() {
    if [ -f "${INSTALL_DIR}/${CORE_BINARY_NAME}" ]; then
        local raw_ver; raw_ver=$("${INSTALL_DIR}/${CORE_BINARY_NAME}" --version 2>/dev/null | awk '{print $2}')
        echo "${raw_ver%%-*}"
    else
        echo "无"
    fi
}

get_network_name() {
    if [ -f "$CONFIG_FILE" ]; then
        local name; name=$(grep -E "^network_name\s*=" "$CONFIG_FILE" | head -n 1 | cut -d'"' -f2)
        echo "${name:-未配置}"
    else
        echo "无"
    fi
}

get_runtime_ip() {
    if [ ! -f "${INSTALL_DIR}/${CLI_BINARY_NAME}" ] || [ ! -f "$CONFIG_FILE" ]; then
        echo "无"; return
    fi
    local status_str; status_str=$(get_runtime_status)
    if [[ "$status_str" != *"运行中"* ]]; then
        local cfg_ip; cfg_ip=$(grep -E "^ipv4\s*=" "$CONFIG_FILE" | head -n 1 | cut -d'"' -f2)
        if [ -n "$cfg_ip" ]; then echo "$cfg_ip (未激活)"; else echo "DHCP模式 (未启动)"; fi
        return
    fi
    local live_ip; live_ip=$("${INSTALL_DIR}/${CLI_BINARY_NAME}" peer 2>/dev/null | grep -i "Local" | awk '{print $2}' | head -n 1)
    if [ -n "$live_ip" ]; then echo "$live_ip"; else echo "获取中/未分配"; fi
}

get_runtime_proxy() {
    if [ -f "$CONFIG_FILE" ]; then
        local cidr; cidr=$(grep -E "^\s*cidr\s*=" "$CONFIG_FILE" | head -n 1 | cut -d'"' -f2)
        echo "${cidr:-未开启}"
    else
        echo "无"
    fi
}

safe_sed_delete_proxy() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        sed -i '' '/\[\[proxy_network\]\]/,+1d' "$1"
    else
        sed -i '/\[\[proxy_network\]\]/,+1d' "$1"
    fi
}

safe_sed_delete_peer() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        sed -i '' '/\[\[peer\]\]/,$d' "$1"
    else
        sed -i '/\[\[peer\]\]/,$d' "$1"
    fi
}

# --- 服务控制管理 ---
create_service_file() {
    if [[ "$OS_TYPE" == "linux" ]]; then
        cat > "${SERVICE_FILE}" << EOL
[Unit]
Description=EasyTier Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/${CORE_BINARY_NAME} -c ${CONFIG_FILE}
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL
    elif [[ "$OS_TYPE" == "alpine" ]]; then
        cat > "${SERVICE_FILE}" << EOL
#!/sbin/openrc-run
description="EasyTier Service with Supervisor"
supervisor=supervise-daemon
command="${INSTALL_DIR}/${CORE_BINARY_NAME}"
command_args="-c ${CONFIG_FILE}"
command_user="root"
pidfile="/var/run/${SERVICE_NAME}.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
depend() { need net; after net; }
EOL
        chmod +x "${SERVICE_FILE}"
    elif [[ "$OS_TYPE" == "macos" ]]; then
        cat > "${SERVICE_FILE}" << EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key> <string>${SERVICE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/${CORE_BINARY_NAME}</string>
        <string>-c</string> <string>${CONFIG_FILE}</string>
    </array>
    <key>RunAtLoad</key> <true/>
    <key>KeepAlive</key> <true/>
    <key>StandardOutPath</key> <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key> <string>${LOG_FILE}</string>
</dict>
</plist>
EOL
    fi
}

reload_service_daemon() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl daemon-reload; fi; }
start_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl start "${SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${SERVICE_NAME}" start; elif [[ "$OS_TYPE" == "macos" ]]; then launchctl load "${SERVICE_FILE}" &>/dev/null; fi; }
stop_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl stop "${SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${SERVICE_NAME}" stop; elif [[ "$OS_TYPE" == "macos" ]]; then launchctl unload "${SERVICE_FILE}" &>/dev/null; fi; }
restart_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl restart "${SERVICE_NAME}"; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${SERVICE_NAME}" restart; elif [[ "$OS_TYPE" == "macos" ]]; then stop_service; sleep 1; start_service; fi; }
enable_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl enable "${SERVICE_NAME}" &>/dev/null; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-update add "${SERVICE_NAME}" default &>/dev/null; elif [[ "$OS_TYPE" == "macos" ]]; then start_service; fi; }
disable_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl disable "${SERVICE_NAME}" &>/dev/null; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-update del "${SERVICE_NAME}" default &>/dev/null; elif [[ "$OS_TYPE" == "macos" ]]; then stop_service; fi; }
log_service() { if [[ "$OS_TYPE" == "linux" ]]; then journalctl -u "${SERVICE_NAME}" -f --no-pager; elif [[ "$OS_TYPE" == "alpine" || "$OS_TYPE" == "macos" ]]; then tail -f "${LOG_FILE}"; fi; }

# 【底层修正】强化快捷键生成
create_shortcut() {
    local SCRIPT_PATH
    
    if [[ "$0" == *"pipe"* || "$0" == "bash" || "$0" == "sh" || "$0" == "/dev/fd/"* ]]; then
        mkdir -p "$CONFIG_DIR"
        local LOCAL_SCRIPT="${CONFIG_DIR}/easytier_menu.sh"
        local SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/nn.sh"
        
        local download_success=false
        for proxy in "${GITHUB_PROXY[@]}"; do
            local final_url="$SCRIPT_URL"
            if [ -n "$proxy" ]; then final_url="${proxy%/}/${SCRIPT_URL}"; fi
            if curl -sL --connect-timeout 5 -o "$LOCAL_SCRIPT" "$final_url" && [ -s "$LOCAL_SCRIPT" ]; then
                download_success=true; break
            fi
        done
        
        if [ "$download_success" = true ]; then
            chmod +x "$LOCAL_SCRIPT"
            ln -sf "$LOCAL_SCRIPT" "${ALIAS_PATH}"
            echo -e "${GREEN} ✔ 脚本已成功安装至: ${LOCAL_SCRIPT}${NC}"
            echo -e "${GREEN} ✔ 快捷命令 “et” 创建成功！以后直接输入 et 即可管理。${NC}"
        else
            echo -e "${RED} ✘ 固化本地脚本失败，网络连接超时。${NC}"
        fi
        return 0
    fi

    SCRIPT_PATH=$(realpath "$0" 2>/dev/null || (cd "$(dirname "$0")" && echo "$(pwd)/$(basename "$0")"))
    if [ -f "${SCRIPT_PATH}" ]; then
        if [ -L "${ALIAS_PATH}" ] && [ "$(readlink "${ALIAS_PATH}")" = "${SCRIPT_PATH}" ]; then return 0; fi
        echo -e "${YELLOW}正在更新“et”快捷命令...${NC}"
        chmod +x "${SCRIPT_PATH}" 2>/dev/null
        ln -sf "${SCRIPT_PATH}" "${ALIAS_PATH}"
    fi
}

remove_shortcut() { if [ -L "${ALIAS_PATH}" ]; then rm -f "${ALIAS_PATH}"; fi; }

install_easytier() {

    local mode="$1" # 获取传参："install" 或 "update"
    
    if [ "$mode" = "update" ]; then
        echo -e "${GREEN}--- 开始检查并更新 EasyTier ---${NC}"
    else
        echo -e "${GREEN}--- 开始安装 EasyTier ---${NC}"
    fi

    local os_identifier="linux"; if [[ "$OS_TYPE" == "macos" ]]; then os_identifier="macos"; fi
    local arch; arch=$(get_arch)

    local latest_info=""
    local chosen_proxy=""

    echo "1. 正在获取最新版本信息 (顺序轮询代理池)..."
    for proxy in "${GITHUB_PROXY[@]}"; do
        local api_url="$GITHUB_API_URL"
        if [ -n "$proxy" ]; then
            api_url="${proxy%/}/${GITHUB_API_URL}"
            echo -e " -> 正在尝试代理: ${YELLOW}${proxy}${NC} ..."
        else
            echo -e " -> 正在尝试: ${BLUE}直连 GitHub${NC} ..."
        fi

        latest_info=$(curl -sL --connect-timeout 5 "$api_url")
        
        if [ -n "$latest_info" ] && echo "$latest_info" | jq -e '.assets' >/dev/null 2>&1; then
            chosen_proxy="$proxy"
            if [ -n "$chosen_proxy" ]; then
                echo -e "${GREEN} ✔ 代理 ${chosen_proxy} 连接成功!${NC}"
            else
                echo -e "${GREEN} ✔ 直连 GitHub 成功!${NC}"
            fi
            break
        else
            echo -e "${RED} ✘ 节点连接失败、无有效数据或遭遇 GitHub API 限流，尝试下一个...${NC}"
            latest_info=""
        fi
    done

    if [ -z "$latest_info" ]; then
        echo -e "${RED}错误: 代理池中所有节点及直连均无法获取有效版本信息，请稍后再试。${NC}"
        return 1
    fi
    
    local search_prefix="easytier-${os_identifier}-${arch}"
    local asset_json; asset_json=$(echo "$latest_info" | jq ".assets[] | select(.name | startswith(\"${search_prefix}\") and endswith(\".zip\"))" 2>/dev/null)
    if [ -z "$asset_json" ]; then echo -e "${RED}错误: 未能找到适用于 ${OS_TYPE}(${arch}) 的包。${NC}"; return 1; fi
    
    local raw_download_url; raw_download_url=$(echo "$asset_json" | jq -r '.browser_download_url')
    local actual_filename; actual_filename=$(echo "$asset_json" | jq -r '.name')
    local version; version=$(echo "$latest_info" | jq -r ".tag_name")
    echo "检测到版本: ${version}, 架构: ${arch}, 文件: ${actual_filename}"
    
    local final_download_url="$raw_download_url"
    if [ -n "$chosen_proxy" ]; then
        if [[ "$chosen_proxy" == */ ]]; then final_download_url="${chosen_proxy}${raw_download_url}"; else final_download_url="${chosen_proxy}/${raw_download_url}"; fi
        echo -e "${YELLOW}2. 使用就绪代理下载: ${final_download_url}${NC}"
    else
        echo "2. 直接从 GitHub 下载: ${final_download_url}"
    fi

    local temp_file; temp_file=$(mktemp)
    curl -L --progress-bar --connect-timeout 10 -o "$temp_file" "$final_download_url" || { echo -e "${RED}下载失败!${NC}"; rm -f "$temp_file"; return 1; }
    echo "3. 解压并安装..."
    local unzip_dir_name="easytier-${os_identifier}-${arch}"
    unzip -o "$temp_file" -d /tmp/ > /dev/null || { echo -e "${RED}解压失败!${NC}"; rm -f "$temp_file"; return 1; }
    local extracted_core="/tmp/${unzip_dir_name}/${CORE_BINARY_NAME}"; local extracted_cli="/tmp/${unzip_dir_name}/${CLI_BINARY_NAME}"
    if [ ! -f "$extracted_core" ] || [ ! -f "$extracted_cli" ]; then echo -e "${RED}错误: 在解压目录中未找到核心文件。${NC}"; rm -f "$temp_file"; rm -rf "/tmp/${unzip_dir_name}"; return 1; fi
    mkdir -p "$INSTALL_DIR"
    mv -f "$extracted_core" "${INSTALL_DIR}/${CORE_BINARY_NAME}"; mv -f "$extracted_cli" "${INSTALL_DIR}/${CLI_BINARY_NAME}"
    chmod +x "${INSTALL_DIR}/${CORE_BINARY_NAME}" "${INSTALL_DIR}/${CLI_BINARY_NAME}"
    rm -f "$temp_file"; rm -rf "/tmp/${unzip_dir_name}"
    
    echo -e "${GREEN}--- EasyTier ${version} 安装/更新成功! ---${NC}"

     if [ "$mode" = "update" ]; then
        echo -e "${GREEN}--- EasyTier 成功更新至 ${version}! ---${NC}"
    else
        echo -e "${GREEN}--- EasyTier ${version} 安装成功! ---${NC}"
        # 【修改点】只有在全新安装模式下，才去创建快捷键
        create_shortcut
    fi
    
    
    if [ -f "$SERVICE_FILE" ]; then
        echo -e "${YELLOW}检测到现有服务，正在静默重启服务...${NC}"
        enable_service; restart_service
    fi
}

create_default_config() { 
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << 'EOF'
hostname = "easytier-node"
ipv4 = ""
dhcp = false
listeners = ["udp://0.0.0.0:11010", "tcp://0.0.0.0:11010", "wg://0.0.0.0:11011", "ws://0.0.0.0:11011/", "wss://0.0.0.0:11012/", "tcp://[::]:11010", "udp://[::]:11010"]

[network_identity]
network_name = ""
network_secret = ""

[flags]
default_protocol = "udp"
dev_name = ""
enable_encryption = true
enable_ipv6 = true
mtu = 1380
latency_first = true
enable_exit_node = false
no_tun = false
use_smoltcp = false
foreign_network_whitelist = "*"
disable_p2p = false
relay_all_peer_rpc = false
disable_udp_hole_punching = false
enable_kcp_proxy = true
EOF
    return $?
}

_core_config_wizard() {
    local is_interactive_join="$1"

    local current_hostname; current_hostname=$(grep -E "^hostname\s*=" "$CONFIG_FILE" | head -n 1 | cut -d'"' -f2)
    local current_ipv4; current_ipv4=$(grep -E "^ipv4\s*=" "$CONFIG_FILE" | head -n 1 | cut -d'"' -f2)
    local current_dhcp; current_dhcp=$(grep -E "^dhcp\s*=" "$CONFIG_FILE" | head -n 1 | awk -F'=' '{print $2}' | tr -d '[:space:]')
    local current_name; current_name=$(grep -E "^network_name\s*=" "$CONFIG_FILE" | head -n 1 | cut -d'"' -f2)
    local current_secret; current_secret=$(grep -E "^network_secret\s*=" "$CONFIG_FILE" | head -n 1 | cut -d'"' -f2)
    local current_peer; current_peer=$(grep -E "^\s*uri\s*=" "$CONFIG_FILE" | head -n 1 | cut -d'"' -f2)
    local current_cidr; current_cidr=$(grep -E "^\s*cidr\s*=" "$CONFIG_FILE" | head -n 1 | cut -d'"' -f2)

    local ip_display="$current_ipv4"
    if [ "$current_dhcp" = "true" ] || [ -z "$current_ipv4" ]; then ip_display="DHCP自动获取"; fi
    if [ -z "$current_peer" ]; then current_peer="未配置"; fi

    echo -e "${GREEN}--- 配置向导 (直接回车保持默认/当前值) ---${NC}"

    # 获取系统当前的实际主机名
    local sys_hostname; sys_hostname=$(hostname)
    
    # 获取当前配置文件中的主机名，如果没有或者等于默认值，则触发自动变更逻辑
    local display_hostname="${current_hostname:-easytier-node}"
    if [[ "$display_hostname" == "easytier-node" ]]; then
        display_hostname="$sys_hostname"
        # 自动在配置文件中更新为系统主机名
        set_toml_value "hostname" "\"$sys_hostname\"" "$CONFIG_FILE"
        echo -e "${YELLOW}检测到当前为主机名默认值，已自动同步为系统主机名: [ $sys_hostname ]${NC}"
    else
        echo -e "${YELLOW}自定义主机名: [ $display_hostname ]${NC}"
    fi

    # 提示用户是否需要手动再次修改
    read -p "请输入主机名称 (回车保持不变): " new_host
    if [ -n "$new_host" ]; then
        set_toml_value "hostname" "\"$new_host\"" "$CONFIG_FILE"
        echo -e " -> 已变更为: $new_host"
    fi

    echo -e "${YELLOW}当前 IP 状态: [ ${ip_display} ]${NC}"
    read -p "请输入虚拟IP (输入 dhcp 启用自动获取, 回车保持不变): " virtual_ip
    if [ -n "$virtual_ip" ]; then
        if [[ "$virtual_ip" == "dhcp" || "$virtual_ip" == "DHCP" ]]; then
            set_toml_value "dhcp" "true" "$CONFIG_FILE"
            set_toml_value "ipv4" "\"\"" "$CONFIG_FILE"
        else
            set_toml_value "dhcp" "false" "$CONFIG_FILE"
            set_toml_value "ipv4" "\"$virtual_ip\"" "$CONFIG_FILE"
        fi
        echo -e " -> IP 配置已更新"
    fi
    echo

    if [ "$is_interactive_join" != "true" ]; then
        echo -e "${YELLOW}当前网络组名称: [ ${current_name:-未配置} ]${NC}"
        read -p "请输入新的网络组名称 (回车保持不变): " net_name
        if [ -n "$net_name" ]; then
            set_toml_value "network_name" "\"$net_name\"" "$CONFIG_FILE"
            echo -e " -> 已变更为: $net_name"
        fi
        echo

        echo -e "${YELLOW}当前网络组密钥: [ ${current_secret:-未配置} ]${NC}"
        read -p "请输入新的网络组密钥 (回车保持不变): " net_secret
        if [ -n "$net_secret" ]; then
            set_toml_value "network_secret" "\"$net_secret\"" "$CONFIG_FILE"
            echo -e " -> 已变更为: $net_secret"
        fi
        echo
    fi

    echo -e "${YELLOW}当前绑稳的内网子网代理: [ ${current_cidr:-未配置/未开启} ]${NC}"
    echo -e "${BLUE}提示: 格式如 192.168.1.0/24，开启后网内其他机器就能访问你身后的局域网设备${NC}"
    read -p "请输入要代理的内网网段 (留空不变, 输入 clear 清除): " proxy_cidr
    if [ -n "$proxy_cidr" ]; then
        safe_sed_delete_proxy "$CONFIG_FILE"
        if [[ "$proxy_cidr" != "clear" ]]; then
            echo -e "\n[[proxy_network]]\ncidr = \"${proxy_cidr}\"" >> "$CONFIG_FILE"
            echo -e " -> 已成功绑定并代理内网网段: $proxy_cidr"
        else
            echo -e " -> 已成功清除子网代理设置"
        fi
    fi
    echo

    if [ "$is_interactive_join" == "true" ] && [ "$current_peer" = "未配置" ]; then
        current_peer="tcp://public.easytier.top:11010 (官方默认公网节点)"
    fi
    echo -e "${YELLOW}当前对端 Peer 中转地址: [ ${current_peer} ]${NC}"
    read -p "请输入新的对端中转节点连接串 (回车保持默认): " peer_uri
    if [ -n "$peer_uri" ]; then
        safe_sed_delete_peer "$CONFIG_FILE"
        echo -e "\n[[peer]]\nuri = \"${peer_uri}\"" >> "$CONFIG_FILE"
        echo -e " -> 已变更为: $peer_uri"
    elif [ "$is_interactive_join" == "true" ] && [ "$current_peer" = "tcp://public.easytier.top:11010 (官方默认公网节点)" ]; then
        safe_sed_delete_peer "$CONFIG_FILE"
        echo -e "\n[[peer]]\nuri = \"tcp://public.easytier.top:11010\"" >> "$CONFIG_FILE"
        echo -e " -> 自动应用默认节点: tcp://public.easytier.top:11010"
    fi
    echo

    echo -e "${YELLOW}正在使配置生效...${NC}"
    if [ ! -f "$SERVICE_FILE" ]; then create_service_file; fi
    reload_service_daemon; enable_service; restart_service
    echo -e "${GREEN}✔ 所有修改处理完毕，EasyTier 服务已自动重载生效！${NC}"
}

modify_existing_config() {
    check_installed || return 1
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}未检测到配置文件，正在为您初始化默认模板...${NC}"
        create_default_config || { echo -e "${RED}创建配置文件失败。${NC}"; return 1; }
    fi
    _core_config_wizard "false"
}

join_existing_network() { 
    check_installed || return 1
    
    echo -e "${GREEN}--- 加入 EasyTier 网络组 ---${NC}"
    read -p "1. 请输入网络组名称 (Network Name): " network_name
    if [ -z "$network_name" ]; then echo -e "${RED}错误: 网络组名称不能为空。${NC}"; return 1; fi
    
    read -p "2. 请输入网络组密钥 (Network Secret): " network_secret
    if [ -z "$network_secret" ]; then echo -e "${RED}错误: 网络组密钥不能为空。${NC}"; return 1; fi
    
    create_default_config || return 1
    
    set_toml_value "network_name" "\"$network_name\"" "$CONFIG_FILE"
    set_toml_value "network_secret" "\"$network_secret\"" "$CONFIG_FILE"
    
    echo
    echo -e "${GREEN}基础网络信息已录入！接下来您可以直接配置主机名、自定义 IP 和子网代理：${NC}"
    echo
    
    _core_config_wizard "true"
    echo -e "${GREEN}--- 成功加入网络 ---${NC}"
}

uninstall_easytier() { 
    read -p "警告: 此操作将停止服务并删除所有相关文件。确定要卸载吗? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then return; fi
    stop_service &>/dev/null; disable_service &>/dev/null
    rm -f "${SERVICE_FILE}" "${INSTALL_DIR}/${CORE_BINARY_NAME}" "${INSTALL_DIR}/${CLI_BINARY_NAME}"
    rm -rf "${CONFIG_DIR}"; remove_shortcut
    if [[ "$OS_TYPE" == "linux" ]]; then systemctl daemon-reload; fi
    echo -e "${GREEN}EasyTier 已成功卸载。${NC}"
}

# --- 主入口 ---
main() {
    set_toml_value() {
        if [[ "$OS_TYPE" == "macos" ]]; then
            sed -i '' "s|^#* *${1} *=.*|${1} = ${2}|" "$3"
        else
            sed -i "s|^#* *${1} *=.*|${1} = ${2}|" "$3"
        fi
    }

    case "$(uname)" in
        Linux) if [ -f /etc/alpine-release ]; then OS_TYPE="alpine"; SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"; else OS_TYPE="linux"; SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"; fi ;;
        Darwin) OS_TYPE="macos"; SERVICE_FILE="/Library/LaunchDaemons/${SERVICE_LABEL}.plist" ;;
        *) exit 1 ;;
    esac
    check_root; check_dependencies
    

    
    while true; do
        clear
        G_STATUS=$(get_runtime_status)
        G_VERSION=$(get_version)
        G_NETNAME=$(get_network_name)
        G_RUNIP=$(get_runtime_ip)
        G_PROXYCIDR=$(get_runtime_proxy)

        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}    ◈  EasyTier 管理面板  ◈     ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态    :${RESET} $G_STATUS"
        echo -e "${GREEN}版本    :${RESET} ${YELLOW}${G_VERSION}${RESET}"
        echo -e "${GREEN}网络组  :${RESET} ${YELLOW}${G_NETNAME}${RESET}"
        echo -e "${GREEN}组网IP  :${RESET} ${YELLOW}${G_RUNIP}${RESET}"
        echo -e "${GREEN}子网代理:${RESET} ${YELLOW}${G_PROXYCIDR}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1. 安装 EasyTier${RESET}"
        echo -e "${GREEN} 2. 更新 EasyTier${RESET}"
        echo -e "${GREEN} 3. 卸载 EasyTier${RESET}"
        echo -e "${GREEN} 4. 修改组网网络${RESET}"
        echo -e "${GREEN} 5. 加入组网网络${RESET}"
        echo -e "${GREEN} 6. 查看配置文件${RESET}"
        echo -e "${GREEN} 7. 查看网络节点${RESET}"
        echo -e "${GREEN} 8. 启动 EasyTier${RESET}"
        echo -e "${GREEN} 9. 停止 EasyTier${RESET}"
        echo -e "${GREEN}10. 重启 EasyTier${RESET}"
        echo -e "${GREEN}11. 查看运行日志${RESET}"
        echo -e "${GREEN} 0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -ne "${GREEN}请输入选项: ${RESET}"
        read -r choice
        echo
        case $choice in
            1) install_easytier "install" ;; 
            2) install_easytier "update"  ;; 
            3) uninstall_easytier ;;
            4) modify_existing_config ;;
            5) join_existing_network ;;
            6) if check_installed && [ -f "$CONFIG_FILE" ]; then cat "$CONFIG_FILE"; else echo "未配置"; fi ;;
            7) if check_installed; then "${INSTALL_DIR}/${CLI_BINARY_NAME}" peer; fi ;;
            8) start_service ;;
            9) stop_service ;;
            10) restart_service ;;
            11) log_service ;;
            0) exit 0 ;;
        esac

        printf "${YELLOW}按回车键返回主菜单...${NC}" && read -r _
    done
}

main "$@"
