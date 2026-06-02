#!/bin/bash
# ==========================================
# ACME Pro 证书申请（支持域名与 IP 短周期）
# ==========================================
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
SSL_DIR="/root/ssl"
mkdir -p $SSL_DIR

# ===============================
# 依赖检测
# ===============================
install_dep(){
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y curl socat cron wget python3 openssl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl socat cronie wget python3 openssl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl socat cronie wget python3 openssl
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
# 更新 acme.sh
# ===============================
update_acme(){
    if [ -f "$ACME_HOME/acme.sh" ]; then
        yellow "正在检查并更新 acme.sh..."
        $ACME_HOME/acme.sh --upgrade
        if [ $? -eq 0 ]; then
            green "acme.sh 更新成功！"
        else
            red "更新失败，请检查网络连接。"
        fi
    else
        red "未检测到已安装的 acme.sh，请先申请证书或执行安装。"
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
# 安装/导出证书
# ===============================
install_cert(){
    domain=$1
    mkdir -p $SSL_DIR/$domain
    $ACME_HOME/acme.sh --install-cert -d $domain \
        --key-file       $SSL_DIR/$domain/private.key \
        --fullchain-file $SSL_DIR/$domain/cert.crt
    green "证书安装完成"
    green "路径: $SSL_DIR/$domain/"
}

# ===============================
# 智能获取公网 IP 函数
# ===============================
get_public_ip() {
    local mode="${1:-"-4"}" 
    local ip cmd urls

    if [[ "$mode" == "-6" ]]; then
        cmd_list=("curl -6fsSL --max-time 5" "wget -6qO- --timeout=5")
        urls=("https://api64.ipify.org" "https://ipv6.ip.sb" "https://v6.ident.me")
    else
        cmd_list=("curl -4fsSL --max-time 5" "wget -4qO- --timeout=5")
        urls=("https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com")
    fi

    for cmd in "${cmd_list[@]}"; do
        for url in "${urls[@]}"; do
            ip=$($cmd "$url" 2>/dev/null || true)
            ip=$(echo "$ip" | tr -d '[:space:]')
            if [[ -n "$ip" ]]; then
                if [[ "$mode" == "-4" && "$ip" =~ \. ]] || [[ "$mode" == "-6" && "$ip" =~ : ]]; then
                    echo "$ip"
                    return 0
                fi
            fi
        done
    done
    return 1
}

# ===============================
# 1. 域名 80 端口模式申请证书
# ===============================
standalone_issue(){
    read -p "请输入域名: " domain
    [ -z "$domain" ] && red "域名不能为空" && return 1
    stop_web
    $ACME_HOME/acme.sh --issue -d $domain --standalone -k ec-256 --server https://acme-v02.api.letsencrypt.org/directory
    [ $? -eq 0 ] && install_cert $domain || red "证书申请失败"
    start_web
}

# ===============================
# 2. IP 短周期证书申请 (单 IP 模式)
# ===============================
ip_issue(){
    yellow "正在检索服务器公网 IP..."
    local v4_ip=$(get_public_ip -4 || true)
    local v6_ip=$(get_public_ip -6 || true)
    
    if [ -z "$v4_ip" ] && [ -z "$v6_ip" ]; then
        red "未检测到任何公网 IP，请检查网络后再试。"
        return 1
    fi

    echo "--------------------------------"
    [ -n "$v4_ip" ] && green "1. IPv4 地址: $v4_ip (默认)" || red "1. 未检测到公网 IPv4"
    [ -n "$v6_ip" ] && green "2. IPv6 地址: $v6_ip" || red "2. 未检测到公网 IPv6"
    echo "--------------------------------"
    
    yellow "请选择需要申请证书的单个 IP 类型:"
    echo "1. 仅申请 IPv4 证书"
    echo "2. 仅申请 IPv6 证书"
    read -p "请选择 (默认 1): " ip_choice
    ip_choice="${ip_choice:-1}"

    local target_ip=""

    if [ "$ip_choice" == "1" ]; then
        [ -z "$v4_ip" ] && red "错误: 未检测到有效的 IPv4" && return 1
        target_ip="$v4_ip"
    elif [ "$ip_choice" == "2" ]; then
        [ -z "$v6_ip" ] && red "错误: 未检测到有效的 IPv6" && return 1
        target_ip="$v6_ip"
    else
        red "无效选项"
        return 1
    fi

    yellow "即将通过 Let's Encrypt 申请 5天短周期单 IP 证书 ($target_ip)..."
    stop_web
    
    $ACME_HOME/acme.sh --issue --standalone \
        --certificate-profile shortlived \
        -d "$target_ip" \
        --keylength 2048 \
        --server letsencrypt \
        --force

    if [ $? -eq 0 ]; then
        install_cert "$target_ip"
    else
        red "IP 证书申请失败。请检查该 IP 的 80 端口是否在防火墙/安全组中放行。"
    fi
    start_web
}

# ===============================
# 3. DNS 模式申请证书
# ===============================
dns_issue(){
    read -p "请输入域名: " domain
    [ -z "$domain" ] && red "域名不能为空" && return 1
    echo "1.Cloudflare"
    echo "2.DNSPod"
    echo "3.Aliyun"
    read -p "请选择: " type
    case $type in
        1)
            read -p "CF_Key: " CF_Key
            read -p "CF_Email: " CF_Email
            export CF_Key CF_Email
            $ACME_HOME/acme.sh --issue --dns dns_cf -d $domain -k ec-256 --server https://acme-v02.api.letsencrypt.org/directory
            ;;
        2)
            read -p "DP_Id: " DP_Id
            read -p "DP_Key: " DP_Key
            export DP_Id DP_Key
            $ACME_HOME/acme.sh --issue --dns dns_dp -d $domain -k ec-256 --server https://acme-v02.api.letsencrypt.org/directory
            ;;
        3)
            read -p "Ali_Key: " Ali_Key
            read -p "Ali_Secret: " Ali_Secret
            export Ali_Key Ali_Secret
            $ACME_HOME/acme.sh --issue --dns dns_ali -d $domain -k ec-256 --server https://acme-v02.api.letsencrypt.org/directory
            ;;
        *)
            red "无效选择"
            return 1
            ;;
    esac
    [ $? -eq 0 ] && install_cert $domain || red "证书申请失败"
}

