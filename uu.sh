#!/bin/bash

# =======================================================================
# 🦞 OpenClaw 一键管理面板
# =======================================================================

# 终端高亮颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"

gl_lv="\033[32m"
gl_huang="\033[33m"
gl_hong="\033[31m"
gl_bai="\033[0m"

# 全局环境静态参数
SCRIPT_VERSION="1.3.5"
ENABLE_STATS="true"
gh_proxy=""

# 统一获取 OpenClaw 配置文件路径
openclaw_get_config_file() {
    echo "${HOME}/.openclaw/openclaw.json"
}

# 请根据实际情况修改你的 OpenClaw 配置文件绝对或相对路径
OPENCLAW_CONFIG="/root/.openclaw/config.json"

# 辅助函数：按键返回
break_end() {
    echo -e "\n${BLUE}----------------------------------------${RESET}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo
}

# 辅助函数：基础依赖检查与安装
install() {
    for pkg in "$@"; do
        if ! command -v "$pkg" &>/dev/null; then
            echo "正在安装系统依赖: $pkg..."
            if command -v apt &>/dev/null; then
                sudo apt update -y && sudo apt install -y "$pkg"
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y "$pkg"
            elif command -v yum &>/dev/null; then
                sudo yum install -y "$pkg"
            fi
        fi
    done
}

# 状态遥测发送函数
send_stats() {
    :
}

