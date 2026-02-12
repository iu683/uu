#!/bin/bash
set -e

#################################
# 基础配置
#################################
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/aa.sh"
BASE_DIR="/opt/rsync_task"
SCRIPT_PATH="$BASE_DIR/rsync_manager.sh"

CONFIG_FILE="$BASE_DIR/rsync_tasks.conf"
KEY_DIR="$BASE_DIR/keys"
LOG_DIR="$BASE_DIR/logs"
TG_CONFIG="$BASE_DIR/.tg.conf"

mkdir -p "$KEY_DIR" "$LOG_DIR"
touch "$CONFIG_FILE"

BIN_LINK_DIR="/usr/local/bin"

#################################
# 首次安装脚本快捷方式
#################################
if [ ! -f "$SCRIPT_PATH" ]; then
    echo -e "${GREEN}首次运行，下载脚本...${RESET}"
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    chmod +x "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/s"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/S"
    echo -e "${GREEN}✅ 安装完成，快捷键已添加: s 或 S 可快速启动${RESET}"
fi

#################################
# 安装依赖
#################################
install_dep() {
    for p in rsync sshpass curl; do
        if ! command -v $p &>/dev/null; then
            echo -e "${YELLOW}安装依赖: $p${RESET}"
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y $p >/dev/null 2>&1
        fi
    done
}
install_dep

#################################
# Telegram通知
#################################
send_tg() {
    [[ ! -f "$TG_CONFIG" ]] && return
    source "$TG_CONFIG"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$1" >/dev/null 2>&1
}

setup_tg() {
    read -p "VPS名称: " name
    read -p "Bot Token: " token
    read -p "Chat ID: " chatid
    cat > "$TG_CONFIG" <<EOF
BOT_TOKEN="$token"
CHAT_ID="$chatid"
VPS_NAME="$name"
EOF
    echo -e "${GREEN}✅ TG配置已保存${RESET}"
}

#################################
# SSH 密钥管理
#################################
generate_and_setup_ssh() {
    local remote="$1"
    local port="$2"

    KEY_FILE="$KEY_DIR/id_rsa_rsync"
    PUB_FILE="$KEY_DIR/id_rsa_rsync.pub"

    if [[ ! -f "$KEY_FILE" ]]; then
        echo -e "${YELLOW}未检测到本地 SSH 密钥，正在生成...${RESET}"
        mkdir -p "$KEY_DIR"
        ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -q
        echo -e "${GREEN}✅ 本地 SSH 密钥生成完成: $KEY_FILE${RESET}"
    else
        echo -e "${GREEN}✅ 已检测到本地 SSH 密钥: $KEY_FILE${RESET}"
    fi

    PUBKEY_CONTENT=$(cat "$PUB_FILE")
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "${remote#*@}" >/dev/null 2>&1
    echo -e "${YELLOW}⚠️ 第一次连接需要输入远程密码进行操作${RESET}"

    ssh -p "$port" "$remote" "bash -s" <<EOF
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak 2>/dev/null
awk '!seen[\$0]++' ~/.ssh/authorized_keys.bak > ~/.ssh/authorized_keys
grep -Fxq "$PUBKEY_CONTENT" ~/.ssh/authorized_keys || echo "$PUBKEY_CONTENT" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
chown \$(whoami):\$(id -gn) ~/.ssh ~/.ssh/authorized_keys

# 安装依赖
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=\$ID
else
    OS=\$(uname -s)
fi

case \$OS in
    ubuntu|debian)
        apt update && apt install -y rsync openssh-client >/dev/null 2>&1
        ;;
    centos|rhel|rocky)
        yum install -y rsync openssh-clients >/dev/null 2>&1
        ;;
    alpine)
        apk add --no-cache rsync openssh-client >/dev/null 2>&1
        ;;
esac
EOF

    ssh -i "$KEY_FILE" -p "$port" "$remote" "echo 2>&1" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✅ 公钥写入成功，可免密码登录 $remote${RESET}"
    else
        echo -e "${RED}❌ 公钥写入失败，请手动检查 SSH 配置${RESET}"
    fi
}

#################################
# 任务管理
#################################
list_tasks() {
    [[ ! -s "$CONFIG_FILE" ]] && { echo "暂无任务"; return; }
    awk -F'|' '{printf "%d) %s  %s -> %s [%s]\n",NR,$1,$2,$5,$6}' "$CONFIG_FILE"
}

