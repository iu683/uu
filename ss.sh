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

# 精准还原你要求的配色方案
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

GITHUB_PROXY=(
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
    '' 
)

if [ "$EUID" -ne 0 ]; then
    echo -e "${GREEN}[错误]${RESET} 请使用 root 权限运行此脚本！" >&2
    exit 1
fi

info() { echo -e "${GREEN}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${GREEN}[ERROR]${RESET} $1" >&2; exit 1; }

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        die "无法识别当前操作系统类型。"
    fi
}
detect_os

REQUIRED_CMDS="curl grep awk unzip"
MISSING_CMDS=""
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then MISSING_CMDS="$MISSING_CMDS $cmd"; fi
done

if [ -n "$MISSING_CMDS" ]; then
    info "正在自动安装缺失的系统组件: $MISSING_CMDS..."
    case "$OS" in
        ubuntu|debian) apt-get update -qy && apt-get install -y $MISSING_CMDS >/dev/null 2>&1 ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then dnf install -y $MISSING_CMDS >/dev/null 2>&1; else yum install -y $MISSING_CMDS >/dev/null 2>&1; fi ;;
    esac
    ok "依赖补全成功！"
fi

# ── 1. 动态获取最新版本并下载 ──────────────────────────────────────────────
download_bin() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="linux_amd64" ;;
        aarch64) TARGET="linux_arm64" ;;
        *) die "暂不支持的系统架构: $ARCH" ;;
    esac

    info "正在自动检索 GitHub 最新 Release 版本..."
    local latest_tag=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        latest_tag=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [ -n "$latest_tag" ] && break
    done

    if [ -z "$latest_tag" ]; then
        latest_tag=$(curl -fsSL --max-time 10 "https://github.com/${REPO}/releases/latest" 2>/dev/null | grep -o 'tag/[vV]*[0-9.]*' | awk -F '/' 'NR==1 {print $2}')
    fi

    [ -z "$latest_tag" ] && latest_tag="v3.0.0"
    local pure_ver="${latest_tag#v}"
    info "锁定最新版本号: v${pure_ver}"

    local zip_name="usque_${pure_ver}_${TARGET}.zip"
    local tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    local download_success=0
    for proxy in "${GITHUB_PROXY[@]}"; do
        local url="https://github.com/${REPO}/releases/download/${latest_tag}/${zip_name}"
        [ -n "$proxy" ] && url="${proxy}${url}"
        
        info "自动切入下载源 [${proxy:-官方直连}]..."
        if curl -fsSL -L --max-time 35 -o "$tmp_dir/$zip_name" "$url"; then
            download_success=1
            break
        fi
    done

    if [ "$download_success" -ne 1 ]; then
        warn "触发 DNS64 管道防御突围..."
        if [ -f /etc/resolv.conf ]; then cp -f /etc/resolv.conf /etc/resolv.conf.bak; fi
        echo -e "nameserver 2a01:4f8:c2c:123f::1\nnameserver 2001:4860:4860::8888" > /etc/resolv.conf
        if curl -fsSL -L --max-time 45 -o "$tmp_dir/$zip_name" "https://github.com/${REPO}/releases/download/${latest_tag}/${zip_name}"; then
            download_success=1
        fi
        [ -f /etc/resolv.conf.bak ] && mv -f /etc/resolv.conf.bak /etc/resolv.conf
    fi

    [ "$download_success" -ne 1 ] && die "全局下载失败，请检查网络。"

    unzip -q -o "$tmp_dir/$zip_name" -d "$tmp_dir"
    if [ -f "$tmp_dir/usque" ]; then
        [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
        cp -f "$tmp_dir/usque" "$INSTALL_BIN"
        chmod +x "$INSTALL_BIN"
        ok "Usque 内核程序成功升级/部署至 v${pure_ver}。"
    else
        die "解压文件异常，未找到内核。"
    fi
}

