#!/usr/bin/env bash
set -e

# ==============================================================================
#      CF-WARP 多区域彻底解耦自治控制台 (纯 v6 终极双强洗 + Tun2Socks 升级版)
# ==============================================================================

# ── 【通用共享空间】 ──
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

# ── 【区域 1: Usque (MASQUE-WARP) 变量空间】 ──
export REPO_WARP="Diniboy1123/usque"
export SERVICE_NAME="usque"
export SERVICE_USER="root"
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ── 【区域 2: Tun2Socks (全局网卡模式) 变量空间】 ──
export REPO_TUN="heiher/hev-socks5-tunnel"
export SERVICE_TUN="tun2socks"
export CONF_DIR_TUN="/etc/tun2socks"
export CONF_FILE_TUN="${CONF_DIR_TUN}/config.yaml"
export FILE_SERVICE_TUN="/etc/systemd/system/${SERVICE_TUN}.service"
export BIN_TUN="/usr/local/bin/tun2socks"

# ── 【区域 3: Google 透明代理专属变量空间】 ──
export PROXY_SERVICE_NAME="warp-google-proxy"
export REDSOCKS_CONF="/etc/redsocks-google.conf"
export DATA_DIR="/etc/warp-google"
export PROXY_RULES_SCRIPT="${DATA_DIR}/proxy_rules.sh"
export PROXY_SERVICE_FILE="/etc/systemd/system/${PROXY_SERVICE_NAME}.service"


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

# 环境依赖自动补齐
REQUIRED_CMDS="curl grep awk unzip iptables"
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

check_v4_connectivity() {
    if curl -4sSk --max-time 3 https://www.cloudflare.com/cdn-cgi/trace | grep -q "ip=" 2>/dev/null; then
        return 0 # 有 v4
    else
        return 1 # 纯 v6
    fi
}


# ==============================================================================
#   【区域 1 独立业务层】：Usque 内核专区
# ==============================================================================
download_warp_bin() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="linux_amd64" ;;
        aarch64) TARGET="linux_arm64" ;;
        *) die "暂不支持的系统架构: $ARCH" ;;
    esac

    info "正在自动检索 GitHub 最新 Release 版本..."
    local latest_tag=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        latest_tag=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/${REPO_WARP}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [ -n "$latest_tag" ] && break
    done
    if [ -z "$latest_tag" ]; then
        latest_tag=$(curl -fsSL --max-time 10 "https://github.com/${REPO_WARP}/releases/latest" 2>/dev/null | grep -o 'tag/[vV]*[0-9.]*' | awk -F '/' 'NR==1 {print $2}')
    fi
    [ -z "$latest_tag" ] && latest_tag="v3.0.0"
    local pure_ver="${latest_tag#v}"
    info "锁定最新版本号: v${pure_ver}"

    local zip_name="usque_${pure_ver}_${TARGET}.zip"
    local tmp_dir=$(mktemp -d)
    
    local download_success=0
    for proxy in "${GITHUB_PROXY[@]}"; do
        local url="https://github.com/${REPO_WARP}/releases/download/${latest_tag}/${zip_name}"
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
        if curl -fsSL -L --max-time 45 -o "$tmp_dir/$zip_name" "https://github.com/${REPO_WARP}/releases/download/${latest_tag}/${zip_name}"; then
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
    rm -rf "$tmp_dir"
}

