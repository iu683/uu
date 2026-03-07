#!/bin/sh

# ===============================
# 颜色定义
# ===============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW="\033[33m"
NC='\033[0m'

# ===============================
# 清理 UDP 跳跃规则
# ===============================
remove_udp_jump() {
    echo "清理 UDP 端口跳跃规则..."
    SERVER_IP=$(ip -4 addr show | awk '/inet/ && $2 !~ /^127/ {split($2,a,"/"); print a[1]; exit}')

    # 遍历保存的规则，安全删除
    for rule in $(iptables-save | grep "DNAT" | grep "$SERVER_IP" | awk '{print $0}'); do
        # 先把 -A 替换成 -D
        del_rule=$(echo "$rule" | sed 's/^-A /-D /')
        # 用 eval 执行，失败也不报错
        eval iptables $del_rule 2>/dev/null || true
    done

    for rule in $(iptables-save | grep "FORWARD" | grep "$SERVER_IP" | awk '{print $0}'); do
        del_rule=$(echo "$rule" | sed 's/^-A /-D /')
        eval iptables $del_rule 2>/dev/null || true
    done

    # 删除保存文件
    rm -f /etc/iptables.rules
    echo "✅ UDP 端口跳跃规则已清理"
}


# ===============================
# 卸载函数
# ===============================
uninstall_hy2() {
    echo "正在卸载 Hysteria2..."
    rc-service hysteria stop 2>/dev/null
    rc-update del hysteria default 2>/dev/null
    rm -f /etc/init.d/hysteria /usr/local/bin/hysteria
    rm -rf /etc/hysteria
    rm -f /var/log/hysteria.log /var/log/hysteria.err
    # 删除 UDP 端口跳跃规则
    remove_udp_jump
    echo "卸载完成！"
    exit 0
}

ACTION=$1
if [ "$ACTION" = "uninstall" ]; then
    uninstall_hy2
fi

# ===============================
# 安装依赖
# ===============================
apk update && apk add curl ca-certificates openssl openrc iptables

# ===============================
# 识别架构
# ===============================
ARCH=$(uname -m)
case $ARCH in
    x86_64)  BIN_ARCH="amd64" ;;
    aarch64) BIN_ARCH="arm64" ;;
    armv7l)  BIN_ARCH="arm" ;;
    *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

# ===============================
# 下载 Hysteria2
# ===============================
REMOTE_VERSION=$(curl -sSL https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
echo "正在获取 Hysteria2 最新版本: $REMOTE_VERSION"

curl -fSL "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-$BIN_ARCH" -o /usr/local/bin/hysteria.new
if [ $? -eq 0 ]; then
    rc-service hysteria stop 2>/dev/null
    mv /usr/local/bin/hysteria.new /usr/local/bin/hysteria
    chmod +x /usr/local/bin/hysteria
else
    echo "下载失败"; exit 1
fi

mkdir -p /etc/hysteria

# ===============================
# 配置逻辑
# ===============================
if [ "$ACTION" = "update" ] && [ -f "/etc/hysteria/config.yaml" ]; then
    echo -e "${GREEN}检测到 update 命令，保留原配置更新程序...${NC}"
    HY_PASSWORD=$(grep 'password:' /etc/hysteria/config.yaml | awk '{print $2}')
    HY_PORT=$(grep 'listen:' /etc/hysteria/config.yaml | cut -d':' -f3)
else
    echo -e "${RED}执行安装${NC}"
    read -p "请输入 Hysteria2 端口 (默认: 57891): " HY_PORT
    [ -z "$HY_PORT" ] && HY_PORT=57891

    echo "使用端口: $HY_PORT"

    # 生成证书
    openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -subj "/CN=www.bing.com" -days 3650 2>/dev/null

    # 生成密码
    HY_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 25)

    # 写入配置
    cat <<EOC > /etc/hysteria/config.yaml
listen: :$HY_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $HY_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true
EOC
fi

# ===============================
# 服务配置
# ===============================
cat <<EOS > /etc/init.d/hysteria
#!/sbin/openrc-run
name="hysteria2"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.err"
depend() { need net; }
EOS

