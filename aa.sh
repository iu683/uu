#!/bin/bash

# 自动清理远程重复公钥 + 写入公钥 + 权限修复 + SSH 登录提示

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 读取用户输入
read -p "$(echo -e ${GREEN}请输入远程用户名:${NC} ) " username
read -p "$(echo -e ${GREEN}请输入远程服务器IP:${NC} ) " ip_address
read -p "$(echo -e ${GREEN}请输入SSH端口（默认22）:${NC} ) " port
port=${port:-22}

# 检查并生成本地公钥
LOCAL_KEY="$HOME/.ssh/id_rsa.pub"
if [ ! -f "$LOCAL_KEY" ]; then
    echo -e "${YELLOW}未检测到本地公钥，正在生成新的 SSH 密钥对...${NC}"
    mkdir -p ~/.ssh
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 密钥生成失败，请检查 ssh-keygen 是否可用${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ SSH 密钥生成完成: $LOCAL_KEY${NC}"
else
    echo -e "${GREEN}✅ 已检测到本地公钥: $LOCAL_KEY${NC}"
fi

PUBKEY_CONTENT=$(cat "$LOCAL_KEY")

echo -e "${YELLOW}⚠️ 第一次连接需要输入远程密码进行操作${NC}"

# 一次性远程执行：创建目录 -> 追加入公钥 -> 全局去重 -> 修复权限
ssh -p $port $username@$ip_address "bash -s" <<EOF
    # 创建并保护 .ssh 目录
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    
    # 备份原始文件
    cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak

    # 先将新公钥追加到备份文件中（如果不存在的话）
    if ! grep -Fxq "$PUBKEY_CONTENT" ~/.ssh/authorized_keys.bak; then
        echo "$PUBKEY_CONTENT" >> ~/.ssh/authorized_keys.bak
    fi

    # 利用 awk 对包含新公钥的文件进行全局去重，并写回正式文件
    awk '!seen[\$0]++' ~/.ssh/authorized_keys.bak > ~/.ssh/authorized_keys
    rm -f ~/.ssh/authorized_keys.bak

    # 严格修复权限
    chmod 600 ~/.ssh/authorized_keys
    chown \$(whoami):\$(id -gn) ~/.ssh ~/.ssh/authorized_keys
    
    echo "远程配置完成。"
EOF

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ 远程操作失败，请检查网络连接、密码或端口是否正确。${NC}"
    exit 1
fi

---

# 显示远程 authorized_keys 供确认（此时应该已经是免密读取了）
echo -e "\n${YELLOW}📂 远程服务器上的 authorized_keys 现状:${NC}"
ssh -p $port $username@$ip_address "cat ~/.ssh/authorized_keys"

# 最后提示 SSH 登录命令
echo -e "\n${GREEN}✅ 操作完成！公钥已成功写入并去重。${NC}"
echo -e "${YELLOW}➡️ 你现在可以使用以下命令免密登录远程服务器:${NC}"
echo -e "${GREEN}ssh -p $port $username@$ip_address${NC}"