register_usque() {
    local has_v4=0
    if curl -4sSk --max-time 4 https://www.cloudflare.com/cdn-cgi/trace | grep -q "ip=" 2>/dev/null; then
        has_v4=1
    fi

    local cp_resolv=0
    if [ "$has_v4" -ne 1 ]; then
        info "检测到当前环境为纯 IPv6 独享机，正在配置临时 DNS64 管道以确保云端握手..."
        if [ -f /etc/resolv.conf ]; then cp -f /etc/resolv.conf /etc/resolv.conf.bak; cp_resolv=1; fi
        # 使用更稳定的多路 DNS64 管道
        echo -e "nameserver 2a01:4f8:c2c:123f::1\nnameserver 2001:4860:4860::8888" > /etc/resolv.conf
    else
        info "检测到当前环境具备常规 IPv4 链路，保持原生配置直连..."
    fi

    # 清理历史可能残存的无效配置，防止干扰新注册
    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
    rm -f "$CONF_FILE"
    cd "$CONF_DIR" || exit 1
    
    info "云端自动申请 Team Token (JWT) [免交互传递]..."
    local jwt_token=""
    jwt_token=$(curl -fsSL --max-time 15 "https://web--public--warp-team-api--coia-mfs4.code.run/" 2>/dev/null)
    
    if [[ "$jwt_token" =~ ^ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
        ok "拦截并应用云端 JWT 凭证成功！"
        local reg_cmd=("${INSTALL_BIN}" "register" "--jwt" "${jwt_token}")
    else
        warn "云端 Token 获取受阻（或因纯 v6 局限），自动降级为无感注册..."
        local reg_cmd=("${INSTALL_BIN}" "register")
    fi

    # 执行设备注册
    if "${reg_cmd[@]}"; then
        ok "Cloudflare 凭据注册完成。"
        
        # 🌟 核心硬核改写：拒绝空变量提取，纯 v6 直接强行焊死镜像端点
        if [ -f "$CONF_FILE" ]; then
            if [ "$has_v4" -ne 1 ]; then
                info "正在对纯 IPv6 环境进行核心配置文件 [硬核端点镜像] 清洗..."
                
                # 1. 强行重写或者插入 endpoint_v4 字段
                if grep -q '"endpoint_v4"' "$CONF_FILE"; then
                    sed -i 's/"endpoint_v4": *"[^"]*"/"endpoint_v4": "2606:4700:102::1"/g' "$CONF_FILE"
                else
                    # 如果没有，在第一层花括号后插入
                    sed -i 's/{/{\n  "endpoint_v4": "2606:4700:102::1",/' "$CONF_FILE"
                fi

                # 2. 强行重写或者插入 endpoint_v6 字段
                if grep -q '"endpoint_v6"' "$CONF_FILE"; then
                    sed -i 's/"endpoint_v6": *"[^"]*"/"endpoint_v6": "2606:4700:102::1"/g' "$CONF_FILE"
                else
                    sed -i 's/{/{\n  "endpoint_v6": "2606:4700:102::1",/' "$CONF_FILE"
                fi
                
                # 3. 针对新版内核通用的主 endpoint 字段（带端口的）同步焊死
                if grep -q '"endpoint"' "$CONF_FILE"; then
                    sed -i -E 's/"endpoint": *"[^"]*"/"endpoint": "[2606:4700:102::1]:443"/g' "$CONF_FILE"
                fi
                
                ok "清洗完毕：全部出站端点已强行锁定重定向至官方 v6 Anycast -> [2606:4700:102::1]"
            else
                ok "双栈/V4 环境验证通过，保留官方原生配置。"
            fi
        fi
    else
        # 还原 DNS
        [ "$cp_resolv" -eq 1 ] && mv -f /etc/resolv.conf.bak /etc/resolv.conf
        die "设备注册失败，请检查机器的外部出站路由。"
    fi

    # 还原 DNS
    [ "$cp_resolv" -eq 1 ] && mv -f /etc/resolv.conf.bak /etc/resolv.conf
}

write_systemd() {
    local bind_ip="$1" local bind_port="$2" local username="$3" local password="$4"
    local exec_args="socks -b ${bind_ip} -p ${bind_port}"
    if [ -n "$username" ] && [ "$username" != "none" ] && [ -n "$password" ]; then exec_args="${exec_args} -u ${username} -w ${password}"; fi

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

menu_install_warp() {
    if [ -f "$INSTALL_BIN" ]; then warn "检测到旧实例，正自动执行全覆盖升级安装..."; fi
    download_warp_bin
    register_usque
    write_systemd "127.0.0.1" "1080" "" ""
    info "拉起后台系统服务..."
    systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then ok "Usque 全自动部署成功！"; else warn "初始化中，可进入日志排查。"; fi
}

menu_update_warp() {
    [ -f "$SERVICE_FILE" ] || die "服务未安装，请先选择一键自动安装。"
    info "正在检测并自动获取上游最新版本..."
    systemctl stop "$SERVICE_NAME"
    download_warp_bin
    systemctl start "$SERVICE_NAME"
    ok "核心组件已无缝热升级至最新版本！"
}

menu_uninstall_warp() {
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$INSTALL_BIN" "$SERVICE_FILE"
    systemctl daemon-reload; rm -rf "$CONF_DIR"
    ok "全套组件及环境快照清理完毕。"
}

menu_edit_config_warp() {
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

    local opt_user="" local opt_pass=""
    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo "[安全审计] 公网暴露下必须强制设定鉴权密码！"
        while true; do read -r -p "请输入用户名 [当前: ${current_user}]: " input_user; opt_user="${input_user:-$current_user}"; [ -n "$opt_user" ] && break; done
        while true; do read -r -p "请输入鉴权密码 (>=16位): " input_pass; opt_pass="${input_pass:-$current_pass}"; if [ ${#opt_pass} -ge 16 ]; then break; fi; warn "密码必须大于16位！"; done
    else
        read -r -p "请输入鉴权用户名 (留空默认不启用，输入 none 清除鉴权): " input_user
        opt_user="${input_user:-$current_user}"
        if [ "$opt_user" = "none" ] || [ -z "$opt_user" ]; then
            opt_user="" opt_pass=""
        else
            read -r -p "请输入鉴权密码: " input_pass
            opt_pass="${input_pass:-$current_pass}"
        fi
    fi

    write_systemd "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    if systemctl is-active --quiet "$SERVICE_NAME"; then systemctl restart "$SERVICE_NAME" && ok "服务同步重启生效！"; else ok "参数重写成功。"; fi
}

menu_show_node_warp() {
    [ -f "${CONF_DIR}/.panel_meta" ] || die "未检测到有效的面板运行记录。"
    local meta=$(cat "${CONF_DIR}/.panel_meta"); local ip_port="${meta%%|*}"
    local bind_ip="${ip_port%%:*}" bind_port="${ip_port##*:}"
    local remain="${meta#*|}" auth_user="${remain%%|*}" auth_pass="${remain##*|}"

    echo -e "\n========= 当前 Usque SOCKS5 服务端详情 ========="
    echo " 监听地址 : ${bind_ip}"
    echo " 监听端口 : ${bind_port}"
    if [ -n "$auth_user" ]; then
        echo " 鉴权用户 : ${auth_user}"
        echo " 鉴权密码 : ${auth_pass}"
    else
        echo " 鉴权状态 : 未开启（无密本地回回环模式）"
    fi
    echo "==============================================="

    local connect_ip="$bind_ip"
    [ "$connect_ip" = "0.0.0.0" ] && connect_ip="127.0.0.1"
    local proxy_args="--socks5-hostname ${connect_ip}:${bind_port}"
    if [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then proxy_args="--socks5-hostname ${auth_user}:${auth_pass}@${connect_ip}:${bind_port}"; fi

    info "正在通过本地 SOCKS5 管道验证 MASQUE 出口链路连通性..."
    local TMP_TRACE=$(mktemp)
    if curl -sS --max-time 8 $proxy_args "https://www.cloudflare.com/cdn-cgi/trace" > "$TMP_TRACE" 2>&1; then
        local trace_ip=$(grep -i '^ip=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        local trace_warp=$(grep -i '^warp=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        local trace_colo=$(grep -i '^colo=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        echo -e "\n========= Cloudflare 真实性验证报告 ========="
        if [ "$trace_warp" = "on" ] || [ "$trace_warp" = "plus" ]; then
            echo -e " 隧道验证状态 :  ✔ 成功连接 (MASQUE 隧道已完成握手分流)"
        else
            echo -e " 隧道验证状态 :  ✘ 未成功流出 (可能未走隧道网络)"
        fi
        echo " MASQUE 隧道出口IP:  ${trace_ip}"
        echo " 接入边缘数据中心 : ${trace_colo}"
        echo "============================================="
    else
        warn "无法通过本地代理通道与 Cloudflare 通信，请排查内核日志。"
    fi
    rm -f "$TMP_TRACE"
}

# ── 【区域 1 子菜单大循环】 ──
loop_zone_warp() {
    while true; do
        if systemctl is-active --quiet "$SERVICE_NAME"; then panel_status="运行中"; else panel_status="已停止"; fi
        if [ -f "$INSTALL_BIN" ]; then panel_version="v$("$INSTALL_BIN" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "已安装")"; else panel_version="未安装"; fi
        if [ -f "${CONF_DIR}/.panel_meta" ]; then local meta=$(cat "${CONF_DIR}/.panel_meta"); panel_port="${meta%%|*}"; else panel_port="127.0.0.1:1080"; fi

        clear
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "      【区域 1】 WARP 内核独立自治菜单      "
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN} 内核状态 :${RESET} $panel_status"
        echo -e "${GREEN} 内核版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
        echo -e "${GREEN} 监听绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN} 1. 一键全自动安装/部署 WARP-Rust 内核${RESET}"
        echo -e "${GREEN} 2. 无缝升级 WARP-Rust 核心组件${RESET}"
        echo -e "${GREEN} 3. 修改 监听参数/密码鉴权 规则${RESET}"
        echo -e "${GREEN} 4. 启动后台守护进程 (Systemd)${RESET}"
        echo -e "${GREEN} 5. 停止后台守护进程 (Systemd)${RESET}"
        echo -e "${GREEN} 6. 重启后台守护进程 (Systemd)${RESET}"
        echo -e "${GREEN} 7. 实时滚动查看内核日志${RESET}"
        echo -e "${GREEN} 8. 诊断当前配置与虚拟出口真实状态${RESET}"
        echo -e "${YELLOW} 9. 彻底卸载擦除当前区域内核组件${RESET}"
        echo -e "${GREEN} 0. 返回大统一管理总控制台${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        read -r -p "请选择内核治理功能序号: " z_choice
        case "$z_choice" in
            1) menu_install_warp ;;
            2) menu_update_warp ;;
            3) menu_edit_config_warp ;;
            4) systemctl start "$SERVICE_NAME" && ok "动作: 守护服务已拉起" ;;
            5) systemctl stop "$SERVICE_NAME" && ok "动作: 守护服务已关闭" ;;
            6) systemctl restart "$SERVICE_NAME" && ok "动作: 守护服务已重启" ;;
            7) (trap 'echo ""' INT; journalctl -u "$SERVICE_NAME" -n 50 -f) ;;
            8) menu_show_node_warp ;;
            9) menu_uninstall_warp ;;
            0|*) return ;;
        esac
        echo -e "\n按任意键返回区 1 控制面板..."
        read -n 1 -s -r
    done
}