chmod +x /etc/init.d/hysteria
rc-update add hysteria default 2>/dev/null
rc-service hysteria restart

# ===============================
# UDP 端口跳跃函数
# ===============================
add_udp_jump() {
    JUMP_START=$1
    JUMP_END=$2

    if [ -z "$JUMP_START" ] || [ -z "$JUMP_END" ]; then
        echo -e "${RED}未指定端口范围，跳跃规则未添加${NC}"
        return
    fi

    SERVER_IP=$(ip -4 addr show | awk '/inet/ && $2 !~ /^127/ {split($2,a,"/"); print a[1]; exit}')
    echo -e "${YELLOW}添加 UDP 端口跳跃规则: $JUMP_START-$JUMP_END -> $HY_PORT${NC}"

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1

    # 删除旧规则
    while iptables -t nat -C PREROUTING -p udp --dport $JUMP_START:$JUMP_END -j DNAT --to-destination ${SERVER_IP}:$HY_PORT 2>/dev/null
    do
        iptables -t nat -D PREROUTING -p udp --dport $JUMP_START:$JUMP_END -j DNAT --to-destination ${SERVER_IP}:$HY_PORT
    done

    # 添加新规则
    iptables -t nat -I PREROUTING 1 -p udp --dport $JUMP_START:$JUMP_END -j DNAT --to-destination ${SERVER_IP}:$HY_PORT

    # 放行 FORWARD
    iptables -C FORWARD -p udp --dport $HY_PORT -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -p udp --dport $HY_PORT -j ACCEPT

    # 保存规则
    iptables-save > /etc/iptables.rules
    echo -e "${GREEN}✅ UDP 端口跳跃规则添加完成并保存${NC}"
}


# ===============================
# 设置开机自动恢复 iptables
# ===============================
cat <<'EOF' > /etc/local.d/udp_jump.start
#!/bin/sh
[ -f /etc/iptables.rules ] && iptables-restore < /etc/iptables.rules
EOF
chmod +x /etc/local.d/udp_jump.start
rc-update add local default 2>/dev/null

# ===============================
# 用户自定义端口跳跃
# ===============================
read -p "请输入 UDP 跳跃端口范围 (格式: 起始-结束, 例如 10000-20000, 不设置则跳过): " JUMP_RANGE
if [ -n "$JUMP_RANGE" ]; then
    JUMP_START=$(echo $JUMP_RANGE | cut -d'-' -f1)
    JUMP_END=$(echo $JUMP_RANGE | cut -d'-' -f2)
    add_udp_jump $JUMP_START $JUMP_END
else
    echo -e "${YELLOW}未设置 UDP 跳跃，跳过此步骤${NC}"
fi

# ===============================
# 输出节点信息
# ===============================
SERVER_IP=$(curl -s https://api.ipify.org || echo "YOUR_SERVER_IP")
HOSTNAME=$(hostname -s | sed 's/ /_/g')

echo "------------------------------------------------"
echo -e "${GREEN}Hysteria2 部署成功！${NC}"
echo "------------------------------------------------"

echo -e "${GREEN}==== v2rayN / Nekobox ====${NC}"
echo -e "${YELLOW}hysteria2://$HY_PASSWORD@$SERVER_IP:$HY_PORT/?insecure=1&sni=www.bing.com#$HOSTNAME${NC}"
echo ""

echo -e "${GREEN}==== Clash Meta ====${NC}"
echo -e "${YELLOW}{ name: $HOSTNAME, type: hysteria2, server: $SERVER_IP, port: $HY_PORT, password: $HY_PASSWORD, sni: www.bing.com, skip-cert-verify: true }${NC}"
echo ""

echo -e "${GREEN}==== Surge ====${NC}"
echo -e "${YELLOW}$HOSTNAME = hysteria2, $SERVER_IP, $HY_PORT, password=$HY_PASSWORD, sni=www.bing.com, skip-cert-verify=true${NC}"
echo "------------------------------------------------"
