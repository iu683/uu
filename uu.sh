#!/bin/bash
# ==========================================
# ACME Pro 证书申请（纯本地管理：支持域名与 IP 强制续期）
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

ACME_HOME="/root/.acme.sh"
SSL_DIR="/root/ssl"
mkdir -p $SSL_DIR

# 简易 pause 函数
pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m' temp
}

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

# ==========================================
# 获取系统状态数据（直接从 acme.sh 源码文件提取 VER=）
# ==========================================
get_system_status() {
    local acme_file="$ACME_HOME/acme.sh"
    if [ -f "$acme_file" ]; then
        STATUS="${GREEN}运行中${RESET}"
        
        # 直接从文件内容中检索 VER=xxx 或 _VERSION=xxx 
        VERSION_SHOW=$(grep -E '^(VER|漏洞标记|_VERSION)=' "$acme_file" | head -n 1 | cut -d'=' -f2 | tr -d '"'\'' ')
        
        # 兜底：如果文本提取依然失败，则赋予 3.1.4 默认值
        if [ -z "$VERSION_SHOW" ]; then
            VERSION_SHOW="3.1.4"
        fi
        
        # 计算已申请的证书数量
        SITE_COUNT=$($ACME_HOME/acme.sh --list | tail -n +2 | wc -l)
    else
        STATUS="${RED}未运行${RESET}"
        VERSION_SHOW="--"
        SITE_COUNT="0"
    fi
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

# ==========================================
# 2. IP 短周期证书申请 (仅支持纯 IPv4 模式)
# ==========================================
ip_issue(){
    yellow "正在检索服务器公网 IPv4..."
    local v4_ip=$(get_public_ip -4 || true)
    
    if [ -z "$v4_ip" ]; then
        red "未检测到有效的公网 IPv4，请检查网络后再试。"
        return 1
    fi

    echo "--------------------------------"
    green "侦测到公网 IPv4: $v4_ip"
    echo "--------------------------------"

    yellow "即将通过 Let's Encrypt 申请 5天短周期证书 ($v4_ip)..."
    stop_web
    
    $ACME_HOME/acme.sh --issue --standalone \
        --certificate-profile shortlived \
        -d "$v4_ip" \
        --keylength 2048 \
        --server letsencrypt \
        --force

    if [ $? -eq 0 ]; then
        install_cert "$v4_ip"
    else
        red "证书申请失败。请检查该 IP 的 80 端口是否在系统防火墙（iptables/ufw）或云服务商安全组中放行。"
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

# ==========================================
# 4. 强制续期全部本地证书（包含 IP 短周期）
# ==========================================
renew_all(){
    yellow "正在强制续期本地全部证书 (包括域名与短周期IP)..."
    stop_web
    $ACME_HOME/acme.sh --renew-all --ecc --force
    local res=$?
    
    # 强制续期成功后重新导出文件到本地存储目录
    if [ -d "$SSL_DIR" ]; then
        for domain in $(ls $SSL_DIR); do
            if $ACME_HOME/acme.sh --list | grep -q "$domain"; then
                yellow "正在重新导出同步 [$domain] 的新证书文件..."
                $ACME_HOME/acme.sh --install-cert -d $domain \
                    --key-file       $SSL_DIR/$domain/private.key \
                    --fullchain-file $SSL_DIR/$domain/cert.crt >/dev/null
            fi
        done
    fi
    start_web
    echo "----------------------------------------"
    green "全部本地证书已执行强制续期并完成同步！"
    pause
}

# ==========================================
# 5. 域名/IP 证书本地状态实时监控
# ==========================================
check_domains_status() {
    clear
    echo -e "${YELLOW}========================================${RESET}"
    echo -e "${YELLOW}        ◈ 本地证书状态实时监控 ◈            ${RESET}"
    echo -e "${YELLOW}========================================${RESET}"

    mapfile -t DOMAINS < <($ACME_HOME/acme.sh --list | tail -n +2 | awk '{print $1}')
    
    if [ ${#DOMAINS[@]} -eq 0 ] || [ "${DOMAINS[0]}" == "" ]; then
        echo -e "${RED} ❌ 当前系统 acme.sh 未检测到任何已签发的本地证书。${RESET}"
        echo -e "${YELLOW}----------------------------------------${RESET}"
        pause
        return
    fi

    for DOMAIN in "${DOMAINS[@]}"; do
        [ -z "$DOMAIN" ] && continue
        local CERT_PATH="$SSL_DIR/$DOMAIN/cert.crt"
        local TYPE="ACME 本地管理 (域名/IP)"

        echo -e "${YELLOW}◈ 域名/IP: ${RESET}${YELLOW}${DOMAIN}${RESET}"
        echo -e "  ├─ ${YELLOW}证书类型: ${RESET}${TYPE}"

        if [ -f "$CERT_PATH" ]; then
            END_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
            if END_TS=$(date -d "$END_DATE" +%s 2>/dev/null); then
                NOW_TS=$(date +%s)
                DAYS_LEFT=$(( (END_TS - NOW_TS) / 86400 ))
                
                if [ $DAYS_LEFT -ge 30 ]; then
                    STATUS_COLOR="${GREEN}"
                    STATUS_TEXT="正常有效"
                elif [ $DAYS_LEFT -ge 0 ]; then
                    STATUS_COLOR="${YELLOW}"
                    STATUS_TEXT="即将过期 (请注意)"
                else
                    STATUS_COLOR="${RED}"
                    STATUS_TEXT="已过期 (请立即更新)"
                fi
                echo -e "  ├─ ${YELLOW}到期时间: ${RESET}$(date -d "$END_DATE" +"%Y-%m-%d" 2>/dev/null || echo "$END_DATE")"
                echo -e "  ├─ ${YELLOW}剩余天数: ${RESET}${STATUS_COLOR}${DAYS_LEFT} 天${RESET}"
                echo -e "  └─ ${YELLOW}运行状态: ${RESET}${STATUS_COLOR}${STATUS_TEXT}${RESET}"
            else
                if openssl x509 -checkend 2592000 -in "$CERT_PATH" >/dev/null; then
                    echo -e "  └─ ${YELLOW}运行状态: ${RESET}${GREEN}正常有效 (剩余 > 30天)${RESET}"
                else
                    echo -e "  └─ ${YELLOW}运行状态: ${RESET}${YELLOW}即将过期或已过期${RESET}"
                fi
            fi
        else
            echo -e "  └─ ${YELLOW}运行状态: ${RESET}${RED}未在 $SSL_DIR 中找到导出的证书文件${RESET}"
        fi
        echo -e "${YELLOW}----------------------------------------${RESET}"
    done
    pause
}

# ==========================================
# 6. 删除本地证书（纯本地列表删除）
# ==========================================
remove_cert(){
    mapfile -t certs < <($ACME_HOME/acme.sh --list | tail -n +2 | awk '{print $1}')
    if [ ${#certs[@]} -eq 0 ] || [ "${certs[0]}" == "" ]; then
        red "当前没有任何本地证书可删除"
        pause
        return 0
    fi
    green "本地可删除的证书列表："
    echo "编号    域名/IP"
    echo "---------------------------"
    for i in "${!certs[@]}"; do
        [ -z "${certs[$i]}" ] && continue
        printf "%-4s %s\n" "$((i+1))" "${certs[$i]}"
    done
    
    read -p "请输入要删除的编号 (输入0返回): " num
    [ "$num" == "0" ] && return 0
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#certs[@]}" ]; then
        red "无效编号"
        pause
        return 0
    fi
    
    domain="${certs[$((num-1))]}"
    
    $ACME_HOME/acme.sh --remove -d "$domain" --ecc >/dev/null 2>&1
    $ACME_HOME/acme.sh --remove -d "$domain" >/dev/null 2>&1
    
    if [ -d "$SSL_DIR/$domain" ]; then
        rm -rf "$SSL_DIR/$domain"
    fi
    
    green "证书 [$domain] 已成功从本地及 acme.sh 中删除。"
    pause
}

# ===============================
# 7. 查看自动续期任务
# ===============================
show_cron(){
    echo
    green "当前 acme.sh 自动续期任务:"
    crontab -l | grep acme.sh || yellow "未发现自动续期任务"
    echo
    pause
}

# ===============================
# 9. 卸载 acme.sh
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
    pause
}

# ===============================
# 主菜单循环
# ===============================
while true
do
    clear
    get_system_status
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}        ACME  管理面板          ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $STATUS"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
    echo -e "${GREEN}证书   :${RESET} ${YELLOW}$SITE_COUNT 个${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装ACME${RESET}"
    echo -e "${GREEN} 2. 申请域名证书(80端口模式)${RESET}"
    echo -e "${GREEN} 3. 申请IP证书(IP短周期模式)${RESET}"
    echo -e "${GREEN} 4. 申请域名证书(DNSAPI模式)${RESET}"
    echo -e "${GREEN} 5. 强制续期全部本地证书${RESET}"
    echo -e "${GREEN} 6. 查看已申请证书${RESET}"
    echo -e "${GREEN} 7. 删除指定本地证书${RESET}"
    echo -e "${GREEN} 8. 查看定时自动续期任务${RESET}"
    echo -e "${GREEN} 9. 更新ACME${RESET}"
    echo -e "${GREEN}10. 卸载ACME${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN} 请选择: ${RESET}"
    
    read num
    case $num in
        1) install_dep; install_acme; pause;;
        2) [ ! -f "$ACME_HOME/acme.sh" ] && install_dep && install_acme; standalone_issue;;
        3) [ ! -f "$ACME_HOME/acme.sh" ] && install_dep && install_acme; ip_issue;;
        4) [ ! -f "$ACME_HOME/acme.sh" ] && install_dep && install_acme; dns_issue;;
        5) renew_all;;
        6) check_domains_status;;
        7) remove_cert;;
        8) show_cron;;
        9) update_acme; pause;;
       10) uninstall_acme;;
        0) exit;;
        *) echo -e "${RED}无效选项${RESET}"; pause;;
    esac
done