# ==============================================================================
#   【区域 2 独立业务层】：Tun2Socks 全局托管网卡专区
# ==============================================================================
cleanup_ip_rules() {
    info "正在清洗全局网卡物理残留路由规则..."
    ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip -6 rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip route del default dev tun0 table 20 2>/dev/null || true
    ip rule del lookup 20 pref 20 2>/dev/null || true
    while ip rule del pref 15 2>/dev/null; do true; done
    while ip -6 rule del pref 15 2>/dev/null; do true; done
    while ip rule del pref 5 2>/dev/null; do true; done
    while ip -6 rule del pref 5 2>/dev/null; do true; done
}

# 🌟 剥离出下载函数，供安装和更新复用
download_tun2socks_bin() {
    info "正在检索 Tun2Socks 最新架构托管数据..."
    local latest_tun_tag=""
    for proxy in "${GITHUB_PROXY[@]}"; do
        latest_tun_tag=$(curl -fsSL --max-time 6 "${proxy}https://api.github.com/repos/$REPO_TUN/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [ -n "$latest_tun_tag" ] && break
    done
    [ -z "$latest_tun_tag" ] && latest_tun_tag="v2.5.2"

    local dl_ok=0
    for proxy in "${GITHUB_PROXY[@]}"; do
        local download_url="${proxy}https://github.com/$REPO_TUN/releases/download/${latest_tun_tag}/tun2socks-linux-amd64.zip"
        local tmp_zip=$(mktemp -u).zip
        if curl -fsSL -L --max-time 30 -o "$tmp_zip" "$download_url"; then
            local tmp_unzip_dir=$(mktemp -d)
            if unzip -q -o "$tmp_zip" -d "$tmp_unzip_dir" 2>/dev/null; then
                local found_bin=$(find "$tmp_unzip_dir" -type f -name "tun2socks*" | head -n1)
                if [ -n "$found_bin" ]; then
                    cp -f "$found_bin" "$BIN_TUN" && chmod +x "$BIN_TUN" && dl_ok=1
                    rm -rf "$tmp_unzip_dir" "$tmp_zip" && break
                fi
            fi
            rm -rf "$tmp_unzip_dir" "$tmp_zip"
        fi
    done
    if [ "$dl_ok" -eq 1 ]; then
        ok "Tun2Socks 核心托管引擎成功部署 (版本: ${latest_tun_tag})！"
    else
        die "所有加速镜像源均未响应，下载失败。"
    fi
}

install_tun2socks() {
    if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then
        warn "检测到区 3 谷歌分流正在运行，已将其安全关闭以防冲突。"
        systemctl stop "$PROXY_SERVICE_NAME" || true
    fi
    cleanup_ip_rules
    mkdir -p "$CONF_DIR_TUN"

    if [ ! -f "$BIN_TUN" ]; then
        download_tun2socks_bin
    fi

    local default_addr="127.0.0.1" local default_port="1080"
    if [ -f "${CONF_DIR}/.panel_meta" ]; then
        local meta=$(cat "${CONF_DIR}/.panel_meta"); local ip_port="${meta%%|*}"
        default_addr="${ip_port%%:*}" default_port="${ip_port##*:}"
        [ "$default_addr" = "0.0.0.0" ] && default_addr="127.0.0.1"
    fi

    echo -e "\n>>>> 全局托管网卡接入配置中心 <<<<"
    read -r -p "请输入上游代理地址 [默认使用本地内核: $default_addr]: " custom_addr
    local final_addr="${custom_addr:-$default_addr}"
    read -r -p "请输入上游代理端口 [默认使用本地内核: $default_port]: " custom_port
    local final_port="${custom_port:-$default_port}"

    local auth_yaml=""
    read -r -p "该上游代理是否配置了账号密码？(y/N): " is_auth
    if [[ "$is_auth" =~ ^[Yy]$ ]]; then
        read -r -p "请输入用户名: " s_user
        read -r -p "请输入鉴权密码: " s_pass
        if [ -n "$s_user" ] && [ -n "$s_pass" ]; then
            auth_yaml="  username: '${s_user}'"$'\n'"  password: '${s_pass}'"
        fi
    fi

    cat <<EOF > "$CONF_FILE_TUN"
tunnel:
  name: tun0
  mtu: 1500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $final_port
  address: '$final_addr'
$auth_yaml
  udp: 'udp'
  mark: 438
EOF

    # 针对纯 v6 / 双栈环境的本地物理路由保留策略
    local main_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    local main_ip6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    
    local rule_v4_in="" local rule_v4_out=""
    if [ -n "$main_ip" ]; then
        rule_v4_in="ExecStartPost=-/sbin/ip rule add from $main_ip lookup main pref 15"
        rule_v4_out="ExecStop=-/sbin/ip rule del from $main_ip lookup main pref 15"
    fi
    
    local rule_v6_in="" local rule_v6_out=""
    if [ -n "$main_ip6" ]; then
        rule_v6_in="ExecStartPost=-/sbin/ip -6 rule add from $main_ip6 lookup main pref 15"
        rule_v6_out="ExecStop=-/sbin/ip -6 rule del from $main_ip6 lookup main pref 15"
    fi

    cat <<EOF > "$FILE_SERVICE_TUN"
[Unit]
Description=Tun2Socks Global Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$BIN_TUN -config $CONF_FILE_TUN
ExecStartPost=/bin/sleep 1
ExecStartPost=-/sbin/ip rule add to 0.0.0.0/0 dport 22 lookup main pref 5
ExecStartPost=-/sbin/ip rule add to 0.0.0.0/0 sport 22 lookup main pref 5
ExecStartPost=-/sbin/ip -6 rule add to ::/0 dport 22 lookup main pref 5
ExecStartPost=-/sbin/ip -6 rule add to ::/0 sport 22 lookup main pref 5
ExecStartPost=-/sbin/ip rule add fwmark 438 lookup main pref 10
ExecStartPost=-/sbin/ip -6 rule add fwmark 438 lookup main pref 10
ExecStartPost=-/sbin/ip route add default dev tun0 table 20
ExecStartPost=-/sbin/ip rule add lookup 20 pref 20
${rule_v4_in}
${rule_v6_in}

ExecStop=-/sbin/ip rule del to 0.0.0.0/0 dport 22 lookup main pref 5
ExecStop=-/sbin/ip rule del to 0.0.0.0/0 sport 22 lookup main pref 5
ExecStop=-/sbin/ip -6 rule del to ::/0 dport 22 lookup main pref 5
ExecStop=-/sbin/ip -6 rule del to ::/0 sport 22 lookup main pref 5
ExecStop=-/sbin/ip rule del fwmark 438 lookup main pref 10
ExecStop=-/sbin/ip -6 rule del fwmark 438 lookup main pref 10
ExecStop=-/sbin/ip route del default dev tun0 table 20
ExecStop=-/sbin/ip rule del lookup 20 pref 20
${rule_v4_out}
${rule_v6_out}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tun2socks.service >/dev/null 2>&1
    systemctl restart tun2socks.service && ok "全局托管虚似网卡已成功挂载运行！"
}

# 🌟 新增的 Tun2Socks 核心在线升级函数
menu_update_tun2socks() {
    [ -f "$FILE_SERVICE_TUN" ] || die "Tun2Socks 服务未安装，无需更新。"
    info "正在为您检测并拉取最新的 Tun2Socks 稳定版核心发行数据..."
    systemctl stop "$SERVICE_TUN" >/dev/null 2>&1 || true
    download_tun2socks_bin
    systemctl start "$SERVICE_TUN"
    ok "Tun2Socks 虚拟网卡引擎已热升级并重启完毕！"
}

uninstall_tun2socks() {
    systemctl stop "$SERVICE_TUN" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_TUN" >/dev/null 2>&1 || true
    cleanup_ip_rules
    rm -f "$BIN_TUN" "$FILE_SERVICE_TUN"
    rm -rf "$CONF_DIR_TUN"
    systemctl daemon-reload
    ok "全局网卡区域已干净卸载，原生路由规则已还原。"
}

# ── 【区域 2 子菜单大循环】 ──
loop_zone_tun() {
    while true; do
        if systemctl is-active --quiet "$SERVICE_TUN"; then tun_status="运行中"; else tun_status="已停止"; fi
        if [ -f "$BIN_TUN" ]; then tun_version="已就绪"; else tun_version="未安装"; fi
        if [ -f "$CONF_FILE_TUN" ]; then
            local tgt_ip=$(grep 'address:' "$CONF_FILE_TUN" | awk '{print $2}' | tr -d "'\"")
            local tgt_pt=$(grep 'port:' "$CONF_FILE_TUN" | awk '{print $2}')
            tun_bind="${tgt_ip}:${tgt_pt}"
        else
            tun_bind="未配置"
        fi

        clear
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "      【区域 2】 全局网卡托管独立菜单      "
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN} 网卡状态 :${RESET} $tun_status"
        echo -e "${GREEN} 组件就绪 :${RESET} ${YELLOW}${tun_version}${RESET}"
        echo -e "${GREEN} 桥接上游 :${RESET} ${YELLOW}${tun_bind}${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN} 1. 🚀 激活 / 部署 Tun2Socks 全局托管网卡模式${RESET}"
        echo -e "${GREEN} 2. ⚡ 在线拉取更新 Tun2Socks 核心托管引擎${RESET}"
        echo -e "${GREEN} 3. 停用 Tun2Socks 全局托管物理路由${RESET}"
        echo -e "${GREEN} 4. 实时滚动查看虚拟网卡物理日志${RESET}"
        echo -e "${YELLOW} 5. 彻底卸载并清除当前区域网卡组件${RESET}"
        echo -e "${GREEN} 0. 返回大统一管理总控制台${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        read -r -p "请选择网卡治理功能序号: " t_choice
        case "$t_choice" in
            1) install_tun2socks ;;
            2) menu_update_tun2socks ;;
            3) systemctl stop "$SERVICE_TUN" && cleanup_ip_rules && ok "全局托管物理网卡已停用" ;;
            4) (trap 'echo ""' INT; journalctl -u "$SERVICE_TUN" -n 50 -f) ;;
            5) uninstall_tun2socks ;;
            0|*) return ;;
        esac
        echo -e "\n按任意键返回区 2 控制面板..."
        read -n 1 -s -r
    done
}


