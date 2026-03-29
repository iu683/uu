#!/bin/bash

set -euo pipefail

readonly SCRIPT_VERSION="SINGBOX-VLESS-HTTPUPGRADE-1.0"
readonly config_path="/etc/sing-box/config.json"

readonly red='\e[91m'
readonly green='\e[92m'
readonly yellow='\e[93m'
readonly cyan='\e[96m'
readonly none='\e[0m'

status_info=""
ws_path=""
ws_host=""

error(){ echo -e "\n$red[✖] $1$none\n"; }
info(){ echo -e "\n$yellow[!] $1$none\n"; }
success(){ echo -e "\n$green[✔] $1$none\n"; }

generate_path(){
ws_path="/$(tr -dc a-z0-9 </dev/urandom | head -c 8)"
}

get_public_ip(){
curl -s https://api.ipify.org || curl -s https://ip.sb
}

pre_check(){

[[ $(id -u) != 0 ]] && error "请用root运行" && exit 1

apt update -y
apt install -y jq curl qrencode wget

mkdir -p /etc/sing-box

}

install_singbox(){

info "安装 sing-box..."

cd /tmp

wget -qO sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.13.0/sing-box-1.13.0-linux-amd64.tar.gz

tar -zxf sing-box.tar.gz

install -m 755 sing-box-1.13.0-linux-amd64/sing-box /usr/local/bin/sing-box

rm -rf sing-box*

cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box

success "sing-box 安装完成"

}

write_config(){

local port=$1
local uuid=$2

cat > $config_path <<EOF
{
"log":{
"level":"warn"
},
"inbounds":[
{
"type":"vless",
"listen":"::",
"listen_port":$port,
"users":[
{
"uuid":"$uuid"
}
],
"transport":{
"type":"httpupgrade",
"path":"$ws_path",
"host":"$ws_host"
}
}
],
"outbounds":[
{
"type":"direct"
}
]
}
EOF

}

install_node(){

local port
local uuid

read -p "端口 (默认8080): " port
[ -z "$port" ] && port=8080

uuid=$(cat /proc/sys/kernel/random/uuid)

generate_path

read -p "Host (可选): " ws_host

install_singbox

write_config "$port" "$uuid"

systemctl restart sing-box

success "节点部署完成"

view_node

}

restart_service(){

systemctl restart sing-box

success "服务已重启"

}

view_log(){

journalctl -u sing-box -f

}

uninstall_node(){

systemctl stop sing-box
rm -f /usr/local/bin/sing-box
rm -rf /etc/sing-box
rm -f /etc/systemd/system/sing-box.service

systemctl daemon-reload

success "已卸载"

}

view_node(){

local ip=$(get_public_ip)

local uuid=$(jq -r '.inbounds[0].users[0].uuid' $config_path)
local port=$(jq -r '.inbounds[0].listen_port' $config_path)
local path=$(jq -r '.inbounds[0].transport.path' $config_path)
local host=$(jq -r '.inbounds[0].transport.host // ""' $config_path)

link="vless://$uuid@$ip:$port?type=httpupgrade&path=$path&host=$host&encryption=none#$(hostname)"

echo
echo "--------------------------------"
echo -e "${green}VLESS HTTPUpgrade 节点${none}"
echo "地址: $ip"
echo "端口: $port"
echo "UUID: $uuid"
echo "Host: $host"
echo "Path: $path"
echo
echo "$link"
echo "--------------------------------"

}

press_key(){

read -n1 -s -r -p "按任意键继续..."

}

check_status(){

if systemctl is-active --quiet sing-box
then
status_info="sing-box: 运行中"
else
status_info="sing-box: 未运行"
fi

}

menu(){

while true
do

clear

check_status

echo "--------------------------------"
echo "Sing-box VLESS+HTTPUpgrade 管理"
echo "--------------------------------"
echo "$status_info"
echo "--------------------------------"
echo "1. 安装节点"
echo "2. 重启服务"
echo "3. 查看节点"
echo "4. 查看日志"
echo "5. 卸载"
echo "0. 退出"
echo "--------------------------------"

read -p "请选择: " choice

case $choice in

1) install_node ;;
2) restart_service ;;
3) view_node ;;
4) view_log ;;
5) uninstall_node ;;
0) exit ;;
*) error "无效选项" ;;

esac

press_key

done

}

main(){

pre_check
menu

}

main
