#!/bin/bash

# --- 脚本配置 ---
# GITHUB 代理加速池（按顺序逐个尝试，空字符串代表直连）
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 颜色定义
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
BLUE="\033;34m"
NC="\033[0m"
RESET="\033[0m"

# --- 平台无关路径和文件名 ---
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/easytier"
CONFIG_FILE="${CONFIG_DIR}/easytier.toml"
CORE_BINARY_NAME="easytier-core"
CLI_BINARY_NAME="easytier-cli"
ALIAS_PATH="/usr/local/bin/et"

# --- 平台特定变量 (将在 main 函数中设置) ---
OS_TYPE=""
SERVICE_FILE=""
SERVICE_LABEL="com.easytier.core"
SERVICE_NAME="easytier"
LOG_FILE="/var/log/easytier.log"

# 原始下载地址
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
		for cmd in "${missing_deps[@]}"; do
			 if ! command -v "$cmd" &> /dev/null; then
				echo -e "${RED}依赖 '$cmd' 安装失败。请手动安装后重试。${NC}"; exit 1
			 fi
		done
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
		"${INSTALL_DIR}/${CORE_BINARY_NAME}" --version 2>/dev/null | awk '{print $2}' || echo "未知"
	else
		echo "无"
	fi
}

get_network_name() {
	if [ -f "$CONFIG_FILE" ]; then
		local name
		name=$(grep -E "^network_name\s*=" "$CONFIG_FILE" | head -n 1 | cut -d'"' -f2)
		echo "${name:-未配置}"
	else
		echo "无"
	fi
}


# --- 平台相关的服务管理功能 ---

