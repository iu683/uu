#!/bin/bash
# ===============================
# ACME Pro 证书申请（Let's Encrypt + IP 支持）
# ===============================
export LANG=en_US.UTF-8

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

green(){ echo -e "${GREEN}$1${RESET}"; }
red(){ echo -e "${RED}$1${RESET}"; }
yellow(){ echo -e "${YELLOW}$1${RESET}"; }

[[ $EUID -ne 0 ]] && red "请使用 root 运行" && exit

ACME_HOME="$HOME/.acme.sh"
SSL_DIR="/etc/acme/ssl"
mkdir -p $SSL_DIR

# ===============================
# 依赖检测
# ===============================
install_dep(){
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y curl socat cron wget
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl socat cronie wget
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl socat cronie wget
    fi
}

# ===============================
# 安装 acme.sh
# ===============================
install_acme(){
    if [ ! -f "$ACME_HOME/acme.sh" ]; then
        read -p "请输入注册邮箱（回车自动生成）: " email
        [ -z "$email" ] && email="$(date +%s)@gmail.com"
        curl https://get.acme.sh | sh -s email=$email
        green "acme.sh 安装完成"
    fi
}

# ===============================
# 停止/恢复 Web 服务
# ===============================
stop_web(){
    if systemctl is-active nginx >/dev/null 2>&1; then
        systemctl stop nginx
        WEB_STOP=nginx
    fi
    if systemctl is-active apache2 >/dev/null 2>&1; then
        systemctl stop apache2
        WEB_STOP=apache2
    fi
}

start_web(){
    [ ! -z "$WEB_STOP" ] && systemctl start $WEB_STOP
}

# ===============================
# 安装证书
# ===============================
install_cert(){
    domain=$1
    mkdir -p $SSL_DIR/$domain
    $ACME_HOME/acme.sh --install-cert -d $domain \
        --key-file       $SSL_DIR/$domain/private.key \
        --fullchain-file $SSL_DIR/$domain/cert.crt
    green "证书安装完成"
    green "路径: $SSL_DIR/$domain/"
    green "如需生效请手动重载 Web 服务"
}

# ===============================
# 80端口模式申请域名证书
# ===============================
standalone_issue(){
    read -p "请输入域名: " domain
    stop_web
    $ACME_HOME/acme.sh --issue -d $domain --standalone -k ec-256 \
        --server https://acme-v02.api.letsencrypt.org/directory
    [ $? -eq 0 ] && install_cert $domain || red "证书申请失败"
    start_web
}

# ===============================
# IP证书申请（short-lived）
# ===============================
check_acme_ip_support(){
    # 检测 acme.sh 是否支持 short-lived IP 证书
    if ! $ACME_HOME/acme.sh --help | grep -q "short-lived"; then
        yellow "当前 acme.sh 版本不支持 IP 证书，正在更新..."
        curl https://get.acme.sh | sh
        green "acme.sh 已更新到最新版"
    else
        green "acme.sh 已支持 IP 证书"
    fi
}
ip_issue(){
    check_acme_ip_support  # 先检测并更新 acme.sh
    read -p "请输入公网IP: " ip
    stop_web
    # 尝试使用 short-lived IP 申请，如果当前版本支持
    $ACME_HOME/acme.sh --issue -d $ip --standalone -k ec-256 \
        --server https://acme-v02.api.letsencrypt.org/directory 2>/tmp/acme_ip.log
    if [ $? -eq 0 ]; then
        install_cert $ip
    else
        red "IP证书申请失败，查看日志: /tmp/acme_ip.log"
    fi
    start_web
}

# ===============================
# DNS模式申请证书
# ===============================
dns_issue(){
    read -p "请输入域名: " domain
    echo "1.Cloudflare"
    echo "2.DNSPod"
    echo "3.Aliyun"
    read -p "请选择: " type
    case $type in
        1)
            read -p "CF_Key: " CF_Key
            read -p "CF_Email: " CF_Email
            export CF_Key CF_Email
            $ACME_HOME/acme.sh --issue --dns dns_cf -d $domain -k ec-256 \
                --server https://acme-v02.api.letsencrypt.org/directory
            ;;
        2)
            read -p "DP_Id: " DP_Id
            read -p "DP_Key: " DP_Key
            export DP_Id DP_Key
            $ACME_HOME/acme.sh --issue --dns dns_dp -d $domain -k ec-256 \
                --server https://acme-v02.api.letsencrypt.org/directory
            ;;
        3)
            read -p "Ali_Key: " Ali_Key
            read -p "Ali_Secret: " Ali_Secret
            export Ali_Key Ali_Secret
            $ACME_HOME/acme.sh --issue --dns dns_ali -d $domain -k ec-256 \
                --server https://acme-v02.api.letsencrypt.org/directory
            ;;
        *)
            red "无效选择"
            return
            ;;
    esac
    [ $? -eq 0 ] && install_cert $domain || red "证书申请失败"
}

