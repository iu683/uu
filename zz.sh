#!/bin/bash
set -e

FRP_INSTALL_DIR="/opt/frp"
FRPS_BIN="/usr/local/bin/frps"
FRPC_BIN="/usr/local/bin/frpc"
ROLE_FILE="$FRP_INSTALL_DIR/.frp_role"
INIT_FLAG="$FRP_INSTALL_DIR/.frp_inited"
IS_OPENWRT=0

GITHUB_PROXY=(
    'https://gh-proxy.com/'
    'https://v6.gh-proxy.org/'
    'https://ghproxy.lvedong.eu.org/'
    'https://proxy.vvvv.ee/'
    'https://hub.glowp.xyz/'
    '' 
)

DEFAULT_BACKUP_VER="0.69.1"

GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RED="\e[31m"
RESET="\e[0m"

is_openwrt() { [ -f /etc/openwrt_release ] && IS_OPENWRT=1 || IS_OPENWRT=0; }
is_openwrt

create_shortcut() {
    local script_path=$(readlink -f "$0" 2>/dev/null || echo "$(cd "$(dirname "$0")"; pwd)/$(basename "$0")")
    if [ "$IS_OPENWRT" = "1" ]; then
        if ! grep -q "alias p=" /etc/profile; then
            echo "alias p='$script_path'" >> /etc/profile
        fi
    else
        for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [ -f "$rc_file" ] && ! grep -q "alias p=" "$rc_file"; then
                echo "alias p='sudo $script_path'" >> "$rc_file"
            fi
        done
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64";;
        aarch64) echo "arm64";;
        armv7*|armv6*) echo "arm";;
        mipsel) echo "mipsle";;
        mips) echo "mips";;
        *) echo "amd64";;
    esac
}

get_auto_version() {
    local fetched_ver=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        fetched_ver=$(curl -sL -m 4 "${proxy}https://api.github.com/repos/fatedier/frp/releases/latest" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *//;s/"//g;s/v//' || echo "")
        if [ -n "$fetched_ver" ]; then
            echo "$fetched_ver"
            return 0
        fi
    done
    echo "$DEFAULT_BACKUP_VER"
}

download_package_loop() {
    local version=$1
    local arch=$2
    local filename="frp_${version}_linux_${arch}.tar.gz"
    local success=0
    for proxy in "${GITHUB_PROXY[@]}"; do
        local url="${proxy}https://github.com/fatedier/frp/releases/download/v${version}/${filename}"
        if wget -T 8 -O "$filename" "$url"; then
            success=1
            break
        else
            rm -f "$filename"
        fi
    done
    [ $success -eq 1 ] && return 0 || return 1
}

detect_role() {
    [ -f "$ROLE_FILE" ] && cat "$ROLE_FILE" || echo "unknown"
}

is_inited() { [ -f "$INIT_FLAG" ]; }

get_status_info() {
    local role=$(detect_role)
    local current_bin_ver="未安装"
    
    if [ "$role" = "server" ] && [ -f "$FRPS_BIN" ]; then
        current_bin_ver=$($FRPS_BIN -v 2>/dev/null || echo "未知")
    elif [ "$role" = "client" ] && [ -f "$FRPC_BIN" ]; then
        current_bin_ver=$($FRPC_BIN -v 2>/dev/null || echo "未知")
    fi

    if [ "$role" = "server" ]; then
        # 增强版进程探测：双重保障检测机制
        if [ "$IS_OPENWRT" = "1" ]; then
            (ps | grep -v grep | grep -q "[f]rps") && status="${GREEN}已启动${RESET}" || status="${RED}已停止${RESET}"
        else
            if systemctl is-active frps >/dev/null 2>&1 || pgrep -x "frps" >/dev/null; then
                status="${GREEN}已启动${RESET}"
            else
                status="${RED}已停止${RESET}"
            fi
        fi
        
        # 提取端口显示
        if [ -f "$FRP_INSTALL_DIR/frps.toml" ]; then
            PORT_SHOW=$(awk -F'=' '/webServer.port/{gsub(/[ "]/,"",$2); print $2}' "$FRP_INSTALL_DIR/frps.toml")
            [ -z "$PORT_SHOW" ] && PORT_SHOW=$(awk -F'=' '/bindPort/{gsub(/[ "]/,"",$2); print $2}' "$FRP_INSTALL_DIR/frps.toml")
            PORT_SHOW=${PORT_SHOW:-"7500"}
        else
            PORT_SHOW="无"
        fi
    elif [ "$role" = "client" ]; then
        if [ "$IS_OPENWRT" = "1" ]; then
            (ps | grep -v grep | grep -q "[f]rpc") && status="${GREEN}已启动${RESET}" || status="${RED}已停止${RESET}"
        else
            if systemctl is-active frpc >/dev/null 2>&1 || pgrep -x "frpc" >/dev/null; then
                status="${GREEN}已启动${RESET}"
            else
                status="${RED}已停止${RESET}"
            fi
        fi
        if [ -f "$FRP_INSTALL_DIR/frpc.toml" ]; then
            PORT_SHOW=$(awk -F'=' '/serverPort/{gsub(/[ "]/,"",$2); print $2}' "$FRP_INSTALL_DIR/frpc.toml")
            PORT_SHOW=${PORT_SHOW:-"7000"}
        else
            PORT_SHOW="无"
        fi
    else
        status="${RED}未初始化${RESET}"
        PORT_SHOW="无"
    fi
    echo "$current_bin_ver" > /dev/null
    echo "$current_bin_ver"
}

select_role() {
    clear
    echo -e "${YELLOW}[自动检测] 当前本机未检测到已初始化的 FRP 服务端或客户端。${RESET}"
    echo "请选择本机角色："
    echo "1) FRPS 服务端 (用于公网VPS)"
    echo "2) FRPC 客户端 (用于内网/被穿透设备)"
    read -p "输入 1 或 2 并回车: " role
    mkdir -p "$FRP_INSTALL_DIR"
    case $role in
        1) echo "server" > "$ROLE_FILE" ;;
        2) echo "client" > "$ROLE_FILE" ;;
        *) echo "输入无效，重新运行脚本"; exit 1 ;;
    esac
}

