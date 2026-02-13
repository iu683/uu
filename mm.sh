#!/bin/bash

# 颜色设置
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}           本地系统快照恢复工具                  ${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""

# ==============================
# 自定义备份目录（新增功能）
# ==============================

DEFAULT_BACKUP="/backups"

if [ -n "$1" ]; then
  BACKUP_DIR="$1"
else
  read -p "请输入备份目录(默认: $DEFAULT_BACKUP): " INPUT_DIR
  BACKUP_DIR="${INPUT_DIR:-$DEFAULT_BACKUP}"
fi

echo -e "${GREEN}使用备份目录: $BACKUP_DIR${NC}"

# ⭐ 注意：这里必须完整 if + fi
if [ ! -d "$BACKUP_DIR" ]; then
  echo -e "${RED}错误: 备份目录 $BACKUP_DIR 不存在!${NC}"
  exit 1
fi


# 查找本地快照文件
echo -e "${BLUE}正在查找本地系统快照...${NC}"
SNAPSHOT_FILES=($(find $BACKUP_DIR -maxdepth 1 -type f -name "system_snapshot_*.tar.gz" | sort -r))

if [ ${#SNAPSHOT_FILES[@]} -eq 0 ]; then
  echo -e "${RED}错误: 未找到系统快照文件!${NC}"
  exit 1
fi

# 显示可用快照列表
echo -e "${YELLOW}可用的本地快照:${NC}"
for i in "${!SNAPSHOT_FILES[@]}"; do
  SNAPSHOT_PATH="${SNAPSHOT_FILES[$i]}"
  SNAPSHOT_NAME=$(basename "$SNAPSHOT_PATH")
  SNAPSHOT_SIZE=$(du -h "$SNAPSHOT_PATH" | cut -f1)
  SNAPSHOT_DATE=$(date -r "$SNAPSHOT_PATH" "+%Y-%m-%d %H:%M:%S")
  echo -e "$((i+1))) ${GREEN}$SNAPSHOT_NAME${NC} (${SNAPSHOT_SIZE}, ${SNAPSHOT_DATE})"
done

# 选择要恢复的快照
read -p "请选择要恢复的快照编号 [1-${#SNAPSHOT_FILES[@]}]: " SNAPSHOT_CHOICE

if ! [[ "$SNAPSHOT_CHOICE" =~ ^[0-9]+$ ]] || [ "$SNAPSHOT_CHOICE" -lt 1 ] || [ "$SNAPSHOT_CHOICE" -gt ${#SNAPSHOT_FILES[@]} ]; then
  echo -e "${RED}错误: 无效的选择!${NC}"
  exit 1
fi

SELECTED_SNAPSHOT="${SNAPSHOT_FILES[$((SNAPSHOT_CHOICE-1))]}"
SNAPSHOT_NAME=$(basename "$SELECTED_SNAPSHOT")

# 确认恢复
echo -e "\n${YELLOW}准备恢复系统快照: ${GREEN}$SNAPSHOT_NAME${NC}"
echo -e "${RED}警告: 恢复操作将把系统状态恢复到快照创建时的状态。此操作不可撤销!${NC}"
echo -e "${RED}恢复后，快照创建时间点之后的所有更改将丢失!${NC}"
read -p "是否继续? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}恢复已取消.${NC}"
  exit 0
fi

echo -e "\n${YELLOW}请选择恢复模式:${NC}"
echo -e "1) ${GREEN}标准恢复(推荐)${NC} - 恢复所有系统文件，但保留网络配置"
echo -e "2) ${GREEN}完全恢复${NC} - 完全恢复所有文件，包括网络配置（可能导致网络中断）"
read -p "请选择恢复模式 [1-2]: " RESTORE_MODE

if ! [[ "$RESTORE_MODE" =~ ^[1-2]$ ]]; then
  echo -e "${RED}错误: 无效的选择!${NC}"
  exit 1
fi

# 备份关键系统配置
if [ "$RESTORE_MODE" -eq 1 ]; then
  echo -e "\n${BLUE}备份当前网络和系统配置...${NC}"
  mkdir -p /root/system_backup
  cp /etc/fstab /root/system_backup/fstab.bak 2>/dev/null
  cp /etc/network/interfaces /root/system_backup/interfaces.bak 2>/dev/null
  cp -r /etc/netplan /root/system_backup/ 2>/dev/null
  cp /etc/hostname /root/system_backup/hostname.bak 2>/dev/null
  cp /etc/hosts /root/system_backup/hosts.bak 2>/dev/null
  cp /etc/resolv.conf /root/system_backup/resolv.conf.bak 2>/dev/null
fi

# 停止关键服务
echo -e "${BLUE}停止关键服务...${NC}"
for service in nginx apache2 mysql docker; do
  if systemctl is-active --quiet $service; then
    echo "停止 $service 服务..."
    systemctl stop $service 2>/dev/null
  fi
done

# 执行恢复
echo -e "${BLUE}正在恢复系统文件...${NC}"

if [ "$RESTORE_MODE" -eq 1 ]; then
  # 标准恢复 - 保留网络设置
  tar -xzf "$SELECTED_SNAPSHOT" -C / \
    --exclude="dev/*" \
    --exclude="proc/*" \
    --exclude="sys/*" \
    --exclude="run/*" \
    --exclude="tmp/*" \
    --exclude="etc/fstab" \
    --exclude="etc/hostname" \
    --exclude="etc/hosts" \
    --exclude="etc/network/*" \
    --exclude="etc/netplan/*" \
    --exclude="etc/resolv.conf" \
    --exclude="backups/*"
else
  # 完全恢复 - 包括网络设置
  tar -xzf "$SELECTED_SNAPSHOT" -C / \
    --exclude="dev/*" \
    --exclude="proc/*" \
    --exclude="sys/*" \
    --exclude="run/*" \
    --exclude="tmp/*" \
    --exclude="backups/*"
fi

RESTORE_RESULT=$?
if [ $RESTORE_RESULT -ne 0 ]; then
  echo -e "${RED}错误: 系统恢复失败!${NC}"
  exit 1
fi

# 恢复网络配置(标准模式)
if [ "$RESTORE_MODE" -eq 1 ]; then
  echo -e "${BLUE}恢复网络配置...${NC}"
  cp /root/system_backup/fstab.bak /etc/fstab 2>/dev/null
  cp /root/system_backup/interfaces.bak /etc/network/interfaces 2>/dev/null
  cp -r /root/system_backup/netplan/* /etc/netplan/ 2>/dev/null
  cp /root/system_backup/hostname.bak /etc/hostname 2>/dev/null
  cp /root/system_backup/hosts.bak /etc/hosts 2>/dev/null
  cp /root/system_backup/resolv.conf.bak /etc/resolv.conf 2>/dev/null
fi

# 通知成功
echo -e "${GREEN}系统快照恢复成功!${NC}"
if [ "$RESTORE_MODE" -eq 1 ]; then
  echo -e "${BLUE}已保留当前网络配置.${NC}"
else
  echo -e "${YELLOW}已恢复所有设置，包括网络配置.${NC}"
fi

# 提示重启
echo -e "${YELLOW}系统需要重启以完成恢复.${NC}"
read -p "是否立即重启系统? [y/N]: " REBOOT
if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
  echo -e "${BLUE}系统将在5秒后重启...${NC}"
  sleep 5
  reboot
else
  echo -e "${YELLOW}请手动重启系统以完成恢复.${NC}"
fi
