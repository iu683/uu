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
echo -e "${Y}       🚀 Docker 资源监控${NC}"
echo -e "${B}========================================${NC}"

# 获取并按内存排序数据
# 1. docker stats 拿到原始数据
# 2. sort 按内存大小排序
docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | sort -k3 -hr | while IFS=$'\t' read -r name cpu mem; do
    
    # 颜色逻辑：CPU 超过 50% 变红
    cpu_val=$(echo $cpu | cut -d'.' -f1 | tr -d '%')
    if [[ "$cpu_val" =~ ^[0-9]+$ ]] && [ "$cpu_val" -gt 50 ]; then 
        CPU_COLOR=$R; 
    else 
        CPU_COLOR=$G; 
    fi

    # 手机端改为每行独立显示一个容器的详细信息
    echo -e "${C}◈ 容器: ${NC}${Y}${name}${NC}"
    echo -e "  ├─ ${G}CPU 占用: ${NC}${CPU_COLOR}${cpu}${NC}"
    echo -e "  └─ ${G}内存使用: ${NC}${mem}"
    echo -e "${B}----------------------------------------${NC}"
done
