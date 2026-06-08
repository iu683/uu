#!/usr/bin/env bash

# ==============================================================================
#   usque (MASQUE-WARP) 一键管理面板 (纯 IPv6 深度优化版)
# ==============================================================================

# ── 核心环境变量 ──────────────────────────────────────────────────────────────
export REPO="Shannon-x/usque"
export SERVICE_NAME="usque"
export SERVICE_USER="root" # 保持 root 以保证未来可能使用高级模式，SOCKS 模式也是安全的
export INSTALL_BIN="/usr/local/bin/usque"
export CONF_DIR="/etc/usque"
export CONF_FILE="${CONF_DIR}/config.json"
export SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ── 终端颜色定义 ──────────────────────────────────
export RESET='\033[0m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'

# ── 基础环境校验 ──────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误]${RESET} 请使用 root 权限运行此脚本！" >&2
    exit 1
fi

info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
die()  { echo -e "${RED}[ERROR]${RESET} $1" >&2; exit 1; }

# 动态识别操作系统包管理器
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        die "无法识别当前操作系统类型。"
    fi
}
detect_os

# 仅检查主程序运行和下载解压所需的基础工具
REQUIRED_CMDS="curl grep awk"
MISSING_CMDS=""

for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING_CMDS="$MISSING_CMDS $cmd"
    fi
done

if [ -n "$MISSING_CMDS" ]; then
    info "检测到系统缺失必要组件:${YELLOW}$MISSING_CMDS${RESET}，正在自动修复..."
    case "$OS" in
        ubuntu|debian)
            apt-get update -qy && apt-get install -y $MISSING_CMDS >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y $MISSING_CMDS >/dev/null 2>&1
            else
                yum install -y $MISSING_CMDS >/dev/null 2>&1
            fi
            ;;
        *)
            die "未未知系统，请手动安装组件: $MISSING_CMDS"
            ;;
    esac
    ok "基础依赖补全成功！"
fi

# ── 1. 核心下载模块 ─────────────────────────────────────────────────────────
download_bin() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  TARGET="linux_amd64" ;;
        aarch64) TARGET="linux_arm64" ;;
        *) die "暂不支持的系统架构: $ARCH" ;;
    esac

    info "正在检测最新的 Usque 发布版本..."
    # 纯 v6 盒子优先尝试双栈反代源，防止直连 GitHub API 报错
    local latest_tag
    latest_tag=$(curl -fsSL --max-time 5 "https://ghproxy.cn/https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$latest_tag" ]; then
        latest_tag=$(curl -fsSL --max-time 5 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    # 兜底版本号
    [ -z "$latest_tag" ] && latest_tag="v0.1.0"

    URL_BIN="https://ghproxy.cn/https://github.com/${REPO}/releases/download/${latest_tag}/usque_${TARGET}"
    URL_BACKUP="https://v6.gh-proxy.org/https://github.com/${REPO}/releases/download/${latest_tag}/usque_${TARGET}"

    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR"
    
    info "正在下载适用于 ${YELLOW}${ARCH}${RESET} 的二进制资产..."
    if ! curl -fsSL -o "${INSTALL_BIN}" "$URL_BIN"; then
        warn "主加速源失效，切换备用纯 IPv6 代理源下载..."
        curl -fsSL -o "${INSTALL_BIN}" "$URL_BACKUP" || die "下载 usque 失败！请检查网络连通性。"
    fi

    chmod +x "$INSTALL_BIN"
    ok "Usque 主程序下载并部署成功！"
}

# ── 2. 纯 v6 环境注册救场模块 ──────────────────────────────────────────────────
register_usque() {
    info "由于您的服务器为纯 IPv6 环境，正在临时挂载 DNS64 以确保可以顺利注册 WARP 账户..."
    
    # 备份原始 resolv.conf
    local cp_resolv=0
    if [ -f /etc/resolv.conf ]; then
        cp -f /etc/resolv.conf /etc/resolv.conf.bak
        cp_resolv=1
    fi

    # 强力注入能够解析并路由到 v4 接口的 DNS64
    echo "nameserver 2a01:4f8:c2c:123f::1" > /etc/resolv.conf

    cd "$CONF_DIR" || exit 1
    info "正在执行设备绑定与 MASQUE 协议注册 (usque register)..."
    
    # 执行注册，在本地生成 config.json
    if "$INSTALL_BIN" register; then
        ok "Cloudflare MASQUE 账号注册与本地凭据生成成功！"
    else
        # 还原 resolv 并报错
        [ "$cp_resolv" -eq 1 ] && mv -f /etc/resolv.conf.bak /etc/resolv.conf
        die "注册失败！请检查 Cloudflare API 连通性或稍后再试。"
    fi

    # 完美还原网络设置
    if [ "$cp_resolv" -eq 1 ]; then
        mv -f /etc/resolv.conf.bak /etc/resolv.conf
        info "系统原网络解析环境已安全还原。"
    fi
}

