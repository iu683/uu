#!/bin/bash

# 颜色定义
G='\033[0;32m' # 绿
B='\033[0;34m' # 蓝
Y='\033[1;33m' # 黄
C='\033[0;36m' # 青
R='\033[0;31m' # 红
NC='\033[0m'    # 无色

clear
echo -e "${B}================================================================================${NC}"
echo -e "${Y}          🚀 Docker 容器资源占用${NC}"
echo -e "${B}================================================================================${NC}"

# 打印表头：固定宽度对齐
printf "${C}%-20s %-10s %-25s %-15s${NC}\n" "容器名称" "CPU占用" "内存使用 (已用/总量)" "磁盘增量"
echo -e "${B}--------------------------------------------------------------------------------${NC}"

# 获取 stats 数据并按内存数值排序 (简单逻辑：先取数据再排序输出)
docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | sort -k3 -hr | while IFS=$'\t' read -r name cpu mem; do
    
    # 获取磁盘真实占用 (RW层)
    # awk '{print $1}' 确保只拿数值，不拿 (virtual...)
    disk=$(docker ps -s --filter "name=^/${name}$" --format "{{.Size}}" | awk '{print $1}')
    
    # 颜色逻辑：CPU 超过 50% 变红
    cpu_val=$(echo $cpu | cut -d'.' -f1 | tr -d '%')
    if [[ "$cpu_val" =~ ^[0-9]+$ ]] && [ "$cpu_val" -gt 50 ]; then 
        CPU_COLOR=$R; 
    else 
        CPU_COLOR=$G; 
    fi

    # 容器名加个长度截断，防止名字太长撑破表格
    short_name=$(echo $name | cut -c1-20)
    
    # 核心打印：严格对齐
    printf "%-20s ${CPU_COLOR}%-10s${NC} %-25s ${Y}%-15s${NC}\n" \
        "$short_name" "$cpu" "$mem" "$disk"
done

echo -e "${B}--------------------------------------------------------------------------------${NC}"
# 获取总占用：从 docker system df 中精准抓取数据
TOTAL_DISK=$(docker system df | grep 'Containers' | awk '{print $4}')
echo -e "${G}所有运行中容器总计占用 VPS 空间:${NC} $TOTAL_DISK"
echo -e "${B}================================================================================${NC}"
