#!/bin/bash
set -e

FRP_INSTALL_DIR="/opt/frp"
FRPS_BIN="/usr/local/bin/frps"
FRPC_BIN="/usr/local/bin/frpc"
ROLE_FILE="$FRP_INSTALL_DIR/.frp_role"
INIT_FLAG="$FRP_INSTALL_DIR/.frp_inited"
LOCAL_SCRIPT="/opt/frp/frp_manager.sh"
IS_OPENWRT=0

G_STATUS=""
G_VERSION=""
G_PORT=""

# GitHub 轮询节点列表（最后一个为空代表直连）
GITHUB_PROXY=(
    'https://gh-proxy.com/'
    'https://v6.gh-proxy.org/'
    'https://ghproxy.lvedong.eu.org/'
    'https://proxy.vvvv.ee/'
    'https://hub.glowp.xyz/'
    '' 
)

# 终极保底硬编码版本
DEFAULT_BACKUP_VER="0.69.1"

# 标准颜色
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RED="\e[31m"
RESET="\e[0m"

is_openwrt() { [ -f /etc/openwrt_release ] && IS_OPENWRT=1 || IS_OPENWRT=0; }
is_openwrt

# ================= 核心改进：远程流式执行自我克隆与快捷键绑定 =================
init_and_clone_self() {
    # 确保本地长效目录存在
    mkdir -p "$FRP_INSTALL_DIR"

    # 判断当前执行路径是否为本地固定路径
    # 如果是用 bash <(curl...) 运行的，$0 会是 /dev/fd/... 或 -bash
    if [[ "$0" != "$LOCAL_SCRIPT" ]]; then
        echo -e "${YELLOW}[系统初始化] 检测到远程/临时流式运行，正在将其固化到本地...${RESET}"
        
        # 将当前正在运行的脚本流，复制保存到本地目标长效路径
        cat "$0" > "$LOCAL_SCRIPT" 2>/dev/null || curl -sL https://raw.githubusercontent.com/iu683/uu/main/oo.sh > "$LOCAL_SCRIPT"
        chmod +x "$LOCAL_SCRIPT"

        # 强制将系统全局快捷键 'p' 软链接到这个固定文件
        if [ -w /usr/bin ]; then
            ln -sf "$LOCAL_SCRIPT" /usr/bin/p 2>/dev/null
            echo -e "${GREEN}[快捷键] 成功创建系统全局快捷键 'p'，下次直接输入 p 即可呼出面板。${RESET}"
        else
            # 兼容无 /usr/bin 写权限的特殊环境（如某些特定 OpenWrt）
            for rc_file in "/etc/profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
                if [ -f "$rc_file" ] && ! grep -q "alias p=" "$rc_file"; then
                    echo "alias p='$LOCAL_SCRIPT'" >> "$rc_file"
                fi
            done
            echo -e "${GREEN}[快捷键] 已尝试向环境配置文件注入 alias p 快捷键。${RESET}"
        fi
        
        # 固化完成后，直接无缝切换到本地长效脚本继续执行，避免管道中断
        exec "$LOCAL_SCRIPT" "$@"
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
    echo -e "${YELLOW}正在尝试获取 GitHub 远端最新 FRP 版本号...${RESET}" >&2

    for proxy in "${GITHUB_PROXY[@]}"; do
        if [ -z "$proxy" ]; then
            echo -e "${YELLOW} -> 正在尝试[直连]获取 GitHub API...${RESET}" >&2
        else
            echo -e "${YELLOW} -> 正在尝试通过节点 [ ${proxy} ] 获取 GitHub API...${RESET}" >&2
        fi

        fetched_ver=$(curl -sL -m 4 "${proxy}https://api.github.com/repos/fatedier/frp/releases/latest" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *//;s/"//g;s/v//' || echo "")
        
        if [ -n "$fetched_ver" ]; then
            echo -e "${GREEN}[成功] 成功获取到最新版本号: v${fetched_ver}${RESET}" >&2
            echo "$fetched_ver"
            return 0
        fi
        echo -e "${RED}    失败，尝试下一个渠道...${RESET}" >&2
    done

    echo -e "${YELLOW}[提示] 无法获取远端版本，激活保底机制，采用预设版本: v${DEFAULT_BACKUP_VER}${RESET}" >&2
    echo "$DEFAULT_BACKUP_VER"
}

download_package_loop() {
    local version=$1
    local arch=$2
    local filename="frp_${version}_linux_${arch}.tar.gz"
    local success=0

    echo -e "${YELLOW}开始下载 FRP 安装包 v${version} (${arch})...${RESET}"

    for proxy in "${GITHUB_PROXY[@]}"; do
        if [ -z "$proxy" ]; then
            echo -e "${YELLOW} -> 正在尝试[直连] GitHub 下载...${RESET}"
        else
            echo -e "${YELLOW} -> 正在尝试通过节点 [ ${proxy} ] 下载...${RESET}"
        fi

        local url="${proxy}https://github.com/fatedier/frp/releases/download/v${version}/${filename}"
        
        if wget -T 8 -O "$filename" "$url"; then
            echo -e "${GREEN}[成功] 安装包下载完成！${RESET}"
            success=1
            break
        else
            echo -e "${RED}    该节点下载失败或超时，自动切换下一个...${RESET}"
            rm -f "$filename"
        fi
    done

    if [ $success -eq 0 ]; then
        echo -e "${RED}[严重错误] 所有加速节点及直连下载均已尝试，全部失败！${RESET}"
        return 1
    fi
    return 0
}

detect_role() {
    [ -f "$ROLE_FILE" ] && cat "$ROLE_FILE" || echo "unknown"
}

is_inited() { [ -f "$INIT_FLAG" ]; }

update_status_variables() {
    local role=$(detect_role)
    G_VERSION="未安装"
    G_STATUS="${RED}已停止${RESET}"
    G_PORT="无"

    if [ "$role" = "server" ]; then
        if [ -f "$FRPS_BIN" ]; then
            G_VERSION=$($FRPS_BIN -v 2>/dev/null || echo "未知")
        fi
        if [ "$IS_OPENWRT" = "1" ]; then
            (ps | grep -v grep | grep -q "[f]rps") && G_STATUS="${GREEN}已启动${RESET}"
        else
            (systemctl is-active --quiet frps 2>/dev/null) && G_STATUS="${GREEN}已启动${RESET}"
        fi
        G_PORT=$(awk -F'=' '/webServer\.port/{gsub(/[ "]/,"",$2); print $2}' "$FRP_INSTALL_DIR/frps.toml" 2>/dev/null)
        [ -z "$G_PORT" ] && G_PORT=$(awk -F'=' '/bindPort/{gsub(/[ "]/,"",$2); print $2}' "$FRP_INSTALL_DIR/frps.toml" 2>/dev/null)
        G_PORT=${G_PORT:-"7000"}

    elif [ "$role" = "client" ]; then
        if [ -f "$FRPC_BIN" ]; then
            G_VERSION=$($FRPC_BIN -v 2>/dev/null || echo "未知")
        fi
        if [ "$IS_OPENWRT" = "1" ]; then
            (ps | grep -v grep | grep -q "[f]rpc") && G_STATUS="${GREEN}已启动${RESET}"
        else
            (systemctl is-active --quiet frpc 2>/dev/null) && G_STATUS="${GREEN}已启动${RESET}"
        fi
        G_PORT=$(awk -F'=' '/serverPort/{gsub(/[ "]/,"",$2); print $2}' "$FRP_INSTALL_DIR/frpc.toml" 2>/dev/null)
        G_PORT=${G_PORT:-"7000"}
    else
        G_STATUS="${RED}未初始化${RESET}"
    fi
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
        echo -e "${RED}[提示] 检测到系统已安装 FRPS，如需更新请使用功能 [2]${RESET}"
        read -p "按回车返回菜单..."
        return
    elif [ "$role" = "client" ] && [ -f "$FRPC_BIN" ]; then
        echo -e "${RED}[提示] 检测到系统已安装 FRPC，如需更新请使用功能 [2]${RESET}"
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
    echo -e "${YELLOW}请务必选择选项 [3. 初始化配置并启动] 激活服务！${RESET}"
    read -p "按回车返回菜单..."
}

update_frp() {
    local role=$(detect_role)
    local BIN_PATH="$FRPC_BIN"
    local SYS_NAME="frpc"
    [ "$role" = "server" ] && BIN_PATH="$FRPS_BIN" && SYS_NAME="frps"

    if [ ! -f "$BIN_PATH" ]; then
        echo -e "${RED}[错误] 未检测到已安装的组件，请先使用功能 [1. 安装]${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    local LATEST_VER=$(get_auto_version)
    local CURRENT_VER=$($BIN_PATH -v 2>/dev/null || echo "0")

    if [ "$CURRENT_VER" = "$LATEST_VER" ]; then
        echo -e "${GREEN}[提示] 当前已是最新/目标版本 v${CURRENT_VER}，无需更新。${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "${YELLOW}准备版本变更: v${CURRENT_VER} -> v${LATEST_VER}...${RESET}"
    
    if [ "$IS_OPENWRT" = "1" ]; then
        /etc/init.d/$SYS_NAME stop 2>/dev/null || true
    else
        systemctl stop $SYS_NAME 2>/dev/null || true
    fi

    cd "$FRP_INSTALL_DIR"
    local ARCH=$(get_arch)
    local FRP_NAME="frp_${LATEST_VER}_linux_${ARCH}"
    
    if ! download_package_loop "$LATEST_VER" "$ARCH"; then
        [ "$IS_OPENWRT" = "1" ] && /etc/init.d/$SYS_NAME start || systemctl start $SYS_NAME
        read -p "按回车返回菜单..."
        return
    fi
    
    tar -xzvf "${FRP_NAME}.tar.gz"
    cp -f "${FRP_NAME}/frps" "$FRPS_BIN"
    cp -f "${FRP_NAME}/frpc" "$FRPC_BIN"
    chmod +x "$FRPS_BIN" "$FRPC_BIN"
    rm -rf "${FRP_NAME}" "${FRP_NAME}.tar.gz"

    if [ "$IS_OPENWRT" = "1" ]; then
        /etc/init.d/$SYS_NAME restart
    else
        systemctl restart $SYS_NAME
    fi

    echo -e "${GREEN}FRP 成功变更至 v${LATEST_VER}，配置已完美保留并重启服务！${RESET}"
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

write_initd_frpc() {
cat > /etc/init.d/frpc <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
PROG=/usr/local/bin/frpc
CFG=/opt/frp/frpc.toml
start_service() {
    procd_open_instance
    procd_set_param command $PROG -c $CFG
    procd_set_param respawn
    procd_close_instance
}
EOF
chmod +x /etc/init.d/frpc
/etc/init.d/frpc enable
}

write_systemd_frpc() {
cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=frpc client
After=network.target
[Service]
Type=simple
ExecStart=$FRPC_BIN -c $FRP_INSTALL_DIR/frpc.toml
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
}

uninstall_frp() {
    echo "正在卸载 FRP..."
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
    rm -f /usr/bin/p 2>/dev/null || true
    rm -rf "$FRP_INSTALL_DIR" "$FRPS_BIN" "$FRPC_BIN"
    echo "FRP 已彻底卸载。"
    sleep 2
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

    cat > "$FRP_INSTALL_DIR/frps.toml" <<EOF
bindPort = $BIND_PORT
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
    echo -e "${GREEN}初始化成功并已尝试启动！${RESET}"
    sleep 1.5
}

init_frpc_and_start() {
    echo "=== 初始化 FRPC 公共参数 (TOML) ==="
    read -p "frps 服务器公网IP: " SERVER_IP
    while [[ -z "$SERVER_IP" ]]; do
        read -p "IP不能为空，请重新输入: " SERVER_IP
    done
    read -p "frps 端口 [默认7000]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-7000}
    read -p "Token（保持与服务端一致）: " FRP_TOKEN

    cat > "$FRP_INSTALL_DIR/frpc.toml" <<EOF
serverAddr = "$SERVER_IP"
serverPort = $SERVER_PORT
EOF
    [[ -n "$FRP_TOKEN" ]] && echo "auth.token = \"$FRP_TOKEN\"" >> "$FRP_INSTALL_DIR/frpc.toml"
    echo "" >> "$FRP_INSTALL_DIR/frpc.toml"

    if [ "$IS_OPENWRT" = "1" ]; then
        write_initd_frpc
        /etc/init.d/frpc restart
    else
        write_systemd_frpc
        systemctl restart frpc
        systemctl enable frpc
    fi
    echo "client" > "$ROLE_FILE"
    touch "$INIT_FLAG"
    echo -e "${GREEN}公共参数初始化成功！${RESET}"
    sleep 1.5
}

add_frpc_rule() {
    is_inited || { echo -e "${RED}请先初始化配置并启动 FRPC！${RESET}"; sleep 2; return; }
    echo "=== 添加 FRPC 端口规则 ==="
    while true; do
        read -p "规则唯一名称（如 nas, ssh, web）: " RULE_NAME
        if grep -q "name = \"$RULE_NAME\"" "$FRP_INSTALL_DIR/frpc.toml"; then
            echo -e "${RED}错误：规则名称 [$RULE_NAME] 已存在，请更换！${RESET}"
            continue
        fi

        while true; do
            echo "请选择协议类型："
            echo "1) tcp"
            echo "2) udp"
            read -p "请选择 [1-2]（默认1）: " TYPESEL
            case "$TYPESEL" in
                1|"") TYPE="tcp"; break ;;
                2) TYPE="udp"; break ;;
                *) echo "输入错误，只能输入 1 或 2" ;;
            esac
        done

        read -p "本地内网IP [默认 127.0.0.1]: " LOCAL_IP
        LOCAL_IP=${LOCAL_IP:-127.0.0.1}
        read -p "本地端口 (如局域网端口): " LOCAL_PORT
        read -p "外网映射VPS端口: " REMOTE_PORT

        cat >> "$FRP_INSTALL_DIR/frpc.toml" <<EOF
