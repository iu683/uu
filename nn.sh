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
echo -e "${Y}       🚀 Docker 全能监控 (手机版)${NC}"
echo -e "${B}========================================${NC}"

# 获取并处理数据 (按内存排序)
docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" | sort -k3 -hr | while IFS=$'\t' read -r name cpu mem net; do
    
    # 1. 获取磁盘真实占用 (RW层)
    # 手机端为了速度，直接从 ps 抓取数值部分
    disk=$(docker ps -s --filter "name=^/${name}$" --format "{{.Size}}" | awk '{print $1}')
    
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
    echo -e "  └─ ${G}磁盘增量: ${NC}${Y}${disk}${NC}"
    echo -e "${B}----------------------------------------${NC}"
done

# 底部汇总
TOTAL_DISK=$(docker system df | grep 'Containers' | awk '{print $4}')
echo -e "${G}所有容器总计占用 VPS 空间:${NC} ${Y}$TOTAL_DISK${NC}"
echo -e "${G}统计时间:${NC} $(date '+%H:%M:%S')"
echo -e "${B}========================================${NC}"
