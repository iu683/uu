#!/bin/bash
set -e

FRP_INSTALL_DIR="/opt/frp"
FRPS_BIN="/usr/local/bin/frps"
FRPC_BIN="/usr/local/bin/frpc"
ROLE_FILE="$FRP_INSTALL_DIR/.frp_role"
INIT_FLAG="$FRP_INSTALL_DIR/.frp_inited"
IS_OPENWRT=0

# Github 反代加速代理
GITHUB_PROXY=('https://v6.gh-proxy.org/' 'https://gh-proxy.com/' 'https://hub.glowp.xyz/' 'https://proxy.vvvv.ee/' 'https://ghproxy.lvedong.eu.org/')

# 定义标准颜色
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RED="\e[31m"
RESET="\e[0m"

is_openwrt() { [ -f /etc/openwrt_release ] && IS_OPENWRT=1 || IS_OPENWRT=0; }
is_openwrt

# 自动创建别名/快捷键 'p'
create_shortcut() {
    local script_path=$(readlink -f "$0" 2>/dev/null || echo "$(cd "$(dirname "$0")"; pwd)/$(basename "$0")")
    if [ "$IS_OPENWRT" = "1" ]; then
        if ! grep -q "alias p=" /etc/profile; then
            echo "alias p='$script_path'" >> /etc/profile
            echo -e "${GREEN}[快捷键] 已成功为 OpenWrt 创建快捷键 'p'。${RESET}"
        fi
    else
        for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [ -f "$rc_file" ] && ! grep -q "alias p=" "$rc_file"; then
                echo "alias p='sudo $script_path'" >> "$rc_file"
                echo -e "${GREEN}[快捷键] 已成功在 $rc_file 中创建快捷键 'p'。${RESET}"
            fi
        done
    fi
}

