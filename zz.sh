#!/bin/bash
# ==========================================
# ACME Pro 证书申请（Alpine 专属：ZeroSSL 驱动）
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
SSL_DIR="/etc/acmessl"
mkdir -p $SSL_DIR

# 简易 pause 函数
pause() {
    read -p $'\033[32m按回车返回菜单...\033[0m' temp
}

# ===============================
# 依赖检测 (Alpine apk 专用)
# ===============================
install_dep(){
    yellow "正在为 Alpine Linux 安装必要依赖..."
    apk update
    # 安装 bash, curl, openssl, socat 以及用于计算时间的 tzdata
    apk add --no-interactive bash curl openssl socat wget crond tzdata python3
    
    # 确保 crond 服务在 Alpine 中启动
    if command -v rc-service >/dev/null 2>&1; then
        rc-service crond start >/dev/null 2>&1
        rc-update add crond default >/dev/null 2>&1
    fi
}

# ===============================
# 安装 acme.sh 并初始化 ZeroSSL
# ===============================
install_acme(){
    if [ ! -f "$ACME_HOME/acme.sh" ]; then
        read -p "请输入注册 ZeroSSL 的邮箱（回车自动生成）: " email
        [ -z "$email" ] && email="$(date +%s)@gmail.com"
        
        yellow "正在下载安装 acme.sh..."
        curl https://get.acme.sh | sh -s email=$email
        
        yellow "正在将默认 CA 设置为 ZeroSSL..."
        $ACME_HOME/acme.sh --set-default-ca --server zerossl
        
        green "acme.sh 安装并初始化 ZeroSSL 完成！"
    else
        $ACME_HOME/acme.sh --set-default-ca --server zerossl >/dev/null 2>&1
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
# 停止/恢复 Web 服务 (Alpine OpenRC 适配)
# ===============================
stop_web(){
    if command -v rc-service >/dev/null 2>&1; then
        if rc-service nginx status >/dev/null 2>&1; then
            rc-service nginx stop >/dev/null 2>&1
            WEB_STOP=nginx
        fi
        if rc-service apache2 status >/dev/null 2>&1; then
            rc-service apache2 stop >/dev/null 2>&1
            WEB_STOP=apache2
        fi
    fi
}

start_web(){
    [ ! -z "$WEB_STOP" ] && command -v rc-service >/dev/null 2>&1 && rc-service $WEB_STOP start >/dev/null 2>&1
}

# ==========================================
# 安装/导出证书
# ==========================================
install_cert(){
    local domain=$1
    mkdir -p $SSL_DIR/$domain
    
    $ACME_HOME/acme.sh --install-cert -d $domain \
        --key-file       $SSL_DIR/$domain/private.key \
        --fullchain-file $SSL_DIR/$domain/cert.crt
        
    green "证书本地同步完成"
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
# 获取系统状态数据
# ==========================================
get_system_status() {
    local acme_file="$ACME_HOME/acme.sh"
    if [ -f "$acme_file" ]; then
        STATUS="${GREEN}运行中 (ZeroSSL)${RESET}"
        VERSION_SHOW=$(grep -E '^(VER|漏洞标记|_VERSION)=' "$acme_file" | head -n 1 | cut -d'=' -f2 | tr -d '"'\'' ')
        if [ -z "$VERSION_SHOW" ]; then
            VERSION_SHOW="3.1.4"
        fi
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
    read -p "请输入域名 (example.com): " domain
    [ -z "$domain" ] && red "域名不能为空" && return 1
    stop_web
    
    $ACME_HOME/acme.sh --issue -d $domain --standalone -k ec-256 --server zerossl
    [ $? -eq 0 ] && install_cert $domain || red "ZeroSSL 域名证书申请失败"
    start_web
}

# ==========================================
# 2. IP 证书申请 (ZeroSSL 公网 IP 模式)
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

    yellow "即将通过 ZeroSSL 申请公网 IP 证书 ($v4_ip)..."
    stop_web
    
    $ACME_HOME/acme.sh --issue --standalone \
        -d "$v4_ip" \
        --keylength 2048 \
        --server zerossl \
        --force

    if [ $? -eq 0 ]; then
        install_cert "$v4_ip"
    else
        red "证书申请失败。请确保防火墙已放行 80 端口。"
    fi
    start_web
}

# ===============================
# 3. DNS 模式申请证书
# ===============================
dns_issue(){
    read -p "请输入域名 (example.com): " domain
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
            $ACME_HOME/acme.sh --issue --dns dns_cf -d $domain -k ec-256 --server zerossl
            ;;
        2)
            read -p "DP_Id: " DP_Id
            read -p "DP_Key: " DP_Key
            export DP_Id DP_Key
            $ACME_HOME/acme.sh --issue --dns dns_dp -d $domain -k ec-256 --server zerossl
            ;;
        3)
            read -p "Ali_Key: " Ali_Key
            read -p "Ali_Secret: " Ali_Secret
            export Ali_Key Ali_Secret
            $ACME_HOME/acme.sh --issue --dns dns_ali -d $domain -k ec-256 --server zerossl
            ;;
        *)
            red "无效选择"
            return 1
            ;;
    esac
    [ $? -eq 0 ] && install_cert $domain || red "ZeroSSL 证书申请失败"
}

