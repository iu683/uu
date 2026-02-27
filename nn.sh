#!/bin/bash

# ===============================
# Linai ACME Pro v2
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
SSL_DIR="/etc/ssl/acme"

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
--key-file       $SSL_DIR/$domain/private.key  \
--fullchain-file $SSL_DIR/$domain/cert.crt

green "证书安装完成"
green "路径: $SSL_DIR/$domain/"
green "如需生效请手动重载 Web 服务"
}

# ===============================
# 80 端口模式
# ===============================

standalone_issue(){
read -p "请输入域名: " domain
stop_web
$ACME_HOME/acme.sh --issue -d $domain --standalone -k ec-256 --server zerossl
[ $? -eq 0 ] && install_cert $domain || red "证书申请失败"
start_web
}

# ===============================
# DNS 模式
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
# 卸载单个证书
# ===============================

remove_cert(){
$ACME_HOME/acme.sh --list
echo
read -p "请输入要删除的域名: " domain

$ACME_HOME/acme.sh --remove -d $domain --ecc >/dev/null 2>&1
rm -rf $SSL_DIR/$domain

green "证书 $domain 已删除"
}

# ===============================
# 卸载 acme.sh
# ===============================

uninstall_acme(){

if [ -f "$ACME_HOME/acme.sh" ]; then
    $ACME_HOME/acme.sh --uninstall >/dev/null 2>&1
fi

rm -rf $ACME_HOME
rm -rf $SSL_DIR

# 只有存在才处理
[ -f ~/.bashrc ] && sed -i '/acme.sh.env/d' ~/.bashrc
[ -f ~/.profile ] && sed -i '/acme.sh.env/d' ~/.profile

green "acme.sh 已彻底卸载"
}

list_cert(){

printf "%-22s %-8s %-15s %-10s\n" "域名" "状态" "到期时间" "剩余天数"
echo "------------------------------------------------------------"

$ACME_HOME/acme.sh --list | tail -n +2 | while read domain keylength san ca created renew; do

    # 读取到期时间
    expire=$($ACME_HOME/acme.sh --info -d $domain --ecc 2>/dev/null | grep "Le_NextRenewTimeStr" | cut -d"'" -f2)

    if [ -z "$expire" ]; then
        expire=$($ACME_HOME/acme.sh --info -d $domain 2>/dev/null | grep "Le_NextRenewTimeStr" | cut -d"'" -f2)
    fi

    if [ -n "$expire" ]; then
        expire_date=$(date -d "$expire" +"%Y-%m-%d" 2>/dev/null)
        now=$(date +%s)
        expire_ts=$(date -d "$expire" +%s 2>/dev/null)
        remain=$(( (expire_ts - now) / 86400 ))

        if [ "$remain" -ge 0 ]; then
            status="有效"
        else
            status="已过期"
        fi
    else
        expire_date="未知"
        remain="--"
        status="未知"
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
green "6. 卸载acme.sh"
green "0. 退出"

read -p $'\033[32m请选择: \033[0m' num

case $num in
1) install_dep; install_acme; standalone_issue;;
2) install_dep; install_acme; dns_issue;;
3) renew_all;;
4) list_cert;;
5) remove_cert;;
6) uninstall_acme;;
0) exit;;
*) echo -e "${RED}无效选项${RESET}";;
esac

echo
read -p $'\033[32m按回车返回菜单...\033[0m' temp
done