[[proxies]]
name = "$RULE_NAME"
type = "$TYPE"
localIp = "$LOCAL_IP"
localPort = $LOCAL_PORT
remotePort = $REMOTE_PORT

EOF
        echo -e "${GREEN}已成功添加规则 [$RULE_NAME]。${RESET}"
        read -p "是否继续添加规则？(y/n) [n]: " MORE
        [[ "$MORE" == "y" || "$MORE" == "Y" ]] || break
    done
    restart_frpc
}

delete_frpc_rule() {
    is_inited || { echo -e "${RED}请先初始化配置并启动 FRPC！${RESET}"; sleep 2; return; }
    echo -e "\n${CYAN}[当前规则列表]${RESET}"
    grep "name =" "$FRP_INSTALL_DIR/frpc.toml" || { echo "暂无任何转发规则"; sleep 1.5; return; }
    echo
    read -p "输入要删除的规则名称: " RULE
    
    if ! grep -q "name = \"$RULE\"" "$FRP_INSTALL_DIR/frpc.toml"; then
        echo -e "${RED}规则 [$RULE] 不存在！${RESET}"
        sleep 2
        return
    fi

    awk -v name="name = \"$RULE\"" '
    BEGIN {RS="\n\n"; FS="\n"}
    $0 ~ name {next}
    {print $0"\n"}
    ' "$FRP_INSTALL_DIR/frpc.toml" | sed '${/^$/d;}' > "$FRP_INSTALL_DIR/frpc.toml.tmp"
    
    mv "$FRP_INSTALL_DIR/frpc.toml.tmp" "$FRP_INSTALL_DIR/frpc.toml"
    echo -e "${GREEN}已成功删除规则 [$RULE]${RESET}"
    restart_frpc
    sleep 1.5
} 