# 动态获取 OpenClaw 状态、配置数以及核心版本号
get_openclaw_status() {
    # 1. 检测运行状态
    if command -v openclaw &>/dev/null; then
        if pgrep -f "openclaw gateway" &>/dev/null || pgrep -f "gateway" &>/dev/null; then
            STATUS="${GREEN}运行中 (Running)${RESET}"
        else
            STATUS="${RED}已停止 (Stopped)${RESET}"
        fi
        # 2. 动态获取 OpenClaw 核心版本号并精细清洗
        local raw_v
        raw_v=$(openclaw -v 2>/dev/null | head -n 1 || openclaw --version 2>/dev/null | head -n 1 || echo "未知")
        # 去除 ANSI 颜色字符
        raw_v=$(echo "$raw_v" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
        # 精准提取 "OpenClaw " 后面的所有内容
        if [[ "$raw_v" =~ OpenClaw[[:space:]]+(.*) ]]; then
            OPENCLAW_VERSION="${BASH_REMATCH[1]}"
        else
            # 如果没匹配到，则兜底取最后两列
            OPENCLAW_VERSION=$(echo "$raw_v" | awk '{if(NF>1) print $(NF-1)" "$NF; else print $1}')
        fi
    else
        STATUS="${RED}未安装 (Not Installed)${RESET}"
        OPENCLAW_VERSION="${RED}未安装${RESET}"
    fi

    # 3. 获取配置供应商数量
    local config_file
    config_file=$(openclaw_get_config_file)
    if [ -f "$config_file" ] && command -v jq &>/dev/null; then
        CONFIG_COUNT=$(jq '.models.providers | length' "$config_file" 2>/dev/null || echo "0")
    else
        CONFIG_COUNT="0"
    fi
}


# 用于在机器人菜单头部展示本地状态的区块
openclaw_show_bot_local_status_block() {
    local config_file
    config_file=$(openclaw_get_config_file)
    if [ -f "$config_file" ] && command -v jq &>/dev/null; then
        local port
        port=$(jq -r '.gateway.port // .port // "9000"' "$config_file" 2>/dev/null)
        echo -e " 本地网关端口: ${YELLOW}${port}${RESET}"
        echo -n " 接口监听状态: "
        if command -v ss &>/dev/null; then
            if ss -tlnp | grep -q "$port"; then echo -e "${GREEN}正常监听中${RESET}"; else echo -e "${RED}未监听 (请先启动网关)${RESET}"; fi
        else
            if netstat -tlnp | grep -q "$port"; then echo -e "${GREEN}正常监听中${RESET}"; else echo -e "${RED}未监听 (请先启动网关)${RESET}"; fi
        fi
    else
        echo -e " 提示: ${RED}未检测到有效配置，请先执行配置向导。${RESET}"
    fi
}

# 重启消息网关后台
start_gateway() {
    echo "🔄 正在重启 OpenClaw Gateway..."
    openclaw gateway stop >/dev/null 2>&1
    sleep 1
    openclaw gateway start
    sleep 3
}

# 安装环境所依赖的 Node 及编译工具树
install_node_and_tools() {
    if command -v dnf &>/dev/null; then
        curl -fsSL https://rpm.nodesource.com/setup_24.x | sudo bash -
        sudo dnf update -y
        sudo dnf group install -y "Development Tools" "Development Libraries"
        sudo dnf install -y cmake libatomic nodejs
    fi

    if command -v apt &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
        sudo apt update -y
        sudo apt install build-essential python3 libatomic1 nodejs -y
    fi
}

# 同步指定或全量 Sessions 默认模型
openclaw_sync_sessions_model() {
    local target_model="$1"
    echo "🎯 全局会话默认模型已同步变变成: $target_model"
}

# =======================================================================
# 核心数据操作区域 (包含 Python / JQ 以及机器人对接子选单)
# =======================================================================

# 1. 安装 OpenClaw 环境
install_moltbot() {
    echo "开始安装 OpenClaw..."
    send_stats "开始安装 OpenClaw..."
    install git jq curl python3 tmux

    install_node_and_tools

    local country
    country=$(curl -s --max-time 3 ipinfo.io/country)
    if [[ "$country" == "CN" || "$country" == "HK" ]]; then
        npm config set registry https://registry.npmmirror.com
    fi

    git config --global url."${gh_proxy}github.com/".insteadOf ssh://git@github.com/
    git config --global url."${gh_proxy}github.com/".insteadOf git@github.com:

    sudo npm install -g openclaw@latest
    openclaw onboard --install-daemon
    start_gateway
    break_end
}

# 4. 状态日志查看
view_logs() {
    echo "📋 查看 OpenClaw 状态日志"
    send_stats "查看 OpenClaw 日志"
    openclaw status
    echo "----------------------------------------"
    openclaw gateway status
    echo "💡 提示: 正在加载实时日志流，按 Ctrl+C 可退出当前日志模式"
    sleep 2
    openclaw logs
    break_end
}



api_management_submenu() {
    if [ ! -f "$OPENCLAW_CONFIG" ]; then
        echo -e "${RED}错误: 未找到 OpenClaw 配置文件 ($OPENCLAW_CONFIG)${NC}"
        sleep 2
        return
    fi

    while true; do
        clear
        # 1. 获取当前激活的 primary 模型
        local current_model=$(jq -r '.agents.defaults.model.primary // "未设置"' "$OPENCLAW_CONFIG")

        echo -e "${GREEN}=======================================${NC}"
        echo -e "${GREEN}             API & 模型管理            ${NC}"
        echo -e "${GREEN}=======================================${NC}"
        echo -e "${CYAN}当前激活模型:${NC} ${YELLOW}${current_model}${NC}"
        echo -e "${GREEN}---------------------------------------${NC}"
        echo -e "${CYAN}已配置 API 列表:${NC}"
        
        # 2. 遍历打印所有的 providers 以及各自持有的模型数量
        local providers_json=$(jq -c '.models.providers | to_entries[]' "$OPENCLAW_CONFIG" 2>/dev/null)
        if [ -z "$providers_json" ]; then
            echo -e "  ${YELLOW}(暂无配置)${NC}"
        else
            while read -r row; do
                [ -z "$row" ] && continue
                local p_key=$(echo "$row" | jq -r .key)
                local m_count=$(echo "$row" | jq -r '.value.models | length')
                echo -e "${YELLOW}  ● [${p_key}] (${m_count} 个模型)${NC}"
            done <<< "$providers_json"
        fi

        echo -e "${GREEN}---------------------------------------${NC}"
        echo -e "${GREEN}1. 切换模型${NC}"
        echo -e "${GREEN}2. 添加 API 供应商${NC}"
        echo -e "${GREEN}3. 同步 API 供应商模型列表${NC}"
        echo -e "${GREEN}4. 删除 API 供应商${NC}"
        echo -e "${GREEN}5. 查看已加模型信息${NC}"
        echo -e "${GREEN}0. 返回主菜单${NC}"
        echo -e "${GREEN}---------------------------------------${NC}"
        echo -ne "${GREEN}选择序号: ${NC}"
        read -r sub_choice

        case "$sub_choice" in
            1) # 1. 切换模型
                clear
                echo -e "${YELLOW}--- 切换激活模型 ---${NC}"
                
                # 提取底层 providers 里定义的所有模型的全路径 (例如: custom-qianxing-ai-cc-cd/codex-auto-review)
                local models_str=$(jq -r '.models.providers | to_entries[] | .key as $p | .value.models[] | "\($p)/\(.id)"' "$OPENCLAW_CONFIG" 2>/dev/null)
                if [ -z "$models_str" ]; then
                    echo -e "${RED}配置中没有发现任何可用模型！${NC}"; sleep 1; continue
                fi
                
                mapfile -t models_array <<< "$models_str"
                PS3=$(echo -e "${GREEN}请选择模型序号 (输入 0 退出): ${NC}")
                select selected_model in "${models_array[@]}"; do
                    [ "$REPLY" = "0" ] && break
                    [ -n "$selected_model" ] && break
                done
                
                if [ -n "$selected_model" ] && [ "$REPLY" != "0" ]; then
                    # 剥离出短模型 ID
                    local short_model_id="${selected_model#*/}"
                    
                    # 使用 jq 同时更新 primary、agents.defaults.models 树结构
                    local tmp_json=$(jq \
                        --arg p "$selected_model" \
                        --arg sm "$short_model_id" \
                        '.agents.defaults.model.primary = $p | .agents.defaults.models = {($p): {}}' \
                        "$OPENCLAW_CONFIG")
                    echo "$tmp_json" > "$OPENCLAW_CONFIG"
                    
                    echo -e "${GREEN}✅ 模型已成功切换为: $selected_model${NC}"
                    restart_openclaw_service
                fi
                ;;

            2) # 2. 添加 API 供应商
                clear
                echo -e "${CYAN}--- 添加新 API 供应商 ---${NC}"
                read -r -p "请输入供应商别名 (如: deepseek): " n; [ -z "$n" ] && continue
                read -r -p "请输入 Base URL: " u; [ -z "$u" ] && continue
                echo -ne "${YELLOW}请输入 API Key: ${NC}"; read -r k; [ -z "$k" ] && continue
                read -r -p "请输入模型 ID (多个请用逗号隔开，如: gpt-4o,gpt-4o-mini): " ms
                [ -z "$ms" ] && continue
                
                # 将逗号隔开的模型组装成 OpenClaw 要求的 JSON 对象数组格式
                local models_json_arr="[]"
                IFS=',' read -r -a m_ids <<< "$ms"
                for m_id in "${m_ids[@]}"; do
                    m_id=$(echo "$m_id" | xargs) # 去空格
                    models_json_arr=$(echo "$models_json_arr" | jq --arg id "$m_id" '. += [{"id": $id, "name": "\($id) (Custom)", "contextWindow": 128000, "maxTokens": 4096, "input": ["text"], "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}, "reasoning": false}]')
                done
                
                # 构建 provider 对象并合并进原 JSON
                local new_provider_json=$(jq -n \
                    --arg bu "${u%/}" \
                    --arg key "$k" \
                    --argjson mods "$models_json_arr" \
                    '{"baseUrl": $bu, "api": "openai-completions", "apiKey": $key, "models": $mods}')
                
                local tmp_json=$(jq --argjson np "$new_provider_json" --arg name "$n" '.models.providers[$name] = $np' "$OPENCLAW_CONFIG")
                echo "$tmp_json" > "$OPENCLAW_CONFIG"
                
                echo -e "${GREEN}✅ 供应商 [${n}] 已成功添加！${NC}"
                restart_openclaw_service
                ;;

            3) # 3. 同步 API 供应商模型列表
                clear
                echo -e "${CYAN}--- 同步 API 供应商模型列表 ---${NC}"
                echo -e "${YELLOW}正在重新拉起网关重载本地配置文件路由...${NC}"
                restart_openclaw_service
                ;;

            4) # 4. 删除 API 供应商
                clear
                echo -e "${CYAN}--- 删除 API 供应商 ---${NC}"
                local p_list=$(jq -r '.models.providers | keys[]' "$OPENCLAW_CONFIG" 2>/dev/null)
                if [ -z "$p_list" ]; then
                    echo -e "${RED}当前无已配置的供应商。${NC}"; sleep 1; continue
                fi
                
                mapfile -t p_array <<< "$p_list"
                PS3="选择要删除的供应商序号 (输入 0 取消): "
                select del_name in "${p_array[@]}"; do
                    [ "$REPLY" = "0" ] && break
                    [ -n "$del_name" ] && break
                done
                
                if [ -n "$del_name" ] && [ "$REPLY" != "0" ]; then
                    read -r -p "确认删除供应商 [$del_name] 及其名下所有模型? (y/N): " del_confirm
                    if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                        # 使用 jq del 剔除对应的路径
                        local tmp_json=$(jq --arg name "$del_name" 'del(.models.providers[$name])' "$OPENCLAW_CONFIG")
                        echo "$tmp_json" > "$OPENCLAW_CONFIG"
                        
                        echo -e "${RED}🗑️ 已删除供应商: $del_name${NC}"
                        restart_openclaw_service
                    fi
                fi
                ;;

            5) # 5. 查看已加模型信息
                clear
                echo -e "${CYAN}--- 已加模型详细信息列表 ---${NC}"
                echo -e "${YELLOW}----------------------------------------${NC}"
                
                local p_detail=$(jq -c '.models.providers | to_entries[]' "$OPENCLAW_CONFIG" 2>/dev/null)
                if [ -z "$p_detail" ]; then
                    echo -e "  ${YELLOW}(暂无任何模型配置信息)${NC}"
                else
                    while read -r row; do
                        [ -z "$row" ] && continue
                        local det_name=$(echo "$row" | jq -r .key)
                        local det_url=$(echo "$row" | jq -r .value.baseUrl)
                        local det_key=$(echo "$row" | jq -r .value.apiKey)
                        local det_models=$(echo "$row" | jq -r '.value.models[].id' | tr '\n' ',' | sed 's/,$//')
                        
                        [ -z "$det_key" ] || [ "$det_key" = "null" ] && det_key="无"

                        echo -e "${YELLOW}◈ 别名: ${NC}${YELLOW}${det_name}${NC}"
                        echo -e "  ├─ 包含模型: ${GREEN}${det_models}${NC}"
                        echo -e "  ├─ Base URL: ${CYAN}${det_url}${NC}"
                        echo -e "  └─ API Key: ${CYAN}${det_key}${NC}"
                        echo -e "${YELLOW}----------------------------------------${NC}"
                    done <<< "$p_detail"
                fi
                echo ""
                read -r -p "按回车键继续..."
                ;;

            0) break ;;
        esac
    done
}

