#!/bin/bash
set -o pipefail

#################################
# 环境变量 & 配置
#################################
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root   # ⭐ 确保 cron 下 ~ 指向 root

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

BASE_DIR="/opt/rsync_task"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/zz.sh"
SCRIPT_PATH="$BASE_DIR/rsync_manager.sh"
KEY_DIR="$BASE_DIR/keys"
LOG_DIR="$BASE_DIR/logs"
CONFIG_FILE="$BASE_DIR/rsync_tasks.conf"
TG_CONFIG="$BASE_DIR/.tg.conf"
BIN_LINK_DIR="/usr/local/bin"
DEP_LOCK="$BASE_DIR/.dep_installed"  # ⭐ 引入依赖安装锁

mkdir -p "$BASE_DIR" "$KEY_DIR" "$LOG_DIR"
touch "$CONFIG_FILE"

# 动态精准识别系统环境
if [ -f /etc/alpine-release ]; then
    OS="Alpine Linux $(cat /etc/alpine-release)"
elif [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="$NAME"
else
    OS=$(uname -s)
fi

#################################
# 稳定统计任务数量
#################################
task_count() {
    awk 'NF{c++} END{print c+0}' "$CONFIG_FILE"
}

cron_count() {
    local count
    count=$(crontab -l 2>/dev/null | grep -c "# rsync_" || true)
    echo $((count + 0))
}

#################################
# ⭐ 优化依赖安装 (增加全局锁，彻底杜绝每次启动重复安装)
#################################
install_dep() {
    # 1. 如果已经有安装锁文件，说明之前装过，直接跳过，实现秒开
    if [ -f "$DEP_LOCK" ]; then
        return 0
    fi

    local need_install=0
    
    # 2. 检查究竟有没有缺失的依赖
    if [ -f /etc/alpine-release ]; then
        for p in rsync ssh sshpass curl tar bash; do
            if ! command -v $p &>/dev/null; then need_install=1; break; fi
        done
        if [ $need_install -eq 1 ]; then
            echo -e "${YELLOW}正在为 Alpine 补充必要依赖...${RESET}"
            apk update -q && apk add -q rsync openssh-client sshpass curl tar bash >/dev/null 2>&1
        fi
    else
        for p in rsync ssh sshpass curl tar; do
            if ! command -v $p &>/dev/null; then need_install=1; break; fi
        done
        if [ $need_install -eq 1 ]; then
            echo -e "${YELLOW}首次运行，正在为您安装基础环境依赖，请稍候...${RESET}"
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y rsync ssh sshpass curl tar >/dev/null 2>&1
        fi
    fi

    # 3. 只要走完这一步，就创建锁文件，下次直接免检
    touch "$DEP_LOCK"
}
install_dep

#################################
# Telegram 通知
#################################
send_tg() {
    [[ -f "$TG_CONFIG" ]] || return
    . "$TG_CONFIG"   
    msg="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="[$VPS_NAME] $msg" >/dev/null 2>&1
}

setup_tg() {
    read -p "VPS名称: " VPS_NAME
    read -p "Bot Token: " BOT_TOKEN
    read -p "Chat ID: " CHAT_ID
    cat > "$TG_CONFIG" <<EOF
VPS_NAME="$VPS_NAME"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
EOF
    chmod 600 "$TG_CONFIG"
    echo -e "${GREEN}TG配置已保存${RESET}"
}

#################################
# SSH 密钥自动化生成与全静默分发
#################################
generate_and_setup_ssh() {
    local remote="$1"     
    local port="$2"       
    local password="$3"   

    KEY_FILE="$KEY_DIR/id_rsa_rsync"
    PUB_FILE="$KEY_FILE.pub"

    if [[ ! -f "$KEY_FILE" ]]; then
        echo -e "${YELLOW}未检测到本地专用密钥对，正在自动创建...${RESET}"
        ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -q
        chmod 600 "$KEY_FILE"
        echo -e "${GREEN}✅ 本地安全密钥对已成功生成。${RESET}"
    fi

    local pubkey_content
    pubkey_content=$(cat "$PUB_FILE")

    echo -e "${YELLOW}正在尝试自动化建立远程密钥授信通道...${RESET}"

    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "${remote#*@}" >/dev/null 2>&1

    local ssh_cmd="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $port"
    
    set +e
    sshpass -p "$password" $ssh_cmd "$remote" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" >/dev/null 2>&1
    sshpass -p "$password" $ssh_cmd "$remote" "touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -Fxq '$pubkey_content' ~/.ssh/authorized_keys || echo '$pubkey_content' >> ~/.ssh/authorized_keys" >/dev/null 2>&1

    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p "$port" "$remote" "echo ok" >/dev/null 2>&1
    local ok=$?
    set -e

    if [[ $ok -eq 0 ]]; then
        echo -e "${GREEN}✅ 密钥自动化分发成功！已成功与远程 VPS 建立免密信任。${RESET}"
        return 0
    else
        echo -e "${RED}❌ 密钥自动化分发失败。请检查你输入的密码、端口、或远程 VPS 是否允许 root 登录。${RESET}"
        return 1
    fi
}

#################################
# 任务管理与快照预览
#################################
list_tasks() {
    [[ ! -s "$CONFIG_FILE" ]] && { echo -e "${YELLOW}暂无任何同步任务${RESET}"; return; }
    awk -F'|' -v YELLOW="$YELLOW" -v RESET="$RESET" -v GREEN="$GREEN" \
    '{
        if (NF == 7) {
            name=$1; local_path=$2; user="root"; ip=$3; port=$5; auth=$6;
            if(ip ~ /@/) { split(ip, arr, "@"); user=arr[1]; ip=arr[2]; }
        } else {
            name=$1; local_path=$2; user=$3; ip=$4; port=$5; auth=$6;
        }
        auth_zh = (auth == "password") ? "密码" : "密钥";
        printf " " GREEN "•" RESET " " YELLOW "%-2d)" RESET " %-12s | 本地:%-16s -> 远端:%s@%s [%s|端口:%s]\n", NR, name, local_path, user, ip, auth_zh, port
    }' "$CONFIG_FILE"
}

