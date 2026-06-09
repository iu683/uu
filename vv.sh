#!/usr/bin/env sh
# ==============================================================================
#   CF-WARP Alpine 专属控制面板 (更新自动保留原配置，安装支持自定义绑定参数)
# ==============================================================================

# 预检：由于 Alpine 默认不带高级语法，必须先自动补齐 bash 并切过去
if [ -z "$BASH_VERSION" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        apk update -q && apk add -q bash
    fi
    exec bash "$0" "$@"
fi

set -e

# --- 核心主程序变量 ---
export REPO_USQUE="Diniboy1123/usque"
export SERVICE_NAME="usque"
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
export META_FILE="${CONF_DIR}/.panel_meta"

# --- 谷歌分流专属变量 ---
export PROXY_SERVICE_NAME="usque-google-proxy"
export DATA_DIR="/var/lib/usque"
export REDSOCKS_CONF="${CONF_DIR}/redsocks.conf"
export PROXY_RULES_SCRIPT="${DATA_DIR}/google_rules.sh"
export PROXY_SERVICE_FILE="/etc/init.d/${PROXY_SERVICE_NAME}"
export REDSOCKS_PID="/run/usque-google-proxy.pid"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
RESET='\033[0m'

GITHUB_PROXY=('https://v6.gh-proxy.org/' 'https://gh-proxy.com/' '')

[[ "$EUID" -ne 0 ]] && echo -e "${RED}[错误]${RESET} 请使用 root 权限运行！" && exit 1

# 状态刷新
get_status_info() {
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        panel_status="${GREEN}运行中${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi
    
    if [ -f "$INSTALL_BIN" ]; then
        local ver
        ver=$("$INSTALL_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        panel_version="${YELLOW}v${ver:-已安装}${RESET}"
    else
        panel_version="${RED}未安装${RESET}"
    fi
    
    if [ -f "$META_FILE" ]; then
        IFS='|' read -r m_mode m_ip m_port _ < "$META_FILE"
        panel_port="${YELLOW}${m_mode}://$m_ip:$m_port${RESET}"
    else
        panel_port="${RED}未配置${RESET}"
    fi
}

# 依赖安装
check_deps() {
    local missing=""
    ! command -v unzip >/dev/null 2>&1 && missing="$missing unzip"
    ! command -v curl >/dev/null 2>&1 && missing="$missing curl"
    ! command -v ip >/dev/null 2>&1 && missing="$missing iproute2"
    if [ -n "$missing" ]; then
        apk update -q && apk add -q $missing >/dev/null 2>&1
    fi
}

# 下载与更新/安装逻辑 (完美支持升级时自动提取并保留原有默认配置)
install_warp() {
    check_deps
    
    local is_upgrade=0
    local o_mode="SOCKS5" o_ip="127.0.0.1" o_port="1080" o_user="" o_pass=""
    
    # 检查是否已经是已安装状态，如果是升级，先提取老配置参数
    if [ -f "$CONF_FILE" ] && [ -f "$INSTALL_BIN" ]; then
        is_upgrade=1
        echo -e "${BLUE}[信息]${RESET} 检测到已有配置，正在进行无损覆盖升级..."
        if [ -f "$META_FILE" ]; then
            IFS='|' read -r o_mode o_ip o_port o_user o_pass < "$META_FILE"
        fi
    else
        echo -e "${BLUE}[信息]${RESET} 正在全新安装 Usque 核心组件..."
    fi
    
    local has_v4=0
    if curl -4sSk --max-time 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "ip="; then
        has_v4=1
    fi

    local ARCH=$(uname -m)
    local TARGET="linux_amd64"
    [[ "$ARCH" == "aarch64" ]] && TARGET="linux_arm64"

    local latest_tag=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        latest_tag=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/${REPO_USQUE}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [ -n "$latest_tag" ] && break
    done
    [ -z "$latest_tag" ] && latest_tag="v3.0.0"
    local pure_ver="${latest_tag#v}"

    local tmp_dir=$(mktemp -d)
    if curl -fsSL -L -o "$tmp_dir/zip" "${GITHUB_PROXY[0]}https://github.com/${REPO_USQUE}/releases/download/${latest_tag}/usque_${pure_ver}_${TARGET}.zip"; then
        unzip -q -o "$tmp_dir/zip" -d "$tmp_dir"
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        cp -f "$tmp_dir/usque" "$INSTALL_BIN"
        chmod +x "$INSTALL_BIN"
    fi
    rm -rf "$tmp_dir"

    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
    cd "$CONF_DIR"
    
    # 【核心修复】：如果是升级，自动沿用提取出来的旧参数重新生成 OpenRC 脚本并启动，不触发任何交互和重新注册
    if [ "$is_upgrade" -eq 1 ]; then
        write_openrc "$o_mode" "$o_ip" "$o_port" "$o_user" "$o_pass"
        rc-service "$SERVICE_NAME" start
        echo -e "${GREEN}[成功]${RESET} 核心组件已成功无损升级至最新版！(已完美保留原默认配置)"
        return 0
    fi

    # 只有全新安装才走注册和自定义配置流程
    echo -e "${BLUE}[信息]${RESET} 正在执行本地匿名注册..."
    if "${INSTALL_BIN}" register; then
        echo -e "${GREEN}[成功]${RESET} Cloudflare 本地注册成功。"
        
        if [ "$has_v4" -ne 1 ] && [ -f "$CONF_FILE" ]; then
            echo -e "${BLUE}[信息]${RESET} 检测到纯 IPv6 环境，正在自动修正配置文件..."
            local v6_ep=$(grep -o '"endpoint_v6": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')
            if [ -z "$v6_ep" ]; then
                v6_ep="[2606:4700:d0::a25c:bc2e]:2408"
            fi
            sed -i "s/\"endpoint_v4\": *\"[^\"]*\"/\"endpoint_v4\": \"${v6_ep}\"/g" "$CONF_FILE"
            echo -e "${GREEN}[成功]${RESET} IPv6 修正已完成 (Endpoint: $v6_ep)。"
        fi
        
        echo -e "\n--- 请配置初始化绑定参数 ---"
        echo -e "请选择运行模式:"
        echo -e "  1. SOCKS5 (默认)"
        echo -e "  2. HTTP"
        echo -ne "${GREEN}请输入选项 [默认: 1]: ${RESET}"
        read -r mode_ch
        local ins_mode="SOCKS5"
        [[ "$mode_ch" == "2" ]] && ins_mode="HTTP"

        echo -ne "${GREEN}请输入监听 IP [默认: 127.0.0.1]: ${RESET}"
        read -r ins_ip
        ins_ip="${ins_ip:-127.0.0.1}"

        echo -ne "${GREEN}请输入监听端口 [默认: 1080]: ${RESET}"
        read -r ins_port
        ins_port="${ins_port:-1080}"

        echo -ne "${GREEN}请输入代理用户名 (留空则无验证): ${RESET}"
        read -r ins_user
        local ins_pass=""
        if [ -n "$ins_user" ]; then
            echo -ne "${GREEN}请输入代理密码: ${RESET}"
            read -r ins_pass
        fi

        write_openrc "$ins_mode" "$ins_ip" "$ins_port" "$ins_user" "$ins_pass"
        rc-service "$SERVICE_NAME" start
        echo -e "${GREEN}[成功]${RESET} WARP 安装并启动成功！"
    else
        echo -e "${RED}[错误]${RESET} 注册失败。提示：请确保你的 VPS 已开启 IPv6 外部访问能力。"
        return 1
    fi
}

# 写入 Alpine OpenRC 脚本
write_openrc() {
    local mode="$1" ip="$2" port="$3" user="$4" pass="$5"
    local cmd="socks"
    [[ "$mode" == "HTTP" ]] && cmd="http-proxy"
    local args="${cmd} -b ${ip} -p ${port}"
    [[ -n "$user" ]] && args="${args} -u ${user} -w ${pass}"

    cat <<EOF > "$SERVICE_FILE"
#!/sbin/openrc-run
description="Usque WARP Proxy Server"
supervisor="supervise-daemon"
command="${INSTALL_BIN}"
command_args="--config ${CONF_FILE} ${args}"
command_background="yes"
directory="${CONF_DIR}"
output_log="/var/log/usque.log"
error_log="/var/log/usque.err"
depend() { need net; after firewall; }
EOF
    chmod +x "$SERVICE_FILE"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    echo "${mode}|${ip}|${port}|${user}|${pass}" > "$META_FILE"
}

# 修改配置
edit_config() {
    if [ ! -f "$META_FILE" ]; then echo -e "${RED}[错误]${RESET} 未发现配置记录"; return; fi
    IFS='|' read -r o_mode o_ip o_port o_user o_pass < "$META_FILE"
    echo "--- 修改配置 ---"
    read -r -p "请选择模式 (1.SOCKS5 2.HTTP) [当前: $o_mode]: " m_ch
    local n_mode="$o_mode"
    [[ "$m_ch" == "1" ]] && n_mode="SOCKS5"
    [[ "$m_ch" == "2" ]] && n_mode="HTTP"
    read -r -p "监听 IP [当前: $o_ip]: " n_ip; n_ip="${n_ip:-$o_ip}"
    read -r -p "监听端口 [当前: $o_port]: " n_port; n_port="${n_port:-$o_port}"
    
    read -r -p "请输入用户名 [当前: ${o_user:-无}]: " n_user
    n_user="${n_user:-$o_user}"
    local n_pass="$o_pass"
    if [ -n "$n_user" ]; then
        read -r -p "请输入新密码: " n_pass
    else
        n_pass=""
    fi

    write_openrc "$n_mode" "$n_ip" "$n_port" "$n_user" "$n_pass"
    rc-service "$SERVICE_NAME" restart
}

# 查看配置与出口状态
show_status() {
    if [ ! -f "$META_FILE" ]; then echo -e "${RED}[错误]${RESET} 未配置过服务"; return; fi
    IFS='|' read -r b_mode b_ip b_port b_user b_pass < "$META_FILE"
    echo -e "\n代理模式: $b_mode | 监听: $b_ip:$b_port"
    local p_url="socks5://"
    [[ "$b_mode" == "HTTP" ]] && p_url="http://"
    [[ "$b_ip" == "0.0.0.0" ]] && b_ip="127.0.0.1"
    if curl -sS --max-time 6 -x "${p_url}${b_ip}:${b_port}" "https://www.cloudflare.com/cdn-cgi/trace" | grep -q "warp=on"; then
        echo -e "${GREEN}[成功]${RESET} WARP 网络出口完全正常！"
    else
        echo -e "${RED}[错误]${RESET} 代理未成功通过 WARP 出网，请检查日志。"
    fi
}

# 谷歌分流二级菜单 (含连通性验证状态查看)
google_split_menu() {
    while true; do
        clear
        local g_status="${RED}未运行${RESET}"
        rc-service "$PROXY_SERVICE_NAME" status >/dev/null 2>&1 && g_status="${GREEN}运行中${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}        谷歌分流管理面板        ${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}当前状态 :${RESET} $g_status"
        echo -e "${GREEN}==============================${RESET}"
        echo -e "${GREEN}  1. 开启谷歌透明分流${RESET}"
        echo -e "${GREEN}  2. 关闭谷歌透明分流${RESET}"
        echo -e "${GREEN}  3. 验证谷歌分流连通性${RESET}"
        echo -e "${GREEN}  0. 返回主菜单${RESET}"
        echo -e "${GREEN}==============================${RESET}"
        echo -ne "${GREEN}请输入选项: ${RESET}"
        read -r sub_ch
        case "$sub_ch" in
            1)
                if ! command -v redsocks &>/dev/null || ! command -v iptables &>/dev/null; then
                    echo -e "${BLUE}[信息]${RESET} 正在安装分流依赖组件..."
                    apk add -q redsocks iptables --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community/ || apk add -q redsocks iptables
                fi
                
                local REDSOCKS_BIN="/usr/bin/redsocks"
                [ ! -f "$REDSOCKS_BIN" ] && REDSOCKS_BIN=$(command -v redsocks 2>/dev/null || echo "/usr/sbin/redsocks")

                rc-service "$PROXY_SERVICE_NAME" stop >/dev/null 2>&1 || true
                pkill -9 -f redsocks >/dev/null 2>&1 || true
                rc-service "$PROXY_SERVICE_NAME" zap >/dev/null 2>&1 || true
                rm -f "$REDSOCKS_PID"
                
                ip -6 route add blackhole 2607:f8b0::/32 2>/dev/null || true
                
                IFS='|' read -r _ _ warp_port _ < "$META_FILE"
                cat <<EOF > "$REDSOCKS_CONF"
base { log_debug = off; log_info = on; log = "syslog:daemon"; daemon = off; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = ${warp_port:-1080}; type = socks5; }
EOF
                [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
                cat <<'EOF' > "$PROXY_RULES_SCRIPT"
#!/bin/bash
ACTION=$1
GOOGLE_IPS="
8.8.4.0/24 8.8.8.0/24 34.0.0.0/9 35.184.0.0/13 35.192.0.0/12
35.224.0.0/12 35.240.0.0/13 64.233.160.0/19 66.102.0.0/20
66.249.64.0/19 72.14.192.0/18 74.125.0.0/16 104.132.0.0/14
108.177.0.0/17 142.250.0.0/15 172.217.0.0/16 172.253.0.0/16
173.194.0.0/16 209.85.128.0/17 216.58.192.0/19 216.239.32.0/19
"
if [ "$ACTION" = "start" ]; then
    iptables -t nat -N WARP_GOOGLE 2>/dev/null || true
    iptables -t nat -F WARP_GOOGLE
    for ip in $GOOGLE_IPS; do iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345; done
    iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || iptables -t nat -A OUTPUT -j WARP_GOOGLE
elif [ "$ACTION" = "stop" ]; then
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null || true
    iptables -t nat -F WARP_GOOGLE 2>/dev/null || true
    iptables -t nat -X WARP_GOOGLE 2>/dev/null || true
fi
EOF
                chmod +x "$PROXY_RULES_SCRIPT"
                
                cat <<EOF > "$PROXY_SERVICE_FILE"
#!/sbin/openrc-run
supervisor="supervise-daemon"
command="${REDSOCKS_BIN}"
command_args="-c ${REDSOCKS_CONF}"
command_background="yes"
pidfile="${REDSOCKS_PID}"
start_post() { ${PROXY_RULES_SCRIPT} start; }
stop_pre() { ${PROXY_RULES_SCRIPT} stop; }
EOF
                chmod +x "$PROXY_SERVICE_FILE"
                
                rc-service "$PROXY_SERVICE_NAME" start
                echo -e "${GREEN}[成功]${RESET} 谷歌分流规则已挂载完成！"
                ;;
            2)
                rc-service "$PROXY_SERVICE_NAME" stop 2>/dev/null || true
                pkill -9 -f redsocks >/dev/null 2>&1 || true
                rc-service "$PROXY_SERVICE_NAME" zap >/dev/null 2>&1 || true
                rm -f "$REDSOCKS_PID"
                echo -e "${GREEN}[成功]${RESET} 谷歌分流规则已卸载。"
                ;;
            3)
                echo -e "\n[正在验证谷歌透明拦截链路...]"
                if iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q "WARP_GOOGLE"; then
                    echo -e " iptables 劫持链: ${GREEN}✔ 正常挂载${RESET}"
                else
                    echo -e " iptables 劫持链: ${RED}✘ 未发现劫持规则 (直连中)${RESET}"
                fi
                
                local code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "https://www.google.com" || echo "000")
                if [ "$code" -eq 200 ] || [ "$code" -eq 301 ] || [ "$code" -eq 302 ]; then
                    echo -e " 谷歌直连测试  : ${GREEN}✔ 成功连通 (状态码: $code)${RESET}"
                else
                    echo -e " 谷歌直连测试  : ${RED}✘ 连接失败 (状态码: $code)${RESET}"
                fi
                ;;
            0) return ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