add_task() {
    read -p "任务名称: " name
    read -p "本地目录: " local
    read -p "远程服务器名称: " remote_name
    read -p "远程目录: " remote_path
    read -p "远程用户@IP: " remote
    read -p "端口(默认22): " port
    port=${port:-22}

    echo "认证方式: 1密码 2密钥"
    read -p "选择: " c

    if [[ $c == 1 ]]; then
        read -s -p "密码: " secret; echo
        auth="password"
    else
        generate_and_setup_ssh "$remote" "$port"
        secret="$KEY_DIR/id_rsa_rsync"
        auth="key"
    fi

    echo "$name|$local|$remote_name|$remote|$remote_path|$port|$auth|$secret" >> "$CONFIG_FILE"
    echo -e "${GREEN}✅ 任务添加完成: $name${RESET}"
}

delete_task() {
    read -p "编号: " n
    sed -i "${n}d" "$CONFIG_FILE"
    echo -e "${YELLOW}✅ 已删除任务编号 $n${RESET}"
}

#################################
# 压缩同步 & Telegram通知
#################################
run_task() {
    direction="$1"
    num="$2"
    [[ -z "$num" ]] && read -p "编号: " num
    task=$(sed -n "${num}p" "$CONFIG_FILE")
    [[ -z "$task" ]] && { echo -e "${RED}❌ 任务不存在${RESET}"; return; }

    IFS='|' read -r name local remote_name remote remote_path port auth secret <<< "$task"

    tmpfile="/tmp/${name}_sync_temp.tar.gz"
    ssh_opt="-p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    if [[ "$direction" == "push" ]]; then
        tar -czf "$tmpfile" -C "$(dirname "$local")" "$(basename "$local")"
        if [[ "$auth" == "password" ]]; then
            sshpass -p "$secret" rsync -avz -e "ssh $ssh_opt" "$tmpfile" "$remote:$remote_path/"
        else
            rsync -avz -e "ssh -i $secret $ssh_opt" "$tmpfile" "$remote:$remote_path/"
        fi
        status=$?
        rm -f "$tmpfile"
    else
        remote_file="$remote:$remote_path/$(basename "$tmpfile")"
        [[ -d "$local" ]] && rm -rf "$local"
        if [[ "$auth" == "password" ]]; then
            sshpass -p "$secret" rsync -avz -e "ssh $ssh_opt" "$remote_file" "$tmpfile"
        else
            rsync -avz -e "ssh -i $secret $ssh_opt" "$remote_file" "$tmpfile"
        fi
        status=$?
        mkdir -p "$local"
        tar -xzf "$tmpfile" -C "$(dirname "$local")"
        rm -f "$tmpfile"
    fi

    if [[ $status -eq 0 ]]; then
        send_tg "✅ [$remote_name] 任务 \"$name\" 同步成功 ($direction)"
        echo -e "${GREEN}✅ [$remote_name] 任务 \"$name\" 同步成功 ($direction)${RESET}"
    else
        send_tg "❌ [$remote_name] 任务 \"$name\" 同步失败 ($direction)"
        echo -e "${RED}❌ [$remote_name] 任务 \"$name\" 同步失败 ($direction)${RESET}"
    fi
}

#################################
# 菜单
#################################
while true; do
    clear
    echo -e "${GREEN}===== Rsync 同步管理器 =====${RESET}"
    list_tasks
    echo
    echo -e "${GREEN} 1) 添加同步任务${RESET}"
    echo -e "${GREEN} 2) 修改同步任务${RESET}"
    echo -e "${GREEN} 3) 删除同步任务${RESET}"
    echo -e "${GREEN} 4) 推送同步${RESET}"
    echo -e "${GREEN} 5) 拉取同步${RESET}"
    echo -e "${GREEN} 6) 批量推送同步${RESET}"
    echo -e "${GREEN} 7) 批量拉取同步${RESET}"
    echo -e "${GREEN} 8) 添加定时任务${RESET}"
    echo -e "${GREEN} 9) 删除定时任务${RESET}"
    echo -e "${GREEN}10) Telegram设置${RESET}"
    echo -e "${GREEN}11) 更新脚本${RESET}"
    echo -e "${GREEN}12) 卸载脚本${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    read -p "$(echo -e ${GREEN} 请选择操作: ${RESET}) " c

    case $c in
        1) add_task ;;
        3) delete_task ;;
        4) run_task push ;;
        5) run_task pull ;;
        6) read -p "任务编号(多个用逗号隔开): " nums; IFS=','; for n in $nums; do run_task push "$n"; done ;;
        7) read -p "任务编号(多个用逗号隔开): " nums; IFS=','; for n in $nums; do run_task pull "$n"; done ;;
        10) setup_tg ;;
        12) rm -rf "$BASE_DIR"; echo -e "${RED}已卸载${RESET}"; exit ;;
        0) exit ;;
    esac

    read -p "回车继续..."
done
