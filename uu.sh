#!/bin/bash
# ======================================
# ZeroClaw 一键菜单管理脚本
# ======================================
export LANG=en_US.UTF-8
CARGO_BIN="$HOME/.cargo/bin"

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# 确保 cargo 在 PATH
export PATH="$CARGO_BIN:$PATH"

install_zeroclaw() {
    green "克隆仓库并安装 ZeroClaw..."
    git clone https://github.com/zeroclaw-labs/zeroclaw.git ~/zeroclaw
    cd ~/zeroclaw || return
    cargo build --release --locked
    cargo install --path . --force --locked
    green "安装完成！确保 ~/.cargo/bin 在 PATH 中"
}

update_zeroclaw() {
    green "更新 ZeroClaw..."
    cd ~/zeroclaw || { red "未找到 zeroclaw 目录，请先安装"; return; }
    git pull
    cargo build --release --locked
    cargo install --path . --force --locked
    green "更新完成！"
}

onboard_menu() {
    echo "选择配置方式:"
    echo "1) 无提示快速设置"
    echo "2) 交互式向导"
    echo "3) 仅修复频道/允许列表"
    read -rp "请选择: " choice
    case $choice in
        1)
            read -rp "请输入 API Key: " apikey
            read -rp "请输入 Provider (openrouter/其它): " provider
            zeroclaw onboard --api-key "$apikey" --provider "$provider"
            ;;
        2) zeroclaw onboard --interactive ;;
        3) zeroclaw onboard --channels-only ;;
        *) red "无效选择" ;;
    esac
}

chat_menu() {
    echo "聊天模式:"
    echo "1) 单条消息模式"
    echo "2) 交互模式"
    read -rp "请选择: " choice
    case $choice in
        1)
            read -rp "输入消息: " msg
            zeroclaw agent -m "$msg"
            ;;
        2) zeroclaw agent ;;
        *) red "无效选择" ;;
    esac
}

gateway_menu() {
    echo "启动网关:"
    echo "1) 默认端口 8080"
    echo "2) 随机端口"
    read -rp "请选择: " choice
    case $choice in
        1) zeroclaw gateway ;;
        2) zeroclaw gateway --port 0 ;;
        *) red "无效选择" ;;
    esac
}

daemon_menu() {
    zeroclaw daemon
}

system_check_menu() {
    echo "系统检查:"
    echo "1) 查看状态"
    echo "2) 运行系统诊断"
    echo "3) 检查频道健康"
    echo "4) 获取集成设置详情"
    read -rp "请选择: " choice
    case $choice in
        1) zeroclaw status ;;
        2) zeroclaw doctor ;;
        3) zeroclaw channel doctor ;;
        4)
            read -rp "请输入集成名称 (如 Telegram): " integ
            zeroclaw integrations info "$integ"
            ;;
        *) red "无效选择" ;;
    esac
}

service_menu() {
    echo "后台服务管理:"
    echo "1) 安装服务"
    echo "2) 查看服务状态"
    echo "3) 启动服务"
    echo "4) 停止服务"
    echo "5) 卸载服务"
    read -rp "请选择: " choice
    case $choice in
        1) zeroclaw service install ;;
        2) zeroclaw service status ;;
        3) zeroclaw service start ;;
        4) zeroclaw service stop ;;
        5) zeroclaw service uninstall ;;
        *) red "无效选择" ;;
    esac
}

main_menu() {
    while true; do
        echo ""
        green "=== ZeroClaw 管理菜单 ==="
        echo "1) 安装 / 更新 ZeroClaw"
        echo "2) 配置 ZeroClaw"
        echo "3) 聊天模式"
        echo "4) 启动网关"
        echo "5) 启动完整守护进程"
        echo "6) 系统检查"
        echo "7) 后台服务管理"
        echo "0) 退出"
        read -rp "请选择: " choice
        case $choice in
            1)
                echo "1) 安装  2) 更新"
                read -rp "选择: " sub
                [[ $sub == 1 ]] && install_zeroclaw
                [[ $sub == 2 ]] && update_zeroclaw
                ;;
            2) onboard_menu ;;
            3) chat_menu ;;
            4) gateway_menu ;;
            5) daemon_menu ;;
            6) system_check_menu ;;
            7) service_menu ;;
            0) exit 0 ;;
            *) red "无效选择" ;;
        esac
    done
}

main_menu