# ===============================
# 续期
# ===============================
renew_all(){
    $ACME_HOME/acme.sh --cron -f
    green "全部证书已尝试续期"
}

# ===============================
# 删除证书
# ===============================
remove_cert(){
    certs=($($ACME_HOME/acme.sh --list | tail -n +2 | awk '{print $1}'))
    if [ ${#certs[@]} -eq 0 ]; then
        red "当前没有任何证书可删除"
        return 0
    fi
    green "可删除的证书列表："
    echo "编号  域名/IP"
    echo "---------------------------"
    for i in "${!certs[@]}"; do
        printf "%-4s %s\n" "$((i+1))" "${certs[$i]}"
    done
    echo
    read -p "请输入要删除的编号 (输入0返回): " num
    [ "$num" == "0" ] && return 0
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#certs[@]}" ]; then
        red "无效编号"
        return 0
    fi
    domain="${certs[$((num-1))]}"
    $ACME_HOME/acme.sh --remove -d "$domain" --ecc >/dev/null 2>&1
    [ -d "$SSL_DIR/$domain" ] && rm -rf "$SSL_DIR/$domain"
    green "证书 $domain 已删除"
}

# ===============================
# 卸载 acme.sh
# ===============================
uninstall_acme(){
    [ -f "$ACME_HOME/acme.sh" ] && $ACME_HOME/acme.sh --uninstall >/dev/null 2>&1
    rm -rf $ACME_HOME $SSL_DIR
    [ -f ~/.bashrc ] && sed -i '/acme.sh.env/d' ~/.bashrc
    [ -f ~/.profile ] && sed -i '/acme.sh.env/d' ~/.profile
    green "acme.sh 已彻底卸载"
}

# ===============================
# 查看已申请证书
# ===============================
list_cert(){
    printf "%-22s %-8s %-15s %-10s\n" "域名/IP" "状态" "到期时间" "剩余天数"
    echo "------------------------------------------------------------"
    $ACME_HOME/acme.sh --list | tail -n +2 | awk '{print $1}' | while read domain; do
        CERT_FILE="$SSL_DIR/$domain/cert.crt"
        if [ ! -f "$CERT_FILE" ]; then
            status="异常"; expire_date="无证书"; remain="--"
        else
            expire=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
            expire_ts=$(date -d "$expire" +%s 2>/dev/null)
            now_ts=$(date +%s)
            if [ -n "$expire_ts" ]; then
                remain=$(( (expire_ts - now_ts) / 86400 ))
                [ "$remain" -ge 0 ] && status="有效" || status="已过期"
                expire_date=$(date -d "$expire" +"%Y-%m-%d" 2>/dev/null)
            else
                status="异常"; expire_date="未知"; remain="--"
            fi
        fi
        printf "%-22s %-8s %-15s %-10s\n" "$domain" "$status" "$expire_date" "$remain 天"
    done
}

# ===============================
# 菜单
# ===============================
while true
do
    clear
    green "==============================="
    green "     ACME申请证书工具"
    green "==============================="
    green "1. 申请证书 (80端口模式)"
    green "2. 申请证书 (DNS API模式)"
    green "3. 续期全部证书"
    green "4. 查看已申请证书"
    green "5. 删除指定证书"
    green "6. IP申请证书"
    green "7. 卸载acme.sh"
    green "0. 退出"

    read -p $'\033[32m请选择: \033[0m' num
    case $num in
        1) install_dep; install_acme; standalone_issue;;
        2) install_dep; install_acme; dns_issue;;
        3) renew_all;;
        4) list_cert;;
        5) remove_cert;;
        6) install_dep; install_acme; ip_issue;;
        7) uninstall_acme;;
        0) exit;;
        *) echo -e "${RED}无效选项${RESET}";;
    esac
    read -p $'\033[32m按回车返回菜单...\033[0m' temp
done