# 辅助函数：安全重启 OpenClaw 网关
restart_openclaw_service() {
    echo -e "${YELLOW}正在重启 OpenClaw 服务...${NC}"
    # 查找并结束之前的 OpenClaw 进程
    local pid=$(pgrep -f "openclaw")
    [ -n "$pid" ] && kill "$pid" && sleep 1
    
    # 根据你的配置，重新后台拉起服务并生成日志
    nohup ./openclaw > openclaw.log 2>&1 &
    
    echo -e "${GREEN}✅ OpenClaw 配置重载并重启完毕！${NC}"
    sleep 1.5
}

# 7. 机器人连接对接交互式子选单
bot_connection_menu() {
    while true; do
        clear
        echo -e "${GREEN}========================================${RESET}"
        echo -e "             机器人连接对接             "
        echo -e "${GREEN}========================================${RESET}"
        openclaw_show_bot_local_status_block
        echo "----------------------------------------"
        echo -e " 1. Telegram 机器人对接"
        echo -e " 2. 飞书 (Lark) 机器人对接"
        echo -e " 3. WhatsApp 机器人对接"
        echo -e " 4. QQ 机器人对接"
        echo -e " 5. 微信机器人对接"
        echo "----------------------------------------"
        echo -e " ${YELLOW}0. 返回上一级选单${RESET}"
        echo "----------------------------------------"
        read -erp "请输入你的选择: " bot_choice

        case $bot_choice in
            1)
                read -erp "请输入TG机器人收到的连接码 (例如 NYA99R2F)（输入 0 退出）： " code
                if [ "$code" = "0" ] || [ -z "$code" ]; then 
                    [ -z "$code" ] && echo -e "${RED}错误：连接码不能为空。${RESET}" && sleep 1
                    continue
                fi
                openclaw pairing approve telegram "$code"
                break_end
                ;;
            2)
                echo -e "${YELLOW}🔄 正在通过 npx 调度部署飞书适配通道...${RESET}"
                npx -y @larksuite/openclaw-lark install
                openclaw config set channels.feishu.streaming true
                openclaw config set channels.feishu.requireMention true --json
                echo -e "${GREEN}✅ 飞书通道参数设置成功！${RESET}"
                break_end
                ;;
            3)
                read -erp "请输入WhatsApp收到的连接码 (例如 NYA99R2F)（输入 0 退出）： " code
                if [ "$code" = "0" ] || [ -z "$code" ]; then 
                    [ -z "$code" ] && echo -e "${RED}错误：连接码不能为空。${RESET}" && sleep 1
                    continue
                fi
                openclaw pairing approve whatsapp "$code"
                break_end
                ;;
            4)
                echo -e "\n${GREEN}QQ 官方对接指引链接：${RESET}"
                echo -e "${BLUE}https://q.qq.com/qqbot/openclaw/login.html${RESET}\n"
                break_end
                ;;
            5)
                echo -e "${YELLOW}🔄 正在下载并注入企业微信/微信开放平台支持组件...${RESET}"
                npx -y @tencent-weixin/openclaw-weixin-cli@latest install
                break_end
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}无效的选择，请重试。${RESET}"
                sleep 1
                ;;
        esac
    done
}

