#!/bin/bash

# ==========================================
# VPS AI 工具与 Agent 检测
# ==========================================

# 颜色定义
G='\033[0;32m'   # 绿色 (Green)
R='\033[0;31m'   # 红色 (Red)
Y='\033[1;33m'   # 黄色 (Yellow)
B='\033[0;34m'   # 蓝色 (Blue)
NC='\033[0m'     # 无颜色 (No Color)

# 为 Code Whale 模块兼容你代码中的颜色变量名
GREEN="${G}"
RED="${R}"
YELLOW="${Y}"
RESET="${NC}"

echo -e "${Y}========================================${NC}"
echo -e "${Y}       ◈      AI 工具检测      ◈       ${NC}"
echo -e "${Y}========================================${NC}"

# ==========================================
# 环境变量与路径补全
# ==========================================
ensure_env_path() {
    local common_paths=(
        "/usr/local/bin"
        "/usr/local/sbin"
        "/usr/bin"
        "/bin"
        "$HOME/.local/bin"
        "$HOME/.npm-global/bin"
        "$HOME/.yarn/bin"
        "$HOME/.cargo/bin"
    )

    for path in "${common_paths[@]}"; do
        if [[ ":$PATH:" != *":$path:"* ]] && [ -d "$path" ]; then
            export PATH="$PATH:$path"
        fi
    done
}

# 立即执行确保后续 command -v 正常识别
ensure_env_path

# ==========================================
# 辅助函数
# ==========================================

# 树状格式化输出函数
print_result() {
    local name=$1
    local location=$2
    local version=$3
    local status=$4

    # 头部：工具名称
    echo -e "${B}◈ 工具: ${NC}${Y}${name}${NC}"

    if [ "$location" == "未安装" ]; then
        # 未安装直接精简输出
        echo -e "  └─ ${R}安装状态: 未安装${NC}"
    else
        # 已安装时的树状输出
        echo -e "  ├─ ${G}安装路径: ${NC}${location}"
        
        # 处理版本号为空的情况并去除多余空白字符
        version=$(echo "$version" | xargs)
        echo -e "  ├─ ${G}当前版本: ${NC}${version:-未知}"
        
        # 状态着色逻辑
        if [[ "$status" =~ "运行中" ]]; then
            local STATUS_COLOR="${G}"
        else
            local STATUS_COLOR="${Y}"
        fi
        echo -e "  └─ ${G}活跃状态: ${NC}${STATUS_COLOR}${status}${NC}"
    fi
    echo -e "${B}----------------------------------------${NC}"
}

# 安全获取命令版本函数
get_version() {
    local cmd=$1
    local args=$2
    local raw_out=""
    
    if command -v timeout &> /dev/null; then
        raw_out=$(timeout 2s "$cmd" $args 2>&1)
    fi
    
    if [ -z "$raw_out" ]; then
        raw_out=$("$cmd" $args 2>&1)
    fi
    
    echo "$raw_out" | grep -v '^$' | head -n 1
}

# 检查 Docker 容器状态的辅助函数
check_docker_container() {
    local keyword=$1
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        local container_info=$(docker ps --format "{{.ID}} [{{.Names}}] ({{.Image}})" | grep -i "$keyword" | head -n 1)
        if [ -n "$container_info" ]; then
            echo "$container_info"
        fi
    fi
}

# ==========================================
# 工具检测核心逻辑
# ==========================================

# 1. Claude Code 检测
if command -v claude &> /dev/null; then
    loc=$(which claude)
    ver=$(get_version "claude" "--version")
    if pgrep -f "claude" > /dev/null; then status="运行中"; else status="已安装/闲置"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "Claude Code" "$loc" "$ver" "$status"

# 2. Codex CLI 检测
if command -v codex &> /dev/null; then
    loc=$(which codex)
    ver=$(get_version "codex" "--version")
    if pgrep -f "codex" > /dev/null; then status="运行中"; else status="已安装/闲置"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "Codex CLI" "$loc" "$ver" "$status"

