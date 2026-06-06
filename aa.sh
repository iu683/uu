#!/bin/bash

APP_DIR="/opt/jcqd"
CONFIG="$APP_DIR/jcqd.json"
RUN_SCRIPT="$APP_DIR/jcqd_run.sh"

GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

mkdir -p $APP_DIR

init_config(){
    if [ ! -f "$CONFIG" ]; then
        echo '{"accounts":[],"tg":{}}' > $CONFIG
    fi
}

pause(){
    read -rp "按回车返回菜单..."
}

# 兼容 Alpine (apk) 和 Debian/Ubuntu (apt)
check_dependencies(){
    if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        echo -e "${GREEN}正在安装依赖 (jq/curl)...${RESET}"
        if command -v apk >/dev/null 2>&1; then
            apk update >/dev/null 2>&1
            apk add jq curl bash >/dev/null 2>&1
        elif command -v apt >/dev/null 2>&1; then
            apt update -y >/dev/null 2>&1
            apt install jq curl -y >/dev/null 2>&1
        fi
    fi
}

install_run_script(){

cat > $RUN_SCRIPT << 'EOF'
#!/bin/bash

CONFIG="/opt/jcqd/jcqd.json"

BotToken=$(jq -r '.tg.BotToken // empty' $CONFIG)
ChatID=$(jq -r '.tg.ChatID // empty' $CONFIG)

TIME=$(date "+%Y-%m-%d %H:%M:%S")

result="🚀 机场签到报告
时间: $TIME
"

count=$(jq '.accounts | length' $CONFIG)

for ((i=0;i<count;i++))
do
    domain=$(jq -r ".accounts[$i].domain" $CONFIG)
    user=$(jq -r ".accounts[$i].user" $CONFIG)
    pass=$(jq -r ".accounts[$i].pass" $CONFIG)

    # 确保域名包含 http(s)://
    if [[ ! "$domain" =~ ^https?:// ]]; then
        url="https://$domain"
    else
        url="$domain"
    fi

    cookie=$(mktemp)

    login=$(curl -s -c "$cookie" \
      -H "Content-Type: application/json" \
      -X POST \
      -d "{\"email\":\"$user\",\"passwd\":\"$pass\",\"remember_me\":\"on\"}" \
      "$url/auth/login")

    # 兼容没有 grep -o 的 busybox 环境，改用 jq 解析
    ret=$(echo "$login" | jq -r '.ret // empty')

    if [ "$ret" != "1" ]; then
        # 尝试获取登录失败的原因
        msg=$(echo "$login" | jq -r '.msg // empty')
        if [ -z "$msg" ]; then msg="❌ 登录失败"; fi
    else
        checkin=$(curl -s -b "$cookie" -X POST "$url/user/checkin")
        
        # 使用 jq 完美解析并提取返回信息，自动处理 Unicode 转义（\uXXXX），规避 sed 兼容性问题
        msg=$(echo "$checkin" | jq -r '.msg // empty')
        if [ -z "$msg" ]; then msg="⚠ 登录成功但签到返回空"; fi
    fi

    result="$result
🌐 $domain
👤 $user
📝 $msg
"
    rm -f "$cookie"
done

echo "$result"

if [ -n "$BotToken" ] && [ -n "$ChatID" ]; then
    curl -s -X POST "https://api.telegram.org/bot$BotToken/sendMessage" \
    -d chat_id="$ChatID" \
    --data-urlencode text="$result" \
    > /dev/null
fi
EOF

chmod +x $RUN_SCRIPT

}

add_account(){
    read -rp "机场域名(例如 69yun69.com): " domain
    read -rp "邮箱: " user
    read -rp "密码: " pass

    # 移除用户输入域名时可能误带的末尾斜杠
    domain=$(echo "$domain" | sed 's/\/$//')

    tmp=$(mktemp)
    jq ".accounts += [{\"domain\":\"$domain\",\"user\":\"$user\",\"pass\":\"$pass\"}]" $CONFIG > $tmp
    mv $tmp $CONFIG
    echo -e "${GREEN}添加成功${RESET}"
}

list_accounts(){
    jq -r '.accounts | to_entries[] | "\(.key+1)) 🌐 \(.value.domain) | 👤 \(.value.user)"' $CONFIG
}

delete_account(){
    list_accounts
    read -rp "删除第几个: " id
    if [ -z "$id" ]; then return; fi
    tmp=$(mktemp)
    jq "del(.accounts[$((id-1))])" $CONFIG > $tmp
    mv $tmp $CONFIG
    echo -e "${GREEN}删除成功${RESET}"
}

set_tg(){
    read -rp "BotToken: " token
    read -rp "ChatID: " chat
    tmp=$(mktemp)
    jq ".tg.BotToken=\"$token\" | .tg.ChatID=\"$chat\"" $CONFIG > $tmp
    mv $tmp $CONFIG
    echo -e "${GREEN}TG设置完成${RESET}"
}

set_cron(){
    echo -e "${GREEN}默认时间：每天0点${RESET}"
    read -rp "自定义cron(回车默认): " cron

    if [ -z "$cron" ]; then
        cron="0 0 * * *"
    fi

    # 兼容 Alpine 的 crontab 写入逻辑
    current_cron=$(crontab -l 2>/dev/null | grep -v "jcqd_run.sh")
    echo -e "$current_cron\n$cron bash $RUN_SCRIPT" | sed '/^$/d' | crontab -

    echo -e "${GREEN}定时任务已设置${RESET}"
}

remove_cron(){
    current_cron=$(crontab -l 2>/dev/null | grep -v "jcqd_run.sh")
    if [ -z "$current_cron" ]; then
        crontab -r >/dev/null 2>&1
    else
        echo "$current_cron" | crontab -
    fi
    echo -e "${GREEN}定时任务已删除${RESET}"
}

view_cron(){
    echo -e "${GREEN}当前签到定时任务:${RESET}"
    cron=$(crontab -l 2>/dev/null | grep jcqd_run.sh)
    if [ -z "$cron" ]; then
        echo "未设置定时任务"
    else
        echo "$cron"
    fi
}

uninstall(){
    remove_cron
    rm -rf /opt/jcqd
    echo -e "${GREEN}脚本已卸载${RESET}"
    exit
}

menu(){
    clear
    echo -e "${GREEN}==== 机场签到管理菜单 ====${RESET}"
    echo -e "${GREEN}1) 添加机场${RESET}"
    echo -e "${GREEN}2) 删除机场${RESET}"
    echo -e "${GREEN}3) 查看机场${RESET}"
    echo -e "${GREEN}4) 设置TG推送${RESET}"
    echo -e "${GREEN}5) 立即签到${RESET}"
    echo -e "${GREEN}6) 设置定时任务${RESET}"
    echo -e "${GREEN}7) 删除定时任务${RESET}"
    echo -e "${GREEN}8) 查看定时任务${RESET}"
    echo -e "${GREEN}9) 卸载${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    echo -ne "${GREEN}请选择:${RESET} "
    read num

    case "$num" in
        1) add_account ; pause ;;
        2) delete_account ; pause ;;
        3) list_accounts ; pause ;;
        4) set_tg ; pause ;;
        5) bash $RUN_SCRIPT ; pause ;;
        6) set_cron ; pause ;;
        7) remove_cron ; pause ;;
        8) view_cron ; pause ;;
        9) uninstall ;;
        0) exit ;;
        *) echo "无效输入" ; pause ;;
    esac
}

init_config
check_dependencies

if [ ! -f "$RUN_SCRIPT" ]; then
    install_run_script
fi

while true
do
    menu
done