install_frp() {
    local role=$(detect_role)
    if [ "$role" = "server" ] && [ -f "$FRPS_BIN" ]; then
        echo -e "${RED}[提示] 检测到系统已安装 FRPS${RESET}"
        read -p "按回车返回菜单..."
        return
    elif [ "$role" = "client" ] && [ -f "$FRPC_BIN" ]; then
        echo -e "${RED}[提示] 检测到系统已安装 FRPC${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    local FRP_VER=$(get_auto_version)
    local ARCH=$(get_arch)
    local FRP_NAME="frp_${FRP_VER}_linux_${ARCH}"
    
    mkdir -p "$FRP_INSTALL_DIR"
    cd "$FRP_INSTALL_DIR"

    if ! download_package_loop "$FRP_VER" "$ARCH"; then
        read -p "按回车返回菜单..."
        return
    fi
    
    tar -xzvf "${FRP_NAME}.tar.gz"
    cp -f "${FRP_NAME}/frps" "$FRPS_BIN"
    cp -f "${FRP_NAME}/frpc" "$FRPC_BIN"
    chmod +x "$FRPS_BIN" "$FRPC_BIN"
    rm -rf "${FRP_NAME}" "${FRP_NAME}.tar.gz"
    
    echo -e "${GREEN}FRP 二进制文件安装成功。${RESET}"
    read -p "按回车返回菜单..."
}

