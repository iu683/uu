#!/usr/bin/env bash

# ==============================================================================
#   Usque (MASQUE-WARP) 面板 - 纯 IPv6 专属全自动注册清洗版 (无乱码)
# ==============================================================================

export REPO="Diniboy1123/usque"
export SERVICE_NAME="usque"
export SERVICE_USER="root"
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

GITHUB_PROXY=(
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
    '' 
)

if [ "$EUID" -ne 0 ]; then
    echo "[错误] 请使用 root 权限运行此脚本！" >&2
    exit 1
fi

info() { echo "[INFO] $1"; }
ok()   { echo "[OK] $1"; }
warn() { echo "[WARN] $1"; }
die()  { echo "[ERROR] $1" >&2; exit 1; }

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

# ── 1. 高速轮询下载 ──────────────────────────────────────────────────────────
download_bin() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="linux_amd64" ;;
        aarch64) TARGET="linux_arm64" ;;
        *) die "暂不支持的系统架构: $ARCH" ;;
    esac

    info "正在检索最新 Release 版本..."
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
    info "锁定版本号: v${pure_ver}"

    local zip_name="usque_${pure_ver}_${TARGET}.zip"
    local tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    local download_success=0
    for proxy in "${GITHUB_PROXY[@]}"; do
        local url="https://github.com/${REPO}/releases/download/${latest_tag}/${zip_name}"
        [ -n "$proxy" ] && url="${proxy}${url}"
        
        info "尝试通过加速源 [${proxy:-官方直连}] 下载..."
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
        ok "Usque 内核程序部署成功。"
    else
        die "解压文件异常，未找到内核。"
    fi
}

