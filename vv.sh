#!/bin/bash
# =========================================================
# 服务器定时自动化清理工具（全面适配 Alpine / Ubuntu / Debian）
# =========================================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

SCRIPT_PATH="/usr/local/bin/clean-server"
# 修复：只保留纯粹的原始文件下载直链
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/vv.sh" 
CONFIG_FILE="/etc/clean-server.conf"

# 加载 TG 配置
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# =========================================================
# 动态获取系统与定时器状态
# =========================================================
get_system_status() {
    # 1. 检查 TG 状态
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        TG_STATUS="${YELLOW}已配置${RESET}"
    else
        TG_STATUS="未配置"
    fi

    # 2. 检查定时任务状态 (支持 Alpine BusyBox crontab)
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH --auto"; then
        CRON_STATUS="${YELLOW}已开启${RESET}"
    else
        CRON_STATUS="已关闭"
    fi

    # 3. 检查 Alpine 环境下 crond 服务是否运行
    if command -v rc-service >/dev/null 2>&1; then
        if rc-service crond status 2>/dev/null | grep -q "started"; then
            CRON_SERVICE="${YELLOW}正常运行${RESET}"
        else
            CRON_SERVICE="${RED}已停止 (需要开启服务定时任务才有效)${RESET}"
        fi
    else
        CRON_SERVICE="${YELLOW}正常 (systemd控制)${RESET}"
    fi
}

# =========================================================
# Telegram 通知模块
# =========================================================
send_tg() {
    [ -z "$TG_BOT_TOKEN" ] && return
    [ -z "$TG_CHAT_ID" ] && return
    SERVER_NAME=${SERVER_NAME:-$(hostname)}
    MESSAGE="$1"
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="[$SERVER_NAME] $MESSAGE" >/dev/null
}

set_telegram() {
    echo -e "${GREEN}=== Telegram 通知配置 ===${RESET}"
    read -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN
    read -p "请输入 Telegram Chat ID: " TG_CHAT_ID
    read -p "请输入服务器名称 (留空使用本机的 hostname): " SERVER_NAME
    [ -z "$SERVER_NAME" ] && SERVER_NAME=$(hostname)
    
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SERVER_NAME="$SERVER_NAME"
EOF
    echo -e "${GREEN}配置已成功保存！${RESET}"
}

# =========================================================
# 核心清理模块 (针对 Alpine 健壮性优化)
# =========================================================
clean_logs() {
    echo -e "${YELLOW}正在清理系统历史日志 /var/log...${RESET}"
    find /var/log -type f -name "*.log" -mtime +7 -delete 2>/dev/null
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
}

clean_journal() {
    if command -v journalctl >/dev/null 2>&1; then
        echo -e "${YELLOW}正在清理 systemd 日志...${RESET}"
        journalctl --vacuum-time=7d >/dev/null 2>&1
    else
        echo -e "${YELLOW}系统没有检测到 journalctl，跳过该项${RESET}"
    fi
}

clean_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 Docker 环境，跳过清理${RESET}"
        return
    fi

    echo -e "${YELLOW}正在安全截断 Docker 容器日志...${RESET}"
    find /var/lib/docker/containers/ -name "*-json.log" -size +50M -exec truncate -s 0 {} \; 2>/dev/null

    echo -e "${YELLOW}正在清理未使用的无用镜像与资源...${RESET}"
    docker system prune -af --volumes >/dev/null 2>&1
    echo -e "${GREEN}Docker 清理完成！${RESET}"
}

clean_tmp() {
    echo -e "${YELLOW}正在清理 /tmp 历史临时文件...${RESET}"
    find /tmp -type f -mtime +3 -delete 2>/dev/null
}

clean_cache() {
    echo -e "${YELLOW}正在清理系统包管理器缓存...${RESET}"
    if command -v apt >/dev/null 2>&1; then
        apt clean
    elif command -v apk >/dev/null 2>&1; then
        apk cache clean >/dev/null 2>&1
        rm -rf /var/cache/apk/*
    fi
}

run_all() {
    echo -e "${GREEN}>>> 开始执行服务器全面清理任务...${RESET}"
    clean_logs
    clean_journal
    clean_docker
    clean_tmp
    clean_cache
    echo -e "${GREEN}>>> 服务器一键清理完成！${RESET}"
    send_tg "✅服务器自动化清理任务已顺利完成"
}

# =========================================================
# 定时任务管理模块 (适配 Alpine BusyBox)
# =========================================================
enable_cron() {
    echo -e "${GREEN}=== 设置定时自动清理频率 ===${RESET}"
    echo -e "${GREEN} 1) 每天凌晨 1:00${RESET}"
    echo -e "${GREEN} 2) 每周一凌晨 1:00${RESET}"
    echo -e "${GREEN} 3) 每月1号凌晨 1:00${RESET}"
    echo -e "${GREEN} 4) 每 6 小时清理一次${RESET}"
    echo -e "${GREEN} 5) 自定义 Cron 表达式${RESET}"
    read -p " 请选择频率: " c

    # 先导出当前的 crontab (过滤掉已有清理任务)
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --auto" > /tmp/cron.tmp || true

    case $c in
        1) echo "0 1 * * * $SCRIPT_PATH --auto" >> /tmp/cron.tmp ;;
        2) echo "0 1 * * 1 $SCRIPT_PATH --auto" >> /tmp/cron.tmp ;;
        3) echo "0 1 1 * * $SCRIPT_PATH --auto" >> /tmp/cron.tmp ;;
        4) echo "0 */6 * * * $SCRIPT_PATH --auto" >> /tmp/cron.tmp ;;
        5)
            echo -e "${YELLOW}提示: 分 时 日 月 周 (例如每30分钟: */30 * * * *)${RESET}"
            read -p "请输入完整 cron 表达式: " CRON_EXP
            if [ -n "$CRON_EXP" ]; then
                echo "$CRON_EXP $SCRIPT_PATH --auto" >> /tmp/cron.tmp
            else
                echo -e "${RED}输入为空，取消操作${RESET}"
                rm -f /tmp/cron.tmp
                return
            fi
            ;;
        *)
            echo -e "${RED}无效选项，操作取消${RESET}"
            rm -f /tmp/cron.tmp
            return
            ;;
    esac

    # 导入回 crontab 并兼容 BusyBox
    crontab /tmp/cron.tmp
    rm -f /tmp/cron.tmp
    
    # 在 Alpine 下尝试自动启动 crond 服务
    if command -v rc-service >/dev/null 2>&1; then
        rc-service crond start >/dev/null 2>&1 || true
        rc-update add crond default >/dev/null 2>&1 || true
    fi
    echo -e "${GREEN}自动清理定时任务已成功激活！${RESET}"
}

