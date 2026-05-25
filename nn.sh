#!/bin/bash

set -euo pipefail

SCRIPT_VERSION="SINGBOX-VLESS-HTTPUPGRADE-1.0"

config_path="/etc/sing-box/config.json"
binary_path="/usr/local/bin/sing-box"

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
cyan='\e[96m'
none='\e[0m'

status_info=""
ws_path="/"
ws_host=""

error(){ echo -e "\n$red[✖] $1$none\n"; }
info(){ echo -e "\n$yellow[!] $1$none\n"; }
success(){ echo -e "\n$green[✔] $1$none\n"; }

get_public_ip(){

for url in api.ipify.org ip.sb checkip.amazonaws.com
do
ip=$(curl -s --max-time 5 $url)
[ -n "$ip" ] && echo "$ip" && return
done

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

[[ $(id -u) != 0 ]] && error "请用root运行" && exit 1

deps=(jq curl wget uuidgen)

for cmd in "${deps[@]}"
do
if ! command -v $cmd >/dev/null 2>&1
then
info "安装依赖 $cmd"
apt update -y
apt install -y jq curl wget uuid-runtime
break
fi
done

mkdir -p /etc/sing-box

}

install_core(){

info "安装/更新 sing-box 最新版..."

arch=$(uname -m)

case "$arch" in
x86_64|amd64)
    sb_arch="amd64"
    ;;
aarch64|arm64)
    sb_arch="arm64"
    ;;
armv7l)
    sb_arch="armv7"
    ;;
*)
    error "不支持架构: $arch"
    exit 1
    ;;
esac

cd /tmp

# 获取最新稳定版版本号
latest_version=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | jq -r '.tag_name')

[ -z "$latest_version" ] && {
    error "获取最新版失败"
    exit 1
}

info "最新版本: $latest_version"

file_name="sing-box-${latest_version#v}-linux-${sb_arch}.tar.gz"
download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/${file_name}"

info "下载: $file_name"

wget -O singbox.tar.gz "$download_url" \
|| wget -O singbox.tar.gz \
"https://mirror.ghproxy.com/${download_url}"

rm -rf sing-box*

tar -xzf singbox.tar.gz

# 自动寻找解压目录
dir=$(find . -maxdepth 1 -type d -name "sing-box*" | head -n1)

[ -z "$dir" ] && {
    error "解压失败"
    exit 1
}

install -m 755 "$dir/sing-box" /usr/local/bin/sing-box

rm -rf singbox.tar.gz "$dir"

# systemd
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1

success "sing-box ${latest_version} 安装/更新完成"

}

check_status(){

if [ ! -f "$binary_path" ]; then
    status_info="Sing-box: 未安装"
    return
fi

# 获取版本
version=$($binary_path version 2>/dev/null | head -n1 | awk '{print $3}')

if systemctl is-active --quiet sing-box
then
    status_info="Sing-box: 运行中 | 版本: ${version:-未知}"
else
    status_info="Sing-box: 未运行 | 版本: ${version:-未知}"
fi

}

write_config(){

port=$1
uuid=$2

jq -n \
--argjson port "$port" \
--arg uuid "$uuid" \
--arg path "$ws_path" \
--arg host "$ws_host" \
'{
log:{level:"warn"},
inbounds:[
{
type:"vless",
listen:"::",
listen_port:$port,
users:[{uuid:$uuid}],
transport:{
type:"httpupgrade",
path:$path,
host:$host
}
}
],
outbounds:[
{type:"direct"}
]
}' > "$config_path"

}

install_node(){

while true
do
read -p "端口 (默认8080): " port
[ -z "$port" ] && port=8080

is_valid_port "$port" || { error "端口无效"; continue; }

is_port_in_use "$port" && { error "端口占用"; continue; }

break
done

while true
do
read -p "UUID (留空自动生成): " uuid
[ -z "$uuid" ] && uuid=$(uuidgen)

is_valid_uuid "$uuid" && break || error "UUID格式错误"
done

read -p "HTTP Host (可选): " ws_host

read -p "Path (默认 /): " ws_path
[ -z "$ws_path" ] && ws_path="/"
[[ "$ws_path" != /* ]] && ws_path="/$ws_path"

install_core

write_config "$port" "$uuid"

systemctl restart sing-box

success "安装完成"

view_node

}

restart_core(){

systemctl restart sing-box
success "已重启"

}

update_core(){

rm -f /usr/local/bin/sing-box

install_core
systemctl restart sing-box

success "已更新到最新版"

}

uninstall_core(){

systemctl stop sing-box

rm -f /usr/local/bin/sing-box
rm -rf /etc/sing-box
rm -f /etc/systemd/system/sing-box.service

systemctl daemon-reload

success "已卸载"

}

view_log(){

journalctl -u sing-box -f

}

modify_config(){

[ ! -f "$config_path" ] && error "配置不存在" && return

port=$(jq -r '.inbounds[0].listen_port' $config_path)
uuid=$(jq -r '.inbounds[0].users[0].uuid' $config_path)
path=$(jq -r '.inbounds[0].transport.path' $config_path)
host=$(jq -r '.inbounds[0].transport.host // ""' $config_path)

echo "当前配置:"
echo "端口: $port"
echo "UUID: $uuid"
echo "Host: $host"
echo "Path: $path"
echo

read -p "新端口 (回车不改): " new_port
read -p "新UUID (回车不改): " new_uuid
read -p "新Host (回车不改): " new_host
read -p "新Path (回车不改): " new_path

[ -n "$new_port" ] && port=$new_port
[ -n "$new_uuid" ] && uuid=$new_uuid
[ -n "$new_host" ] && host=$new_host
[ -n "$new_path" ] && path=$new_path

[[ "$path" != /* ]] && path="/$path"

# 关键修复
ws_host="$host"
ws_path="$path"

write_config "$port" "$uuid"

systemctl restart sing-box

success "配置已更新"

view_node

}

view_node(){

ip=$(get_public_ip)

uuid=$(jq -r '.inbounds[0].users[0].uuid' $config_path)
port=$(jq -r '.inbounds[0].listen_port' $config_path)
path=$(jq -r '.inbounds[0].transport.path' $config_path)
host=$(jq -r '.inbounds[0].transport.host // ""' $config_path)

link="vless://$uuid@$ip:$port?type=httpupgrade&path=$path&host=$host&encryption=none#$(hostname)"

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

press_any_key(){
read -n1 -s -r -p "按任意键继续..."
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
echo "2. 更新"
echo "3. 重启"
echo "4. 卸载"
echo "5. 查看日志"
echo "6. 修改配置"
echo "7. 查看节点"
echo "0. 退出"
echo "--------------------------------"

read -p "请选择: " choice

case $choice in

1) install_node ;;
2) update_core ;;
3) restart_core ;;
4) uninstall_core ;;
5) view_log ;;
6) modify_config ;;
7) view_node ;;
0) exit ;;

*) error "无效选项" ;;

esac

press_any_key

done

}

main(){

pre_check
menu

}

main
