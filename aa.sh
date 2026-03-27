#!/bin/bash

set -euo pipefail

readonly SCRIPT_VERSION="VMESS-WS-1.0"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

readonly red='\e[91m'
readonly green='\e[92m'
readonly yellow='\e[93m'
readonly cyan='\e[96m'
readonly none='\e[0m'

xray_status_info=""
is_quiet=false
ws_path="/"

error(){ echo -e "\n$red[✖] $1$none\n"; }
info(){ echo -e "\n$yellow[!] $1$none\n"; }
success(){ echo -e "\n$green[✔] $1$none\n"; }

spinner(){
    local pid=$1
    local spin='|/-\'
    while kill -0 $pid 2>/dev/null; do
        for i in ${spin}; do
            printf "\r[%c] " "$i"
            sleep .1
        done
    done
}

get_public_ip(){
    curl -s https://api.ipify.org || curl -s https://ip.sb
}

is_valid_port(){
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_port_in_use(){
    ss -tuln | grep -q ":$1 "
}

is_valid_uuid(){
    [[ "$1" =~ ^[0-9a-fA-F-]{36}$ ]]
}

pre_check(){
    [[ $(id -u) != 0 ]] && error "请使用root运行" && exit 1

    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        apt update -y
        apt install -y jq curl
    fi
}

execute_official_script(){
    bash <(curl -L "$xray_install_script_url") "$@" &>/dev/null &
    spinner $!
}

check_xray_status(){
    if [[ ! -f "$xray_binary_path" ]]; then
        xray_status_info="Xray: 未安装"
        return
    fi

    local v=$($xray_binary_path version | head -n1 | awk '{print $2}')
    if systemctl is-active --quiet xray; then
        xray_status_info="Xray: 运行中 | $v"
    else
        xray_status_info="Xray: 未运行 | $v"
    fi
}

install_xray(){

    local port uuid

    while true; do
        read -p "端口 (默认443): " port
        [ -z "$port" ] && port=443

        is_valid_port "$port" || { error "端口无效"; continue; }
        is_port_in_use "$port" && { error "端口占用"; continue; }

        break
    done

    while true; do
        read -p "UUID (留空自动生成): " uuid
        [ -z "$uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid)

        is_valid_uuid "$uuid" && break || error "UUID格式错误"
    done

    read -p "WS Path (默认 /): " ws_path
    [ -z "$ws_path" ] && ws_path="/"
    [[ "$ws_path" != /* ]] && ws_path="/$ws_path"

    run_install "$port" "$uuid"
}

write_config(){

    local port=$1
    local uuid=$2

jq -n \
--argjson port "$port" \
--arg uuid "$uuid" \
--arg ws_path "$ws_path" \
'{
"log":{"loglevel":"warning"},
"inbounds":[
{
"listen":"0.0.0.0",
"port":$port,
"protocol":"vmess",
"settings":{
"clients":[
{
"id":$uuid,
"alterId":0
}
]
},
"streamSettings":{
"network":"ws",
"wsSettings":{
"path":$ws_path
}
},
"sniffing":{
"enabled":true,
"destOverride":["http","tls"]
}
}
],
"outbounds":[
{
"protocol":"freedom",
"settings":{
"domainStrategy":"UseIPv4v6"
}
}
]
}' > "$xray_config_path"
}

run_install(){

    local port=$1
    local uuid=$2

    info "安装 Xray..."
    execute_official_script install

    write_config "$port" "$uuid"

    systemctl enable xray
    systemctl restart xray

    success "安装完成"

    view_subscription_info
}

restart_xray(){
    systemctl restart xray
    success "Xray 已重启"
}

update_xray(){
    execute_official_script install
    restart_xray
}

uninstall_xray(){
    execute_official_script remove --purge
    success "已卸载"
}

view_xray_log(){
    journalctl -u xray -f
}

view_subscription_info(){

    local ip=$(get_public_ip)

    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$xray_config_path")

vmess_json=$(cat <<EOF
{
"v":"2",
"ps":"$(hostname)",
"add":"$ip",
"port":"$port",
"id":"$uuid",
"aid":"0",
"scy":"auto",
"net":"ws",
"type":"none",
"host":"",
"path":"$path",
"tls":""
}
EOF
)

vmess_link="vmess://$(echo -n "$vmess_json" | base64 -w0)"

echo "---------------------------------------"
echo -e "${green}VMESS WS 节点${none}"
echo "地址: $ip"
echo "端口: $port"
echo "UUID: $uuid"
echo "Path: $path"
echo
echo "$vmess_link"
echo "---------------------------------------"

echo "$vmess_link" > ~/xray_vmess_link.txt
}

press_any_key(){
read -n1 -s -r -p "按任意键继续..."
}

main_menu(){

while true
do
clear

check_xray_status

echo "--------------------------------"
echo "Xray VMESS WS 管理脚本"
echo "--------------------------------"
echo "$xray_status_info"
echo "--------------------------------"
echo "1. 安装 Xray (VMESS WS)"
echo "2. 更新 Xray"
echo "3. 重启 Xray"
echo "4. 卸载 Xray"
echo "5. 查看日志"
echo "6. 查看节点"
echo "0. 退出"
echo "--------------------------------"

read -p "请选择: " choice

case $choice in

1) install_xray ;;
2) update_xray ;;
3) restart_xray ;;
4) uninstall_xray ;;
5) view_xray_log ;;
6) view_subscription_info ;;
0) exit 0 ;;
*) error "无效选项" ;;

esac

press_any_key

done
}

main(){

pre_check
main_menu

}

main