# 动态测试最快的 GitHub 代理节点
get_fastest_proxy() {
    echo -e "${YELLOW}正在对 GitHub 加速节点进行延迟测速...${RESET}"
    local fastest=""
    local min_time=999999
    
    for proxy in "${GITHUB_PROXY[@]}"; do
        local start_time=$(date +%s%N 2>/dev/null || date +%s)
        if curl -o /dev/null -s -m 3 --connect-timeout 2 "$proxy"; then
            local end_time=$(date +%s%N 2>/dev/null || date +%s)
            local duration=$(( (end_time - start_time) / 1000000 )) 
            [ $duration -le 0 ] && duration=$(( (end_time - start_time) * 1000 ))
            
            echo -e " 节点: ${CYAN}$proxy${RESET} -> 延迟: ${YELLOW}${duration}ms${RESET}"
            if [ $duration -lt $min_time ]; then
                min_time=$duration
                fastest=$proxy
            fi
        else
            echo -e " 节点: ${RED}$proxy (连接超时)${RESET}"
        fi
    done

    if [ -z "$fastest" ]; then
        echo -e "${RED}[警告] 所有加速节点均不可用，将尝试直连 GitHub。${RESET}"
        echo ""
    else
        echo -e "${GREEN}[优选] 已自动选择最快节点：${fastest} (延迟: ${min_time}ms)${RESET}\n"
        echo "$fastest"
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

# 交互式获取版本号，支持手动输入
get_target_ver() {
    local proxy_node=$1
    local version=""
    
    # 尝试自动从 API 抓取一次
    version=$(curl -sL -m 4 "${proxy_node}https://api.github.com/repos/fatedier/frp/releases/latest" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *//;s/"//g;s/v//' || echo "")
    
    if [ -z "$version" ]; then
        echo -e "${YELLOW}[提示] 无法通过代理从 GitHub API 获取最新版本号。${RESET}"
        read -p "请输入你想安装的 FRP 版本号 [默认 0.69.1]: " user_ver
        version=${user_ver:-"0.69.1"}
    else
        read -p "检测到最新版本为 v${version}，是否直接安装？若需指定版本请输入（如 0.69.1），直接回车按检测版本安装: " user_ver
        if [ -n "$user_ver" ]; then
            version="$user_ver"
        fi
    fi
    # 过滤掉用户误输入的 'v' 字符
    version=$(echo "$version" | sed 's/v//g')
    echo "$version"
}

detect_role() {
    [ -f "$ROLE_FILE" ] && cat "$ROLE_FILE" || echo "unknown"
}

is_inited() { [ -f "$INIT_FLAG" ]; }

get_status_info() {
    local role=$(detect_role)
    
    if [ "$role" = "server" ] && [ -f "$FRPS_BIN" ]; then
        version=$($FRPS_BIN -v 2>/dev/null || echo "未知")
    elif [ "$role" = "client" ] && [ -f "$FRPC_BIN" ]; then
        version=$($FRPC_BIN -v 2>/dev/null || echo "未知")
    else
        version="未安装"
    fi

    if [ "$role" = "server" ]; then
        if [ "$IS_OPENWRT" = "1" ]; then
            (ps | grep -v grep | grep -q "[f]rps") && status="${GREEN}已启动${RESET}" || status="${RED}已停止${RESET}"
        else
            (systemctl is-active --quiet frps 2>/dev/null) && status="${GREEN}已启动${RESET}" || status="${RED}已停止${RESET}"
        fi
        PORT_SHOW=$(awk -F'=' '/webServer.port/{gsub(/ /,"",$2);print $2}' "$FRP_INSTALL_DIR/frps.toml" 2>/dev/null || echo "7500")
    elif [ "$role" = "client" ]; then
        if [ "$IS_OPENWRT" = "1" ]; then
            (ps | grep -v grep | grep -q "[f]rpc") && status="${GREEN}已启动${RESET}" || status="${RED}已停止${RESET}"
        else
            (systemctl is-active --quiet frpc 2>/dev/null) && status="${GREEN}已启动${RESET}" || status="${RED}已停止${RESET}"
        fi
        PORT_SHOW=$(awk -F'=' '/serverPort/{gsub(/ /,"",$2);print $2}' "$FRP_INSTALL_DIR/frpc.toml" 2>/dev/null || echo "7000")
    else
        status="${RED}未初始化${RESET}"
        PORT_SHOW="无"
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
        echo -e "${RED}[提示] 检测到系统已安装 FRPS，如需更新请使用功能 [2. 更新 FRPS]${RESET}"
        read -p "按回车返回菜单..."
        return
    elif [ "$role" = "client" ] && [ -f "$FRPC_BIN" ]; then
        echo -e "${RED}[提示] 检测到系统已安装 FRPC，如需更新请使用功能 [2. 更新 FRPC]${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    local proxy=$(get_fastest_proxy)
    FRP_VER=$(get_target_ver "$proxy")
    ARCH=$(get_arch)
    FRP_NAME="frp_${FRP_VER}_linux_${ARCH}"
    
    echo -e "\n正在通过加密加速通道下载 v${FRP_VER} (${ARCH}) ..."
    if ! wget -O "${FRP_NAME}.tar.gz" "${proxy}https://github.com/fatedier/frp/releases/download/v${FRP_VER}/${FRP_NAME}.tar.gz"; then
        echo -e "${RED}[错误] 下载失败，请检查版本号 [ ${FRP_VER} ] 是否在全球 GitHub 真实存在！${RESET}"
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
    if [ "$role" = "server" ] && [ ! -f "$FRPS_BIN" ]; then
        echo -e "${RED}[错误] 未检测到已安装的 FRPS，请先使用功能 [1. 安装]${RESET}"
        read -p "按回车返回菜单..."
        return
    elif [ "$role" = "client" ] && [ ! -f "$FRPC_BIN" ]; then
        echo -e "${RED}[错误] 未检测到已安装的 FRPC，请先使用功能 [1. 安装]${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    local proxy=$(get_fastest_proxy)
    local LATEST_VER=$(get_target_ver "$proxy")
    local CURRENT_VER=""
    
    if [ "$role" = "server" ]; then CURRENT_VER=$($FRPS_BIN -v 2>/dev/null || echo "0"); else CURRENT_VER=$($FRPC_BIN -v 2>/dev/null || echo "0"); fi

    if [ "$CURRENT_VER" = "$LATEST_VER" ]; then
        echo -e "${GREEN}[提示] 当前已是最新版本 v${CURRENT_VER}，无需更新。${RESET}"
        read -p "按回车返回菜单..."
        return
    fi

    echo -e "${YELLOW}发现新版本: v${CURRENT_VER} -> v${LATEST_VER}，开始无损升级...${RESET}"
    
    if [ "$role" = "server" ]; then
        [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps stop 2>/dev/null || systemctl stop frps 2>/dev/null
    else
        [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc stop 2>/dev/null || systemctl stop frpc 2>/dev/null
    fi

    cd "$FRP_INSTALL_DIR"
    local ARCH=$(get_arch)
    local FRP_NAME="frp_${LATEST_VER}_linux_${ARCH}"
    
    if ! wget -O "${FRP_NAME}.tar.gz" "${proxy}https://github.com/fatedier/frp/releases/download/v${LATEST_VER}/${FRP_NAME}.tar.gz"; then
        echo -e "${RED}[错误] 下载升级包失败，请确保版本号正确！${RESET}"
        # 恢复拉起原服务
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

    echo -e "${GREEN}FRP 成功升级至 v${LATEST_VER}，旧配置已完美保留并重启服务！${RESET}"
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
        awk '
        /\[\[proxies\]\]/ {if(name!="") printf "  %-11s | %-5s | %-10s | %-10s\n", name, type, lport, rport; name=""; type=""; lport=""; rport=""}
        /name =/ {gsub(/[ "]/,"",$3); name=$3}
        /type =/ {gsub(/[ "]/,"",$3); type=$3}
        /localPort =/ {gsub(/ /,"",$3); lport=$3}
        /remotePort =/ {gsub(/ /,"",$3); rport=$3}
        END {if(name!="") printf "  %-11s | %-5s | %-10s | %-10s\n", name, type, lport, rport}
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
        local DASH_PORT=$(awk -F'=' '/webServer.port/{gsub(/ /,"",$2);print $2}' "$FRP_INSTALL_DIR/frps.toml")
        local DASH_USER=$(awk -F'=' '/webServer.user/{gsub(/[ "]/,"",$2);print $2}' "$FRP_INSTALL_DIR/frps.toml")
        local DASH_PWD=$(awk -F'=' '/webServer.password/{gsub(/[ "]/,"",$2);print $2}' "$FRP_INSTALL_DIR/frps.toml")
        local DASH_IP=$(hostname -I | awk '{print $1}')
        
        echo -e "${GREEN}地址   :${RESET} ${CYAN}http://$DASH_IP:${DASH_PORT:-7500}${RESET}"
        echo -e "${GREEN}用户名 :${RESET} ${YELLOW}${DASH_USER:-admin}${RESET}"
        echo -e "${GREEN}密码   :${RESET} ${YELLOW}${DASH_PWD:-admin123}${RESET}"
    else
        echo -e "${RED}未找到配置文件${RESET}"
    fi
    echo -e "${GREEN}================================${RESET}"
    read -p "按回车返回菜单..."
}

# ------------------- 服务端管理面板 -------------------
server_menu() {
    while true; do
        clear
        get_status_info
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}       FRPS 服务端管理面板      ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}状态   :${RESET} $status"
        echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
        echo -e "${GREEN}面板端口:${RESET} ${YELLOW}${PORT_SHOW}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}1. 安装 FRPS${RESET}"
        echo -e "${GREEN}2. 更新 FRPS${RESET}"
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

# ------------------- 客户端管理面板 -------------------
client_menu() {
    while true; do
        clear
        get_status_info
        echo -e "${CYAN}================================${RESET}"
        echo -e "${CYAN}       FRPC 客户端管理面板      ${RESET}"
        echo -e "${CYAN}================================${RESET}"
        echo -e "${CYAN}状态   :${RESET} $status"
        echo -e "${CYAN}version:${RESET} ${YELLOW}${version}${RESET}"
        echo -e "${CYAN}连接端口:${RESET} ${YELLOW}${PORT_SHOW}${RESET}"
        echo -e "${CYAN}================================${RESET}"
        
        print_embedded_rules
        echo -e "${CYAN}================================${RESET}"
        
        echo -e "${CYAN}1. 安装 FRPC${RESET}"
        echo -e "${CYAN}2. 更新 FRPC${RESET}"
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
create_shortcut

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
