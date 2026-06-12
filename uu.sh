#!/usr/bin/env bash
set -e

#################################
# 基础路径
#################################
ROOT="/root"
SCRIPT_PATH="$ROOT/toolboxupdate.sh"
SCRIPT_URL="tool/update.sh"  # 提取相对路径，方便拼接代理
CONF="/etc/toolbox-update.conf"
LOG_FILE="/var/log/toolbox-update.log"
CRON_TAG="# toolbox-auto-update"

# GitHub 代理列表
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

#################################
# 颜色
#################################
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

#################################
# 统一代理下载函数
# 参数: $1=相对路径/URL, $2=保存的目标路径, $3=项目名称(用于提示)
#################################
download_file() {
    local target_path="$1"
    local dest="$2"
    local name="$3"
    local base_url="https://raw.githubusercontent.com/sistarry/toolbox/main"
    
    # 判断传入的是绝对 URL 还是相对路径，如果是绝对 URL 则提取相对部分
    if [[ "$target_path" =~ ^https://raw.githubusercontent.com/sistarry/toolbox/main/(.*) ]]; then
        target_path="${BASH_REMATCH[1]}"
    fi

    for proxy in "${GITHUB_PROXY[@]}"; do
        # 拼接最终的下载链接
        local final_url="${proxy}${base_url}/${target_path}"
        
        if [ -n "$proxy" ]; then
            echo
        else
            echo
        fi

        # 尝试下载
        if curl -fsSL "$final_url" -o "$dest"; then
            return 0
        fi

        echo -e "${RED}❌ 下载失败，稍后尝试切换下一个节点...${RESET}"
        sleep 1
    done

    return 1
}

#################################
# 自动下载安装管理器（首次运行）
#################################
if [ ! -f "$SCRIPT_PATH" ]; then
    if ! download_file "$SCRIPT_URL" "$SCRIPT_PATH" "管理器自身"; then
        echo -e "${RED}❌ 尝试了所有代理节点，初始化安装依旧失败，请检查网络！${RESET}"
        exit 1
    fi
    chmod +x "$SCRIPT_PATH"
fi

#################################
# 读取配置
#################################
load_conf() {
    [ -f "$CONF" ] && source "$CONF"
    SERVER_NAME="${SERVER_NAME:-$(hostname)}"
}


#################################
# 获取当前自动更新状态用于菜单显示
#################################
get_cron_status() {
    local task
    task=$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH --auto" || true)
    if [ -z "$task" ]; then
        echo -e "${RED}[已关闭]${RESET}"
    else
        # 提取表达式前缀，简单判断周期
        if [[ "$task" =~ ^0\ 0\ \*\ \*\ \* ]]; then
            echo -e "${YELLOW}[已开启 - 每天]${RESET}"
        elif [[ "$task" =~ ^0\ 0\ \*\ \*\ 1 ]]; then
            echo -e "${YELLOW}[已开启 - 每周]${RESET}"
        elif [[ "$task" =~ ^0\ 0\ 1\ \*\ \* ]]; then
            echo -e "${YELLOW}[已开启 - 每月]${RESET}"
        elif [[ "$task" =~ ^0\ \*/6\ \*\ \*\ \* ]]; then
            echo -e "${YELLOW}[已开启 - 每6小时]${RESET}"
        else
            # 自定义表达式显示前部分
            local expr
            expr=$(echo "$task" | awk '{print $1,$2,$3,$4,$5}')
            echo -e "${YELLOW}[已开启 - 自定义: $expr]${RESET}"
        fi
    fi
}

#################################
# Telegram 可选
#################################
tg_send() {
    load_conf
    [ -z "${TG_BOT_TOKEN:-}" ] && return
    [ -z "${TG_CHAT_ID:-}" ] && return

    curl -s -X POST \
      "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d chat_id="$TG_CHAT_ID" \
      -d text="$1" \
      -d parse_mode="HTML" >/dev/null 2>&1 || true
}

#################################
# 更新逻辑
#################################
update_one() {
    NAME="$1"
    FILE="$2"
    URL="$3" # 这里传入相对路径或绝对URL均能被 download_file 识别

    if [ ! -f "$ROOT/$FILE" ]; then
        echo -e "${YELLOW}跳过 $NAME（未安装）${RESET}"
        return
    fi

    echo -e "${GREEN}开始更新 $NAME ...${RESET}"

    TMP=$(mktemp)

    # 调用带代理轮询的下载函数
    if download_file "$URL" "$TMP" "$NAME"; then
        chmod +x "$TMP"
        if printf "0\n" | bash "$TMP" >/dev/null 2>&1; then
            mv "$TMP" "$ROOT/$FILE"
            UPDATED_LIST+=("$NAME")
            echo -e "${GREEN}✅ $NAME 更新成功！${RESET}"
        else
            echo -e "${RED}❌ $NAME 更新脚本执行失败${RESET}"
            rm -f "$TMP"
        fi
    else
        echo -e "${RED}❌ $NAME 所有代理节点均下载失败，已跳过${RESET}"
        rm -f "$TMP"
    fi
}

run_update() {
    load_conf
    UPDATED_LIST=()

    # 更新各脚本（支持传相对路径）
    update_one "vps-toolbox" "vps-toolbox.sh" "tool/vps-toolbox.sh"
    update_one "proxy" "proxy.sh" "PROXY/proxy.sh"
    update_one "oracle" "oracle.sh" "Oracle/oracle.sh"
    update_one "store" "store.sh" "Docker/Store.sh"
    update_one "panel" "panel.sh" "Panel/panel.sh"
    update_one "nat" "nat.sh" "toy/NAT.sh"

    if [ ${#UPDATED_LIST[@]} -gt 0 ]; then
        MSG="🚀 脚本已更新
服务器: ${SERVER_NAME}
脚本: ${UPDATED_LIST[*]}"
        tg_send "$MSG"
        echo -e "${GREEN}更新完成${RESET}"
    else
        echo -e "${YELLOW}没有脚本需要更新${RESET}"
    fi
}

#################################
# cron 管理（支持自定义）
#################################
enable_cron() {
    echo -e "${GREEN}选择更新频率：${RESET}"
    echo -e "${GREEN}1) 每天${RESET}"
    echo -e "${GREEN}2) 每周${RESET}"
    echo -e "${GREEN}3) 每月${RESET}"
    echo -e "${GREEN}4) 每6小时${RESET}"
    echo -e "${GREEN}5) 自定义 cron 表达式${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " c

    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --auto" > /tmp/cron.tmp || true

    case $c in
        1) echo "0 0 * * * $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
        2) echo "0 0 * * 1 $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
        3) echo "0 0 1 * * $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
        4) echo "0 */6 * * * $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
        5)
            echo "示例: 每30分钟 */30 * * * *"
            read -p "请输入完整 cron 表达式: " CRON_EXP
            echo "$CRON_EXP $SCRIPT_PATH --auto" >>/tmp/cron.tmp
            ;;
        *)
            echo -e "${YELLOW}无效选项，取消操作${RESET}"
            rm -f /tmp/cron.tmp
            return
            ;;
    esac

    crontab /tmp/cron.tmp
    rm -f /tmp/cron.tmp
    echo -e "${GREEN}自动更新已开启${RESET}"
}

