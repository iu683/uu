#!/bin/bash

# 颜色定义
G='\033[0;32m' # 绿
B='\033[0;34m' # 蓝
Y='\033[1;33m' # 黄
C='\033[0;36m' # 青
R='\033[0;31m' # 红
NC='\033[0m'    # 无色

# 检查 Docker 是否运行
if ! docker info > /dev/null 2>&1; then
    echo -e "${R}错误: Docker 未运行或没有权限。${NC}"
    exit 1
fi

clear
echo -e "${B}================================================================================${NC}"
echo -e "${Y}           🚀 Docker 容器资源占用实时概览 (VPS 专用版)${NC}"
echo -e "${B}================================================================================${NC}"

# 打印表头 (增加了对齐宽度)
printf "${C}%-22s %-10s %-15s %-8s %-18s %-12s${NC}\n" "容器名称" "CPU%" "内存使用" "内存%" "网络I/O" "磁盘空间"
echo -e "${B}--------------------------------------------------------------------------------${NC}"

# 获取 stats 数据
stats_data=$(docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}")

if [ -z "$stats_data" ]; then
    echo -e "      ${R}当前没有正在运行的容器${NC}"
else
    echo "$stats_data" | while IFS=$'\t' read -r name cpu mem memp net; do
        # 核心改进：只提取磁盘可写层的大小，去掉 virtual 部分，并处理空白字符
        disk=$(docker ps -a --filter "name=^/${name}$" --format "{{.Size}}" | awk '{print $1$2}')
        
        # 只有在容器名不为空时才处理
        if [ -n "$name" ]; then
            # 颜色逻辑：CPU 超过 50% 变红
            cpu_val=$(echo $cpu | cut -d'.' -f1 | tr -d '%')
            if [[ "$cpu_val" =~ ^[0-9]+$ ]] && [ "$cpu_val" -gt 50 ]; then 
                CPU_COLOR=$R; 
            else 
                CPU_COLOR=$G; 
            fi
            
            # 格式化输出
            printf "%-22s ${CPU_COLOR}%-10s${NC} %-15s %-8s %-18s ${Y}%-12s${NC}\n" \
                "$name" "$cpu" "$mem" "$memp" "$net" "$disk"
        fi
    done
fi