# 12. 健康检测与自动环境修复
health_doctor_fix() {
    echo -e "${GREEN}=== OpenClaw 全自动化故障巡检与修复 ===${RESET}"
    local config_file
    config_file=$(openclaw_get_config_file)

    echo -n "[1/3] 核心进程状态扫描: "
    if pgrep -f "openclaw" &>/dev/null; then
        echo -e "${GREEN}正常运行${RESET}"
    else
        echo -e "${YELLOW}离线。正在为您强制拉起网关进程守护...${RESET}"
        openclaw gateway start
    fi

    echo -n "[2/3] 核心配置文件格式校验: "
    if [ -f "$config_file" ]; then
        if jq . "$config_file" &>/dev/null; then
            echo -e "${GREEN}结构合法 (Valid JSON)${RESET}"
        else
            echo -e "${RED}结构损坏！正在为您排查加载最近一次的备份恢复...${RESET}"
            local bak
            bak=$(ls -t "${config_file}.bak."* 2>/dev/null | head -n 1)
            if [ -n "$bak" ]; then
                cp "$bak" "$config_file" && echo -e "${GREEN}已成功还原历史快照配置: $bak${RESET}"
            else
                echo -e "${RED}无历史快照备份，建议执行选项 11 重新进行 onboard向导初始化。${RESET}"
            fi
        fi
    else
        echo -e "${RED}缺失核心配置文件${RESET}"
    fi

    echo -n "[3/3] 全系统底层运行环境依属检测: "
    if command -v node &>/dev/null && command -v tmux &>/dev/null; then
        echo -e "${GREEN}环境完备${RESET}"
    else
        echo -e "${YELLOW}发现缺失，自动补全修复依赖项...${RESET}"
        install tmux jq nodejs
    fi
    break_end
}

