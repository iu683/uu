#!/bin/bash

# 颜色定义
G='\033[0;32m' # 绿
B='\033[0;34m' # 蓝
Y='\033[1;33m' # 黄
C='\033[0;36m' # 青
R='\033[0;31m' # 红
NC='\033[0m'    # 无色

clear
echo -e "${B}========================================${NC}"
echo -e "${Y}       🚀 Docker 运行监控${NC}"
echo -e "${B}========================================${NC}"

# 获取并处理数据 (按内存排序)
docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" | sort -k3 -hr | while IFS=$'\t' read -r name cpu mem net; do
    
    # 1. 获取运行时间并汉化
    raw_status=$(docker ps -a --filter "name=^/${name}$" --format "{{.Status}}")
    
    # 汉化处理
    uptime=$(echo "$raw_status" | \
        sed 's/Up /运行 /' | \
        sed 's/Exited/已停止/' | \
        sed 's/seconds/秒/' | \
        sed 's/second/秒/' | \
        sed 's/minutes/分钟/' | \
        sed 's/minute/分钟/' | \
        sed 's/hours/小时/' | \
        sed 's/hour/小时/' | \
        sed 's/days/天/' | \
        sed 's/day/天/' | \
        sed 's/weeks/周/' | \
        sed 's/week/周/' | \
        sed 's/months/月/' | \
        sed 's/month/月/' | \
        sed 's/about //' | \
        sed 's/ago/前/')
    
    # 2. 颜色逻辑：CPU 超过 50% 变红
    cpu_val=$(echo $cpu | cut -d'.' -f1 | tr -d '%')
    if [[ "$cpu_val" =~ ^[0-9]+$ ]] && [ "$cpu_val" -gt 50 ]; then 
        CPU_COLOR=$R; 
    else 
        CPU_COLOR=$G; 
    fi

    # 3. 手机端纵向块状输出
    echo -e "${C}◈ 容器: ${NC}${Y}${name}${NC}"
    echo -e "  ├─ ${G}CPU 占用: ${NC}${CPU_COLOR}${cpu}${NC}"
    echo -e "  ├─ ${G}内存使用: ${NC}${mem}"
    echo -e "  ├─ ${G}网络 I/O: ${NC}${net}"
    echo -e "  └─ ${G}运行状态: ${NC}${Y}${uptime}${NC}"
    echo -e "${B}----------------------------------------${NC}"
done
