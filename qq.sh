#!/bin/bash
# ===============================
# ACME Pro 证书工具（域名+IP short-lived）
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
# 安装依赖
# ===============================
install_dep(){
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y curl socat cron wget docker.io
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl socat cronie wget docker
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl socat cronie wget docker
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
    cp "$2" "$SSL_DIR/$domain/cert.crt"
    cp "$3" "$SSL_DIR/$domain/private.key"
    green "证书安装完成，路径: $SSL_DIR/$domain/"
    green "如需生效请手动重载 Web 服务"
}

# ===============================
# 域名证书申请（80端口模式）
# ===============================
standalone_issue(){
    read -p "请输入域名: " domain
    stop_web
    $ACME_HOME/acme.sh --issue -d $domain --standalone -k ec-256 \
        --server https://acme-v02.api.letsencrypt.org/directory
    if [ $? -eq 0 ]; then
        install_cert $domain "$ACME_HOME/$domain/fullchain.cer" "$ACME_HOME/$domain/$domain.key"
    else
        red "证书申请失败"
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
    if [ $? -eq 0 ]; then
        install_cert $domain "$ACME_HOME/$domain/fullchain.cer" "$ACME_HOME/$domain/$domain.key"
    else
        red "证书申请失败"
    fi
}

# ===============================
# IP证书申请（docker lego short-lived）
# ===============================
ip_issue(){
    read -p "请输入公网IP: " IP_ADDRESS
    read -p "请输入注册邮箱: " EMAIL
    [ -z "$EMAIL" ] && EMAIL="$(date +%s)@gmail.com"

    LEGO_DIR="$SSL_DIR/$IP_ADDRESS"
    mkdir -p "$LEGO_DIR"

    echo "正在申请 IP 证书（short-lived）..."
    docker run --rm -it \
      -v "${LEGO_DIR}":/.lego \
      -p 80:8888 \
      goacme/lego \
      --email="${EMAIL}" \
      --accept-tos \
      --server="https://acme-v02.api.letsencrypt.org/directory" \
      --http \
      --http.port=":8888" \
      --key-type="rsa2048" \
      --domains="${IP_ADDRESS}" \
      --disable-cn \
      run --profile "shortlived"

    CERT_FILE="${LEGO_DIR}/certificates/${IP_ADDRESS}.crt"
    KEY_FILE="${LEGO_DIR}/certificates/${IP_ADDRESS}.key"

    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        cp "$CERT_FILE" "$LEGO_DIR/cert.crt"
        cp "$KEY_FILE" "$LEGO_DIR/private.key"
        green "IP证书申请成功，路径: $LEGO_DIR/"
    else
        red "IP证书申请失败，请查看容器日志"
    fi
}

# ===============================
# IP证书续期（提前30天）
# ===============================
ip_renew(){
    read -p "请输入公网IP: " IP_ADDRESS
    read -p "请输入注册邮箱: " EMAIL
    LEGO_DIR="$SSL_DIR/$IP_ADDRESS"
    CERT_FILE="${LEGO_DIR}/cert.crt"
    KEY_FILE="${LEGO_DIR}/private.key"

    if [[ ! -d "$LEGO_DIR" ]]; then
        red "证书目录不存在: $LEGO_DIR"
        return
    fi

    echo "执行 IP 证书续期..."
    docker run --rm \
      -v "${LEGO_DIR}":/.lego \
      -p 80:8888 \
      goacme/lego \
      --email="${EMAIL}" \
      --path="/.lego" \
      --server="https://acme-v02.api.letsencrypt.org/directory" \
      --http --http.port=":8888" \
      --domains="${IP_ADDRESS}" \
      renew --profile "shortlived" --days 30 --reuse-key

    if [[ -f "${CERT_FILE}" && -f "${KEY_FILE}" ]]; then
        green "✓ IP证书续期成功！"
    else
        red "✗ IP证书续期失败，请查看日志"
    fi
}

# ===============================
# 续期全部域名证书
# ===============================
renew_all(){
    $ACME_HOME/acme.sh --cron -f
    green "全部域名证书已尝试续期"
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
# 安装 IP 自动续期 cron
# ===============================
setup_ip_cron(){
    read -p "请输入公网IP: " IP_ADDRESS
    read -p "请输入注册邮箱: " EMAIL
    LEGO_DIR="$SSL_DIR/$IP_ADDRESS"

    if [[ ! -d "$LEGO_DIR" ]]; then
        red "证书目录不存在: $LEGO_DIR，请先申请 IP 证书"
        return
    fi

    CRON_CMD="docker run --rm -v \"${LEGO_DIR}\":/.lego -p 80:8888 goacme/lego --email=\"${EMAIL}\" --path=\"/.lego\" --server=\"https://acme-v02.api.letsencrypt.org/directory\" --http --http.port=\":8888\" --domains=\"${IP_ADDRESS}\" renew --profile shortlived --days 30 --reuse-key && cp \"${LEGO_DIR}/certificates/${IP_ADDRESS}.crt\" \"${LEGO_DIR}/cert.crt\" && cp \"${LEGO_DIR}/certificates/${IP_ADDRESS}.key\" \"${LEGO_DIR}/private.key\""

    # 判断是否已有相同 cron
    crontab -l 2>/dev/null | grep -F "$CRON_CMD" >/dev/null
    if [ $? -eq 0 ]; then
        green "IP证书续期 cron 已存在，无需重复添加"
    else
        # 每天凌晨3点执行续期
        (crontab -l 2>/dev/null; echo "0 3 * * * $CRON_CMD >/dev/null 2>&1") | crontab -
        green "IP证书自动续期 cron 添加成功，每天凌晨3点自动续期"
    fi
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
    green "3. 续期全部域名证书"
    green "4. 查看已申请证书"
    green "5. 删除指定证书"
    green "6. 卸载acme.sh"
    green "7. IP申请证书"
    green "8. IP证书续期"
    green "9. 设置IP证书自动续期cron"

    green "0. 退出"

    read -p $'\033[32m请选择: \033[0m' num
    case $num in
        1) install_dep; install_acme; standalone_issue;;
        2) install_dep; install_acme; dns_issue;;
        3) renew_all;;
        4) list_cert;;
        5) remove_cert;;
        6) uninstall_acme;;
        7) install_dep; ip_issue;;
        8) ip_renew;;
        9) setup_ip_cron;;
        0) exit;;
        *) echo -e "${RED}无效选项${RESET}";;
    esac
    read -p $'\033[32m按回车返回菜单...\033[0m' temp
done
