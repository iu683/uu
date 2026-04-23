#!/bin/bash

# 1. 下载脚本
wget -O vless-server.sh https://raw.githubusercontent.com/Zyx0rx/vless-all-in-one/main/vless-server.sh

# 2. 赋予执行权限
chmod +x vless-server.sh

# 3. 自动化运行并输入 1 和 11
echo "2. 正在执行安装并自动提交参数 (1 和 11)..."
# \n 代表回车键
printf "1\n11" | ./vless-server.sh