# =======================================================================
# 主菜单及指令控制层
# =======================================================================
show_menu() {
    get_openclaw_status
    clear
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}     ◈   🦞 OPENCLAW 管理工具  ◈      ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}核心状态 : $STATUS${RESET}"
    echo -e "${GREEN}核心版本 :${RESET} ${YELLOW}$OPENCLAW_VERSION${RESET}"
    echo -e "${GREEN}集群数据 :${RESET} ${YELLOW}$CONFIG_COUNT 个 API 供应商${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "  1. 安装 环境依赖与 OpenClaw"
    echo -e "  2. 启动 Gateway (消息网关后台)"
    echo -e "  3. 停止 Gateway (消息网关服务)"
    echo -e " -------------------------------------"
    echo -e "  4. 状态日志查看"
    echo -e "  6. API 管理 "
    echo -e "  7. 机器人连接对接窗口"
    echo -e " -------------------------------------"
    echo -e " 11. 配置向导 (Onboard 初始化)"
    echo -e " 12. 健康检测与自动故障修复"
    echo -e " 14. TUI 命令行窗口本地对话"
    echo -e " 19. 更新 OpenClaw 核心程序"
    echo -e " 20. 卸载 清理全部运行环境"
    echo -e " -------------------------------------"
    echo -e "  0. 退出"
    echo -e "${GREEN}=======================================${RESET}"
    printf " 请输入选项并回车: "
}