# ==============================================================================
#   【区域 3 独立业务层】：Google 专属透明分流专区
# ==============================================================================
start_google_proxy() {
    if systemctl is-active --quiet "$SERVICE_TUN"; then
        warn "检测到区 2 全局网卡正在运行！必须先关闭全局代理，才能开启专属分流。"
        return
    fi

    local default_port="1080"
    if [ -f "${CONF_DIR}/.panel_meta" ]; then
        local meta=$(cat "${CONF_DIR}/.panel_meta"); local ip_port="${meta%%|*}"
        default_port="${ip_port##*:}"
    fi

    info "自动补齐专属透明代理依赖组件群 (redsocks)..."
    if ! command -v redsocks &>/dev/null; then
        case $OS in
            ubuntu|debian) apt-get update -qy && apt-get install -y redsocks >/dev/null 2>&1 ;;
            *) yum install -y redsocks >/dev/null 2>&1 || true ;;
        esac
    fi

    systemctl stop redsocks >/dev/null 2>&1 || true
    systemctl disable redsocks >/dev/null 2>&1 || true

    cat <<EOF > "$REDSOCKS_CONF"
base { log_debug = off; log_info = on; log = "syslog:daemon"; daemon = off; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = ${default_port}; type = socks5; }
EOF

    mkdir -p "$DATA_DIR"
    cat <<'EOF' > "$PROXY_RULES_SCRIPT"
