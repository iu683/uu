#!/bin/bash
# ========================================
# CoreDNS 管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

APP_DIR="/etc/coredns"
BIN="/usr/local/bin/coredns"
SERVICE="/etc/systemd/system/coredns.service"

install_coredns() {

echo -e "${GREEN}开始安装 CoreDNS...${RESET}"

apt update -y
apt install -y wget jq tar dnsutils

COREDNS_VERSION=$(wget -qO- https://api.github.com/repos/coredns/coredns/releases/latest | jq -r '.tag_name')
COREDNS_N_VERSION=${COREDNS_VERSION:1}

cd /tmp
wget -q https://github.com/coredns/coredns/releases/download/${COREDNS_VERSION}/coredns_${COREDNS_N_VERSION}_linux_amd64.tgz

tar zxf coredns_${COREDNS_N_VERSION}_linux_amd64.tgz

chmod +x coredns
mv coredns $BIN

mkdir -p $APP_DIR
mkdir -p /var/log/coredns

cat > $APP_DIR/Corefile <<EOF
.:8053 {
    bind 0.0.0.0
    forward . 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 {
        max_concurrent 1000
    }
    cache 300 {
        prefetch 10 60s
    }
    errors
    log
    reload
}
EOF

cat > $SERVICE <<EOF
[Unit]
Description=CoreDNS
After=network.target

[Service]
ExecStart=$BIN -conf $APP_DIR/Corefile
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable coredns
systemctl restart coredns

echo -e "${GREEN}CoreDNS 安装完成 ✔${RESET}"
echo -e "${YELLOW}http://127.0.0.1:8053${RESET}"
}

start_coredns() {
systemctl start coredns
echo -e "${GREEN}CoreDNS 已启动${RESET}"
}

stop_coredns() {
systemctl stop coredns
echo -e "${YELLOW}CoreDNS 已停止${RESET}"
}

restart_coredns() {
systemctl restart coredns
echo -e "${GREEN}CoreDNS 已重启${RESET}"
}

status_coredns() {
systemctl status coredns --no-pager
}

test_dns() {

if ! command -v dig &>/dev/null; then
apt install dnsutils -y
fi

echo
echo -e "${GREEN}DNS 测试:${RESET}"
dig @127.0.0.1 -p 8053 google.com +short
}

uninstall_coredns() {

echo -e "${RED}开始卸载 CoreDNS...${RESET}"

systemctl stop coredns
systemctl disable coredns

rm -f $SERVICE
rm -f $BIN
rm -rf $APP_DIR
rm -rf /var/log/coredns

systemctl daemon-reload

echo -e "${GREEN}CoreDNS 已卸载 ✔${RESET}"
}

menu() {

clear
echo -e "${GREEN}==================================${RESET}"
echo -e "${GREEN}        CoreDNS 管理菜单          ${RESET}"
echo -e "${GREEN}==================================${RESET}"
echo -e "${GREEN}1.安装 CoreDNS${RESET}"
echo -e "${GREEN}2.启动 CoreDNS${RESET}"
echo -e "${GREEN}3.停止 CoreDNS${RESET}"
echo -e "${GREEN}4.重启 CoreDNS${RESET}"
echo -e "${GREEN}5.查看状态${RESET}"
echo -e "${GREEN}6.测试 DNS${RESET}"
echo -e "${GREEN}7.卸载 CoreDNS${RESET}"
echo -e "${GREEN}0.退出${RESET}"
read -rp $'\033[32m请输入选项: \033[0m' choice

case $choice in
1) install_coredns ;;
2) start_coredns ;;
3) stop_coredns ;;
4) restart_coredns ;;
5) status_coredns ;;
6) test_dns ;;
7) uninstall_coredns ;;
0) exit ;;
*) echo -e "${RED}无效选项${RESET}" ;;
esac

read -rp "按回车返回菜单..."
menu
}

menu
