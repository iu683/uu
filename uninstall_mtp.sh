#!/bin/bash

RED="\e[1;91m"
GREEN="\e[1;32m"
RESET="\e[0m"

red() { echo -e "${RED}$1${RESET}"; }
green() { echo -e "${GREEN}$1${RESET}"; }

WORKDIR="$HOME/mtp"
SERVICE_NAME="mtp.service"

green "停止 MTProto systemd 服务..."
sudo systemctl stop $SERVICE_NAME 2>/dev/null || true
sudo systemctl disable $SERVICE_NAME 2>/dev/null || true
sudo rm -f /etc/systemd/system/$SERVICE_NAME
sudo systemctl daemon-reload

green "杀掉运行中的 mtg 进程..."
pkill -9 mtg 2>/dev/null || true

green "删除安装目录 $WORKDIR ..."
rm -rf "$WORKDIR"

green "✅ MTProto 已卸载完成"
