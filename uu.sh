#!/bin/sh
# ==========================================
# 哪吒监控 & Komari Agent & NodeGet Agent 全自动卸载工具
# 支持系统: Alpine (OpenRC), Debian/Ubuntu/CentOS (Systemd)
# ==========================================

NZ_BASE_PATH="/opt/nezha"
NZ_AGENT_PATH="${NZ_BASE_PATH}/agent"
KOMARI_PATH="/opt/komari/agent"

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# 输出函数
info() { printf "${yellow}[INFO] %s${plain}\n" "$*"; }
err() { printf "${red}[ERROR] %s${plain}\n" "$*" >&2; }
success() { printf "${green}[SUCCESS] %s${plain}\n" "$*"; }

# 权限检查
sudo_exec() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo > /dev/null 2>&1; then
            sudo "$@"
        else
            err "错误: 需要root权限且未找到sudo"
            exit 1
        fi
    else
        "$@"
    fi
}

# --- 1. 卸载哪吒 Agent ---
uninstall_nezha() {
    if [ -d "$NZ_AGENT_PATH" ]; then
        info "正在检测并停止 哪吒-agent 服务..."
        config_files=$(find "$NZ_AGENT_PATH" -name "config*.yml" 2>/dev/null)
        
        if [ -n "$config_files" ]; then
            for config in $config_files; do
                sudo_exec "${NZ_AGENT_PATH}/nezha-agent" service -c "$config" uninstall >/dev/null 2>&1 || true
            done
        fi

        info "清理哪吒文件..."
        sudo_exec rm -rf "$NZ_AGENT_PATH"
        if [ -d "$NZ_BASE_PATH" ] && [ -z "$(ls -A "$NZ_BASE_PATH" 2>/dev/null)" ]; then
            sudo_exec rm -rf "$NZ_BASE_PATH"
        fi
        success "哪吒-agent 卸载完成"
    else
        info "未发现哪吒安装目录，跳过"
    fi
}

# --- 2. 卸载 Komari Agent ---
uninstall_komari() {
    info "开始检测并停止 Komari-agent..."

    # Systemd
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files | grep -q "komari-agent"; then
            sudo_exec systemctl stop komari-agent >/dev/null 2>&1 || true
            sudo_exec systemctl disable komari-agent >/dev/null 2>&1 || true
            sudo_exec rm -f /etc/systemd/system/komari-agent.service
            sudo_exec systemctl daemon-reload
            info "Systemd: Komari 服务已清理"
        fi
    fi

    # OpenRC
    if command -v rc-service >/dev/null 2>&1; then
        if [ -f "/etc/init.d/komari-agent" ]; then
            sudo_exec rc-service komari-agent stop >/dev/null 2>&1 || true
            sudo_exec rc-update del komari-agent default >/dev/null 2>&1 || true
            sudo_exec rm -f /etc/init.d/komari-agent
            info "OpenRC: Komari 服务已清理"
        fi
    fi

    info "清理 Komari 文件残留..."
    sudo_exec rm -rf "$KOMARI_PATH"
    
    success "Komari-agent 卸载完成"
}

# --- 3. 卸载 NodeGet Agent ---
uninstall_nodeget() {
    info "开始卸载 NodeGet Agent..."
    bash <(curl -sL https://install.nodeget.com) uninstall-agent
    success "NodeGet Agent 卸载完成"
}

# --- 执行流程 ---
echo -e "${yellow}--- 自动化清理程序启动 ---${plain}"

uninstall_nezha
uninstall_komari
uninstall_nodeget

echo -e "${yellow}--- 所有组件已检测清理完毕 ---${plain}"