disable_cron() {
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --auto" | crontab -
    echo -e "${RED}自动更新已关闭${RESET}"
}

#################################
# Telegram 设置
#################################
tg_setup() {
    read -p "Bot Token: " token
    read -p "Chat ID: " chat
    read -p "VPS 名称(回车默认 hostname): " name
    name="${name:-$(hostname)}"

    cat >"$CONF" <<EOF
TG_BOT_TOKEN="$token"
TG_CHAT_ID="$chat"
SERVER_NAME="$name"
EOF

    echo -e "${GREEN}Telegram 与 VPS 名称已保存${RESET}"
}

#################################
# 卸载管理器函数
#################################
uninstall_manager() {
    echo -e "${RED}正在卸载管理器...${RESET}"
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --auto" | crontab -
    echo -e "${GREEN}✅ 已删除所有定时任务${RESET}"
    [ -f "$SCRIPT_PATH" ] && rm -f "$SCRIPT_PATH" && echo -e "${GREEN}✅ 已删除管理器脚本${RESET}"
    [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE" && echo -e "${GREEN}✅ 已删除日志${RESET}"
    [ -f "$CONF" ] && rm -f "$CONF" && echo -e "${GREEN}✅ 已删除配置文件${RESET}"
    echo -e "${GREEN}卸载完成${RESET}"
    exit 0
}

#################################
# 自动模式（cron调用）
#################################
if [ "${1:-}" = "--auto" ]; then
    run_update
    exit
fi

#################################
# 删除日志
#################################
delete_log() {
    [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE"
    echo -e "${RED}日志已删除${RESET}"
}

#################################
# 自更新管理器
#################################
self_update() {
    load_conf
    echo -e "${GREEN}正在更新管理器自身...${RESET}"

    TMP=$(mktemp)

    if download_file "$SCRIPT_URL" "$TMP" "管理器自身"; then
        chmod +x "$TMP"
        mv "$TMP" "$SCRIPT_PATH"

        MSG="🚀 管理器已更新
服务器: ${SERVER_NAME}
文件: toolboxupdate.sh"

        tg_send "$MSG"

        echo -e "${GREEN}更新完成，重新启动中...${RESET}"
        exec "$SCRIPT_PATH"
    else
        echo -e "${RED}❌ 管理器自更新失败，所有代理均不可用${RESET}"
        rm -f "$TMP"
    fi
}

#################################
# 查看定时任务
#################################
list_cron() {
    echo
    TASKS=$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH --auto" || true)

    if [ -z "$TASKS" ]; then
        echo -e "${YELLOW}暂无自动更新任务${RESET}"
    else
        echo -e "${GREEN}当前自动更新任务：${RESET}"
        echo "$TASKS"
    fi

    echo
}

#################################
# 菜单循环
#################################
while true; do
    clear
    STATUS=$(get_cron_status)
    echo -e "${GREEN}============================${RESET}"
    echo -e "${GREEN} ◈ Toolbox 自动更新管理器 ◈ ${RESET}"
    echo -e "${GREEN}============================${RESET}"
    echo -e "${GREEN}当前状态: ${STATUS}${RESET}"
    echo -e "${GREEN}============================${RESET}"
    echo -e "${GREEN}1) 立即更新${RESET}"
    echo -e "${GREEN}2) 开启自动更新${RESET}"
    echo -e "${GREEN}3) 关闭自动更新${RESET}"
    echo -e "${GREEN}4) 查看定时任务${RESET}"
    echo -e "${GREEN}5) 设置 Telegram & 服务器名称(可选)${RESET}"
    echo -e "${GREEN}6) 删除日志${RESET}"
    echo -e "${GREEN}7) 更新管理器${RESET}"
    echo -e "${GREEN}8) 卸载管理器${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -e "${GREEN}============================${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) run_update; read -p "$(echo -e ${GREEN}回车继续...${RESET})" ;;
        2) enable_cron; read -p "$(echo -e ${GREEN}回车继续...${RESET})" ;;
        3) disable_cron; read -p "$(echo -e ${GREEN}回车继续...${RESET})" ;;
        4) list_cron; read -p "$(echo -e ${GREEN}回车继续...${RESET})" ;;
        5) tg_setup; read -p "$(echo -e ${GREEN}回车继续...${RESET})" ;;
        6) delete_log; read -p "$(echo -e ${GREEN}回车继续...${RESET})" ;;
        7) self_update ;;
        8) uninstall_manager ;;
        0) exit ;;
    esac
done
