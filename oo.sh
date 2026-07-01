#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "错误：请以 root 用户运行此脚本！"
  exit 1
fi

echo "开始清理指定的脚本文件..."

# 1. 定义需要删除的文件列表
FILES=(
    "/root/vps-toolbox.sh"
    "/root/toolboxupdate.sh"
    "/root/proxy.sh"
    "/root/Alpine.sh"
    "/root/oracle.sh"
    "/root/store.sh"
    "/root/panel.sh"
    "/root/dockerupdate.sh"
    "/usr/local/bin/clean-server"
)

# 循环删除文件
for FILE in "${FILES[@]}"; do
    if [ -f "$FILE" ]; then
        rm -f "$FILE"
        echo "已删除: $FILE"
    else
        echo "未找到文件（跳过）: $FILE"
    fi
done

echo "--------------------------------"
echo "开始清理相关的 crontab 定时任务..."

# 2. 备份当前的 crontab 以防万一
crontab -l > /tmp/cron_backup_$(date +%F).txt 2>/dev/null

# 导出当前任务，过滤掉包含特定脚本的行，然后重新写入
crontab -l 2>/dev/null | grep -v -E "toolboxupdate.sh|clean-server|dockerupdate.sh" | crontab -

echo "定时任务清理完成！"
echo "--------------------------------"
echo "所有清理工作已完成。"
