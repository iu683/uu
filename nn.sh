#!/bin/bash

# 颜色定义
G='\033[0;32m' # 绿
B='\033[0;34m' # 蓝
Y='\033[1;33m' # 黄
C='\033[0;36m' # 青
R='\033[0;31m' # 红
NC='\033[0m'    # 无色

clear
echo -e "${B}==============================================================${NC}"
echo -e "${Y}           🚀 Docker 容器资源占用${NC}"
echo -e "${B}==============================================================${NC}"

# 打印表头：固定宽度对齐
# %-25s 为容器名留出25字符宽度
# %-12s 为CPU留出12字符宽度
# %-30s 为内存留出30字符宽度
printf "${C}%-25s %-12s %-30s${NC}\n" "容器名称" "CPU占用" "内存使用 (已用/总量)"
echo -e "${B}--------------------------------------------------------------${NC}"

# 获取并处理数据
# 1. docker stats 获取数据
# 2. sort -k3 -hr 按内存大小降序排列
docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | sort -k3 -hr | while IFS=$'\t' read -r name cpu mem; do
    
    # 颜色逻辑：CPU 超过 50% 变红
    cpu_val=$(echo $cpu | cut -d'.' -f1 | tr -d '%')
    if [[ "$cpu_val" =~ ^[0-9]+$ ]] && [ "$cpu_val" -gt 50 ]; then 
        CPU_COLOR=$R; 
    else 
        CPU_COLOR=$G; 
    fi

    # 截断超长容器名，防止破坏对齐 (保留前 24 位)
    short_name=$(echo $name | cut -c1-24)
    
    # 格式化输出
    printf "%-25s ${CPU_COLOR}%-12s${NC} %-30s\n" \
        "$short_name" "$cpu" "$mem"
done