#!/bin/bash
ACTION=$1
GOOGLE_IPS="8.8.4.0/24 8.8.8.0/24 34.0.0.0/9 35.184.0.0/13 35.192.0.0/12 35.224.0.0/12 35.240.0.0/13 64.233.160.0/19 66.102.0.0/20 66.249.64.0/19 72.14.192.0/18 74.125.0.0/16 104.132.0.0/14 108.177.0.0/17 142.250.0.0/15 172.217.0.0/16 172.253.0.0/16 173.194.0.0/16 209.85.128.0/17 216.58.192.0/19 216.239.32.0/19"
if [ "$ACTION" = "start" ]; then
    /sbin/iptables -t nat -N WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -F WARP_GOOGLE
    for ip in $GOOGLE_IPS; do /sbin/iptables -t nat -A WARP_GOOGLE -d $ip -p tcp -j REDIRECT --to-ports 12345; done
    /sbin/iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null || /sbin/iptables -t nat -A OUTPUT -j WARP_GOOGLE
elif [ "$ACTION" = "stop" ]; then
    /sbin/iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -F WARP_GOOGLE 2>/dev/null || true
    /sbin/iptables -t nat -X WARP_GOOGLE 2>/dev/null || true
fi
EOF
    chmod +x "$PROXY_RULES_SCRIPT"

    cat <<EOF > "$PROXY_SERVICE_FILE"
