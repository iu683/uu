#!/bin/bash

# 颜色定义
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

# 基础变量初始化
HOSTNAME=$(hostname)
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
WORKDIR="$HOME/mtp"
export SECRET=${SECRET:-$(echo -n "$USERNAME+$HOSTNAME" | md5sum | head -c 32)}

# 获取公网 IP
get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "127.0.0.1"
}

# 架构检测
get_arch() {
    local cmd=$(uname -m)
    if [ "$cmd" == "x86_64" ] || [ "$cmd" == "amd64" ] ; then
        echo "amd64"
    elif [ "$cmd" == "386" ]; then
        echo "386"
    elif [ "$cmd" == "arm" ]; then
        echo "arm"
    elif [ "$cmd" == "aarch64" ]; then
        echo "arm64"    
    else
        echo "amd64"
    fi
}

# 核心安装逻辑
install_mtg() {
    mkdir -p "$WORKDIR"
    pkill -9 mtg >/dev/null 2>&1
    
    purple "正在开始安装 MTProto 代理..."

    # 端口选择
    read -p "请输入你想使用的端口 (默认随机 10000-60000): " input_port
    MTP_PORT=${input_port:-$(shuf -i 10000-60000 -n 1)}
    echo "$MTP_PORT" > "$WORKDIR/.port"
    
    SERVER_IP=$(get_public_ip)
    arch=$(get_arch)
    
    # 下载对应架构的 mtg
    wget -q -O "${WORKDIR}/mtg" "https://github.com/whunt1/onekeymakemtg/raw/master/builds/ccbuilds/mtg-linux-$arch"
    if [ ! -s "${WORKDIR}/mtg" ]; then
        red "下载代理文件失败，请检查网络是否能访问 GitHub！"
        exit 1
    fi
    chmod +x "${WORKDIR}/mtg"

    # === 自启服务配置 ===
    if [ "$EUID" -eq 0 ]; then
        # 1. Root 用户：使用标准系统 systemd 服务托管，最稳妥
        cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTProto Go Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORKDIR
ExecStart=${WORKDIR}/mtg run -b 0.0.0.0:${MTP_PORT} ${SECRET} --stats-bind=127.0.0.1:${MTP_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mtg >/dev/null 2>&1
        systemctl start mtg
        green "已成功创建 Systemd 守护服务，配置开机自启！"
    else
        # 2. 非 Root 用户：降级采用 nohup 后台 + crontab 定时检查拉起
        nohup "${WORKDIR}/mtg" run -b 0.0.0.0:$MTP_PORT $SECRET --stats-bind=127.0.0.1:$MTP_PORT >/dev/null 2>&1 &
        
        cat > "${WORKDIR}/keepalive.sh" <<EOF
#!/bin/bash
if ! pgrep -x "mtg" > /dev/null; then
    nohup ${WORKDIR}/mtg run -b 0.0.0.0:${MTP_PORT} ${SECRET} --stats-bind=127.0.0.1:${MTP_PORT} >/dev/null 2>&1 &
fi
EOF
        chmod +x "${WORKDIR}/keepalive.sh"
        # 写入定时任务，每2分钟检查一次是否在线，并配置重启自启
        (crontab -l 2>/dev/null | grep -v "keepalive.sh"; echo "*/2 * * * * ${WORKDIR}/keepalive.sh") | crontab -
        (crontab -l 2>/dev/null | grep -v "@reboot"; echo "@reboot ${WORKDIR}/keepalive.sh") | crontab -
        green "当前为非Root用户，已通过 Crontab 定时器配置开机自启与掉线保活！"
    fi

    # 保存连接信息到文件
    LINKS="tg://proxy?server=${SERVER_IP}&port=${MTP_PORT}&secret=${SECRET}"
    echo "$LINKS" > "${WORKDIR}/link.txt"
    
    show_info
}

# 显示配置信息
show_info() {
    if [ ! -f "${WORKDIR}/link.txt" ]; then
        red "未发现安装记录或代理未运行。"
        return
    fi
    purple "\n========== TG 代理分享链接 =========="
    green "$(cat ${WORKDIR}/link.txt)"
    purple "====================================="
    if [ "$EUID" -eq 0 ]; then
        yellow "提示: 代理运行在 Systemd 守护下，遭遇系统重启、崩溃时会自动拉起。"
    else
        yellow "提示: 代理运行在 Cron 守护下，遭遇系统重启后 2 分钟内会自动拉起。"
    fi
}

# 卸载逻辑
uninstall_mtg() {
    purple "正在卸载 MTProto 代理并清理自启任务..."
    pkill -9 mtg >/dev/null 2>&1
    
    # 清理对应的自启服务/定时任务
    if [ "$EUID" -eq 0 ]; then
        systemctl stop mtg >/dev/null 2>&1
        systemctl disable mtg >/dev/null 2>&1
        rm -f /etc/systemd/system/mtg.service
        systemctl daemon-reload
    else
        crontab -l 2>/dev/null | grep -v "keepalive.sh" | crontab -
    fi
    
    rm -rf "$WORKDIR"
    green "卸载完成！所有相关文件及自启配置已清除干净。"
}

# 交互菜单
menu() {
    clear
    purple "========================================="
    purple "     MTProto (mtg) 一键安装/管理脚本      "
    purple "========================================="
    echo -e " 1. \e[1;32m安装 MTProto 代理 (配置开机自启)\033[0m"
    echo -e " 2. \e[1;31m完整卸载代理 (清理文件及自启配置)\033[0m"
    echo -e " 3. \e[1;36m查看当前代理连接链接\033[0m"
    echo -e " 4. 退出脚本"
    purple "========================================="
    read -p "请输入数字选择功能 [1-4]: " num
    case "$num" in
        1) install_mtg ;;
        2) uninstall_mtg ;;
        3) show_info ;;
        4) exit 0 ;;
        *) red "输入错误，请输入正确数字！"; sleep 2; menu ;;
    esac
}

# 进入菜单
menu
