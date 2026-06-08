#!/usr/bin/env bash

# ==============================================================================
#   Usque (MASQUE-WARP) 面板
# ==============================================================================

export REPO="Diniboy1123/usque"
export SERVICE_NAME="usque"
export SERVICE_USER="root"
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
export META_FILE="${CONF_DIR}/.panel_meta"

# 配色方案 (保持你的原版)
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

GITHUB_PROXY=('https://v6.gh-proxy.org/' 'https://gh-proxy.com/' 'https://hub.glowp.xyz/' 'https://proxy.vvvv.ee/' 'https://ghproxy.lvedong.eu.org/' '')

[[ "$EUID" -ne 0 ]] && echo -e "${GREEN}[错误]${RESET} 请使用 root 权限运行！" && exit 1

info() { echo -e "${GREEN}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${GREEN}[ERROR]${RESET} $1" >&2; exit 1; }

# --- 1. 下载模块 ---
download_bin() {
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

    [ "$success" -ne 1 ] && die "下载失败。"
    unzip -q -o "$tmp_dir/zip" -d "$tmp_dir"
    cp -f "$tmp_dir/usque" "$INSTALL_BIN"
    chmod +x "$INSTALL_BIN"
    rm -rf "$tmp_dir"
}

# --- 2. 本地注册 (已融合你的 v6 修正逻辑) ---
register_usque() {
    local has_v4=0
    # 探测是否有 IPv4 出口
    curl -4sSk --max-time 3 https://www.cloudflare.com/cdn-cgi/trace | grep -q "ip=" && has_v4=1

    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
    cd "$CONF_DIR" || exit 1
    
    info "正在执行本地匿名注册..."
    if "${INSTALL_BIN}" register; then
        ok "Cloudflare 本地注册成功。"
        # 你的 v6 修正逻辑：针对纯 IPv6 环境强行替换 endpoint
        if [ "$has_v4" -ne 1 ] && [ -f "$CONF_FILE" ]; then
            info "检测到纯 IPv6 环境，正在修正配置文件..."
            local v6_ep=$(grep -o '"endpoint_v6": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')
            [ -n "$v6_ep" ] && sed -i "s/\"endpoint_v4\": *\"[^\"]*\"/\"endpoint_v4\": \"${v6_ep}\"/g" "$CONF_FILE"
            ok "IPv6 修正已完成。"
        fi
    else
        die "注册失败，请检查网络。"
    fi
}

