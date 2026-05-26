#!/bin/bash

# =========================================================
# Hysteria 2 管理脚本 (修复变量未定义崩溃版)
# =========================================================

set -Eeop pipefail  # 移除 -u 限制，防止因部分未定义空变量导致脚本意外退出

export LANG=en_US.UTF-8

# ================== 颜色 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# ================== 基础变量 ==================
readonly SCRIPT_VERSION="2.6"
readonly HY_CONFIG="/etc/hysteria/config.yaml"
readonly HY_BINARY="/usr/local/bin/hysteria"
readonly HY_DIR="/root/hy"

# ================== 日志函数 ==================
info() {
    echo -e "${GREEN}[信息] $*${RESET}" >&2
}

warn() {
    echo -e "${YELLOW}[警告] $*${RESET}" >&2
}

error() {
    echo -e "${RED}[错误] $*${RESET}" >&2
}

pause() {
    read -n 1 -s -r -p "按任意键返回菜单..." || true
    echo
}

# ================== 权限与系统检查 ==================
[[ $EUID -ne 0 ]] && error "注意: 请在 root 用户下运行脚本" && exit 1

# 判断系统及定义系统安装依赖方式
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

SYS=""
for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

SYSTEM=""
INT_IDX=0
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        INT_IDX=$int
        break
    fi
done

[[ -z $SYSTEM ]] && error "目前暂不支持你的VPS的操作系统！" && exit 1

# ================== 基础工具检查 ==================
if [[ -z $(type -P curl) || -z $(type -P jq) ]]; then
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[INT_IDX]}
    fi
    ${PACKAGE_INSTALL[INT_IDX]} curl jq >/dev/null 2>&1 || true
fi

