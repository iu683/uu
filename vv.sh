#!/bin/bash
set -e

DNS1="100.100.2.136"
DNS2="100.100.2.138"
FDNS1="8.8.8.8"
FDNS2="1.1.1.1"

echo "===== DNS 自动配置脚本 ====="
echo "正在检测系统环境..."

# 检测是否存在 systemd-resolved
if systemctl list-unit-files 2>/dev/null | grep -q systemd-resolved; then
    echo "检测到 systemd-resolved，使用 resolved 模式"

    mkdir -p /etc/systemd

    cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak 2>/dev/null || true

    cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=$DNS1 $DNS2
FallbackDNS=$FDNS1 $FDNS2
EOF

    systemctl restart systemd-resolved

    # 确保 resolv.conf 正确链接
    if [ -L /etc/resolv.conf ]; then
        echo "resolv.conf 已是符号链接"
    else
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi

else
    echo "未检测到 systemd-resolved，使用 resolv.conf 模式"

    cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true

    cat > /etc/resolv.conf <<EOF
nameserver $DNS1
nameserver $DNS2
nameserver $FDNS1
nameserver $FDNS2
EOF

    echo "是否锁定 resolv.conf 防止被 DHCP 覆盖？(y/n)"
    read LOCK

    if [[ "$LOCK" == "y" || "$LOCK" == "Y" ]]; then
        chattr +i /etc/resolv.conf 2>/dev/null || echo "锁定失败（可能不支持 chattr）"
        echo "已锁定 /etc/resolv.conf"
    fi
fi

echo
echo "===== 当前 DNS 状态 ====="
if command -v resolvectl >/dev/null 2>&1; then
    resolvectl status | grep "DNS Servers" -A2 || true
fi

echo
cat /etc/resolv.conf
echo "===== 配置完成 ====="