# ── 2. 核心：云端自动获取 JWT Token 与跨界清洗 ───────────────────────────────
register_usque() {
    info "正在配置临时 DNS64 注册大管道..."
    local cp_resolv=0
    if [ -f /etc/resolv.conf ]; then cp -f /etc/resolv.conf /etc/resolv.conf.bak; cp_resolv=1; fi
    echo "nameserver 2a01:4f8:c2c:123f::1" > /etc/resolv.conf

    cd "$CONF_DIR" || exit 1
    
    # === 自动化高光：静默请求第三方 API 获取凭证 ===
    info "正在连接第三方云端自动申请 Team Token (JWT)..."
    local jwt_token=""
    jwt_token=$(curl -fsSL --max-time 15 "https://web--public--warp-team-api--coia-mfs4.code.run/" 2>/dev/null)
    
    # 简单的格式校验，确保拿到的是合规的 JWT
    if [[ "$jwt_token" =~ ^ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
        ok "成功自动截获有效的云端 JWT 凭证！"
        local reg_cmd=("${INSTALL_BIN}" "register" "--jwt" "${jwt_token}")
    else
        warn "云端自动获取 Token 失败或接口断流，将尝试进行本地普通匿名注册..."
        local reg_cmd=("${INSTALL_BIN}" "register")
    fi

    info "正在向 Cloudflare 边缘网络集群签发设备契约文件..."
    if "${reg_cmd[@]}"; then
        ok "Cloudflare 凭据注册成功！"
        
        # === 核心清洗：修正纯 IPv6 机器固执读取 v4 键值的 bug ===
        if [ -f "$CONF_FILE" ]; then
            info "正在对纯 IPv6 环境进行核心配置文件欺骗清洗..."
            local real_v6=$(grep -o '"endpoint_v6": *"[^"]*"' "$CONF_FILE" | awk -F '"' '{print $4}')
            
            if [ -n "$real_v6" ]; then
                # 强行把 endpoint_v4 的值也改写成获取到的真实 IPv6 地址
                sed -i "s/\"endpoint_v4\": *\"[^\"]*\"/\"endpoint_v4\": \"${real_v6}\"/g" "$CONF_FILE"
                ok "清洗成功：已强制将 [endpoint_v4] 键值克隆为 IPv6 节点 -> ${real_v6}"
            else
                warn "未在配置文件中捕获到 endpoint_v6 字段，跳过自动清洗。"
            fi
        fi
    else
        [ "$cp_resolv" -eq 1 ] && mv -f /etc/resolv.conf.bak /etc/resolv.conf
        die "注册设备失败，请检查当前服务器的 IPv6 外部出站路由。"
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

# ── 4. 控制中心常规模块 ──────────────────────────────────────────────────────
get_status_info() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        panel_status="运行中 (MASQUE 隧道已接通)"
    else
        panel_status="未运行"
    fi
    if [ -f "$INSTALL_BIN" ]; then panel_version="已安装/动态最新"; else panel_version="未安装"; fi
    if [ -f "${CONF_DIR}/.panel_meta" ]; then
        local meta=$(cat "${CONF_DIR}/.panel_meta"); panel_port="${meta%%|*}"
    else panel_port="127.0.0.1:1080"; fi
}

menu_install() {
    if [ -f "$INSTALL_BIN" ]; then
        warn "检测到系统中已存在运行中的实例。"
        read -r -p "是否确定完全覆盖重新安装？[y/N]: " res
        [[ "$res" =~ ^[Yy]$ ]] || return
    fi

    echo ""
    echo "==== [自定义安装配置] ===="
    read -r -p "请输入监听 IP 地址 [默认: 127.0.0.1]: " input_ip
    local opt_ip="${input_ip:-127.0.0.1}"

    read -r -p "请输入 SOCKS5 监听端口 [默认: 1080]: " input_port
    local opt_port="${input_port:-1080}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then opt_port=1080; fi

    local opt_user="" local opt_pass=""
    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo "[安全审计] 公网暴露必须强制启用账号密码鉴权！"
        while true; do read -r -p "请输入用户名: " opt_user; [ -n "$opt_user" ] && break; done
        while true; do
            read -r -p "请输入强密码 (>=16位): " opt_pass
            if [ ${#opt_pass} -ge 16 ]; then break; fi
            warn "密码强度过低，公网高危！请重新设置。"
        done
    else
        read -r -p "请输入鉴权用户名 (本地回环模式留空免密): " opt_user
        if [ -n "$opt_user" ]; then read -r -p "请输入鉴权密码: " opt_pass; fi
    fi

    download_bin
    register_usque
    write_systemd "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"

    info "正在拉起后台系统服务..."
    systemctl start "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Usque 全自动无感部署大获成功！"
    else
        warn "服务正在初始化，可选择选项 [8] 追查实时日志。"
    fi
}

menu_update() {
    [ -f "$SERVICE_FILE" ] || die "服务未安装，请先选择 [1]。"
    systemctl stop "$SERVICE_NAME"
    download_bin
    systemctl start "$SERVICE_NAME"
    ok "Usque 组件已完美更新。"
}

menu_uninstall() {
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$INSTALL_BIN" "$SERVICE_FILE"
    systemctl daemon-reload; rm -rf "$CONF_DIR"
    ok "全套组件清理完毕。"
}

menu_edit_config() {
    [ -f "${CONF_DIR}/.panel_meta" ] || die "未发现运行元记录，请先执行安装步骤。"
    local meta=$(cat "${CONF_DIR}/.panel_meta"); local ip_port="${meta%%|*}"
    local current_ip="${ip_port%%:*}" current_port="${ip_port##*:}"
    local remain="${meta#*|}" current_user="${remain%%|*}" current_pass="${remain##*|}"

    echo ""
    echo "==== [修改运行配置参数] ===="
    read -r -p "请输入监听 IP 地址 [当前: ${current_ip}]: " input_ip
    local opt_ip="${input_ip:-$current_ip}"
    read -r -p "请输入 SOCKS5 监听端口 [当前: ${current_port}]: " input_port
    local opt_port="${input_port:-$current_port}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then opt_port="$current_port"; fi

    local opt_user="" local opt_pass=""
    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo "[安全审计] 公网暴露下必须强制设定鉴权密码！"
        while true; do read -r -p "请输入用户名 [当前: ${current_user}]: " input_user; opt_user="${input_user:-$current_user}"; [ -n "$opt_user" ] && break; done
        while true; do read -r -p "请输入鉴权密码 (>=16位): " input_pass; opt_pass="${input_pass:-$current_pass}"; if [ ${#opt_pass} -ge 16 ]; then break; fi; warn "公网安全审计：密码必须大于16位！"; done
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
    if [ ! -f "${CONF_DIR}/.panel_meta" ]; then die "未检测到运行元记录。"; fi
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
    echo "[正在通过本地 SOCKS5 管道验证 MASQUE 出口链路连通性...]"
    TMP_TRACE="$(mktemp)"
    if curl -sS --max-time 8 $proxy_args "https://www.cloudflare.com/cdn-cgi/trace" > "$TMP_TRACE" 2>&1; then
        local trace_ip=$(grep -i '^ip=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        local trace_warp=$(grep -i '^warp=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        local trace_colo=$(grep -i '^colo=' "$TMP_TRACE" | awk -F '=' '{print $2}')

        echo ""
        echo "========= Cloudflare 真实性验证报告 ========="
        if [ "$trace_warp" = "on" ] || [ "$trace_warp" = "plus" ]; then
            echo " 隧道验证状态 :  ✔ 成功连接 (MASQUE 隧道已完成握手分流)"
            echo " WARP 激活状态:  ${trace_warp}"
        else
            echo " 隧道验证状态 :  ✘ 未成功流出 (可能未走隧道网络)"
            echo " WARP 激活状态:  ${trace_warp:-off}"
        fi
        echo " MASQUE 隧道出口IP:  ${trace_ip}"
        echo " 接入边缘数据中心 : ${trace_colo}"
        echo "============================================="
    else
        echo "[验证失败] 无法通过本地代理通道与 Cloudflare 通信，请选择选项 [8] 排查。"
    fi
    rm -f "$TMP_TRACE"
}

# ── 5. 主控制循环 ────────────────────────────────────────────────────────────
while true; do
    get_status_info; clear
    echo "=============================="
    echo "    Usque (MASQUE-WARP) 面板   "
    echo "=============================="
    echo "状态 : $panel_status"
    echo "版本 : $panel_version"
    echo "绑定 : $panel_port"
    echo "=============================="
    echo " 1. 自动适配安装 Usque"
    echo " 2. 检查并更新核心组件"
    echo " 3. 卸载全套组件"
    echo " 4. 修改端口/鉴权配置"
    echo " 5. 启动服务"
    echo " 6. 停止服务"
    echo " 7. 重启服务"
    echo " 8. 查看内核实时日志"
    echo " 9. 验证本地 SOCKS5 状态"
    echo " 0. 退出"
    echo "=============================="
    read -r -p "请输入选项: " choice
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
        0) clear; exit 0 ;;
        *) warn "未识别的无效序号！"; sleep 1 ;;
    esac
    read -n 1 -s -r -p "按任意键返回主控制面板..."
done