# --- 主循环逻辑 ---
while true; do
    clear
    get_status_info
    
    # 你的原版菜单外观模板，原汁原味，完美对齐
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}         CF-WARP 面板          ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $panel_status"
    echo -e "${GREEN}版本 :${RESET} ${panel_version}"
    echo -e "${GREEN}绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}  1. 安装 WARP${RESET}"
    echo -e "${GREEN}  2. 更新 WARP${RESET}"
    echo -e "${GREEN}  3. 卸载 WARP${RESET}"
    echo -e "${GREEN}  4. 修改配置${RESET}"
    echo -e "${GREEN}  5. 启动 WARP${RESET}"
    echo -e "${GREEN}  6. 停止 WARP${RESET}"
    echo -e "${GREEN}  7. 重启 WARP${RESET}"
    echo -e "${GREEN}  8. 查看日志${RESET}"
    echo -e "${GREEN}  9. 查看配置与出口状态${RESET}"
    echo -e "${GREEN} 10.${RESET} ${YELLOW}谷歌分流${RESET}"
    echo -e "${GREEN} 11.${RESET} ${RED}[已移除] Tun2Socks全局${RESET}"
    echo -e "${GREEN}  0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    
    read -r choice
    
    case "$choice" in
        1) install_warp ;;
        2) install_warp ;; 
        3) 
            rc-service "$PROXY_SERVICE_NAME" stop 2>/dev/null || true
            pkill -9 -f redsocks >/dev/null 2>&1 || true
            rc-service "$SERVICE_NAME" stop 2>/dev/null || true
            rc-update del "$SERVICE_NAME" default 2>/dev/null || true
            rm -f "$SERVICE_FILE" "$PROXY_SERVICE_FILE" "$INSTALL_BIN" "$META_FILE" "$REDSOCKS_PID"
            rm -rf "$CONF_DIR" "$DATA_DIR"
            echo -e "${GREEN}[成功]${RESET} 卸载完成。"
            ;;
        4) edit_config ;;
        5) rc-service "$SERVICE_NAME" start ;;
        6) rc-service "$SERVICE_NAME" stop ;;
        7) rc-service "$SERVICE_NAME" restart ;;
        8)
            echo "--- 最近 20 行日志 ---"
            [ -f /var/log/usque.log ] && tail -n 20 /var/log/usque.log || echo "暂无普通日志"
            [ -f /var/log/usque.err ] && tail -n 20 /var/log/usque.err || echo "暂无错误日志"
            ;;
        9) show_status ;;
        10) google_split_menu ;;
        11) echo -e "${RED}[提示]${RESET} Alpine 环境下已彻底剔除 Tun2Socks 模块！" ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${RESET}" ;;
    esac
    read -n 1 -s -r -p "按任意键返回面板..."
done