# ==========================================
# 4. 强制续期全部本地证书
# ==========================================
renew_all(){
    yellow "正在强制续期本地全部 ZeroSSL 证书..."
    stop_web
    
    $ACME_HOME/acme.sh --renew-all --force
    
    if [ -d "$SSL_DIR" ]; then
        for domain in $(ls $SSL_DIR); do
            if $ACME_HOME/acme.sh --list | grep -q "$domain"; then
                yellow "正在同步重新导出 [$domain] 的证书文件..."
                $ACME_HOME/acme.sh --install-cert -d "$domain" \
                    --key-file       $SSL_DIR/$domain/private.key \
                    --fullchain-file $SSL_DIR/$domain/cert.crt >/dev/null
            fi
        done
    fi
    start_web
    echo "----------------------------------------"
    green "全部本地 ZeroSSL 证书已执行强制续期并完成同步！"
    pause
}

# ==========================================
# 5. 域名/IP 证书本地状态实时监控 (Alpine 兼容版)
# ==========================================
check_domains_status() {
    clear
    echo -e "${YELLOW}========================================${RESET}"
    echo -e "${YELLOW}        ◈ 本地 ZeroSSL 证书状态实时监控 ◈            ${RESET}"
    echo -e "${YELLOW}========================================${RESET}"

    # Alpine 下使用 awk 安全提取域名列表
    local domains_list=$($ACME_HOME/acme.sh --list | tail -n +2 | awk '{print $1}')
    
    if [ -z "$domains_list" ]; then
        echo -e "${RED} ❌ 当前系统 acme.sh 未检测到任何已签发的本地证书。${RESET}"
        echo -e "${YELLOW}----------------------------------------${RESET}"
        pause
        return
    fi

    for DOMAIN in $domains_list; do
        [ -z "$DOMAIN" ] && continue
        local CERT_PATH="$SSL_DIR/$DOMAIN/cert.crt"
        local TYPE="ZeroSSL 本地管理 (域名/IP)"

        echo -e "${YELLOW}◈ 域名/IP: ${RESET}${YELLOW}${DOMAIN}${RESET}"
        echo -e "  ├─ ${YELLOW}证书类型: ${RESET}${TYPE}"

        if [ -f "$CERT_PATH" ]; then
            # 针对 Alpine BusyBox date 命令的局限性，改用 openssl 循环步进探测剩余天数
            local days=0
            while openssl x509 -checkend $((days * 86400)) -in "$CERT_PATH" >/dev/null 2>&1; do
                days=$((days + 1))
                if [ $days -gt 120 ]; then break; fi # 防止异常无限循环
            done
            local DAYS_LEFT=$((days - 1))
            
            # 提取原始到期时间文本显示
            local END_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)

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
            
            echo -e "  ├─ ${YELLOW}到期时间: ${RESET}$END_DATE"
            echo -e "  ├─ ${YELLOW}剩余天数: ${RESET}${STATUS_COLOR}${DAYS_LEFT} 天${RESET}"
            echo -e "  └─ ${YELLOW}运行状态: ${RESET}${STATUS_COLOR}${STATUS_TEXT}${RESET}"
        else
            echo -e "  └─ ${YELLOW}运行状态: ${RESET}${RED}未在 $SSL_DIR 中找到导出的证书文件${RESET}"
        fi
        echo -e "${YELLOW}----------------------------------------${RESET}"
    done
    pause
}

# ==========================================
# 6. 删除本地证书
# ==========================================
remove_cert(){
    local certs=$($ACME_HOME/acme.sh --list | tail -n +2 | awk '{print $1}')
    if [ -z "$certs" ]; then
        red "当前没有任何本地证书可删除"
        pause
        return 0
    fi
    
    green "本地可删除的证书列表："
    echo "编号    域名/IP"
    echo "---------------------------"
    
    local i=1
    for cert in $certs; do
        printf "%-4s %s\n" "$i" "$cert"
        eval cert_map_$i="$cert"
        i=$((i+1))
    done
    local total_certs=$((i-1))
    
    read -p "请输入要删除的编号 (输入0返回): " num
    [ "$num" == "0" ] && return 0
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$total_certs" ]; then
        red "无效编号"
        pause
        return 0
    fi
    
    local domain=$(eval echo \$cert_map_$num)
    
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
    crontab -l 2>/dev/null | grep acme.sh || yellow "未发现自动续期任务"
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
    echo -e "${GREEN}      ACME 管理面板 (ZeroSSL)    ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $STATUS"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
    echo -e "${GREEN}证书   :${RESET} ${YELLOW}$SITE_COUNT 个${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装ACME${RESET}"
    echo -e "${GREEN} 2. 申请域名证书(80端口模式)${RESET}"
    echo -e "${GREEN} 3. 申请IP证书(IP模式)${RESET}"
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
