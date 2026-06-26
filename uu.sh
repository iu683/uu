#!/bin/sh
set -eu
APP="mini-sb-agent"
INSTALL_DIR="/opt/mini-sb-agent"
RUN_DIR="/run/mini-sb-agent"
SERVICE_NAME="mini-sb-agent"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME.service"
  systemctl daemon-reload 2>/dev/null || true
fi
if command -v rc-service >/dev/null 2>&1; then
  rc-service "$SERVICE_NAME" stop 2>/dev/null || true
  rc-update del "$SERVICE_NAME" default 2>/dev/null || true
  rm -f "/etc/init.d/$SERVICE_NAME" "/etc/conf.d/$SERVICE_NAME"
fi
if [ -x "$INSTALL_DIR/$APP" ]; then
  pkill -f "$INSTALL_DIR/$APP" 2>/dev/null || true
fi
rm -rf "$INSTALL_DIR" "$RUN_DIR"
rm -f /tmp/mini-sb-agent.sock
printf '%s\n' "mini-sb-agent 已卸载，仅移除了本安装器创建的文件。"
