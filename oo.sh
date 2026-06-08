#!/bin/bash

# 取消全局 set -e，改用手工逻辑控制，防止流式输入时意外闪退
CFT_INSTALL_DIR="/opt/cloudflared"
CFT_BIN="/usr/local/bin/cloudflared"
CONF_FILE="$CFT_INSTALL_DIR/config.yml"
CRED_FILE="$CFT_INSTALL_DIR/tunnel_cred.json"
INIT_FLAG="$CFT_INSTALL_DIR/.cft_inited"
IS_OPENWRT=0

G_STATUS=""
G_VERSION=""
G_TUNNEL_ID=""

# GitHub 轮询节点列表（用于加速下载 cloudflared 二进制文件）
GITHUB_PROXY=(
    'https://gh-proxy.com/'
    'https://v6.gh-proxy.org/'
    'https://ghproxy.lvedong.eu.org/'
    'https://proxy.vvvv.ee/'
    'https://hub.glowp.xyz/'
    '' 
)

DEFAULT_BACKUP_VER="2026.5.0"

# 标准颜色
CYAN="\e[36m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

is_openwrt() { [ -f /etc/openwrt_release ] && IS_OPENWRT=1 || IS_OPENWRT=0; }
is_openwrt

get_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64";;
        aarch64) echo "arm64";;
        armv7*|armv6*) echo "arm";;
        *) echo "amd64";;
    esac
}