# 3. Gemini CLI 检测
if command -v gemini &> /dev/null; then
    loc=$(which gemini)
    ver=$( "$loc" --version 2>&1 | grep -E '[0-9]+\.[0-9]' | head -n 1 )
    if pgrep -f "gemini" > /dev/null; then status="运行中"; else status="已安装/闲置"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "Gemini CLI" "$loc" "$ver" "$status"

# 4. OpenCode 检测
if command -v opencode &> /dev/null; then
    loc=$(which opencode)
    ver=$(get_version "opencode" "--version")
    if pgrep -f "opencode" > /dev/null; then status="运行中"; else status="已安装/闲置"; fi
elif command -v open-code &> /dev/null; then
    loc=$(which open-code)
    ver=$(get_version "open-code" "--version")
    if pgrep -f "open-code" > /dev/null; then status="运行中"; else status="已安装/闲置"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "OpenCode" "$loc" "$ver" "$status"

# 5. OpenClaw 检测 (加入 Docker 联动)
docker_res=$(check_docker_container "openclaw\|clawdbot")

if [ -n "$docker_res" ]; then
    loc="Docker Container ($docker_res)"
    ver="Docker Managed"
    status="运行中 (Running)"
elif command -v openclaw &> /dev/null || command -v clawdbot &> /dev/null; then
    loc=$(which openclaw 2>/dev/null || which clawdbot)
    ver=$(get_version "$loc" "--version")
    if pgrep -f "openclaw\|clawdbot" > /dev/null; then status="运行中"; else status="已安装/闲置"; fi
elif command -v pip &> /dev/null && pip show openclaw &> /dev/null; then
    loc="Python Pip Package"
    ver=$(pip show openclaw | grep -i "^Version:" | cut -d' ' -f2)
    if pgrep -f "openclaw" > /dev/null; then status="运行中"; else status="已安装/闲置"; fi
else
    loc="未安装"; ver=""; status=""
fi
print_result "OpenClaw" "$loc" "$ver" "$status"

# 6. Hermes Agent 检测 (加入 Docker 联动)
docker_res=$(check_docker_container "hermes")

if [ -n "$docker_res" ]; then
    loc="Docker Container ($docker_res)"
    ver="Docker Managed"
    status="运行中 (Running)"
elif command -v hermes &> /dev/null || command -v hermes-agent &> /dev/null; then
    loc=$(which hermes 2>/dev/null || which hermes-agent)
    raw_ver=$(get_version "$loc" "--version")
    ver=$(echo "$raw_ver" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "$raw_ver")
    if pgrep -f "hermes" > /dev/null; then status="运行中"; else status="已安装/闲置"; fi
elif command -v npm &> /dev/null && npm list -g --depth=0 hermes-agent &> /dev/null; then
    loc="NPM Global Module"
    ver=$(npm list -g --depth=0 hermes-agent | grep hermes-agent | awk -F@ '{print $2}')
    status="已安装 (可通过 npm 启动)"
elif command -v pip &> /dev/null && pip show hermes-agent &> /dev/null; then
    loc="Python Pip Package"
    ver=$(pip show hermes-agent | grep -i "^Version:" | cut -d' ' -f2)
    status="已安装 (可通过 python 运行)"
else
    loc="未安装"; ver=""; status=""
fi
print_result "Hermes Agent" "$loc" "$ver" "$status"

# 7. Code Whale 检测
echo -e "${B}◈ 工具: ${NC}${Y}Code Whale${NC}"
if command -v codewhale &> /dev/null; then
    status="${GREEN}已安装${RESET}"
    version_info=$(codewhale --version 2>/dev/null | head -n 1)
    [ -z "$version_info" ] && version_info="已就绪"
    codewhale_version="${YELLOW}${version_info}${RESET}"
    
    loc=$(which codewhale)
    echo -e "  ├─ ${G}安装路径: ${NC}${loc}"
    echo -e "  ├─ ${G}当前版本: ${NC}${codewhale_version}"
    echo -e "  └─ ${G}活跃状态: ${NC}${status}"
else
    status="${RED}未安装${RESET}"
    codewhale_version="${RED}-${RESET}"
    echo -e "  └─ ${R}安装状态: ${status}${NC}"
fi
echo -e "${B}----------------------------------------${NC}"