create_service_file() {
    if [[ "$OS_TYPE" == "macos" || "$OS_TYPE" == "alpine" ]]; then
        touch "$LOG_FILE"
        chown root:root "$LOG_FILE" &>/dev/null
        chmod 644 "$LOG_FILE"
    fi

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
depend() {
	need net
	after net
}
EOL
        chmod +x "${SERVICE_FILE}";
    elif [[ "$OS_TYPE" == "macos" ]]; then
        cat > "${SERVICE_FILE}" << EOL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/${CORE_BINARY_NAME}</string>
        <string>-c</string>
        <string>${CONFIG_FILE}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
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
status_service() { if [[ "$OS_TYPE" == "linux" ]]; then systemctl status "${SERVICE_NAME}" --no-pager -l; elif [[ "$OS_TYPE" == "alpine" ]]; then rc-service "${SERVICE_NAME}" status; elif [[ "$OS_TYPE" == "macos" ]]; then if launchctl list | grep -q "${SERVICE_LABEL}"; then echo -e "${GREEN}EasyTier 服务 (${SERVICE_LABEL}) 正在运行。${NC}"; ps aux | grep "${CORE_BINARY_NAME}" | grep -v grep; else echo -e "${YELLOW}EasyTier 服务 (${SERVICE_LABEL}) 已停止。${NC}"; fi; fi; }
log_service() { if [[ "$OS_TYPE" == "linux" ]]; then journalctl -u "${SERVICE_NAME}" -f --no-pager; elif [[ "$OS_TYPE" == "alpine" || "$OS_TYPE" == "macos" ]]; then echo "正在显示日志文件: ${LOG_FILE}"; tail -f "${LOG_FILE}"; fi; }

# --- 主功能函数 ---
create_shortcut() {
	local SCRIPT_PATH
	
	# 检测是否通过进程替换、管道或标准输入运行（例如 bash <(curl...) 或 curl...|bash）
	if [[ "$0" == *"pipe"* || "$0" == "bash" || "$0" == "sh" || "$0" == "/dev/fd/"* ]]; then
		echo -e "${YELLOW}检测到当前为远程首次运行，正在自动固化脚本到本地...${NC}"
		
		# 确保配置目录存在
		mkdir -p "$CONFIG_DIR"
		local LOCAL_SCRIPT="${CONFIG_DIR}/easytier_menu.sh"
		
		# 从你指定的 URL 自动下载脚本本体到本地
		local SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/oo.sh"
		
		# 遍历代理池尝试下载脚本本体
		local download_success=false
		for proxy in "${GITHUB_PROXY[@]}"; do
			local final_url="$SCRIPT_URL"
			if [ -n "$proxy" ]; then
				final_url="${proxy%/}/${SCRIPT_URL}"
			fi
			
			if curl -sL --connect-timeout 5 -o "$LOCAL_SCRIPT" "$final_url" && [ -s "$LOCAL_SCRIPT" ]; then
				download_success=true
				break
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

	# 正常的本地运行逻辑
	SCRIPT_PATH=$(realpath "$0" 2>/dev/null || (cd "$(dirname "$0")" && echo "$(pwd)/$(basename "$0")"))
	if [ -f "${SCRIPT_PATH}" ]; then
		if [ -L "${ALIAS_PATH}" ] && [ "$(readlink "${ALIAS_PATH}")" = "${SCRIPT_PATH}" ]; then return 0; fi
		echo -e "${YELLOW}正在更新“et”快捷命令...${NC}"
		chmod +x "${SCRIPT_PATH}" 2>/dev/null
		ln -sf "${SCRIPT_PATH}" "${ALIAS_PATH}"
	fi
}

remove_shortcut() {
	if [ -L "${ALIAS_PATH}" ]; then rm -f "${ALIAS_PATH}" &>/dev/null; fi
}

install_easytier() {
	echo -e "${GREEN}--- 开始安装或更新 EasyTier ---${NC}"
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
		
		# 增强验证：不仅要是合法 JSON，还必须包含 assets 字段，防止被 GitHub API 限流错误坑到
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
		echo -e "${RED}错误: 代理池中所有节点及直连均无法获取有效版本信息（可能全部触发了 GitHub API 频率限制），请稍后再试。${NC}"
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
		if [[ "$chosen_proxy" == */ ]]; then
			final_download_url="${chosen_proxy}${raw_download_url}"
		else
			final_download_url="${chosen_proxy}/${raw_download_url}"
		fi
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
	create_shortcut
	
	if [ -f "$SERVICE_FILE" ]; then
		echo -e "${YELLOW}检测到现有服务，正在静默重启服务...${NC}"
		enable_service
		restart_service
	fi
}
create_default_config() { mkdir -p "$CONFIG_DIR"; cat > "$CONFIG_FILE" << 'EOF'
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
enableKcp_Proxy = true
EOF
	if [ $? -eq 0 ]; then return 0; else return 1; fi; }

deploy_new_network() { 
	check_installed || return 1
	read -p "请输入网络名称: " network_name
	read -p "请输入网络密钥: " network_secret
	read -p "请输入此虚拟IP (回车则启用DHCP): " virtual_ip
	
	create_default_config || return 1
	set_toml_value "network_name" "\"$network_name\"" "$CONFIG_FILE"
	set_toml_value "network_secret" "\"$network_secret\"" "$CONFIG_FILE"
	
	if [ -z "$virtual_ip" ]; then
		echo -e "${YELLOW}未输入IP，将启用 DHCP 自动获取地址。${NC}"
		set_toml_value "dhcp" "true" "$CONFIG_FILE"
		set_toml_value "ipv4" "\"\"" "$CONFIG_FILE"
	else
		echo -e "${GREEN}已设置静态IP: ${virtual_ip}${NC}"
		set_toml_value "dhcp" "false" "$CONFIG_FILE"
		set_toml_value "ipv4" "\"$virtual_ip\"" "$CONFIG_FILE"
	fi

	# [静默自动化改造]
	create_service_file
	reload_service_daemon
	enable_service
	restart_service
	echo -e "${GREEN}--- 网络已部署完成，开机自启已自动设置并激活运行！ ---${NC}"
}

join_existing_network() { 
	check_installed || return 1
	read -p "请输入网络名称: " network_name
	read -p "请输入网络密钥: " network_secret
	read -p "请输入此节点虚拟IP (留空则启用DHCP): " virtual_ip
	read -p "请输入一个对端节点地址 (回车默认为 tcp://public.easytier.top:11010): " peer_address
	if [ -z "$peer_address" ]; then
		peer_address="tcp://public.easytier.top:11010"
		echo -e "${YELLOW}使用默认对端节点: ${peer_address}${NC}"
	fi

	create_default_config || return 1
	set_toml_value "network_name" "\"$network_name\"" "$CONFIG_FILE"
	set_toml_value "network_secret" "\"$network_secret\"" "$CONFIG_FILE"
	echo -e "\n[[peer]]\nuri = \"${peer_address}\"" >> "$CONFIG_FILE"

	if [ -z "$virtual_ip" ]; then
		echo -e "${YELLOW}未输入IP，将启用 DHCP 自动获取地址。${NC}"
		set_toml_value "dhcp" "true" "$CONFIG_FILE"
		set_toml_value "ipv4" "\"\"" "$CONFIG_FILE"
	else
		echo -e "${GREEN}已设置静态IP: ${virtual_ip}${NC}"
		set_toml_value "dhcp" "false" "$CONFIG_FILE"
		set_toml_value "ipv4" "\"$virtual_ip\"" "$CONFIG_FILE"
	fi

	# [静默自动化改造]
	create_service_file
	reload_service_daemon
	enable_service
	restart_service
	echo -e "${GREEN}--- 成功加入网络，开机自启已自动设置并激活运行！ ---${NC}"
}

uninstall_easytier() { 
	read -p "警告: 此操作将停止服务并删除所有相关文件。确定要卸载吗? (y/n): " confirm; 
	if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then echo "操作已取消。"; return; fi; 
	echo "正在停止并禁用服务..."; stop_service &> /dev/null; disable_service &> /dev/null; 
	echo "正在删除文件..."; rm -f "${SERVICE_FILE}" "${INSTALL_DIR}/${CORE_BINARY_NAME}" "${INSTALL_DIR}/${CLI_BINARY_NAME}"; 
	rm -rf "${CONFIG_DIR}"; remove_shortcut; 
	if [[ "$OS_TYPE" == "linux" ]]; then systemctl daemon-reload; fi; 
	if [[ "$OS_TYPE" == "macos" || "$OS_TYPE" == "alpine" ]]; then rm -f "$LOG_FILE"; fi; 
	echo -e "${GREEN}EasyTier 已成功卸载。${NC}"; 
}

# --- 主菜单 ---
main() {
	# 优化 sed 兼容性，避免在精简 Linux/Alpine 上报错
	set_toml_value() {
		sed -i "s|^#* *${1} *=.*|${1} = ${2}|" "$3"
	}

	case "$(uname)" in
		Linux) if [ -f /etc/alpine-release ]; then OS_TYPE="alpine"; SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"; else OS_TYPE="linux"; SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"; fi ;;
		Darwin) OS_TYPE="macos"; SERVICE_FILE="/Library/LaunchDaemons/${SERVICE_LABEL}.plist"; ;;
		*) echo -e "${RED}错误: 不支持的操作系统: $(uname)${NC}"; exit 1 ;;
	esac
	check_root; check_dependencies
	
	while true; do
		clear
		
		# 提取面板需要的状态参数
		G_STATUS=$(get_runtime_status)
		G_VERSION=$(get_version)
		G_NETNAME=$(get_network_name)

		echo -e "${GREEN}================================${RESET}"
		echo -e "${GREEN}        EasyTier 管理面板        ${RESET}"
		echo -e "${GREEN}================================${RESET}"
		echo -e "${GREEN}状态   :${RESET} $G_STATUS"
		echo -e "${GREEN}版本   :${RESET} ${YELLOW}${G_VERSION}${RESET}"
		echo -e "${GREEN}网络组 :${RESET} ${YELLOW}${G_NETNAME}${RESET}"
		echo -e "${GREEN}================================${RESET}"
		echo -e "${GREEN} 1. 安装 EasyTier${RESET}"
		echo -e "${GREEN} 2. 更新 EasyTier${RESET}"
		echo -e "${GREEN} 3. 卸载 EasyTier${RESET}"
		echo -e "${GREEN} 4. 部署新网络 (首个节点)${RESET}"
		echo -e "${GREEN} 5. 加入组网网络${RESET}"
		echo -e "${GREEN} 6. 查看配置文件${RESET}"
		echo -e "${GREEN} 7. 查看网络节点${RESET}"
		echo -e "${GREEN} 8. 启动 EasyTier 服务${RESET}"
		echo -e "${GREEN} 9. 停止 EasyTier 服务${RESET}"
		echo -e "${GREEN}10. 重启 EasyTier 服务${RESET}"
		echo -e "${GREEN}11. 查看运行日志${RESET}"
		echo -e "${GREEN}12. 详细查看服务底层状态${RESET}"
		echo -e "${GREEN} 0. 退出${RESET}"
		echo -e "${GREEN}================================${RESET}"
		echo -ne "${GREEN}请输入选项: ${RESET}"
		read -r choice
		
		echo
		
		case $choice in
			1) install_easytier ;;
			2) install_easytier ;;
			3) uninstall_easytier ;;
			4) deploy_new_network ;;
			5) join_existing_network ;;
			6) if check_installed && [ -f "$CONFIG_FILE" ]; then cat "$CONFIG_FILE"; else echo -e "${YELLOW}配置文件不存在或未安装。${NC}"; fi ;;
			7) if check_installed; then "${INSTALL_DIR}/${CLI_BINARY_NAME}" peer; fi ;;
			8) start_service && echo -e "${GREEN}服务已激活。${NC}" ;;
			9) stop_service && echo -e "${GREEN}服务已关闭。${NC}" ;;
			10) restart_service && echo -e "${GREEN}服务已重新启动。${NC}" ;;
			11) log_service ;;
			12) status_service ;;
			0) exit 0 ;;
			*) echo -e "${RED}无效输入${NC}" ;;
		esac
		echo
		printf "${YELLOW}按回车键返回主菜单...${NC}" && read -r _
	done
}

main "$@"