# ================== 辅助工具函数 ==================
get_public_ip() {
    local ip
    ip=$(curl -s4m5 ip.sb -k || curl -s6m5 ip.sb -k || echo "")
    if [[ -z "$ip" ]]; then
        ip=$(curl -s4m5 https://api.ipify.org || curl -s6m5 https://api.ipify.org || echo "未知")
    fi
    echo "$ip"
}

check_port() {
    local port="$1"
    if ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -q -w "$port"; then
        return 1 # 被占用
    fi
    return 0 # 没占用
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

get_random_port() {
    local rand_port
    while true; do
        rand_port=$(shuf -i 2000-65535 -n 1)
        if check_port "$rand_port"; then
            echo "$rand_port"
            return 0
        fi
    done
}

get_hy_status() {
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        echo -e "${GREEN}● 运行中${RESET}"
    else
        echo -e "${RED}● 未运行${RESET}"
    fi
}

get_hy_version() {
    if [[ -x "$HY_BINARY" ]]; then
        "$HY_BINARY" version 2>/dev/null | head -n 1 | awk '{print $3}' || echo "未知"
    else
        echo "未安装"
    fi
}

get_current_port_display() {
    if [[ -f "$HY_CONFIG" ]]; then
        local main_port jump_range
        main_port=$(grep -E '^listen:' "$HY_CONFIG" | awk -F ':' '{print $3}' | tr -d ' ')
        
        if [[ -f "$HY_DIR/hy-client.yaml" ]]; then
            jump_range=$(grep -E '^server:' "$HY_DIR/hy-client.yaml" | awk -F ',' '{print $2}' | tr -d ' ')
            if [[ -n "$jump_range" ]]; then
                echo "${main_port} [${jump_range}]"
                return
            fi
        fi
        echo "${main_port:- -}"
    else
        echo "-"
    fi
}

check_warp_and_get_ip() {
    local warpv4 warpv6
    warpv4=$(curl -s4m5 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2 || echo "")
    warpv6=$(curl -s6m5 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2 || echo "")
    
    if [[ $warpv4 =~ on|plus || $warpv6 =~ on|plus ]]; then
        wg-quick down wgcf >/dev/null 2>&1 || true
        systemctl stop warp-go >/dev/null 2>&1 || true
        local real_ip
        real_ip=$(get_public_ip)
        wg-quick up wgcf >/dev/null 2>&1 || true
        systemctl start warp-go >/dev/null 2>&1 || true
        echo "$real_ip"
    else
        get_public_ip
    fi
}

# ================== 证书申请逻辑 ==================
inst_cert() {
    echo "---------------------------------------------"
    echo -e "Hysteria 2 协议证书申请方式如下："
    echo -e " 1) 必应自签证书 ${YELLOW}（默认）${RESET}"
    echo -e " 2) Acme 脚本自动申请"
    echo -e " 3) 自定义证书路径"
    echo "---------------------------------------------"
    
    local certInput
    read -rp "请输入选项 [1-3] (直接回车默认自签): " certInput
    certInput=${certInput:-1}

    if [[ $certInput == 2 ]]; then
        cert_path="/root/cert.crt"
        key_path="/root/private.key"
        chmod a+x /root

        if [[ -f /root/cert.crt && -f /root/private.key && -s /root/cert.crt && -s /root/private.key && -f /root/ca.log ]]; then
            hy_domain=$(cat /root/ca.log)
            info "检测到原有域名 [${hy_domain}] 的证书，正在复用..."
            domain=$hy_domain
        else
            local vps_ip
            vps_ip=$(check_warp_and_get_ip)
            
            read -rp "请输入需要申请证书的域名: " domain
            [[ -z $domain ]] && error "未输入域名，无法执行操作！" && return 1
            
            info "正在校验域名解析..."
            local domainIP
            domainIP=$(curl -sm5 ipget.net/?ip="${domain}" || echo "")
            
            if [[ "$domainIP" == "$vps_ip" ]]; then
                ${PACKAGE_INSTALL[INT_IDX]} curl wget sudo socat openssl
                if [[ $SYSTEM == "CentOS" ]]; then
                    ${PACKAGE_INSTALL[INT_IDX]} cronie
                    systemctl start crond && systemctl enable crond
                else
                    ${PACKAGE_INSTALL[INT_IDX]} cron
                    systemctl start cron && systemctl enable cron
                fi
                
                curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
                source ~/.bashrc || true
                
                local acme_cmd="/root/.acme.sh/acme.sh"
                "$acme_cmd" --upgrade --auto-upgrade
                "$acme_cmd" --set-default-ca --server letsencrypt
                
                if [[ "$vps_ip" =~ ":" ]]; then
                    "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
                else
                    "$acme_cmd" --issue -d "${domain}" --standalone -k ec-256 --insecure
                fi
                
                "$acme_cmd" --install-cert -d "${domain}" --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
                
                if [[ -f /root/cert.crt && -f /root/private.key ]]; then
                    echo "$domain" > /root/ca.log
                    sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1 || true
                    echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab
                    info "证书申请成功！已保存到 /root 目录下。"
                    hy_domain=$domain
                else
                    error "Acme 证书申请失败，切换回自签模式。"
                    certInput=1
                fi
            else
                error "当前域名解析的 IP [$domainIP] 与当前 VPS 的真实公网 IP [$vps_ip] 不匹配！"
                return 1
            fi
        fi
    elif [[ $certInput == 3 ]]; then
        read -rp "请输入公钥文件 crt 的路径: " cert_path
        read -rp "请输入密钥文件 key 的路径: " key_path
        read -rp "请输入证书对应的域名: " domain
        hy_domain=$domain
    fi

    if [[ $certInput == 1 ]]; then
        info "将使用必应自签证书作为 Hysteria 2 的节点证书"
        mkdir -p /etc/hysteria
        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"
        openssl ecparam -genkey -name prime256v1 -out "$key_path"
        openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
        chmod 644 "$cert_path" "$key_path"
        hy_domain="www.bing.com"
        domain="www.bing.com"
    fi
}

# ================== 端口与跳跃配置 ==================
inst_port() {
    local default_port
    if [[ -f "$HY_CONFIG" ]]; then
        default_port=$(grep -E '^listen:' "$HY_CONFIG" | awk -F ':' '{print $3}' | tr -d ' ')
    else
        default_port=""
    fi

    local prompt_msg="设置 Hysteria 2 主端口 [1-65535] (回车随机分配): "
    [[ -n "$default_port" ]] && prompt_msg="设置 Hysteria 2 主端口 [当前: ${default_port}, 回车不修改]: "

    while true; do
        read -rp "$prompt_msg" port
        if [[ -z "$port" ]]; then
            if [[ -n "$default_port" ]]; then
                port="$default_port"
                break
            else
                port=$(get_random_port)
                info "已为您随机分配未被占用端口: $port"
                break
            fi
        elif is_valid_port "$port"; then
            if [[ "$port" != "$default_port" ]] && ! check_port "$port"; then
                error "端口 ${port} 已被其它程序占用，请更换。"
                continue
            fi
            break
        else
            error "请输入有效的端口数字 (1-65535)"
        fi
    done

    echo "---------------------------------------------"
    echo -e "Hysteria 2 端口群使用模式："
    echo -e " 1) 单端口模式"
    echo -e " 2) 端口跳跃模式 (IPTables 转发端口群) ${YELLOW}（默认)${RESET}"
    echo "---------------------------------------------"
    local jumpInput
    read -rp "请选择端口模式 [1-2] (默认2): " jumpInput
    jumpInput=${jumpInput:-2}

    iptables -t nat -F PREROUTING >/dev/null 2>&1 || true
    ip6tables -t nat -F PREROUTING >/dev/null 2>&1 || true

    if [[ $jumpInput == 2 ]]; then
        while true; do
            read -rp "设置起始端口 (建议10000-65535): " firstport
            read -rp "设置末尾端口 (必须大于起始端口): " endport
            if is_valid_port "$firstport" && is_valid_port "$endport" && [[ $firstport -lt $endport ]]; then
                break
            else
                error "输入无效，起始端口必须小于末尾端口，请重新输入。"
            fi
        done

        iptables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":$port"
        ip6tables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":$port"
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
        info "已成功配置端口跳跃规则: $firstport-$endport -> $port"
    else
        firstport=""
        endport=""
        info "将继续使用单端口模式"
    fi
}

# ================== 写入与输出配置文件 ==================
write_and_show_config() {
    local HOSTNAME
    HOSTNAME=$(hostname -s | sed 's/ /_/g')
    
    local vps_ip
    vps_ip=$(check_warp_and_get_ip)

    cat << EOF > /etc/hysteria/config.yaml
listen: :$port

tls:
  cert: $cert_path
  key: $key_path

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: $auth_pwd

masquerade:
  type: proxy
  proxy:
    url: https://$proxysite
    rewriteHost: true
EOF

    local last_port
    if [[ -n "${firstport}" ]]; then
        last_port="$port,$firstport-$endport"
    else
        last_port=$port
    fi

    local last_ip="$vps_ip"
    [[ "$vps_ip" =~ ":" ]] && last_ip="[$vps_ip]"

    mkdir -p "$HY_DIR"
    
    cat << EOF > "$HY_DIR/hy-client.yaml"
server: $last_ip:$last_port
auth: $auth_pwd
tls:
  sni: $hy_domain
  insecure: true
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
fastOpen: true
socks5:
  listen: 127.0.0.1:5678
transport:
  udp:
    hopInterval: 30s 
EOF

    cat << EOF > "$HY_DIR/hy-client.json"
{
  "server": "$last_ip:$last_port",
  "auth": "$auth_pwd",
  "tls": {
    "sni": "$hy_domain",
    "insecure": true
  },
  "quic": {
    "initStreamReceiveWindow": 16777216,
    "maxStreamReceiveWindow": 16777216,
    "initConnReceiveWindow": 33554432,
    "maxConnReceiveWindow": 33554432
  },
  "socks5": {
    "listen": "127.0.0.1:5678"
  },
  "transport": {
    "udp": {
      "hopInterval": "30s"
    }
  }
}
EOF

    cat << EOF > "$HY_DIR/url.txt"
V2rayN / Necro:
hysteria2://$auth_pwd@$last_ip:$port?insecure=1&sni=$hy_domain#$HOSTNAME
Surge / Shadowrocket:
$HOSTNAME = hysteria2, $last_ip, $port, password=$auth_pwd, skip-cert-verify=true, sni=$hy_domain
EOF

    systemctl daemon-reload
    systemctl enable hysteria-server >/dev/null 2>&1 || true
    systemctl restart hysteria-server >/dev/null 2>&1 || true

    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        info "Hysteria 2 服务配置并启动成功！"
    else
        error "Hysteria 2 服务启动失败，请检查状态。"
    fi
    showconf
}

# ================== 核心功能模块 ==================
insthysteria() {
    info "正在安装必要系统依赖..."
    if [[ ! ${SYSTEM} == "CentOS" ]]; then
        ${PACKAGE_UPDATE[INT_IDX]} >/dev/null 2>&1 || true
    fi
    ${PACKAGE_INSTALL[INT_IDX]} curl wget sudo qrencode procps iptables iptables-persistent netfilter-persistent >/dev/null 2>&1 || true

    info "正在下载官方 AZHysteria2 核心组件..."
    wget -N https://raw.githubusercontent.com/sistarry/toolbox/main/PROXY/AZHysteria2.sh >/dev/null 2>&1 || true
    bash AZHysteria2.sh || true
    rm -f AZHysteria2.sh

    if [[ ! -f "$HY_BINARY" ]]; then
        error "Hysteria 2 核心安装失败，请检查网络。"
        return 1
    fi

    # 显式全局变量初始化，阻断未定义报错
    firstport=""
    endport=""

    inst_cert || return 1
    inst_port
    
    read -rp "设置 Hysteria 2 验证密码 (回车自动分配随机密码): " auth_pwd
    auth_pwd=${auth_pwd:-$(date +%s%N | md5sum | cut -c 1-8)}
    
    read -rp "请输入 Hysteria 2 的伪装网站地址 (默认: en.snu.ac.kr): " proxysite
    proxysite=${proxysite:-"en.snu.ac.kr"}

    write_and_show_config
}

unsthysteria() {
    warn "即将从当前系统中彻底卸载 Hysteria 2"
    read -rp "确认卸载吗？[y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    systemctl stop hysteria-server >/dev/null 2>&1 || true
    systemctl disable hysteria-server >/dev/null 2>&1 || true
    rm -f /lib/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server@.service
    rm -rf /usr/local/bin/hysteria /etc/hysteria "$HY_DIR"
    
    iptables -t nat -F PREROUTING >/dev/null 2>&1 || true
    ip6tables -t nat -F PREROUTING >/dev/null 2>&1 || true
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    info "Hysteria 2 已彻底卸载！"
}

# ================== 修改配置功能 ==================
changeconf() {
    if [[ ! -f "$HY_CONFIG" ]]; then
        error "配置文件不存在，请先安装 Hysteria 2"
        return 1
    fi

    local old_port old_pwd old_cert old_key old_site old_sni
    old_port=$(grep -E '^listen:' "$HY_CONFIG" | awk -F ':' '{print $3}' | tr -d ' ')
    old_pwd=$(grep -E '^\s*password:' "$HY_CONFIG" | awk '{print $2}' | tr -d '"'\')
    old_cert=$(grep -E '^\s*cert:' "$HY_CONFIG" | awk '{print $2}' | tr -d '"'\')
    old_key=$(grep -E '^\s*key:' "$HY_CONFIG" | awk '{print $2}' | tr -d '"'\')
    old_site=$(grep -E '^\s*url:' "$HY_CONFIG" | awk '{print $2}' | sed 's#https://##' | tr -d '"'\')
    
    if [[ -f "$HY_DIR/hy-client.yaml" ]]; then
        old_sni=$(grep -E '^\s*sni:' "$HY_DIR/hy-client.yaml" | awk '{print $2}' | tr -d '"'\')
    else
        old_sni="www.bing.com"
    fi

    clear
    echo -e "${GREEN}====== 修改 Hysteria 2 配置 ======${RESET}"
    echo "提示：直接敲回车将保持原有配置不变"
    echo "---------------------------------------------"
    
    firstport=""
    endport=""
    inst_port 

    local auth_pwd
    read -rp "设置 Hysteria 2 密码 [当前: ${old_pwd}, 回车不修改]: " auth_pwd
    auth_pwd=${auth_pwd:-$old_pwd}

    local cert_path key_path hy_domain domain
    echo "---------------------------------------------"
    read -rp "是否需要修改证书？[y/N] (直接回车默认不修改): " change_cert_flag
    if [[ "$change_cert_flag" == "y" || "$change_cert_flag" == "Y" ]]; then
        inst_cert || return 1
    else
        cert_path="$old_cert"
        key_path="$old_key"
        hy_domain="$old_sni"
    fi

    local proxysite
    echo "---------------------------------------------"
    read -rp "请输入新的伪装网站地址 [当前: ${old_site}, 回车不修改]: " proxysite
    proxysite=${proxysite:-$old_site}

    cp "$HY_CONFIG" "${HY_CONFIG}.bak.$(date +%s)"
    write_and_show_config
    info "配置修改并应用成功！"
}

showconf() {
    if [[ ! -d "$HY_DIR" ]]; then
        error "未找到客户端配置文件。"
        return
    fi
    echo -e "${GREEN}====== 客户端 YAML 配置 (hy-client.yaml) ======${RESET}"
    cat "$HY_DIR/hy-client.yaml"
    echo
    echo -e "${GREEN}====== 节点分享链接 ======${RESET}"
    cat "$HY_DIR/url.txt"
    echo
}

# ================== 主菜单 ==================
menu() {
    while true; do
        clear
        local status version port_show
        status=$(get_hy_status)
        version=$(get_hy_version)
        port_show=$(get_current_port_display)

        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}      Hysteria 2 管理面板       ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "状态   : $status"
        echo -e "版本   : ${YELLOW}${version}${RESET}"
        echo -e "端口   : ${YELLOW}${port_show}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}1. 安装 Hysteria 2${RESET}"
        echo -e "${GREEN}2. 卸载 Hysteria 2${RESET}"
        echo -e "${GREEN}3. 启动 Hysteria 2${RESET}"
        echo -e "${GREEN}4. 关闭 Hysteria 2${RESET}"
        echo -e "${GREEN}5. 重启 Hysteria 2${RESET}"
        echo -e "${GREEN}6. 修改配置${RESET}"
        echo -e "${GREEN}7. 查看配置${RESET}"
        echo -e "${GREEN}0. 退出${RESET}"
        echo -e "${GREEN}================================${RESET}"

        local choice=""
        read -r -p $'\033[32m请输入选项: \033[0m' choice || true
        [[ -z "$choice" ]] && continue

        case "$choice" in
            1) insthysteria; pause ;;
            2) unsthysteria; pause ;;
            3) systemctl start hysteria-server && info "服务已成功启动！"; pause ;;
            4) systemctl stop hysteria-server && info "服务已成功停止！"; pause ;;
            5) systemctl restart hysteria-server && info "服务已成功重启！"; pause ;;
            6) changeconf; pause ;;
            7) showconf; pause ;;
            0) exit 0 ;;
            *) error "无效输入，请选择正确的菜单项。"; sleep 1 ;;
        esac
    done
}

menu "$@"