add_task() {
    read -p "任务名称: " name
    read -p "本地目录: " local
    read -p "远程目录: " remote_path
    read -p "远程用户名 (默认 root): " user
    user=${user:-root}
    read -p "远程服务器 IP: " ip
    read -p "端口 (默认 22): " port
    port=${port:-22}

    echo -e "${GREEN}选择远端认证方式: 1) 密码验证  2) 密钥对验证 (全自动铺设)${RESET}"
    read -p "请选择 [1-2]: " c
    if [[ $c == 1 ]]; then
        read -s -p "请输入远程服务器密码: " secret; echo
        auth="password"
    else
        read -s -p "请输入远程服务器密码 (仅用于首次自动拷贝密钥): " temp_pwd; echo
        if generate_and_setup_ssh "${user}@${ip}" "$port" "$temp_pwd"; then
            secret="$KEY_DIR/id_rsa_rsync"
            auth="key"
        else
            echo -e "${RED}由于密钥无法送达，任务放弃添加。${RESET}"
            return 1
        fi
    fi

    echo "$name|$local|$user|$ip|$port|$auth|$secret|$remote_path" >> "$CONFIG_FILE"
    echo -e "${GREEN}✅ 同步传输链路添加成功！${RESET}"
}

delete_task() {
    read -p "请输入要删除的任务编号: " n
    if sed -n "${n}p" "$CONFIG_FILE" | grep -q '.*'; then
        sed -i "${n}d" "$CONFIG_FILE"
        echo -e "${GREEN}任务已删除。${RESET}"
    else
        echo -e "${RED}编号不存在。${RESET}"
    fi
}