disable_cron() {
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --auto" > /tmp/cron.tmp || true
    crontab /tmp/cron.tmp
    rm -f /tmp/cron.tmp
    echo -e "${YELLOW}自动清理定时任务已关闭${RESET}"
}

install_script() {
    # 动态获取当前正在执行的脚本名/路径
    local current_run="$0"

    # 创建本地目标目录
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    
    # 检查当前执行的是否是有效的实体脚本文件（本地运行），还是通过管道喂给 bash 的（远程运行）
    if [ -f "$current_run" ] && [ "$(basename "$current_run")" = "uu.sh" ]; then
        echo -e "${YELLOW}检测到本地脚本，正在复制到系统目录...${RESET}"
        cp "$current_run" "$SCRIPT_PATH"
    else
        # 远程运行或找不到本地源文件时，走网络下载
        echo -e "${YELLOW}正在下载组件到 $SCRIPT_PATH ...${RESET}"
        if command -v curl >/dev/null 2>&1; then
            curl -sL "$SCRIPT_URL" -o "$SCRIPT_PATH"
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$SCRIPT_PATH" "$SCRIPT_URL"
        else
            echo -e "${RED}错误: 系统缺少 curl 或 wget 命令，无法下载组件${RESET}"
            return 1
        fi
    fi

    # 【核心修复】安全校验：确保文件确实存在且大小大于 0 字节
    if [ -s "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH"
        sleep 1
    else
        echo -e "${RED}错误: 脚本未能成功写入到 $SCRIPT_PATH，请检查网络或 URL 权限！${RESET}"
        # 如果是第一次下载失败，由于没有生成可用脚本，建议直接退出，防止后面的菜单报错
        exit 1
    fi
}

update_script() {
    echo -e "${YELLOW}正在从远程获取最新版本...${RESET}"
    curl -sL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}脚本升级更新完成！${RESET}"
}

uninstall_script() {
    echo -e "${RED}正在清理并准备卸载...${RESET}"
    disable_cron
    rm -f "$SCRIPT_PATH"
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}卸载已全部完成${RESET}"
    exit 0
}

# =========================================================
# 自动化静默执行入口 (由 Cron 触发)
# =========================================================
if [ "$1" = "--auto" ]; then
    run_all
    exit 0
fi

# 【修复核心】只有当本地找不到有效的实体脚本时，才触发安装/下载逻辑
if [ ! -s "$SCRIPT_PATH" ]; then
    install_script
fi

# =========================================================
# 主视觉面板菜单逻辑
# =========================================================
auto_clean_menu() {
    while true; do
        # 刷新当前状态
        get_system_status

    
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN}     ◈   服务器自动化清理面板   ◈      ${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN} 定时清理状态 : ${CRON_STATUS}"
        echo -e "${GREEN} Cron服务监控 : ${CRON_SERVICE}"
        echo -e "${GREEN} TG 通知状态  : ${TG_STATUS}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -e "${GREEN}  1. 仅清理系统日志 (/var/log)${RESET}"
        echo -e "${GREEN}  2. 仅清理 systemd 运行时日志${RESET}"
        echo -e "${GREEN}  3. 仅清理 Docker (资源与容器日志)${RESET}"
        echo -e "${GREEN}  4. 仅清理 /tmp 历史临时文件${RESET}"
        echo -e "${GREEN}  5. 仅清理系统包管理器缓存${RESET}"
        echo -e "${GREEN} ------------------------------------- ${RESET}"
        echo -e "${GREEN}  6. 一键手动全面清理${RESET}"
        echo -e "${GREEN}  7. 开启/修改 定时自动清理任务${RESET}"
        echo -e "${GREEN}  8. 关闭定时自动清理任务${RESET}"
        echo -e "${GREEN}  9. 设置/调整 Telegram 消息通知${RESET}"
        echo -e "${GREEN} 10. 更新脚本${RESET}"
        echo -e "${GREEN} 11. 卸载脚本${RESET}"
        echo -e "${GREEN}  0. 退出面板${RESET}"
        echo -e "${GREEN}=======================================${RESET}"
        echo -ne "${GREEN} 请选择操作: ${RESET}"
        
        read -r choice

        case $choice in
            1) clean_logs ;;
            2) clean_journal ;;
            3) clean_docker ;;
            4) clean_tmp ;;
            5) clean_cache ;;
            6) run_all ;;
            7) enable_cron ;;
            8) disable_cron ;;
            9) set_telegram ;;
            10) update_script ;;
            11) uninstall_script ;;
            0) break ;;
            *) echo -e "${RED}无效选择，请重新输入...${RESET}"; sleep 1; continue ;;
        esac

        echo -ne "\n${GREEN}按回车返回面板...${RESET}"
        read -r
    done
}

# 运行菜单
auto_clean_menu