[Unit]
Description=Cloudflare WARP Google Transparent Proxy
After=network.target ${SERVICE_NAME}.service

[Service]
Type=simple
ExecStart=/usr/sbin/redsocks -c ${REDSOCKS_CONF}
ExecStartPost=${PROXY_RULES_SCRIPT} start
ExecStop=${PROXY_RULES_SCRIPT} stop
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
    systemctl start "$PROXY_SERVICE_NAME" && ok "Google 专属透明分流代理链条已部署并完全咬合启动！"
}

uninstall_google_proxy() {
    systemctl stop "$PROXY_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1 || true
    [ -f "$PROXY_RULES_SCRIPT" ] && "$PROXY_RULES_SCRIPT" stop >/dev/null 2>&1 || true
    rm -f "$REDSOCKS_CONF" "$PROXY_SERVICE_FILE"
    rm -rf "$DATA_DIR"
    systemctl daemon-reload
    ok "Google 透明分流链条已完美安全御载。"
}

# ── 【区域 3 子菜单大循环】 ──
loop_zone_google() {
    while true; do
        if systemctl is-active --quiet "$PROXY_SERVICE_NAME"; then g_status="分流中"; else g_status="已停止"; fi
        if command -v redsocks &>/dev/null; then g_ver="已就绪"; else g_ver="未配置"; fi

        clear
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "      【区域 3】 谷歌透明分流独立专属菜单      "
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN} 分流状态 :${RESET} $g_status"
        echo -e "${GREEN} 劫持组件 :${RESET} ${YELLOW}${g_ver}${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN} 1. 一键开启 📂 谷歌全线流量透明劫持分流模式${RESET}"
        echo -e "${GREEN} 2. 一键断开 / 关闭 谷歌专属透明分流代理链条${RESET}"
        echo -e "${GREEN} 3. 实时滚动查看分流内核底层日志数据流${RESET}"
        echo -e "${YELLOW} 4. 彻底卸载清除当前区域透明劫持分流元数据${RESET}"
        echo -e "${GREEN} 0. 返回大统一管理总控制台${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        read -r -p "请选择分流治理功能序号: " g_choice
        case "$g_choice" in
            1) start_google_proxy ;;
            2) systemctl stop "$PROXY_SERVICE_NAME" && ok "谷歌劫持规则已摘除" ;;
            3) (trap 'echo ""' INT; journalctl -u "$PROXY_SERVICE_NAME" -n 50 -f) ;;
            4) uninstall_google_proxy ;;
            0|*) return ;;
        esac
        echo -e "\n按任意键返回区 3 控制面板..."
        read -n 1 -s -r
    done
}


