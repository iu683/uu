#!/bin/bash

# 定义配置文件路径
CONFIG_FILE="/opt/lxdapi/configs/config.yaml"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 获取公网 IP 的函数
get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://checkip.amazonaws.com" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "127.0.0.1"
}

# 增强型提取函数：专门提取 admin 块下的字段
get_admin_val() {
    local key=$1
    # 查找 admin: 之后的内容，直到找到目标 key
    sed -n '/admin:/,/plugins:/p' "$CONFIG_FILE" | grep "$key:" | awk -F': ' '{print $2}' | tr -d '"' | tr -d "'" | xargs
}

# 提取 YAML 字段的辅助函数 (简单正则提取)
get_yaml_val() {
    local key=$1
    # 匹配 key: value 格式，去掉引号和多余空格
    grep "$key:" "$CONFIG_FILE" | head -n 1 | awk -F': ' '{print $2}' | tr -d '"' | tr -d "'" | xargs
}

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}错误: 配置文件 $CONFIG_FILE 不存在！${NC}"
    exit 1
fi

# 开始提取信息
SERVER_IP=$(get_public_ip)
PORT=$(get_yaml_val "port")
API_HASH=$(get_yaml_val "api_hash")
USER=$(get_admin_val "username")
PASS=$(get_admin_val "password")
TLS_ENABLED=$(get_yaml_val "enabled")

# 协议判断
PROTOCOL="http"
[[ "$TLS_ENABLED" == "true" ]] && PROTOCOL="https"

echo -e "${YELLOW}================ LXDAPI 管理信息 ==================${NC}"
echo -e "${GREEN}管理面板地址:${NC} ${PROTOCOL}://${SERVER_IP}:${PORT}/admin/login"
echo -e "${GREEN}管理员账号:${NC}   ${USER}"
echo -e "${GREEN}管理员密码:${NC}   ${PASS}"
echo -e "--------------------------------------------------"
echo -e "${GREEN}系统 API 密钥:${NC} ${API_HASH}"
echo -e "${GREEN}数据存储目录:${NC} /opt/lxdapi"
echo -e "${GREEN}文档财务对接地址:${NC} https://github.com/xkatld/lxdapi-web-server/wiki"
echo -e "${YELLOW}===================================================${NC}"
