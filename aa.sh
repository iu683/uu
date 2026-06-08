#!/usr/bin/env bash

# ==============================================================================
#   Usque (MASQUE-WARP) 面板 (含 Google 透明代理分流控制中心)
# ==============================================================================

export REPO="Diniboy1123/usque"
export SERVICE_NAME="usque"
export SERVICE_USER="root"
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
export META_FILE="${CONF_DIR}/.panel_meta"

# --- 透明代理专属变量定义 ---
export PROXY_SERVICE_NAME="usque-google-proxy"
export DATA_DIR="/var/lib/usque"
export REDSOCKS_CONF="${CONF_DIR}/redsocks.conf"
export PROXY_RULES_SCRIPT="${DATA_DIR}/google_rules.sh"
export PROXY_SERVICE_FILE="/etc/systemd/system/${PROXY_SERVICE_NAME}.service"

# 配色方案
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
RESET='\033[0m'

GITHUB_PROXY=('https://v6.gh-proxy.org/' 'https://gh-proxy.com/' 'https://hub.glowp.xyz/' 'https://proxy.vvvv.ee/' 'https://ghproxy.lvedong.eu.org/' '')

[[ "$EUID" -ne 0 ]] && echo -e "${RED}[错误]${RESET} 请使用 root 权限运行！" && exit 1

# 自动识别系统发行版 (适配透明代理的组件安装)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS="unknown"
fi

info() { echo -e "${GREEN}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }

# --- 依赖环境预检 ---
check_deps() {
    if ! command -v unzip >/dev/null 2>&1; then
        warn "未检测到 unzip 命令，正在尝试安装..."
        case $OS in
            ubuntu|debian) apt-get update -qy && apt-get install -y unzip >/dev/null 2>&1 ;;
            centos|rhel|rocky|almalinux|fedora) yum install -y unzip >/dev/null 2>&1 ;;
            *) die "未找到 unzip 且无法自动安装，请手动安装后重试。" ;;
        esac
    fi
}

# --- 1. 下载模块 ---
download_bin() {
    check_deps
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) TARGET="linux_amd64" ;;
        aarch64) TARGET="linux_arm64" ;;
        *) die "不支持的架构: $ARCH" ;;
    esac

    info "检索最新版本..."
    local latest_tag=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        latest_tag=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [ -n "$latest_tag" ] && break
    done

    [ -z "$latest_tag" ] && latest_tag="v3.0.0"
    local pure_ver="${latest_tag#v}"
    info "下载版本: v${pure_ver}"

    local zip_name="usque_${pure_ver}_${TARGET}.zip"
    local tmp_dir=$(mktemp -d)
    local success=0
    for proxy in "${GITHUB_PROXY[@]}"; do
        if curl -fsSL -L -o "$tmp_dir/zip" "${proxy}https://github.com/${REPO}/releases/download/${latest_tag}/${zip_name}"; then
            success=1; break
        fi
    done

    [ "$success" -ne 1 ] && { rm -rf "$tmp_dir"; die "下载失败。"; }
    unzip -q -o "$tmp_dir/zip" -d "$tmp_dir"
    cp -f "$tmp_dir/usque" "$INSTALL_BIN"
    chmod +x "$INSTALL_BIN"
    rm -rf "$tmp_dir"
}

# --- 2. 本地注册 ---
register_usque() {
    local has_v4=0
    if curl -4sSk --max-time 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "ip="; then
        has_v4=1
    fi

    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
    cd "$CONF_DIR" || exit 1
    
    info "正在执行本地匿名注册..."
    if "${INSTALL_BIN}" register; then
        ok "Cloudflare 本地注册成功。"
        
        if [ "$has_v4" -ne 1 ] && [ -f "$CONF_FILE" ]; then
            info "检测到纯 IPv6 环境，正在修正配置文件..."
            local v6_ep=$(grep -o '"endpoint_v6": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')
            if [ -z "$v6_ep" ]; then
                v6_ep="[2606:4700:d0::a25c:bc2e]:2408"
            fi
            sed -i "s/\"endpoint_v4\": *\"[^\"]*\"/\"endpoint_v4\": \"${v6_ep}\"/g" "$CONF_FILE"
            ok "IPv6 修正已完成 (Endpoint: $v6_ep)。"
        fi
    else
        die "注册失败。提示：请确保你的 VPS 已开启 IPv6 外部访问能力。"
    fi
}

# --- 3. 写入服务 ---
write_systemd() {
    local mode="$1" ip="$2" port="$3" user="$4" pass="$5"
    local cmd="socks"
    [[ "$mode" == "HTTP" ]] && cmd="http-proxy"

    local args="${cmd} -b ${ip} -p ${port}"
    [[ -n "$user" ]] && args="${args} -u \"${user}\" -w \"${pass}\""

    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Usque WARP SOCKS5/HTTP
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${CONF_DIR}
ExecStart=${INSTALL_BIN} --config ${CONF_FILE} ${args}
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    echo "${mode}|${ip}|${port}|${user}|${pass}" > "$META_FILE"
}