update_frp() {
    local role=$(detect_role)
    local LATEST_VER=$(get_auto_version)
    local CURRENT_VER=""
    
    if [ "$role" = "server" ]; then CURRENT_VER=$($FRPS_BIN -v 2>/dev/null || echo "0"); else CURRENT_VER=$($FRPC_BIN -v 2>/dev/null || echo "0"); fi
    if [ "$CURRENT_VER" = "$LATEST_VER" ]; then
        echo -e "${GREEN}[提示] 当前已是最新版本 v${CURRENT_VER}${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    if [ "$role" = "server" ]; then
        [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps stop 2>/dev/null || systemctl stop frps 2>/dev/null
    else
        [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc stop 2>/dev/null || systemctl stop frpc 2>/dev/null
    fi

    cd "$FRP_INSTALL_DIR"
    local ARCH=$(get_arch)
    local FRP_NAME="frp_${LATEST_VER}_linux_${ARCH}"
    
    if ! download_package_loop "$LATEST_VER" "$ARCH"; then
        if [ "$role" = "server" ]; then
            [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps start || systemctl start frps
        else
            [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc start || systemctl start frpc
        fi
        read -p "按回车返回菜单..."
        return
    fi
    
    tar -xzvf "${FRP_NAME}.tar.gz"
    cp -f "${FRP_NAME}/frps" "$FRPS_BIN"
    cp -f "${FRP_NAME}/frpc" "$FRPC_BIN"
    chmod +x "$FRPS_BIN" "$FRPC_BIN"
    rm -rf "${FRP_NAME}" "${FRP_NAME}.tar.gz"

    if [ "$role" = "server" ]; then
        [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps restart || systemctl restart frps
    else
        [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc restart || systemctl restart frpc
    fi
    read -p "按回车返回菜单..."
}

write_initd_frps() {
cat > /etc/init.d/frps <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
PROG=/usr/local/bin/frps
CFG=/opt/frp/frps.toml
start_service() {
    procd_open_instance
    procd_set_param command $PROG -c $CFG
    procd_set_param respawn
    procd_close_instance
}
EOF
chmod +x /etc/init.d/frps
/etc/init.d/frps enable
}

write_systemd_frps() {
cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frps server
After=network.target
[Service]
Type=simple
ExecStart=$FRPS_BIN -c $FRP_INSTALL_DIR/frps.toml
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
}

uninstall_frp() {
    if [ "$IS_OPENWRT" = "1" ]; then
        /etc/init.d/frps stop 2>/dev/null || true
        /etc/init.d/frpc stop 2>/dev/null || true
        rm -f /etc/init.d/frps /etc/init.d/frpc
    else
        systemctl stop frps frpc 2>/dev/null || true
        systemctl disable frps frpc 2>/dev/null || true
        rm -f /etc/systemd/system/frps.service /etc/systemd/system/frpc.service
        systemctl daemon-reload
    fi
    rm -rf "$FRP_INSTALL_DIR" "$FRPS_BIN" "$FRPC_BIN"
    sleep 1
    exit 0
}

init_frps_and_start() {
    echo "=== 初始化 FRPS 配置 (TOML) ==="
    read -p "监听端口 [默认7000]: " BIND_PORT
    BIND_PORT=${BIND_PORT:-7000}
    read -p "面板端口 [默认7500]: " DASH_PORT
    DASH_PORT=${DASH_PORT:-7500}
    read -p "面板用户名 [默认admin]: " DASH_USER
    DASH_USER=${DASH_USER:-admin}
    read -p "面板密码 [默认admin123]: " DASH_PWD
    DASH_PWD=${DASH_PWD:-admin123}
    read -p "Token（防蹭用，建议填写）: " FRP_TOKEN

    # 🛠️ 核心修正：显式指定 webServer.addr 为 0.0.0.0 允许全网外网访问
    cat > "$FRP_INSTALL_DIR/frps.toml" <<EOF
bindPort = $BIND_PORT
webServer.addr = "0.0.0.0"
webServer.port = $DASH_PORT
webServer.user = "$DASH_USER"
webServer.password = "$DASH_PWD"
EOF
    [[ -n "$FRP_TOKEN" ]] && echo "auth.token = \"$FRP_TOKEN\"" >> "$FRP_INSTALL_DIR/frps.toml"

    if [ "$IS_OPENWRT" = "1" ]; then
        write_initd_frps
        /etc/init.d/frps restart
    else
        write_systemd_frps
        systemctl restart frps
        systemctl enable frps
    fi
    echo "server" > "$ROLE_FILE"
    touch "$INIT_FLAG"
    sleep 1
}

start_frps() { [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps start || systemctl start frps; sleep 0.5; }
stop_frps()  { [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps stop  || systemctl stop frps;  sleep 0.5; }
restart_frps() { [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps restart || systemctl restart frps; sleep 0.5; }

log_frps() { [ "$IS_OPENWRT" = "1" ] && logread | grep frps | tail -n 30 || journalctl -u frps -n 40 --no-pager; read -p "按回车返回..."; }

show_frps_dashboard_info() {
    clear
    if [ -f "$FRP_INSTALL_DIR/frps.toml" ]; then
        local D_PORT=$(awk -F'=' '/webServer.port/{gsub(/[ "]/,"",$2);print $2}' "$FRP_INSTALL_DIR/frps.toml")
        echo -e "${GREEN}面板登录地址 :${RESET} ${CYAN}http://$(hostname -I | awk '{print $1}'):${D_PORT:-7500}${RESET}"
    fi
    read -p "按回车返回..."
}

server_menu() {
    while true; do
        clear
        local version_now=$(get_status_info)
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}       FRPS 服务端管理面板      ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $status"
        echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version_now}${RESET}"
        echo -e "${GREEN}面板端口:${RESET} ${YELLOW}${PORT_SHOW}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo "1. 安装 FRPS"
        echo "2. 更新/同步版本"
        echo "3. 初始化配置并启动"
        echo "4. 启动 FRPS 服务"
        echo "5. 停止 FRPS 服务"
        echo "6. 重启 FRPS 服务"
        echo "7. 查看面板信息"
        echo "8. 查看运行日志"
        echo "9. 卸载 FRPS 服务"
        echo "0. 退出"
        echo -e "${GREEN}================================${RESET}"
        echo -ne "请输入选项: "
        read choice
        case $choice in
            1) install_frp ;;
            2) update_frp ;;
            3) init_frps_and_start ;;
            4) start_frps ;;
            5) stop_frps ;;
            6) restart_frps ;;
            7) show_frps_dashboard_info ;;
            8) log_frps ;;
            9) uninstall_frp ;;
            0) exit 0 ;;
        esac
    done
}

create_shortcut
role="$(detect_role)"
server_menu