# ===============================
# 续期所有证书
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
    echo "编号   域名/IP"
    echo "---------------------------"
    for i in "${!certs[@]}"; do
        printf "%-4s %s\n" "$((i+1))" "${certs[$i]}"
    done
    
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
    [ -f "$ACME_HOME/acme.sh" ] && "$ACME_HOME/acme.sh" --uninstall >/dev/null 2>&1
    [ -d "$ACME_HOME" ] && rm -rf "$ACME_HOME"
    [ -d "/etc/acme" ] && rm -rf "/etc/acme"
    [ -d "$SSL_DIR" ] && rm -rf "$SSL_DIR"

    crontab -l 2>/dev/null | grep -v acme.sh | crontab -
    
    [ -f "$HOME/.bashrc" ] && sed -i '/acme.sh.env/d' "$HOME/.bashrc"
    [ -f "$HOME/.profile" ] && sed -i '/acme.sh.env/d' "$HOME/.profile"
    
    green "acme.sh 已彻底卸载"
}

show_cron(){
    echo
    green "当前 acme.sh 自动续期任务:"
    crontab -l | grep acme.sh || yellow "未发现自动续期任务"
    echo
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
    green "     ACME申请证书工具 "
    green "==============================="
    green "1. 申请域名证书 (80端口模式)"
    green "2. 申请 IP 证书 (短周期5天)"
    green "3. 申请域名证书 (DNSAPI模式)"
    green "4. 续期全部证书"
    green "5. 查看已申请证书"
    green "6. 删除指定证书"
    green "7. 查看自动续期任务"
    green "8. 更新acme.sh"
    green "9. 卸载"
    green "0. 退出"

    read -p $'\033[32m请选择: \033[0m' num
    case $num in
        1) install_dep; install_acme; standalone_issue;;
        2) install_dep; install_acme; ip_issue;;
        3) install_dep; install_acme; dns_issue;;
        4) renew_all;;
        5) list_cert;;
        6) remove_cert;;
        7) show_cron;;
        8) update_acme;;
        9) uninstall_acme;;
        0) exit;;
        *) echo -e "${RED}无效选项${RESET}";;
    esac
    read -p $'\033[32m按回车返回菜单...\033[0m' temp
done