# --- 4. 状态获取 ---
get_status_info() {
    systemctl is-active --quiet "$SERVICE_NAME" && panel_status="运行中" || panel_status="未运行"
    if [ -f "$INSTALL_BIN" ]; then
        local ver=$("$INSTALL_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        panel_version="v${ver:-已安装}"
    else
        panel_version="未安装"
    fi
    if [ -f "$META_FILE" ]; then
        IFS='|' read -r m_mode m_ip m_port m_user m_pass < "$META_FILE"
        panel_port="${m_mode}://$m_ip:$m_port"
    else
        panel_port="未配置"
    fi
}

# --- 5. 修改配置 ---
menu_edit_config() {
    [ -f "$META_FILE" ] || die "未发现配置。"
    
    local o_mode o_ip o_port o_user o_pass
    local m_choice n_mode n_ip n_port i_user n_user i_pass n_pass
    
    IFS='|' read -r o_mode o_ip o_port o_user o_pass < "$META_FILE"

    echo -e "\n==== [修改监听配置] ===="
    echo -e "${YELLOW}说明：直接回车保持不变，输入 read 则清空该项${RESET}"
    
    echo "1. SOCKS5 模式"
    echo "2. HTTP 模式"
    read -r -p "选择模式 [当前: $o_mode]: " m_choice
    case "$m_choice" in
        1) n_mode="SOCKS5" ;;
        2) n_mode="HTTP" ;;
        *) n_mode="$o_mode" ;;
    esac

    read -r -p "监听 IP [当前: $o_ip]: " n_ip
    n_ip="${n_ip:-$o_ip}"

    read -r -p "监听端口 [当前: $o_port]: " n_port
    n_port="${n_port:-$o_port}"
    
    read -r -p "用户名 [当前: ${o_user:-空}]: " i_user
    if [ -z "$i_user" ]; then
        n_user="$o_user"
    elif [ "$i_user" = "read" ]; then
        n_user=""
    else
        n_user="$i_user"
    fi

    read -r -p "密码 [当前: ${o_pass:-空}]: " i_pass
    if [ -z "$i_pass" ]; then
        n_pass="$o_pass"
    elif [ "$i_pass" = "read" ]; then
        n_pass=""
    else
        n_pass="$i_pass"
    fi

    write_systemd "$n_mode" "$n_ip" "$n_port" "$n_user" "$n_pass"
    systemctl restart "$SERVICE_NAME" && ok "配置已更新并重启服务。"
    sleep 0.5
}

# --- 6. 验证逻辑 ---
menu_show_node_config() {
    [ -f "$META_FILE" ] || die "记录不存在。"
    local b_mode b_ip b_port b_user b_pass
    IFS='|' read -r b_mode b_ip b_port b_user b_pass < "$META_FILE"

    echo -e "\n========= 当前服务详情 ========="
    echo " 代理模式 : ${b_mode}"
    echo " 监听地址 : ${b_ip}:${b_port}"
    [[ -n "$b_user" ]] && echo " 鉴权信息 : ${b_user}:${b_pass}" || echo " 鉴权状态 : 未开启"
    echo "================================"

    local p_url="socks5://"
    [[ "$b_mode" == "HTTP" ]] && p_url="http://"
    [[ -n "$b_user" ]] && p_url="${p_url}${b_user}:${b_pass}@"
    
    local test_ip="$b_ip"
    [[ "$test_ip" == "0.0.0.0" ]] && test_ip="127.0.0.1"
    [[ "$test_ip" == "::" ]] && test_ip="[::1]"
    p_url="${p_url}${test_ip}:${b_port}"

    info "正在验证出口状态..."
    if curl -sS --max-time 10 -x "$p_url" "https://www.cloudflare.com/cdn-cgi/trace" | grep -q "warp=on"; then
        ok "验证成功！WARP 已开启。"
    else
        warn "验证失败，请检查端口、鉴权或端口是否受阻。"
    fi
}

