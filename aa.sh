#!/bin/bash

wget -O vless-server.sh https://raw.githubusercontent.com/Zyx0rx/vless-all-in-one/main/vless-server.sh
chmod +x vless-server.sh

echo "自动输入 1，后续手动操作..."

printf "1\n" | ./vless-server.sh