# --- 3. 写入服务 ---
write_systemd() {
    local mode="$1" ip="$2" port="$3" user="$4" pass="$5"
    local cmd="socks"
    [[ "$mode" == "HTTP" ]] && cmd="http-proxy"

    local args="${cmd} -b ${ip} -p ${port}"
    [[ -n "$user" ]] && args="${args} -u ${user} -w ${pass}"

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

# --- 5. 修改配置 (回车保持，输入 read 清空) ---
menu_edit_config() {
    [ -f "$META_FILE" ] || die "未发现配置。"
    IFS='|' read -r o_mode o_ip o_port o_user o_pass < "$META_FILE"

    echo -e "\n==== [修改监听配置] ===="
    echo -e "${YELLOW}说明：直接回车保持不变，输入 read 则清空该项${RESET}"
    
    # 1. 模式修改
    echo "1. SOCKS5 模式"
    echo "2. HTTP 模式"
    read -r -p "选择模式 [当前: $o_mode]: " m_choice
    case "$m_choice" in
        1) n_mode="SOCKS5" ;;
        2) n_mode="HTTP" ;;
        *) n_mode="$o_mode" ;;
    esac

    # 2. IP 修改
    read -r -p "监听 IP [当前: $o_ip]: " n_ip
    n_ip="${n_ip:-$o_ip}"

    # 3. 端口修改
    read -r -p "监听端口 [当前: $o_port]: " n_port
    n_port="${n_port:-$o_port}"
    
    # 4. 用户名修改
    read -r -p "用户名 [当前: ${o_user:-空}]: " i_user
    if [ -z "$i_user" ]; then
        n_user="$o_user"          # 直接回车，保持原样
    elif [ "$i_user" = "read" ]; then
        n_user=""                 # 输入 read，设为空
    else
        n_user="$i_user"          # 输入其他，设为新值
    fi

    # 5. 密码修改
    read -r -p "密码 [当前: ${o_pass:-空}]: " i_pass
    if [ -z "$i_pass" ]; then
        n_pass="$o_pass"          # 直接回车，保持原样
    elif [ "$i_pass" = "read" ]; then
        n_pass=""                 # 输入 read，设为空
    else
        n_pass="$i_pass"          # 输入其他，设为新值
    fi

    write_systemd "$n_mode" "$n_ip" "$n_port" "$n_user" "$n_pass"
    systemctl restart "$SERVICE_NAME" && ok "配置已更新并重启服务。"
}
# --- 6. 验证逻辑 ---
menu_show_node_config() {
    [ -f "$META_FILE" ] || die "记录不存在。"
    IFS='|' read -r b_mode b_ip b_port b_user b_pass < "$META_FILE"

    local p_url="socks5://"
    [[ "$b_mode" == "HTTP" ]] && p_url="http://"
    [[ -n "$b_user" ]] && p_url="${p_url}${b_user}:${b_pass}@"
    p_url="${p_url}127.0.0.1:${b_port}"

    info "正在请求 Cloudflare 边缘节点进行验证..."
    local trace_data=$(curl -6 -sS --max-time 10 -x "$p_url" "https://www.cloudflare.com/cdn-cgi/trace")
    
    if [ -n "$trace_data" ]; then
        local trace_ip=$(echo "$trace_data" | grep "ip=" | cut -d= -f2)
        local trace_warp=$(echo "$trace_data" | grep "warp=" | cut -d= -f2)
        local trace_colo=$(echo "$trace_data" | grep "colo=" | cut -d= -f2)

        echo -e "\n${GREEN}========= Cloudflare 真实性报告 =========${RESET}"
        if [ "$trace_warp" = "on" ] || [ "$trace_warp" = "plus" ]; then
            echo -e " 隧道验证状态 :  ${GREEN}✔ 通过 (流量确实从 Cloudflare 网络流出)${RESET}"
            echo -e " WARP 激活状态:  ${GREEN}${trace_warp}${RESET}"
        else
            echo -e " 隧道验证状态 :  ${RED}✘ 未通过 (可能没有走代理隧道)${RESET}"
            echo -e " WARP 激活状态:  ${RED}${trace_warp:-off}${RESET}"
        fi
        echo -e " CF 分配出口IP:  ${YELLOW}${trace_ip}${RESET}"
        echo -e " CF 边缘数据中心: ${YELLOW}${trace_colo}${RESET}"
        echo -e "${GREEN}=========================================${RESET}"
    else
        echo -e "${RED}[验证失败]${RESET} 无法通过代理连接至验证端点。"
    fi
}

# --- 主循环 ---
while true; do
    get_status_info; clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}           CF-WARP 面板          ${RESET}"
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
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) download_bin; register_usque; write_systemd "SOCKS5" "127.0.0.1" "1080" "" ""; systemctl restart "$SERVICE_NAME"; ok "安装完成。" ;;
        2) systemctl stop "$SERVICE_NAME"; download_bin; systemctl start "$SERVICE_NAME"; ok "更新完成。" ;;
        3) systemctl stop "$SERVICE_NAME"; rm -f "$INSTALL_BIN" "$SERVICE_FILE" "$META_FILE"; rm -rf "$CONF_DIR"; ok "已卸载。" ;;
        4) menu_edit_config ;;
        5) systemctl start "$SERVICE_NAME" ;;
        6) systemctl stop "$SERVICE_NAME" ;;
        7) systemctl restart "$SERVICE_NAME" ;;
        8) journalctl -u "$SERVICE_NAME" -n 50 -f ;;
        9) menu_show_node_config ;;
        0) exit 0 ;;
    esac
    read -n 1 -s -r -p "按任意键返回..."
done