#################################
# 压缩同步
#################################
run_task() {
    local direction="$1"
    local num="$2"

    if [[ -z "$num" ]]; then
        read -p "请输入要执行的任务编号: " num
    fi

    local task
    task=$(sed -n "${num}p" "$CONFIG_FILE" | tr -d '\r\n')

    if [[ -z "$task" ]]; then
        echo "任务编号 $num 不存在" >> "$LOG_DIR/error.log"
        send_tg "同步失败：任务 $num 不存在 ❌"
        return 1
    fi

    local name local_dir user ip port auth secret remote_path
    local field_count
    field_count=$(echo "$task" | awk -F'|' '{print NF}')

    if [ "$field_count" -eq 7 ]; then
        IFS='|' read -r name local_dir ip remote_path port auth secret <<< "$task"
        user="root"
        if [[ "$ip" == *@* ]]; then
            user="${ip%%@*}"
            ip="${ip##*@}"
        fi
    else
        IFS='|' read -r name local_dir user ip port auth secret remote_path <<< "$task"
    fi
    
    local safe_name
    safe_name=$(echo "$name" | tr '/' '_')
    local archive="/tmp/sync_task_${safe_name}.tar.gz"
    local remote="${user}@${ip}"

    echo -e "${YELLOW}正在开始执行同步任务 [$name] ...${RESET}"

    local common_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $port"

    if [[ "$direction" == "push" ]]; then
        tar -czf "$archive" -C "$(dirname "$local_dir")" "$(basename "$local_dir")"
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ [$name] 本地打包失败。${RESET}"
            return 1
        fi

        local sync_ok=1
        if [[ "$auth" == "password" ]]; then
            sshpass -p "$secret" ssh $common_opts "$remote" "mkdir -p $remote_path" && \
            sshpass -p "$secret" rsync -az -e "ssh $common_opts" "$archive" "$remote:$remote_path/"
            sync_ok=$?
        else
            ssh -i "$secret" $common_opts "$remote" "mkdir -p $remote_path" && \
            rsync -az -e "ssh -i $secret $common_opts" "$archive" "$remote:$remote_path/"
            sync_ok=$?
        fi
        
        rm -f "$archive"

        if [ $sync_ok -eq 0 ]; then
            echo -e "${GREEN}✅ [$name] 推送完成${RESET}"
            send_tg "$name 推送完成 ✅"
            return 0
        else
            echo -e "${RED}❌ [$name] 同步推流期间发生严重错误 (代码: $sync_ok)。${RESET}"
            send_tg "$name 推送发生错误 ❌"
            return 1
        fi
    else
        local sync_ok=1
        if [[ "$auth" == "password" ]]; then
            sshpass -p "$secret" rsync -az -e "ssh $common_opts" "$remote:$remote_path/$(basename "$archive")" "/tmp/"
            sync_ok=$?
        else
            rsync -az -e "ssh -i $secret $common_opts" "$remote:$remote_path/$(basename "$archive")" "/tmp/"
            sync_ok=$?
        fi

        if [ $sync_ok -eq 0 ] && [ -f "$archive" ]; then
            rm -rf "$local_dir"
            mkdir -p "$local_dir"
            tar -xzf "$archive" -C "$(dirname "$local_dir")"
            rm -f "$archive"
            echo -e "${GREEN}✅ [$name] 拉取同步恢复完成${RESET}"
            send_tg "$name 拉取完成 ✅"
            return 0
        else
            echo -e "${RED}❌ [$name] 拉取同步流错误或未发现远端压缩文件。${RESET}"
            send_tg "$name 拉取失败 ❌"
            rm -f "$archive"
            return 1
        fi
    fi
}

batch_run() {
    read -p "批量任务编号(多个逗号隔开，或输入 all): " nums
    if [[ "$nums" == "all" ]]; then
        local count
        count=$(task_count)
        nums=$(seq 1 $count | tr '\n' ',' | sed 's/,$//')
    fi
    
    OLDIFS=$IFS
    IFS=','
    for n in $nums; do
        n=$(echo "$n" | tr -d '\r\n ')
        [[ -n "$n" ]] && run_task "$1" "$n"
    done
    IFS=$OLDIFS
}

#################################
# 定时任务管理
#################################
schedule_task() {
    echo -e "${GREEN}定时任务频率模板:${RESET}"
    echo -e "  1) 每天0点"
    echo -e "  2) 每周一0点"
    echo -e "  3) 每月1号0点"
    echo -e "  4) 自定义cron表达式"
    read -p "选择模板: " tmpl
    case $tmpl in
        1) cron="0 0 * * *" ;;
        2) cron="0 0 * * 1" ;;
        3) cron="0 0 1 * *" ;;
        4) read -p "请输入标准cron表达式: " cron ;;
        *) echo -e "${RED}无效选择${RESET}"; return ;;
    esac

    read -p "请输入要绑定的任务编号(多个用逗号隔开，或输入 all): " nums
    if [[ "$nums" == "all" ]]; then
        count=$(task_count)
        nums=$(seq 1 $count)
    fi

    OLDIFS=$IFS
    IFS=','
    for n in $nums; do
        n=$(echo "$n" | tr -d '\r\n ')
        [[ -z "$n" ]] && continue
        job="$cron /bin/bash $SCRIPT_PATH auto push $n >> $LOG_DIR/cron_$n.log 2>&1 # rsync_$n"
        crontab -l 2>/dev/null | grep -v "# rsync_$n" | { cat; echo "$job"; } | crontab -
        echo -e "${GREEN}✅ 任务 $n 已成功挂载定时自动化守护${RESET}"
    done
    IFS=$OLDIFS
}