# ==============================================================================
#   3. 透明代理二级专属菜单控制中心
# ==============================================================================
start_transparent_proxy() {
    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        warn "Google 透明分流代理已经处于启动运行状态，无需重复启动。"
        return
    fi

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        warn "核心 WARP-Rust 未在后台运行！透明代理依赖底层代理通道，请先开启主服务。"
        return
    fi

    # 从元数据读取绑定，而非不可靠的正则解析
    local warp_ip="127.0.0.1" local warp_port="1080" local has_auth=""
    if [ -f "$META_FILE" ]; then
        IFS='|' read -r _ warp_ip warp_port has_auth _ < "$META_FILE"
    fi

    if [ -n "$has_auth" ] && [ "$warp_ip" != "127.0.0.1" ] && [ "$warp_ip" != "localhost" ]; then
        warn "当前 WARP 节点开启了账号密码鉴权。透明分流暂不支持有密公网代理。"
        warn "建议在主菜单 [4.修改配置] 中将监听 IP 切换回 127.0.0.1 并不设置密码后再试。"
        return
    fi

    info "正在检查并安装透明代理核心组件 (redsocks / iptables)..."
    local proxy_missing=""
    if ! command -v redsocks &>/dev/null; then proxy_missing="$proxy_missing redsocks"; fi
    if ! command -v iptables &>/dev/null; then proxy_missing="$proxy_missing iptables"; fi

    if [ -n "$proxy_missing" ]; then
        info "正在为系统补齐透明分流组件群:${YELLOW}$proxy_missing${RESET}..."
        case $OS in
            ubuntu|debian)
                apt-get update -qy && apt-get install -y $proxy_missing >/dev/null 2>&1
                ;;
            centos|rhel|rocky|almalinux|fedora)
                if command -v dnf &>/dev/null; then
                    dnf install -y $proxy_missing >/dev/null 2>&1
                else
                    yum install -y $proxy_missing >/dev/null 2>&1
                fi
                ;;
        esac
    fi

    if ! command -v redsocks &>/dev/null || ! command -v iptables &>/dev/null; then
        die "透明代理所需核心网络组件安装失败，请检查你的系统源网络环境。"
    fi

    if systemctl is-enabled redsocks >/dev/null 2>&1 || systemctl is-active redsocks >/dev/null 2>&1; then
        info "检测到系统自带的默认 redsocks 服务，正在将其解绑卸载以防端口冲突..."
        systemctl stop redsocks >/dev/null 2>&1
        systemctl disable redsocks >/dev/null 2>&1
    fi

    info "阻断并优化系统的 Google IPv6 路由解析..."
    ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true
    if ! grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    fi

    cat <<EOF > "$REDSOCKS_CONF"
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = off;
    redirector = iptables;
}
redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = 127.0.0.1;
    port = ${warp_port};
    type = socks5;
}
EOF

    [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
    cat <<'EOF' > "$PROXY_RULES_SCRIPT"
#!/bin/bash
ACTION=$1
GOOGLE_IPS="
8.8.4.0/24
8.8.8.0/24
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0.0/13
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
72.14.192.0/18
74.125.0.0/16
104.132.0.0/14
108.177.0.0/17
142.250.0.0/15
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
"

if [ "$ACTION" = "start" ]; then
    /sbin/iptables -t nat -N WARP_GOOGLE 2>/dev/null
    /sbin/iptables -t nat -F WARP_GOOGLE
    for ip in $GOOGLE_IPS; do
        /sbin/iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345
    done
    /sbin/iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || /sbin/iptables -t nat -A OUTPUT -j WARP_GOOGLE
elif [ "$ACTION" = "stop" ]; then
    /sbin/iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    /sbin/iptables -t nat -F WARP_GOOGLE 2>/dev/null
    /sbin/iptables -t nat -X WARP_GOOGLE 2>/dev/null
fi
EOF
    chmod +x "$PROXY_RULES_SCRIPT"

    cat <<EOF > "$PROXY_SERVICE_FILE"
[Unit]
Description=Cloudflare WARP Google Transparent Proxy (Redsocks Engine)
After=network.target ${SERVICE_NAME}.service
Requires=${SERVICE_NAME}.service

[Service]
Type=simple
ExecStart=/usr/sbin/redsocks -c ${REDSOCKS_CONF}
ExecStartPost=${PROXY_RULES_SCRIPT} start
ExecStop=${PROXY_RULES_SCRIPT} stop
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    
    info "正在拉起透明代理引擎..."
    systemctl start "$PROXY_SERVICE_NAME"
    
    sleep 1.5
    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        ok "Google 透明分流代理已彻底成功启动并挂载！"
    else
        warn "透明代理拉起异常，正在为你输出实时崩溃错误日志："
        journalctl -u "$PROXY_SERVICE_NAME" -n 15 --no-pager
    fi
}

stop_transparent_proxy() {
    if ! systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        warn "Google 透明代理本来就处于关闭状态。"
        return
    fi
    systemctl stop "$PROXY_SERVICE_NAME"
    systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    ok "Google 透明代理已被安全停止，系统 NetFilter 劫持链已完全卸载。"
}

