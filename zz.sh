#!/bin/bash
set -e

CONF="/etc/systemd/resolved.conf"

echo "正在配置 systemd-resolved DNS..."

# 备份原文件
if [ ! -f ${CONF}.bak ]; then
    sudo cp $CONF ${CONF}.bak
    echo "已备份原配置为 ${CONF}.bak"
fi

# 写入新的 DNS 配置
sudo sed -i '/^\[Resolve\]/,/^\[/{s/^DNS=.*/DNS=100.100.2.136 100.100.2.138/}' $CONF
sudo sed -i '/^\[Resolve\]/,/^\[/{s/^FallbackDNS=.*/FallbackDNS=8.8.8.8 1.1.1.1/}' $CONF

# 如果没有 DNS 字段则追加
if ! grep -q "^DNS=" $CONF; then
    sudo sed -i '/^\[Resolve\]/a DNS=100.100.2.136 100.100.2.138' $CONF
fi

if ! grep -q "^FallbackDNS=" $CONF; then
    sudo sed -i '/^\[Resolve\]/a FallbackDNS=8.8.8.8 1.1.1.1' $CONF
fi

# 重启服务
sudo systemctl restart systemd-resolved

echo "DNS 配置完成，当前状态："
resolvectl status | grep "DNS Servers" -A2

echo "检查 /etc/resolv.conf 内容："
cat /etc/resolv.conf