delete_schedule() {
    read -p "请输入要取消定时的任务编号(多个用逗号隔开，或输入 all): " nums
    if [[ "$nums" == "all" ]]; then
        crontab -l 2>/dev/null | grep -v "# rsync_" | crontab -
        echo -e "${YELLOW}✅ 已清空全部定时同步任务${RESET}"
        return
    fi
    OLDIFS=$IFS
    IFS=','
    for n in $nums; do
        n=$(echo "$n" | tr -d '\r\n ')
        [[ -z "$n" ]] && continue
        crontab -l 2>/dev/null | grep -v "# rsync_$n" | crontab -
        echo -e "${YELLOW}✅ 任务 $n 的定时任务已成功卸载${RESET}"
    done
    IFS=$OLDIFS
}

#################################
# 更新 & 卸载
#################################
update_self() {
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}管理面板已成功自我更新！${RESET}"
}

if [[ "$1" == "auto" ]]; then
    run_task "$2" "$3"
    exit
fi

uninstall_self() {
    crontab -l 2>/dev/null | grep -v "rsync_" | crontab - || true
    rm -rf "$BASE_DIR"
    rm -f "$BIN_LINK_DIR/s" "$BIN_LINK_DIR/S"
    echo -e "${RED}本同步工具已彻底从当前系统卸载。${RESET}"
    exit
}

# 首次安装配置快捷命令
if [ ! -f "$SCRIPT_PATH" ]; then
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    chmod +x "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/s"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/S"
    echo -e "${GREEN}✅ 快捷键已添加：s 或 S 可快速启动面板${RESET}"
fi

#################################
# 主菜单循环
#################################
while true; do
    clear
    FILE_COUNT=$(task_count)
    CRON_ACTIVE=$(cron_count)
    
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}      ◈  VPS Rsync同步管理系统  ◈      ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 当前系统环境 : ${YELLOW}${OS}${RESET}"
    echo -e "${GREEN} 活跃任务总数 : ${YELLOW}${FILE_COUNT} 个${RESET}"
    echo -e "${GREEN} 守护时空计划 : ${YELLOW}${CRON_ACTIVE} 个定时任务正在运行${RESET}"
    echo -e "${GREEN} 配置数据路径 : ${YELLOW}${BASE_DIR}${RESET}"
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN} 📦 当前活动的同步任务通道快照预览：${RESET}"
    
    list_tasks
    
    echo -e "${GREEN}---------------------------------------${RESET}"
    echo -e "${GREEN}  1) 添加同步传输任务${RESET}"
    echo -e "${GREEN}  2) 移除同步传输任务${RESET}"
    echo -e "${GREEN}  3) 执行推送远端(Push)${RESET}"
    echo -e "${GREEN}  4) 执行拉回本地(Pull)${RESET}"
    echo -e "${GREEN}  5) 批量推送远端(Push)${RESET}"
    echo -e "${GREEN}  6) 批量拉回本地(Pull)${RESET}"
    echo -e "${GREEN}  7) 设置定时任务${RESET}"
    echo -e "${GREEN}  8) 删除定时任务${RESET}"
    echo -e "${GREEN}  9) 配置Telegram通知${RESET}"
    echo -e "${GREEN} 10) 更新${RESET}"
    echo -e "${GREEN} 11) 卸载${RESET}"
    echo -e "${GREEN}  0) 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    
    echo -ne "${GREEN}请选择操作编号: ${RESET}"
    read -r choice
    case $choice in
        1) add_task ;;
        2) delete_task ;;
        3) run_task push ;;
        4) run_task pull ;;
        5) batch_run push ;;
        6) batch_run pull ;;
        7) schedule_task ;;
        8) delete_schedule ;;
        9) setup_tg ;;
        10) update_self ;;
        11) uninstall_self ;;
        0) exit 0 ;;
        *) echo -e "${RED}❌ 无效选项${RESET}" ;;
    esac
    echo
    echo -ne "${GREEN}按回车键刷新控制台数据矩阵... ${RESET}"
    read -r
done