main() {
    while true; do
        show_menu
        read -r choice
        case "$choice" in
            1)  install_moltbot ;;
            2)  start_gateway && echo -e "${GREEN}✅ 启动指令发送执行完成${RESET}" && break_end ;;
            3)  
                echo "停止 OpenClaw..."
                send_stats "停止 OpenClaw..."
                tmux kill-session -t gateway > /dev/null 2>&1
                openclaw gateway stop >/dev/null 2>&1
                echo -e "${GREEN}✅ 网关核心及守护会话已完全离线停止${RESET}"
                break_end 
                ;;
            4)  view_logs ;;
            6)  api_management_submenu ;;
            7)  bot_connection_menu ;;
            11) openclaw onboard; break_end ;;
            12) health_doctor_fix ;;
            14) openclaw chat ;;
            19) 
                echo "🔄 正在为您执行 NPM 全量拉取覆写更新 OpenClaw..."
                sudo npm install -g openclaw@latest && start_gateway
                echo -e "${GREEN}✅ 覆写更新完成！${RESET}"
                break_end
                ;;
            20) 
                echo -e "${RED}⚠️ 警告：您正准备全盘卸载 OpenClaw 控制程序及清空所有配置。${RESET}"
                read -erp "确定要继续执行强力清除吗？(y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    openclaw gateway stop >/dev/null 2>&1
                    sudo npm uninstall -g openclaw
                    rm -rf "${HOME}/.openclaw"
                    echo -e "${GREEN}✅ OpenClaw 卸载洗刷完成。${RESET}"
                else
                    echo "❌ 操作已取消。"
                fi
                break_end
                ;;
            0)  echo "退出 OpenClaw 管理面板，再见！"; exit 0 ;;
            *)  echo -e "${RED}输入有误，请输入菜单中有效的数字代号！${RESET}"; sleep 1 ;;
        esac
    done
}

# 启动执行
main