# ==============================================================================
#   【总控大面板逻辑】：多区域完全分流自治
# ==============================================================================
uninstall_all_components() {
    echo -e "\n${YELLOW}[警告] 您正在下发最高清算洗刷指令，全套三区域组件将被彻底湮灭！${RESET}"
    read -r -p "确认清空吗？(y/N): " conf_un
    if [[ "$conf_un" =~ ^[Yy]$ ]]; then
        uninstall_google_proxy || true
        uninstall_tun2socks || true
        menu_uninstall_warp || true
        ok "全域大统一三级空间及物理元数据已彻底灰飞烟灭，系统回滚至初始状态。"
    else
        info "操作已安全取消。"
    fi
}

while true; do
    clear
    echo -e "${GREEN}===================================================${RESET}"
    echo -e "      CF-WARP 多区域彻底解耦自治控制台 (经典原版样貌)      "
    echo -e "${GREEN}===================================================${RESET}"
    echo -e "${GREEN} 1. 📂 进入 [区域 1: WARP 内核] 专属深度管理子菜单${RESET}"
    echo -e "${GREEN} 2. 🚀 进入 [区域 2: 全局网卡] 专属托管配置子菜单${RESET}"
    echo -e "${GREEN} 3. 🎯 进入 [区域 3: 谷歌分流] 专属透明分流子菜单${RESET}"
    echo -e "---------------------------------------------------"
    echo -e "${YELLOW} 9. 💥 强制清算净化全套三区域自治组件与残留环境快照${RESET}"
    echo -e "${GREEN} 0. 安全退出当前原生态大系统管理面板${RESET}"
    echo -e "${GREEN}===================================================${RESET}"
    read -r -p "请输入您要治理的区域中心序号: " main_choice
    case "$main_choice" in
        1) loop_zone_warp ;;
        2) loop_zone_tun ;;
        3) loop_zone_google ;;
        9) uninstall_all_components ;;
        0) clear; exit 0 ;;
        *) warn "未识别的中心管理序列号！"; sleep 1 ;;
    esac
done