# ── 2. 全自动云端注册与克隆清洗 (环境自适应) ──────────────────────────────────
register_usque() {
    local has_v4=0
    if curl -4sSk --max-time 4 https://www.cloudflare.com/cdn-cgi/trace | grep -q "ip=" 2>/dev/null; then
        has_v4=1
    fi

    local cp_resolv=0
    if [ "$has_v4" -ne 1 ]; then
        info "检测到当前环境为纯 IPv6 独享机，正在配置临时 DNS64 管道..."
        if [ -f /etc/resolv.conf ]; then cp -f /etc/resolv.conf /etc/resolv.conf.bak; cp_resolv=1; fi
        echo "nameserver 2a01:4f8:c2c:123f::1" > /etc/resolv.conf
    else
        info "检测到当前环境具备常规 IPv4 链路，保持原生配置直连..."
    fi

    cd "$CONF_DIR" || exit 1
    
    info "云端自动申请 Team Token (JWT) [免交互传递]..."
    local jwt_token=""
    jwt_token=$(curl -fsSL --max-time 15 "https://web--public--warp-team-api--coia-mfs4.code.run/" 2>/dev/null)
    
    if [[ "$jwt_token" =~ ^ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
        ok "拦截并应用云端 JWT 凭证成功！"
        local reg_cmd=("${INSTALL_BIN}" "register" "--jwt" "${jwt_token}")
    else
        warn "云端 Token 获取受阻，自动降级为匿名无感注册..."
        local reg_cmd=("${INSTALL_BIN}" "register")
    fi

    if "${reg_cmd[@]}"; then
        ok "Cloudflare 凭据注册完成。"
        
        # 自适应：只有纯 v6 机才改写配置文件，拥有 v4 则绝对不动
        if [ -f "$CONF_FILE" ]; then
            if [ "$has_v4" -ne 1 ]; then
                info "正在对纯 IPv6 环境进行核心配置文件欺骗清洗..."
                local real_v6=$(grep -o '"endpoint_v6": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')
                if [ -n "$real_v6" ]; then
                    sed -i "s/\"endpoint_v4\": *\"[^\"]*\"/\"endpoint_v4\": \"${real_v6}\"/g" "$CONF_FILE"
                    ok "清洗成功：[endpoint_v4] 已重定向至 -> ${real_v6}"
                else
                    warn "未检测到 endpoint_v6，跳过自动清洗。"
                fi
            else
                ok "双栈/V4 环境验证通过，保留官方原生 endpoint_v4 配置，未做任何修改。"
            fi
        fi
    else
        [ "$cp_resolv" -eq 1 ] && mv -f /etc/resolv.conf.bak /etc/resolv.conf
        die "设备注册失败，请检查机器的外部出站路由。"
    fi
    [ "$cp_resolv" -eq 1 ] && mv -f /etc/resolv.conf.bak /etc/resolv.conf
}

# ── 3. Systemd 生成器 ─────────────────────────────────────────────────────────
write_systemd() {
    local bind_ip="$1" local bind_port="$2" local username="$3" local password="$4"
    local exec_args="socks -b ${bind_ip} -p ${bind_port}"
    if [ -n "$username" ] && [ -n "$password" ]; then exec_args="${exec_args} -u ${username} -w ${password}"; fi

    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Cloudflare WARP MASQUE Proxy Client (Usque Engine)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${CONF_DIR}
ExecStart=${INSTALL_BIN} --config ${CONF_FILE} ${exec_args}
Restart=always
RestartSec=4s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    echo "${bind_ip}:${bind_port}|${username}|${password}" > "${CONF_DIR}/.panel_meta"
}

# ── 4. 状态与配置管理模块 ──────────────────────────────────────────────────────
get_status_info() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        panel_status="运行中"
    else
        panel_status="未运行"
    fi
    
    if [ -f "$INSTALL_BIN" ]; then
        # 使用 version 子命令替代 -v
        local check_ver
        check_ver=$("$INSTALL_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        if [ -n "$check_ver" ]; then
            panel_version="v${check_ver}"
        else
            panel_version="解析失败"
        fi
    else
        panel_version="未安装"
    fi

    if [ -f "${CONF_DIR}/.panel_meta" ]; then
        local meta=$(cat "${CONF_DIR}/.panel_meta"); panel_port="${meta%%|*}"
    else 
        panel_port="127.0.0.1:1080"
    fi
}

menu_install() {
    if [ -f "$INSTALL_BIN" ]; then
        warn "检测到旧实例，正自动执行全覆盖升级安装..."
    fi

    local opt_ip="127.0.0.1"
    local opt_port="1080"
    local opt_user=""
    local opt_pass=""

    download_bin
    register_usque
    write_systemd "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"

    info "拉起后台系统服务..."
    systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Usque 全自动部署成功！"
    else
        warn "初始化中，请选择选项 [8] 追查日志。"
    fi
}

menu_update() {
    [ -f "$SERVICE_FILE" ] || die "服务未安装，请先选择 [1] 一键自动安装。"
    info "正在检测并自动获取上游最新版本..."
    systemctl stop "$SERVICE_NAME"
    download_bin
    systemctl start "$SERVICE_NAME"
    ok "核心组件已无缝热升级至最新版本！"
}

menu_uninstall() {
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$INSTALL_BIN" "$SERVICE_FILE"
    systemctl daemon-reload; rm -rf "$CONF_DIR"
    ok "全套组件及环境快照清理完毕。"
}

menu_edit_config() {
    [ -f "${CONF_DIR}/.panel_meta" ] || die "未发现运行记录，请先执行安装步骤。"
    local meta=$(cat "${CONF_DIR}/.panel_meta"); local ip_port="${meta%%|*}"
    local current_ip="${ip_port%%:*}" current_port="${ip_port##*:}"
    local remain="${meta#*|}" current_user="${remain%%|*}" current_pass="${remain##*|}"

    echo ""
    echo "==== [自定义修改监听配置] ===="
    read -r -p "请输入监听 IP 地址 [当前: ${current_ip}]: " input_ip
    local opt_ip="${input_ip:-$current_ip}"
    read -r -p "请输入 SOCKS5 监听端口 [当前: ${current_port}]: " input_port
    local opt_port="${input_port:-$current_port}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then opt_port="$current_port"; fi

    local opt_user="" local opt_pass=""
    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo "[安全审计] 公网暴露下必须强制设定鉴权密码！"
        while true; do read -r -p "请输入用户名 [当前: ${current_user}]: " input_user; opt_user="${input_user:-$current_user}"; [ -n "$opt_user" ] && break; done
        while true; do read -r -p "请输入鉴权密码 (>=16位): " input_pass; opt_pass="${input_pass:-$current_pass}"; if [ ${#opt_pass} -ge 16 ]; then break; fi; warn "密码必须大于16位！"; done
    else
        if [ -n "$current_user" ]; then
            read -r -p "请输入用户名 [当前: ${current_user}，回车不变，输入 none 清除鉴权]: " input_user
            if [ -z "$input_user" ]; then opt_user="$current_user" opt_pass="$current_pass"
            elif [ "$input_user" = "none" ]; then opt_user="" opt_pass=""
            else opt_user="$input_user"; read -r -p "请输入新密码: " opt_pass; fi
        else
            read -r -p "请输入鉴权用户名 (留空默认不启用): " opt_user
            if [ -n "$opt_user" ]; then read -r -p "请输入鉴权密码: " opt_pass; fi
        fi
    fi

    write_systemd "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    if systemctl is-active --quiet "$SERVICE_NAME"; then systemctl restart "$SERVICE_NAME" && ok "服务同步重启生效！"; else ok "参数重写成功。"; fi
}

menu_show_node_config() {
    if [ ! -f "${CONF_DIR}/.panel_meta" ] ; then die "未检测到有效的面板运行记录。"; fi
    local meta=$(cat "${CONF_DIR}/.panel_meta"); local ip_port="${meta%%|*}"
    local bind_ip="${ip_port%%:*}" bind_port="${ip_port##*:}"
    local remain="${meta#*|}" auth_user="${remain%%|*}" auth_pass="${remain##*|}"

    echo ""
    echo "========= 当前 Usque SOCKS5 服务端详情 ========="
    echo " 监听地址 : ${bind_ip}"
    echo " 监听端口 : ${bind_port}"
    if [ -n "$auth_user" ]; then
        echo " 鉴权用户 : ${auth_user}"
        echo " 鉴权密码 : ${auth_pass}"
    else
        echo " 鉴权状态 : 未开启（无密本地回环模式）"
    fi
    echo "==============================================="

    local connect_ip="$bind_ip"
    [ "$connect_ip" = "0.0.0.0" ] && connect_ip="127.0.0.1"
    local proxy_args="--socks5-hostname ${connect_ip}:${bind_port}"
    if [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then proxy_args="--socks5-hostname ${auth_user}:${auth_pass}@${connect_ip}:${bind_port}"; fi

    echo ""
    info "正在通过本地 SOCKS5 管道验证 MASQUE 出口链路连通性..."
    TMP_TRACE="$(mktemp)"
    if curl -sS --max-time 8 $proxy_args "https://www.cloudflare.com/cdn-cgi/trace" > "$TMP_TRACE" 2>&1; then
        local trace_ip=$(grep -i '^ip=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        local trace_warp=$(grep -i '^warp=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        local trace_colo=$(grep -i '^colo=' "$TMP_TRACE" | awk -F '=' '{print $2}')

        echo ""
        echo "========= Cloudflare 真实性验证报告 ========="
        if [ "$trace_warp" = "on" ] || [ "$trace_warp" = "plus" ]; then
            echo -e " 隧道验证状态 :  ✔ 成功连接 (MASQUE 隧道已完成握手分流)"
            echo -e " WARP 激活状态:  ${trace_warp}"
        else
            echo " 隧道验证状态 :  ✘ 未成功流出 (可能未走隧道网络)"
            echo " WARP 激活状态:  ${trace_warp:-off}"
        fi
        echo " MASQUE 隧道出口IP:  ${trace_ip}"
        echo " 接入边缘数据中心 : ${trace_colo}"
        echo "============================================="
    else
        warn "无法通过本地代理通道与 Cloudflare 通信，请选择选项 [8] 排查。"
    fi
    rm -f "$TMP_TRACE"
}


while true; do
    get_status_info; clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}        CF-WARP 面板         ${RESET}"
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
        1) menu_install ;;
        2) menu_update ;;
        3) menu_uninstall ;;
        4) menu_edit_config ;;
        5) systemctl start "$SERVICE_NAME" && ok "动作: 引擎启动成功" ;;
        6) systemctl stop "$SERVICE_NAME" && ok "动作: 引擎停止成功" ;;
        7) systemctl restart "$SERVICE_NAME" && ok "动作: 引擎重启成功" ;;
        8) (trap 'echo ""' INT; journalctl -u "$SERVICE_NAME" -n 50 -f) ;;
        9) menu_show_node_config ;;
        0) exit 0 ;;
        *) warn "未识别的无效序号！"; sleep 1 ;;
    esac

    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键返回主控制面板...${RESET}")"
done