get_auto_version() {
    local fetched_ver=""
    echo -e "${YELLOW}正在尝试获取 GitHub 远端最新 cloudflared 版本号...${RESET}" >&2

    for proxy in "${GITHUB_PROXY[@]}"; do
        if [ -z "$proxy" ]; then
            echo -e "${YELLOW} -> 正在尝试[直连]获取 GitHub API...${RESET}" >&2
        else
            echo -e "${YELLOW} -> 正在尝试通过节点 [ ${proxy} ] 获取 GitHub API...${RESET}" >&2
        fi

        fetched_ver=$(curl -sL -m 4 "${proxy}https://api.github.com/repos/cloudflare/cloudflared/releases/latest" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *//;s/"//g')
        
        if [ -n "$fetched_ver" ]; then
            echo -e "${GREEN}[成功] 成功获取到最新版本号: ${fetched_ver}${RESET}" >&2
            echo "$fetched_ver"
            return 0
        fi
        echo -e "${RED}    失败，尝试下一个渠道...${RESET}" >&2
    done

    echo -e "${YELLOW}[提示] 无法获取远端版本，激活保底机制，采用预设版本: ${DEFAULT_BACKUP_VER}${RESET}" >&2
    echo "$DEFAULT_BACKUP_VER"
}

download_package_loop() {
    local version=$1
    local arch=$2
    # cloudflared 官方命名的本地文件名格式：cloudflared-linux-amd64
    local remote_filename="cloudflared-linux-${arch}"
    local success=0

    echo -e "${YELLOW}开始下载 cloudflared 二进制文件 ${version} (${arch})...${RESET}"

    for proxy in "${GITHUB_PROXY[@]}"; do
        if [ -z "$proxy" ]; then
            echo -e "${YELLOW} -> 正在尝试[直连] GitHub 下载...${RESET}"
        else
            echo -e "${YELLOW} -> 正在尝试通过节点 [ ${proxy} ] 下载...${RESET}"
        fi

        local url="${proxy}https://github.com/cloudflare/cloudflared/releases/download/${version}/${remote_filename}"
        
        if wget -T 10 -O "cloudflared" "$url"; then
            echo -e "${GREEN}[成功] 下载完成！${RESET}"
            success=1
            break
        else
            echo -e "${RED}    该节点下载失败或超时，自动切换下一个...${RESET}"
            rm -f "cloudflared"
        fi
    done

    if [ $success -eq 0 ]; then
        echo -e "${RED}[严重错误] 所有加速节点及直连下载均已尝试，全部失败！${RESET}"
        return 1
    fi
    return 0
}

is_inited() { [ -f "$INIT_FLAG" ]; }

update_status_variables() {
    G_VERSION="未安装"
    G_STATUS="${RED}已停止${RESET}"
    G_TUNNEL_ID="无"

    if [ -f "$CFT_BIN" ]; then
        G_VERSION=$($CFT_BIN --version 2>/dev/null | awk '{print $3}' || echo "未知")
        
        if [ "$IS_OPENWRT" = "1" ]; then
            (ps | grep -v grep | grep -q "[c]loudflared") && G_STATUS="${GREEN}已启动${RESET}"
        else
            (systemctl is-active --quiet cloudflared 2>/dev/null) && G_STATUS="${GREEN}已启动${RESET}"
        fi
    fi

    if [ -f "$CONF_FILE" ]; then
        G_TUNNEL_ID=$(awk '/tunnel:/{gsub(/[ "]/,"",$2); print $2}' "$CONF_FILE" 2>/dev/null)
        G_TUNNEL_ID=${G_TUNNEL_ID:-"未配置"}
    fi
}

config_after_install() {
    echo -e "\n${YELLOW}========================================${RESET}"
    echo -e "${GREEN}cloudflared 安装成功！正在自动进入配置引导...${RESET}"
    echo -e "${YELLOW}========================================${RESET}\n"
    sleep 1
    init_tunnel_config
}

install_cloudflared() {
    if [ -f "$CFT_BIN" ]; then
        echo -e "${RED}[提示] 检测到系统已安装 cloudflared，如需修改配置请使用菜单对应功能${RESET}"
        read -p "按回车返回菜单..." </dev/tty
        return
    fi

    local CFT_VER=$(get_auto_version)
    local ARCH=$(get_arch)
    
    mkdir -p "$CFT_INSTALL_DIR"
    cd "$CFT_INSTALL_DIR"

    if ! download_package_loop "$CFT_VER" "$ARCH"; then
        read -p "按回车返回菜单..." </dev/tty
        return
    fi
    
    cp -f "cloudflared" "$CFT_BIN"
    chmod +x "$CFT_BIN"
    rm -f "cloudflared"
    
    config_after_install
}

write_initd_service() {
cat > /etc/init.d/cloudflared <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
PROG=/usr/local/bin/cloudflared
CFG=/opt/cloudflared/config.yml
start_service() {
    procd_open_instance
    procd_set_param command $PROG --config $CFG tunnel run
    procd_set_param respawn
    procd_close_instance
}
EOF
chmod +x /etc/init.d/cloudflared
/etc/init.d/cloudflared enable
}

write_systemd_service() {
cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
Type=simple
ExecStart=$CFT_BIN --config $CONF_FILE tunnel run
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
}

init_tunnel_config() {
    echo "=== 设定 Cloudflare Tunnel 基础参数 ==="
    mkdir -p "$CFT_INSTALL_DIR"

    echo -e "${YELLOW}提示：本地配置模式需要您提供在 Cloudflare 创立的 Tunnel ID 以及对应的 Credentials JSON 内容。${RESET}"
    echo -e "${YELLOW}如果不清楚，建议直接使用 Cloudflare 控制台的【Dashboard 远程管理模式】，直接将生成的官方一键安装服务指令拿来运行即可。${RESET}\n"
    
    read -p "请输入你的 Tunnel ID (UUID格式): " TUNNEL_UUID </dev/tty
    while [[ -z "$TUNNEL_UUID" ]]; do
        read -p "${RED}Tunnel ID 不能为空，请重新输入: ${RESET}" TUNNEL_UUID </dev/tty
    done

    echo -e "\n请粘入该 Tunnel 的 Credentials JSON 完整内容 (按下 Enter 后，按 Ctrl+D 结束输入):"
    local JSON_CONTENT=$(cat)
    
    if [ -z "$JSON_CONTENT" ]; then
        echo -e "${RED}输入内容为空，放弃配置。${RESET}"
        read -p "按回车返回菜单..." </dev/tty
        return
    fi

    # 保存凭证文件
    echo "$JSON_CONTENT" > "$CRED_FILE"

    # 生成初始的基础配置文件 (默认自带一条 404 兜底规则)
    cat > "$CONF_FILE" <<EOF
tunnel: $TUNNEL_UUID
credentials-file: $CRED_FILE

ingress:
  - service: http_status:404
EOF

    touch "$INIT_FLAG"
    restart_service
    echo -e "${GREEN}基础配置文件已生成并尝试启动服务！${RESET}"
    read -p "按回车返回菜单..." </dev/tty
}

add_tunnel_rule() {
    is_inited || { echo -e "${RED}请先初始化 Tunnel 基础参数！${RESET}"; sleep 2; return; }
    echo "=== 添加域名映射规则 ==="
    
    read -p "完整的公网自定义域名 (如: nas.yourdomain.com): " INGRESS_HOST </dev/tty
    while [[ -z "$INGRESS_HOST" ]]; do
        read -p "${RED}域名不能为空: ${RESET}" INGRESS_HOST </dev/tty
    done

    if grep -q "hostname: $INGRESS_HOST" "$CONF_FILE"; then
        echo -e "${RED}错误：该域名 [$INGRESS_HOST] 转发规则已存在！${RESET}"
        sleep 2
        return
    fi

    read -p "本地转发的目标服务 (如: http://127.0.0.1:5000 或 tcp://127.0.0.1:22): " LOCAL_SERVICE </dev/tty
    while [[ -z "$LOCAL_SERVICE" ]]; do
        read -p "${RED}本地目标服务不能为空: ${RESET}" LOCAL_SERVICE </dev/tty
    done

    # 临时移除尾部的 404 兜底规则，追加新规则后再补回
    sed -i '/- service: http_status:404/d' "$CONF_FILE"
    
    cat >> "$CONF_FILE" <<EOF
  - hostname: $INGRESS_HOST
    service: $LOCAL_SERVICE
  - service: http_status:404
EOF

    echo -e "${GREEN}成功添加规则 [$INGRESS_HOST -> $LOCAL_SERVICE]${RESET}"
    restart_service
    sleep 1.5
}

delete_tunnel_rule() {
    is_inited || { echo -e "${RED}请先初始化 Tunnel 基础参数！${RESET}"; sleep 2; return; }
    echo -e "\n${CYAN}[当前规则列表]${RESET}"
    grep "hostname:" "$CONF_FILE" || { echo "暂无任何转发规则"; sleep 1.5; return; }
    echo
    read -p "输入要删除的公网域名: " DEL_HOST </dev/tty
    
    if ! grep -q "hostname: $DEL_HOST" "$CONF_FILE"; then
        echo -e "${RED}未找到域名 [$DEL_HOST] 的规则！${RESET}"
        sleep 2
        return
    fi

    # 利用 awk 精确删除对应的 hostname 和紧随其后的 service 行
    awk -v host="hostname: $DEL_HOST" '
    $0 ~ host { getline; next }
    { print $0 }
    ' "$CONF_FILE" > "${CONF_FILE}.tmp"
    
    mv "${CONF_FILE}.tmp" "$CONF_FILE"
    echo -e "${GREEN}已成功删除域名 [$DEL_HOST] 的映射规则${RESET}"
    restart_service
    sleep 1.5
}

print_tunnel_rules() {
    if [ -f "$CONF_FILE" ]; then
        echo -e "${CYAN} 公网域名                    | 本地目标服务${RESET}"
        echo -e "${CYAN}------------------------------------------------${RESET}"
        awk '
        /hostname:/ { host=$3 }
        /service:/ && !/http_status:404/ { service=$2; printf "  %-26s | %-20s\n", host, service; host="" }
        ' "$CONF_FILE" | while read -r line; do
            echo -e "${YELLOW}$line${RESET}"
        done
        if ! grep -q "hostname:" "$CONF_FILE"; then
            echo -e "   ${RED}(暂无本地规则，如已采用网页面板模式请忽略此列表)${RESET}"
        fi
    else
        echo -e "   ${RED}配置文件未生成${RESET}"
    fi
}

start_service() {
    if [ "$IS_OPENWRT" = "1" ]; then
        write_initd_service
        /etc/init.d/cloudflared start
    else
        write_systemd_service
        systemctl start cloudflared
        systemctl enable cloudflared 2>/dev/null || true
    fi
    echo "cloudflared 已启动"; sleep 1;
}

stop_service() {
    [ "$IS_OPENWRT" = "1" ] && /etc/init.d/cloudflared stop || systemctl stop cloudflared
    echo "cloudflared 已停止"; sleep 1;
}

restart_service() {
    if [ "$IS_OPENWRT" = "1" ]; then
        write_initd_service
        /etc/init.d/cloudflared restart
    else
        write_systemd_service
        systemctl restart cloudflared
        systemctl enable cloudflared 2>/dev/null || true
    fi
    echo "cloudflared 已重启"; sleep 1;
}

log_service() {
    if [ "$IS_OPENWRT" = "1" ]; then 
        logread | grep cloudflared | tail -n 30 || echo "暂无日志"
    else 
        journalctl -u cloudflared -n 40 --no-pager
    fi
    read -p "按回车返回菜单..." </dev/tty
}

uninstall_all() {
    echo "正在卸载 Cloudflare Tunnel..."
    if [ "$IS_OPENWRT" = "1" ]; then
        /etc/init.d/cloudflared stop 2>/dev/null || true
        rm -f /etc/init.d/cloudflared
    else
        systemctl stop cloudflared 2>/dev/null || true
        systemctl disable cloudflared 2>/dev/null || true
        rm -f /etc/systemd/system/cloudflared.service
        systemctl daemon-reload
    fi
    rm -rf "$CFT_INSTALL_DIR" "$CFT_BIN"
    echo "Cloudflare Tunnel 已彻底从本机移除。"
    sleep 2
    exit 0
}

# ---------- 主菜单界面 ----------
main_menu() {
    while true; do
        update_status_variables
        clear
        echo -e "${CYAN}================================${RESET}"
        echo -e "${CYAN}   Cloudflare Tunnel 管理面板   ${RESET}"
        echo -e "${CYAN}================================${RESET}"
        echo -e "${CYAN}状态     :${RESET} $G_STATUS"
        echo -e "${CYAN}版本     :${RESET} ${YELLOW}${G_VERSION}${RESET}"
        echo -e "${CYAN}TunnelID :${RESET} ${YELLOW}${G_TUNNEL_ID}${RESET}"
        echo -e "${CYAN}================================${RESET}"
        
        print_tunnel_rules
        echo -e "${CYAN}================================${RESET}"
        
        echo -e "${CYAN} 1. 安装 cloudflared${RESET}"
        echo -e "${CYAN} 2. 修改参数${RESET}"
        echo -e "${CYAN} 3. 新增域名转发规则${RESET}"
        echo -e "${CYAN} 4. 删除域名转发规则${RESET}"
        echo -e "${CYAN} 5. 启动隧道服务${RESET}"
        echo -e "${CYAN} 6. 停止隧道服务${RESET}"
        echo -e "${CYAN} 7. 重启隧道服务${RESET}"
        echo -e "${CYAN} 8. 查看运行日志${RESET}"
        echo -e "${CYAN} 9. 卸载服务${RESET}"
        echo -e "${CYAN} 0. 退出${RESET}"
        echo -e "${CYAN}================================${RESET}"
        echo -ne "${CYAN}请输入选项: ${RESET}"
        read choice </dev/tty
        case $choice in
            1) install_cloudflared ;;
            2) init_tunnel_config ;;
            3) add_tunnel_rule ;;
            4) delete_tunnel_rule ;;
            5) start_service ;;
            6) stop_service ;;
            7) restart_service ;;
            8) log_service ;;
            9) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项！${RESET}" && sleep 1 ;;
        esac
    done
}

main_menu
