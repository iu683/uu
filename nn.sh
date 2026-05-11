#!/bin/bash

# 颜色定义
G='\033[0;32m' # 绿
B='\033[0;34m' # 蓝
Y='\033[1;33m' # 黄
C='\033[0;36m' # 青
R='\033[0;31m' # 红
NC='\033[0m'    # 无色

clear
echo -e "${B}======================================================================${NC}"
echo -e "${Y}          🚀 Docker 容器资源占用${NC}"
echo -e "${B}======================================================================${NC}"

# 打印表头
printf "${C}%-25s %-12s %-20s %-15s${NC}\n" "容器名称" "CPU占用" "内存使用" "磁盘空间"
echo -e "${B}----------------------------------------------------------------------${NC}"

# 获取 stats 数据
stats_data=$(docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}")

if [ -z "$stats_data" ]; then
    echo -e "      ${R}当前没有正在运行的容器${NC}"
else
    echo "$stats_data" | while IFS=$'\t' read -r name cpu mem; do
        # 提取磁盘占用：只显示可写层大小，去掉 (virtual...) 部分
        disk=$(docker ps -a --filter "name=^/${name}$" --format "{{.Size}}" | awk '{print $1}')
        
        # 容器名超长截断处理
        display_name=$(echo $name | cut -c1-24)

        # 颜色逻辑：CPU 超过 50% 变红
        cpu_val=$(echo $cpu | cut -d'.' -f1 | tr -d '%')
        if [[ "$cpu_val" =~ ^[0-9]+$ ]] && [ "$cpu_val" -gt 50 ]; then 
            CPU_COLOR=$R; 
        else 
            CPU_COLOR=$G; 
        fi
        
        # 格式化输出
        printf "%-25s ${CPU_COLOR}%-12s${NC} %-20s ${Y}%-15s${NC}\n" \
            "$display_name" "$cpu" "$mem" "$disk"
    done
fi