print_embedded_rules() {
    if [ -f "$FRP_INSTALL_DIR/frpc.toml" ]; then
        echo -e "${CYAN} 规则名称     | 协议  | 内网端口   | 外网映射端口${RESET}"
        echo -e "${CYAN}------------------------------------------------${RESET}"
        awk -F'=' '
        BEGIN { name=""; type=""; lport=""; rport="" }
        /\[\[proxies\]\]/ {
            if(name!="") printf "  %-11s | %-5s | %-10s | %-10s\n", name, type, lport, rport;
            name=""; type=""; lport=""; rport=""
        }
        $1 ~ /name/      { gsub(/[ "]/, "", $2); name=$2 }
        $1 ~ /type/      { gsub(/[ "]/, "", $2); type=$2 }
        $1 ~ /localPort/ { gsub(/[ "]/, "", $2); lport=$2 }
        $1 ~ /remotePort/{ gsub(/[ "]/, "", $2); rport=$2 }
        END { if(name!="") printf "  %-11s | %-5s | %-10s | %-10s\n", name, type, lport, rport }
        ' "$FRP_INSTALL_DIR/frpc.toml" | while read -r line; do
            echo -e "${YELLOW}$line${RESET}"
        done
        if ! grep -q "\[\[proxies\]\]" "$FRP_INSTALL_DIR/frpc.toml"; then
            echo -e "   ${RED}(暂无转发规则，请选择 4 添加)${RESET}"
        fi
    else
        echo -e "   ${RED}配置文件未生成${RESET}"
    fi
}

start_frps() { [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps start || systemctl start frps; echo "frps 已启动"; sleep 1; }
stop_frps()  { [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps stop  || systemctl stop frps;  echo "frps 已停止"; sleep 1; }
restart_frps() { [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps restart || systemctl restart frps; echo "frps 已重启"; sleep 1; }

start_frpc() { [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc start || systemctl start frpc; echo "frpc 已启动"; sleep 1; }
stop_frpc()  { [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc stop  || systemctl stop frpc;  echo "frpc 已停止"; sleep 1; }
restart_frpc() { [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc restart || systemctl restart frpc; echo "frpc 已重启"; sleep 1; }

log_frps() {
    if [ "$IS_OPENWRT" = "1" ]; then logread | grep frps | tail -n 30 || echo "暂无日志"; else journalctl -u frps -n 40 --no-pager; fi
    read -p "按回车返回菜单..."
}
log_frpc() {
    if [ "$IS_OPENWRT" = "1" ]; then logread | grep frpc | tail -n 30 || echo "暂无日志"; else journalctl -u frpc -n 40 --no-pager; fi
    read -p "按回车返回菜单..."
}

show_frps_dashboard_info() {
    clear
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}       FRPS 面板认证详情        ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    if [ -f "$FRP_INSTALL_DIR/frps.toml" ]; then
        local DASH_PORT=$(awk -F'=' '/webServer\.port/{gsub(/[ "]/,"",$2);print $2}' "$FRP_INSTALL_DIR/frps.toml")
        local DASH_USER=$(awk -F'=' '/webServer\.user/{gsub(/[ "]/,"",$2);print $2}' "$FRP_INSTALL_DIR/frps.toml")
        local DASH_PWD=$(awk -F'=' '/webServer\.password/{gsub(/[ "]/,"",$2);print $2}' "$FRP_INSTALL_DIR/frps.toml")
        local DASH_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
        
        echo -e "${GREEN}地址   :${RESET} ${CYAN}http://$DASH_IP:${DASH_PORT:-7500}${RESET}"
        echo -e "${GREEN}用户名 :${RESET} ${YELLOW}${DASH_USER:-admin}${RESET}"
        echo -e "${GREEN}密码   :${RESET} ${YELLOW}${DASH_PWD:-admin123}${RESET}"
    else
        echo -e "${RED}未找到配置文件${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
    read -p "按回车返回菜单..."
}

server_menu() {
    while true; do
        update_status_variables
        clear
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}       FRPS 服务端管理面板      ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $G_STATUS"
        echo -e "${GREEN}版本   :${RESET} ${YELLOW}${G_VERSION}${RESET}"
        echo -e "${GREEN}面板端口:${RESET} ${YELLOW}${G_PORT}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}1. 安装 FRPS${RESET}"
        echo -e "${GREEN}2. 更新/同步版本${RESET}"
        echo -e "${GREEN}3. 初始化配置并启动${RESET}"
        echo -e "${GREEN}4. 启动 FRPS 服务${RESET}"
        echo -e "${GREEN}5. 停止 FRPS 服务${RESET}"
        echo -e "${GREEN}6. 重启 FRPS 服务${RESET}"
        echo -e "${GREEN}7. 查看面板信息${RESET}"
        echo -e "${GREEN}8. 查看运行日志${RESET}"
        echo -e "${GREEN}9. 卸载 FRPS 服务${RESET}"
        echo -e "${GREEN}0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -ne "${GREEN}请输入选项: ${RESET}"
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
            *) echo -e "${RED}无效选项！${RESET}" && sleep 1 ;;
        esac
    done
}

client_menu() {
    while true; do
        update_status_variables
        clear
        echo -e "${CYAN}================================${RESET}"
        echo -e "${CYAN}       FRPC 客户端管理面板      ${RESET}"
        echo -e "${CYAN}================================${RESET}"
        echo -e "${CYAN}状态   :${RESET} $G_STATUS"
        echo -e "${CYAN}version:${RESET} ${YELLOW}${G_VERSION}${RESET}"
        echo -e "${CYAN}连接端口:${RESET} ${YELLOW}${G_PORT}${RESET}"
        echo -e "${CYAN}================================${RESET}"
        
        print_embedded_rules
        echo -e "${CYAN}================================${RESET}"
        
        echo -e "${CYAN}1. 安装 FRPC${RESET}"
        echo -e "${CYAN}2. 更新/同步版本${RESET}"
        echo -e "${CYAN}3. 初始化公共参数并启动${RESET}"
        echo -e "${CYAN}4. 新增本地端口转发规则${RESET}"
        echo -e "${CYAN}5. 删除本地端口转发规则${RESET}"
        echo -e "${CYAN}6. 启动 FRPC 服务${RESET}"
        echo -e "${CYAN}7. 停止 FRPC 服务${RESET}"
        echo -e "${CYAN}8. 重启 FRPC 服务${RESET}"
        echo -e "${CYAN}9. 查看运行日志${RESET}"
        echo -e "${CYAN}10. 卸载 FRPC 服务${RESET}"
        echo -e "${CYAN}0. 退出${RESET}"
        echo -e "${CYAN}================================${RESET}"
        echo -ne "${CYAN}请输入选项: ${RESET}"
        read choice
        case $choice in
            1) install_frp ;;
            2) update_frp ;;
            3) init_frpc_and_start ;;
            4) add_frpc_rule ;;
            5) delete_frpc_rule ;;
            6) start_frpc ;;
            7) stop_frpc ;;
            8) restart_frpc ;;
            9) log_frpc ;;
            10) uninstall_frp ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项！${RESET}" && sleep 1 ;;
        esac
    done
}

# ---------- 启动主入口 ----------
# 第一步：检查执行模式并自动固化到本地、绑定快捷键
init_and_clone_self

# 第二步：检测角色并加载菜单
role="$(detect_role)"
case "$role" in
    server) server_menu ;;
    client) client_menu ;;
    *)
        select_role
        role2="$(detect_role)"
        [ "$role2" = "server" ] && server_menu
        [ "$role2" = "client" ] && client_menu
        ;;
esac