verify_transparent_proxy() {
    echo -e "\n${CYAN}========= 透明代理链路深度验证 =========${RESET}"
    
    info "1. 正在检索系统 iptables 劫持规则 status..."
    if command -v iptables &>/dev/null && iptables -t nat -L OUTPUT -n | grep -q "WARP_GOOGLE"; then
        echo -e "   iptables 拦截链: ${GREEN}✔ 正常挂载 (已接管系统 OUTPUT 流量)${RESET}"
    else
        echo -e "   iptables 拦截链: ${RED}✘ 未挂载 (Google 流量目前处于直连状态)${RESET}"
    fi

    info "2. 正在通过链路层测试 Google 真实连通性 (直接请求)..."
    local http_status
    http_status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://www.google.com")

    if [ "$http_status" -eq 200 ] || [ "$http_status" -eq 301 ] || [ "$http_status" -eq 302 ]; then
        echo -e "   联通性测试结果: ${GREEN}✔ 成功连接 (HTTP 状态码: ${http_status})${RESET}"
        
        local total_time
        total_time=$(curl -o /dev/null -s -w "%{time_total}" --max-time 5 "https://www.google.com")
        echo -e "   透明代理端延迟: ${YELLOW}${total_time} 秒${RESET}"
    else
        echo -e "   联通性测试结果: ${RED}✘ 失败 (无法连接 Google，状态码: ${http_status:-超时/断流})${RESET}"
        warn "提示: 请检查主核心 WARP 账户是否有效，或主服务是否真的获取到了 Cloudflare 的网络分配。"
    fi
    echo -e "${CYAN}========================================${RESET}"
}

menu_transparent_proxy_center() {
    while true; do
        clear
        local proxy_status="${RED}未运行${RESET}"
        if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
            proxy_status="${YELLOW}运行中 (已自动接管 Google IP 流量)${RESET}"
        fi

        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}      Google 透明代理管理控制菜单       ${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}当前状态 :${RESET} $proxy_status"
        echo -e "${GREEN}=====================================${RESET}"
        echo -e "${GREEN}1. 开启透明代理${RESET}"
        echo -e "${GREEN}2. 关闭透明代理${RESET}"
        echo -e "${GREEN}3. 查看并验证代理连通性${RESET}"
        echo -e "${GREEN}0. 返回主菜单${RESET}"
        echo -e "${GREEN}=====================================${RESET}"
        
        read -r -p "$(echo -e "${GREEN}请输入子选项: ${RESET}")" sub_choice
        case "$sub_choice" in
            1) start_transparent_proxy ;;
            2) stop_transparent_proxy ;;
            3) verify_transparent_proxy ;;
            0|*) return ;;
        esac
        read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键继续...${RESET}")"
    done
}

# --- 主循环 ---
while true; do
    get_status_info; clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}         CF-WARP 面板          ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} ${YELLOW}$panel_status${RESET}"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1. 安装 WARP${RESET}"
    echo -e "${GREEN} 2. 更新 WARP${RESET}"
    echo -e "${GREEN} 3. 卸载 WARP${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 WARP${RESET}"
    echo -e "${GREEN} 6. 停止 WARP${RESET}"
    echo -e "${GREEN} 7. 重启 WARP${RESET}"
    echo -e "${GREEN} 8. 查看日志${RESET}"
    echo -e "${GREEN} 9. 查看配置与出口状态${RESET}"
    echo -e "${GREEN} 10. Google 透明代理控制中心${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) download_bin; register_usque; write_systemd "SOCKS5" "127.0.0.1" "1080" "" ""; systemctl restart "$SERVICE_NAME"; ok "安装完成。"; sleep 0.5 ;;
        2) systemctl stop "$SERVICE_NAME"; download_bin; systemctl start "$SERVICE_NAME"; ok "更新完成。"; sleep 0.5 ;;
        3) 
            # 联动卸载：优先注销透明代理防护规则与服务，防止断网残留
            systemctl stop "$PROXY_SERVICE_NAME" >/dev/null 2>&1
            systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
            systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
            rm -f "$INSTALL_BIN" "$SERVICE_FILE" "$META_FILE" "$PROXY_SERVICE_FILE" "$REDSOCKS_CONF" "$PROXY_RULES_SCRIPT"
            rm -rf "$CONF_DIR" "$DATA_DIR"
            ok "已彻底连同透明代理组件卸载干净。"
            sleep 0.5 
            ;;
        4) menu_edit_config ;;
        5) systemctl start "$SERVICE_NAME" && ok "服务已启动。"; sleep 0.5 ;; 
        6) systemctl stop "$SERVICE_NAME" && ok "服务已停止。"; sleep 0.5 ;;  
        7) systemctl restart "$SERVICE_NAME" && ok "服务已重启。"; sleep 0.5 ;; 
        8) journalctl -u "$SERVICE_NAME" -n 50 -f ;;
        9) menu_show_node_config ;;
        10) menu_transparent_proxy_center ;;
        0) exit 0 ;;
        *) warn "无效选项，请重新选择。" ;; 
    esac
    read -n 1 -s -r -p "按任意键返回..."
done