# ── 3. Systemd 生成器 ─────────────────────────────────────────────────────────
write_systemd() {
    local bind_ip="$1" local bind_port="$2" local username="$3" local password="$4"

    local exec_args="socks -b ${bind_ip} -p ${bind_port}"
    if [ -n "$username" ] && [ -n "$password" ]; then
        exec_args="${exec_args} -u ${username} -w ${password}"
    fi

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
    
    # 存储当前的参数供面板读取显示
    echo "${bind_ip}:${bind_port}|${username}|${password}" > "${CONF_DIR}/.panel_meta"
}

# ── 4. 面板常规功能模块 ──────────────────────────────────────────────────────
get_status_info() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        panel_status="${GREEN}运行中 (MASQUE 协议已接通)${RESET}"
    else
        panel_status="${RED}未运行${RESET}"
    fi

    if [ -f "$INSTALL_BIN" ]; then
        panel_version="已安装"
    else
        panel_version="${RED}未安装${RESET}"
    fi

    if [ -f "${CONF_DIR}/.panel_meta" ]; then
        local meta
        meta=$(cat "${CONF_DIR}/.panel_meta")
        panel_port="${meta%%|*}"
    else
        panel_port="0.0.0.0:1080"
    fi
}

menu_install() {
    if [ -f "$INSTALL_BIN" ]; then
        warn "系统中已存在运行中的 usque 实例。"
        read -r -p "$(echo -e "${GREEN}是否确定完全覆盖重新安装？[y/N]: ${RESET}")" res
        [[ "$res" =~ ^[Yy]$ ]] || return
    fi

    echo -e "\n${GREEN}==== [自定义安装配置] ====${RESET}"
    read -r -p "$(echo -e "${GREEN}请输入监听 IP 地址 [默认: 127.0.0.1]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-127.0.0.1}"

    read -r -p "$(echo -e "${GREEN}请输入 SOCKS5 监听端口 [默认: 1080]: ${RESET}")" input_port
    local opt_port="${input_port:-1080}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then
        opt_port=1080
    fi

    local opt_user="" local opt_pass=""
    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo -e "${YELLOW}[安全审计] 检测到公网绑定，必须强制设置鉴权密码！${RESET}"
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入鉴权用户名: ${RESET}")" opt_user
            [ -n "$opt_user" ] && break
        done
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入鉴权密码 (≥16位): ${RESET}")" opt_pass
            if [ ${#opt_pass} -ge 16 ]; then break; fi
            warn "为了您的公网安全，密码长度不能少于16位！"
        done
    else
        read -r -p "$(echo -e "${GREEN}请输入鉴权用户名 (本地回环默认留空免密): ${RESET}")" opt_user
        if [ -n "$opt_user" ]; then
            read -r -p "$(echo -e "${GREEN}请输入鉴权密码: ${RESET}")" opt_pass
        fi
    fi

    download_bin
    register_usque
    write_systemd "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"

    info "正在拉起后台服务..."
    systemctl start "$SERVICE_NAME"
    
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Usque MASQUE-WARP 安全部署成功！"
    else
        warn "服务拉起较慢，请稍后选择 [8] 查看实时日志。"
    fi
}

menu_update() {
    [ -f "$SERVICE_FILE" ] || die "未检测到系统服务，请先选择 [1] 进行安装。"
    systemctl stop "$SERVICE_NAME"
    download_bin
    systemctl start "$SERVICE_NAME"
    ok "Usque 核心组件已成功平滑更新。"
}

menu_uninstall() {
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$INSTALL_BIN" "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$CONF_DIR"
    ok "Usque 全套组件及本地配置已全部彻底清理卸载完毕。"
}

menu_edit_config() {
    [ -f "${CONF_DIR}/.panel_meta" ] || die "未发现任何面板元配置，请先执行安装步骤。"
    
    local meta current_ip current_port current_user current_pass
    meta=$(cat "${CONF_DIR}/.panel_meta")
    local ip_port="${meta%%|*}"
    current_ip="${ip_port%%:*}"
    current_port="${ip_port##*:}"
    
    # 提取账号密码
    local remain="${meta#*|}"
    current_user="${remain%%|*}"
    current_pass="${remain##*|}"

    echo -e "\n${GREEN}==== [修改运行配置参数] ====${RESET}"
    read -r -p "$(echo -e "${GREEN}请输入监听 IP 地址 [当前: ${current_ip}]: ${RESET}")" input_ip
    local opt_ip="${input_ip:-$current_ip}"

    read -r -p "$(echo -e "${GREEN}请输入 SOCKS5 监听端口 [当前: ${current_port}]: ${RESET}")" input_port
    local opt_port="${input_port:-$current_port}"
    if ! [[ "$opt_port" =~ ^[0-9]+$ ]] || [ "$opt_port" -le 0 ] || [ "$opt_port" -gt 65535 ]; then
        opt_port="$current_port"
    fi

    local opt_user="" local opt_pass=""
    if [ "$opt_ip" != "127.0.0.1" ] && [ "$opt_ip" != "localhost" ]; then
        echo -e "${YELLOW}[安全审计] 公网暴露下必须强制设定鉴权密码！${RESET}"
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入用户名 [当前: ${current_user}]: ${RESET}")" input_user
            opt_user="${input_user:-$current_user}"
            [ -n "$opt_user" ] && break
        done
        while true; do
            read -r -p "$(echo -e "${GREEN}请输入鉴权密码 (≥16位): ${RESET}")" input_pass
            opt_pass="${input_pass:-$current_pass}"
            if [ ${#opt_pass} -ge 16 ]; then break; fi
            warn "公网安全审计：密码必须大于16位！"
        done
    else
        if [ -n "$current_user" ]; then
            read -r -p "$(echo -e "${GREEN}请输入用户名 [当前: ${current_user}，回车不变，输入 ${RED}none${GREEN} 清除鉴权]: ${RESET}")" input_user
            if [ -z "$input_user" ]; then
                opt_user="$current_user" opt_pass="$current_pass"
            elif [ "$input_user" = "none" ]; then
                opt_user="" opt_pass=""
            else
                opt_user="$input_user"
                read -r -p "$(echo -e "${GREEN}请输入新密码: ${RESET}")" opt_pass
            fi
        else
            read -r -p "$(echo -e "${GREEN}请输入鉴权用户名 (留空默认不启用): ${RESET}")" opt_user
            if [ -n "$opt_user" ]; then read -r -p "$(echo -e "${GREEN}请输入鉴权密码: ${RESET}")" opt_pass; fi
        fi
    fi

    write_systemd "$opt_ip" "$opt_port" "$opt_user" "$opt_pass"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
        ok "配置已覆盖，后台引擎服务已同步重启生效！"
    else
        ok "配置参数已成功重写更新。"
    fi
}

menu_show_node_config() {
    if [ ! -f "${CONF_DIR}/.panel_meta" ]; then die "未检测到有效的面板运行记录。"; fi
    
    local meta ip_port bind_ip bind_port auth_user auth_pass
    meta=$(cat "${CONF_DIR}/.panel_meta")
    ip_port="${meta%%|*}"
    bind_ip="${ip_port%%:*}"
    bind_port="${ip_port##*:}"
    
    local remain="${meta#*|}"
    auth_user="${remain%%|*}"
    auth_pass="${remain##*|}"

    echo -e "\n${GREEN}========= 当前 Usque SOCKS5 服务端详情 =========${RESET}"
    echo -e " 监听地址 : ${YELLOW}${bind_ip}${RESET}"
    echo -e " 监听端口 : ${YELLOW}${bind_port}${RESET}"
    if [ -n "$auth_user" ]; then
        echo -e " 鉴权用户 : ${YELLOW}${auth_user}${RESET}"
        echo -e " 鉴权密码 : ${YELLOW}${auth_pass}${RESET}"
    else
        echo -e " 鉴权状态 : ${GREEN}未开启（无密本地回环模式）${RESET}"
    fi
    echo -e "${GREEN}===============================================${RESET}"

    local connect_ip="$bind_ip"
    if [ "$connect_ip" = "0.0.0.0" ]; then connect_ip="127.0.0.1"; fi

    local proxy_args="--socks5-hostname ${connect_ip}:${bind_port}"
    if [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then
        proxy_args="--socks5-hostname ${auth_user}:${auth_pass}@${connect_ip}:${bind_port}"
    fi

    echo -e "\n${YELLOW}[正在通过本地 SOCKS5 管道验证 MASQUE 出口链路连通性...]${RESET}"
    TMP_TRACE="$(mktemp)"
    if curl -sS --max-time 8 $proxy_args "https://www.cloudflare.com/cdn-cgi/trace" > "$TMP_TRACE" 2>&1; then
        local trace_ip trace_warp trace_colo
        trace_ip=$(grep -i '^ip=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        trace_warp=$(grep -i '^warp=' "$TMP_TRACE" | awk -F '=' '{print $2}')
        trace_colo=$(grep -i '^colo=' "$TMP_TRACE" | awk -F '=' '{print $2}')

        echo -e "\n${GREEN}========= Cloudflare 真实性验证报告 =========${RESET}"
        if [ "$trace_warp" = "on" ] || [ "$trace_warp" = "plus" ]; then
            echo -e " 隧道验证状态 :  ${GREEN}✔ 成功连接 (MASQUE 隧道已完成握手分流)${RESET}"
            echo -e " WARP 激活状态:  ${GREEN}${trace_warp}${RESET}"
        else
            echo -e " 隧道验证状态 :  ${RED}✘ 未成功流出 (可能未走隧道网络)${RESET}"
            echo -e " WARP 激活状态:  ${RED}${trace_warp:-off}${RESET}"
        fi
        echo -e " MASQUE 隧道出口IP:  ${YELLOW}${trace_ip}${RESET}"
        echo -e " 接入边缘数据中心 : ${YELLOW}${trace_colo}${RESET}"
        echo -e "${GREEN}=============================================${RESET}"
    else
        echo -e "${RED}[验证失败]${RESET} 无法通过本地代理通道与 Cloudflare MASQUE 节点通信，请选择选项[8]检查服务状态。"
    fi
    rm -f "$TMP_TRACE"
}

# ── 5. 主循环控制中心 ─────────────────────────────────────────────────────────
while true; do
    get_status_info
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}    Usque (MASQUE-WARP) 面板   ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $panel_status"
    echo -e "${GREEN}版本 :${RESET} ${YELLOW}${panel_version}${RESET}"
    echo -e "${GREEN}绑定 :${RESET} ${YELLOW}${panel_port}${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1. 安装 Usque (MASQUE)${RESET}"
    echo -e "${GREEN} 2. 更新 Usque 核心组件${RESET}"
    echo -e "${GREEN} 3. 卸载全套组件${RESET}"
    echo -e "${GREEN} 4. 修改端口/鉴权配置${RESET}"
    echo -e "${GREEN} 5. 启动服务${RESET}"
    echo -e "${GREEN} 6. 停止服务${RESET}"
    echo -e "${GREEN} 7. 重启服务${RESET}"
    echo -e "${GREEN} 8. 查看实时崩溃日志${RESET}"
    echo -e "${GREEN} 9. 验证本地 SOCKS5 状态${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    
    read -r -p "$(echo -e "${GREEN}请输入选项: ${RESET}")" choice
    
    case "$choice" in
        1) menu_install ;;
        2) menu_update ;;
        3) menu_uninstall ;;
        4) menu_edit_config ;;
        5) systemctl start "$SERVICE_NAME" && ok "动作: 引擎启动成功" ;;
        6) systemctl stop "$SERVICE_NAME" && ok "动作: 引擎停止成功" ;;
        7) systemctl restart "$SERVICE_NAME" && ok "动作: 引擎重启成功" ;;
        8) (trap 'echo -e "\n"' INT; journalctl -u "$SERVICE_NAME" -n 50 -f) ;;
        9) menu_show_node_config ;;
        0) clear; exit 0 ;;
        *) warn "未识别的无效序号！"; sleep 1 ;;
    esac
    
    read -n 1 -s -r -p "$(echo -e "${GREEN}按任意键返回主控制面板...${RESET}")"
done
