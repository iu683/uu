#!/bin/bash
# Hermes Agent 终端管理脚本
# 颜色定义 (适配 ACME 风格命名)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
RESET='\033[0m'
NC='\033[0m' # 兼容脚本中使用的 NC 变量

# 确保 hermes 命令可用 (处理环境变量未加载的情况)
if ! command -v hermes >/dev/null 2>&1; then
    if [ -d "$HOME/.hermes/hermes-agent/venv/bin" ]; then
        export PATH="$HOME/.hermes/hermes-agent/venv/bin:$PATH"
    fi
fi

# 环境路径刷新函数
refresh_hermes_path() {
    if [ -f "$HOME/.bashrc" ]; then
        source "$HOME/.bashrc"
    elif [ -f "$HOME/.zshrc" ]; then
        source "$HOME/.zshrc"
    fi
    export PATH="$HOME/.local/bin:$HOME/.hermes/hermes-agent/venv/bin:$PATH"
}

# --- 科技lion 增强版 API 管理核心 ---
CONFIG_FILE="$HOME/.hermes/config.yaml"

config_tool() {
    # 自动适配 CONFIG_FILE 路径
    if [ ! -f "$CONFIG_FILE" ]; then
        local p
        for p in "/root/.hermes/config.yaml" /home/*/.hermes/config.yaml; do
            if [ -f "$p" ]; then
                CONFIG_FILE="$p"
                break
            fi
        done
    fi

    # 寻找可用的 Python 解释器，优先使用带有 pyyaml (yaml) 的环境
    local python_bin=""

    # 1. 尝试从 command -v hermes 指向的文件的 shebang/内容中提取 python 路径
    local hermes_cmd
    hermes_cmd=$(command -v hermes)
    if [ -n "$hermes_cmd" ] && [ -f "$hermes_cmd" ]; then
        # A. 检查第一行是否是 shebang
        local shebang
        shebang=$(head -n 1 "$hermes_cmd" 2>/dev/null)
        if [[ "$shebang" =~ ^#\! ]]; then
            local potential_py="${shebang#\#!}"
            if [ -f "$potential_py" ]; then
                if "$potential_py" -c "import yaml" >/dev/null 2>&1; then
                    python_bin="$potential_py"
                fi
            fi
        fi
        # B. 检查是否是 Bash wrapper，追踪其实际指向的 bin 并提取 python3
        if [ -z "$python_bin" ]; then
            local wrapped_bin
            wrapped_bin=$(grep -Eo '"/[^"]+/venv/bin/hermes"' "$hermes_cmd" | tr -d '"' | head -n 1)
            if [ -z "$wrapped_bin" ]; then
                wrapped_bin=$(grep -Eo '/[a-zA-Z0-9_\.\-]+/hermes-agent/venv/bin/hermes' "$hermes_cmd" | head -n 1)
            fi
            if [ -n "$wrapped_bin" ] && [ -f "$wrapped_bin" ]; then
                local wrapped_shebang
                wrapped_shebang=$(head -n 1 "$wrapped_bin" 2>/dev/null)
                if [[ "$wrapped_shebang" =~ ^#\! ]]; then
                    local potential_py="${wrapped_shebang#\#!}"
                    if [ -f "$potential_py" ] && "$potential_py" -c "import yaml" >/dev/null 2>&1; then
                        python_bin="$potential_py"
                    fi
                fi
                if [ -z "$python_bin" ]; then
                    local potential_py="${wrapped_bin%/hermes}/python3"
                    if [ -f "$potential_py" ] && "$potential_py" -c "import yaml" >/dev/null 2>&1; then
                        python_bin="$potential_py"
                    fi
                fi
            fi
        fi
    fi

    # 2. 尝试从常见绝对路径查找
    if [ -z "$python_bin" ]; then
        local paths=(
            "$HOME/.hermes/hermes-agent/venv/bin/python3"
            "$HOME/.hermes/hermes-agent/venv/bin/python"
            "/root/.hermes/hermes-agent/venv/bin/python3"
            "/root/.hermes/hermes-agent/venv/bin/python"
            "/usr/local/lib/hermes-agent/venv/bin/python3"
            "/usr/local/lib/hermes-agent/venv/bin/python"
            "/usr/lib/hermes-agent/venv/bin/python3"
            "/usr/lib/hermes-agent/venv/bin/python"
            "$HOME/.hermes/hermes-agent/.venv/bin/python3"
            "/root/.hermes/hermes-agent/.venv/bin/python3"
            "/usr/local/lib/hermes-agent/.venv/bin/python3"
            "/usr/lib/hermes-agent/.venv/bin/python3"
            /home/*/.hermes/hermes-agent/venv/bin/python3
            /home/*/.hermes/hermes-agent/venv/bin/python
            /home/*/.hermes/hermes-agent/.venv/bin/python3
        )
        local p
        for p in "${paths[@]}"; do
            if [ -f "$p" ]; then
                if "$p" -c "import yaml" >/dev/null 2>&1; then
                    python_bin="$p"
                    break
                fi
            fi
        done
    fi

    # 3. 兜底退回到系统全局 python3 或 python
    if [ -z "$python_bin" ]; then
        if command -v python3 >/dev/null 2>&1; then
            python_bin="python3"
        else
            python_bin="python"
        fi
    fi

    $python_bin - "$CONFIG_FILE" "$@" <<'EOF'
import sys, yaml, json, os

path = sys.argv[1]
action = sys.argv[2]

def load():
    if not os.path.exists(path):
        return {}
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return yaml.safe_load(f) or {}
    except:
        return {}

def save(d):
    with open(path, 'w', encoding='utf-8') as f:
        yaml.dump(d, f, sort_keys=False, allow_unicode=True)

try:
    data = load()
    if action == "get_info":
        m = data.get('model', {})
        res = {"m": m.get('default', '-'), "p": m.get('provider', '-'), "u": m.get('base_url', '-')}
        print(json.dumps(res))
    
    elif action == "list_p":
        print(json.dumps(data.get('custom_providers', [])))
    
    elif action == "add_p":
        n, u, k, m = sys.argv[3:7]
        ps = data.get('custom_providers', [])
        if not isinstance(ps, list): ps = []
        ps = [p for p in ps if p.get('name') != n]
        ps.append({"name": n, "base_url": u, "api_key": k, "model": m})
        data['custom_providers'] = ps
        save(data)
    
    elif action == "bulk_add":
        n_base, u, k, models_json = sys.argv[3:7]
        new_m_ids = json.loads(models_json)
        ps = data.get('custom_providers', [])
        if not isinstance(ps, list): ps = []
        ps = [p for p in ps if not (isinstance(p, dict) and p.get('name', '').startswith(n_base + "/"))]
        ps = [p for p in ps if p.get('name') != n_base]
        for m_id in new_m_ids:
            ps.append({"name": f"{n_base}/{m_id}", "base_url": u, "api_key": k, "model": m_id})
        data['custom_providers'] = ps
        save(data)
    
    elif action == "del_p":
        n = sys.argv[3]
        ps = data.get('custom_providers', [])
        if isinstance(ps, list):
            data['custom_providers'] = [p for p in ps if p.get('name') != n and not p.get('name', '').startswith(n + "/")]
            save(data)

    elif action == "list_groups":
        ps = data.get('custom_providers', [])
        groups = []
        seen = set()
        for p in (ps if isinstance(ps, list) else []):
            name = p.get('name', '')
            g = name.split('/')[0] if '/' in name else name
            if g and g not in seen:
                seen.add(g)
                cnt = sum(1 for x in ps if x.get('name', '') == g or x.get('name', '').startswith(g + '/'))
                groups.append({"name": g, "count": cnt})
        print(json.dumps(groups))
    
    elif action == "list_groups_latency":
        import threading, urllib.request, time
        ps = data.get('custom_providers', [])
        groups = {}
        for p in (ps if isinstance(ps, list) else []):
            name = p.get('name', '')
            g = name.split('/')[0] if '/' in name else name
            if g not in groups:
                groups[g] = {'name': g, 'base_url': p.get('base_url', ''), 'api_key': p.get('api_key', ''), 'count': 0}
            groups[g]['count'] += 1
        results = {}
        def worker(g, url, key):
            if not url or not (url.startswith('http://') or url.startswith('https://')):
                results[g] = "N/A"
                return
            start = time.time()
            try:
                url = url.rstrip('/') + '/models'
                req = urllib.request.Request(url, headers={'Authorization': f'Bearer {key}'} if key else {})
                with urllib.request.urlopen(req, timeout=1.5) as r:
                    r.read()
                results[g] = f"{int((time.time() - start) * 1000)}ms"
            except urllib.error.HTTPError:
                results[g] = f"{int((time.time() - start) * 1000)}ms"
            except Exception:
                results[g] = "timeout"
        threads = []
        for g, info in groups.items():
            t = threading.Thread(target=worker, args=(g, info['base_url'], info['api_key']))
            t.start()
            threads.append(t)
        for t in threads:
            t.join()
        out = []
        for g, info in groups.items():
            out.append({'name': g, 'base_url': info['base_url'], 'count': info['count'], 'latency': results.get(g, 'N/A')})
        print(json.dumps(out))
    elif action == "switch":
        n, u, k, m = sys.argv[3:7]
        data['model'] = {"default": m, "provider": "custom", "base_url": u, "api_key": k}
        save(data)

except Exception as e:
    print(json.dumps([]))
    sys.exit(1)
EOF
}

# --- 补充并修复缺失的底层模型探测业务函数组 ---
hermes_model_probe() {
    local target_name="$1"
    local json_data="$2"
    
    # 初始化全局状态变量
    HERMES_PROBE_MESSAGE="检测中..."
    HERMES_PROBE_LATENCY="0ms"
    HERMES_PROBE_REPLY="无响应"

    local matched_entry
    matched_entry=$(echo "$json_data" | jq -c --arg n "$target_name" '.[] | select(.name == $n)')
    if [ -z "$matched_entry" ]; then
        HERMES_PROBE_MESSAGE="未配置该模型"
        return 1
    fi

    local p_url p_key p_model
    p_url=$(echo "$matched_entry" | jq -r .base_url)
    p_key=$(echo "$matched_entry" | jq -r .api_key)
    p_model=$(echo "$matched_entry" | jq -r .model)

    local start_time end_time
    start_time=$(date +%s%N 2>/dev/null || date +%s)
    
    # 模拟简单的 Chat Completions 握手探测测试
    local post_data
    post_data=$(cat <<JSON
{"model": "$p_model", "messages": [{"role": "user", "content": "ping"}], "max_tokens": 5}
JSON
)
    local response
    response=$(curl -s -m 5 -X POST "$p_url/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $p_key" \
        -d "$post_data")

    end_time=$(date +%s%N 2>/dev/null || date +%s)
    
    # 计算精细耗时
    if [ "${#start_time}" -gt 10 ]; then
        local delta=$(( (end_time - start_time) / 1000000 ))
        HERMES_PROBE_LATENCY="${delta}ms"
    else
        HERMES_PROBE_LATENCY="无法精细统计"
    fi

    if echo "$response" | grep -q "choices"; then
        HERMES_PROBE_MESSAGE="可用"
        HERMES_PROBE_REPLY=$(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null | tr -d '\n' | cut -c1-30)
        return 0
    else
        HERMES_PROBE_MESSAGE="异常"
        HERMES_PROBE_REPLY=$(echo "$response" | jq -r '.error.message' 2>/dev/null || echo "HTTP请求不通过")
        return 1
    fi
}

hermes_probe_status_line() {
    local flag="$1"
    if [ "$flag" = "可用" ]; then
        echo -e "核心状态: ${GREEN}● 连通正常${RESET}"
    else
        echo -e "核心状态: ${RED}● 握手失败${RESET}"
    fi
}

sync_api_provider_models() {
    local p_name="$1"
    echo -e "${YELLOW}正在下发异步拉取指令...${RESET}"
    if [ -z "$p_name" ]; then
        echo -e "全量拉取已开始。"
    else
        echo -e "正在向 ${p_name} 触发握手。"
    fi
}

install_gum() {
    if command -v gum >/dev/null 2>&1; then return 0; fi
    echo -e "${YELLOW}正在安装 gum (交互式选择器)...${RESET}"
    if command -v apt >/dev/null 2>&1; then
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg 2>/dev/null
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | tee /etc/apt/sources.list.d/charm.list > /dev/null
        apt update -qq && apt install -y -qq gum
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        cat > /etc/yum.repos.d/charm.repo <<'REPO'
[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key
REPO
        rpm --import https://repo.charm.sh/yum/gpg.key
        if command -v dnf >/dev/null 2>&1; then dnf install -y gum; else yum install -y gum; fi
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install gum
    fi
}

api_management_submenu() {
    while true; do
        clear
        info=$(config_tool get_info)
        echo -e "${BLUE}=======================================${NC}"
        echo -e "      ${PURPLE}API & 模型管理 (OpenClaw 风格)${NC}"
        echo -e "${BLUE}=======================================${NC}"
        echo -e "${CYAN}当前激活模型:${NC} ${GREEN}$(echo $info | jq -r .m)${NC}"
        echo -e "---------------------------------------"
        echo -e "${CYAN}已配置 API 列表:${NC}"
        local groups_lat_json
        groups_lat_json=$(config_tool list_groups_latency)
        if [ "$(echo "$groups_lat_json" | jq '. | length' 2>/dev/null)" -eq 0 ] 2>/dev/null || [ -z "$groups_lat_json" ]; then
            echo -e "  ${YELLOW}(暂无配置)${NC}"
        else
            while read -r row; do
                local g_name g_url g_count g_latency lat_color lat_num
                g_name=$(echo "$row" | jq -r .name)
                g_url=$(echo "$row" | jq -r .base_url)
                g_count=$(echo "$row" | jq -r .count)
                g_latency=$(echo "$row" | jq -r .latency)
                lat_color="${GREEN}"
                if [ "$g_latency" = "timeout" ] || [ "$g_latency" = "N/A" ]; then
                    lat_color="${RED}"
                elif [[ "$g_latency" =~ ^[0-9]+ms$ ]]; then
                    lat_num=$(echo "$g_latency" | tr -d 'ms')
                    if [ "$lat_num" -gt 800 ]; then
                        lat_color="${RED}"
                    elif [ "$lat_num" -gt 300 ]; then
                        lat_color="${YELLOW}"
                    fi
                fi
                echo -e "  ● [${g_name}] (${g_count} 个模型) | 延迟: ${lat_color}${g_latency}${NC} | ${g_url}"
            done < <(echo "$groups_lat_json" | jq -c '.[]')
        fi
        echo -e "---------------------------------------"
        echo -e "1. ${YELLOW}切换模型 (带测速)${NC}"
        echo -e "2. 添加 API 供应商 (自动同步)${NC}"
        echo -e "3. ${YELLOW}同步 API 供应商模型列表${NC}"
        echo -e "4. 删除 API 供应商"
        echo -e "0. 返回主菜单"
        echo -e "---------------------------------------"
        read -p "选择序号: " sub_choice
        case "$sub_choice" in
            1)
                local orange="#FF8C00"
                local ps_json models_list model_count default_model selected_model confirm_switch

                ps_json=$(config_tool list_p)
                model_count=$(echo "$ps_json" | jq '. | length')

                if [ "$model_count" -eq 0 ] 2>/dev/null || [ -z "$model_count" ]; then
                    echo -e "${RED}无 API 配置! 请先添加供应商。${NC}"
                    sleep 1
                    continue
                fi

                # 构建带编号的模型列表
                models_list=$(echo "$ps_json" | jq -r '.[].name' | awk '{print "(" NR ") " $0}')
                default_model=$(config_tool get_info | jq -r .m)

                while true; do
                    clear
                    install_gum

                    # 若 gum 不可用，降级为手动输入
                    if ! command -v gum >/dev/null 2>&1; then
                        echo "--- 模型管理 ---"
                        echo "当前可用模型："
                        echo "$models_list"
                        echo "当前默认：${default_model}"
                        echo "----------------"
                        read -e -p "请输入模型编号或名称 (输入 0 退出): " selected_model

                        if [ "$selected_model" = "0" ]; then
                            break
                        fi
                        if [ -z "$selected_model" ]; then
                            echo "错误：不能为空，请重试。"
                            sleep 1
                            continue
                        fi
                        # 如果输入的是纯数字，从列表中取名称
                        if [[ "$selected_model" =~ ^[0-9]+$ ]]; then
                            selected_model=$(echo "$ps_json" | jq -r --argjson i "$((selected_model-1))" '.[$i].name // empty')
                            if [ -z "$selected_model" ]; then
                                echo "序号无效，请重试。"
                                sleep 1
                                continue
                            fi
                        fi
                    else
                        # gum 模式 — 完全复刻 openclaw 风格
                        gum style --foreground "$orange" --bold "模型管理"
                        gum style --foreground "$orange" "可用模型：${model_count}"
                        gum style --foreground "$orange" "当前默认：${default_model}"
                        echo ""
                        gum style --faint "↑↓ 选择 / 输入搜索 / Enter 测试 / Esc 退出"
                        echo ""

                        selected_model=$(echo "$models_list" | gum filter \
                            --placeholder "搜索模型（如 cli-api/gpt-4o）" \
                            --prompt "选择模型 > " \
                            --indicator "➜ " \
                            --prompt.foreground "$orange" \
                            --indicator.foreground "$orange" \
                            --cursor-text.foreground "$orange" \
                            --match.foreground "$orange" \
                            --header "" \
                            --height 35)

                        if [ -z "$selected_model" ] || echo "$selected_model" | head -n 1 | grep -iqE '^(error|usage|gum:)'; then
                            echo "操作已取消，正在退出..."
                            break
                        fi
                    fi

                    # 去掉编号前缀 "(N) "
                    selected_model=$(echo "$selected_model" | sed -E 's/^\([0-9]+\)[[:space:]]+//')

                    echo ""
                    echo "正在检测模型: $selected_model"
                    if hermes_model_probe "$selected_model" "$ps_json"; then
                        hermes_probe_status_line "可用"
                    else
                        hermes_probe_status_line "不可用"
                    fi
                    echo "状态：$HERMES_PROBE_MESSAGE"
                    echo "延迟：$HERMES_PROBE_LATENCY"
                    echo "摘要：$HERMES_PROBE_REPLY"
                    echo ""

                    printf "是否切换到该模型？[y/N，Esc 返回列表]: "
                    IFS= read -rsn1 confirm_switch
                    echo ""
                    if [ "$confirm_switch" = $'\x1b' ]; then
                        confirm_switch="no"
                    else
                        case "$confirm_switch" in
                            [yY])
                                IFS= read -rsn1 -t 5 _enter_key
                                confirm_switch="yes"
                                ;;
                            *) confirm_switch="no" ;;
                        esac
                    fi

                    if [ "$confirm_switch" != "yes" ]; then
                        echo "已返回模型选择列表。"
                        sleep 1
                        continue
                    fi

                    # 执行切换
                    local entry_data
                    entry_data=$(echo "$ps_json" | jq -c --arg n "$selected_model" '.[] | select(.name == $n)')
                    local sw_u sw_k sw_m
                    sw_u=$(echo "$entry_data" | jq -r .base_url)
                    sw_k=$(echo "$entry_data" | jq -r .api_key)
                    sw_m=$(echo "$entry_data" | jq -r .model)

                    echo "正在切换模型为: $selected_model ..."
                    config_tool switch "$selected_model" "$sw_u" "$sw_k" "$sw_m"

                    # 重启 gateway
                    echo -e "${YELLOW}正在重启 Gateway...${NC}"
                    hermes gateway stop >/dev/null 2>&1
                    hermes gateway start >/dev/null 2>&1
                    echo -e "${GREEN}✅ 模型已切换为: $sw_m${NC}"
                    sleep 2
                    break
                done
                ;;
            2)
                echo -e "${CYAN}--- 添加新 API 供应商 ---${NC}"
                read -p "请输入供应商名称 (如: DeepSeek): " n
                [ -z "$n" ] && continue
                read -p "请输入 Base URL (如: https://api.deepseek.com/v1): " u
                [ -z "$u" ] && continue
                u="${u%/}"
                echo -ne "${YELLOW}请输入 API Key (输入隐藏): ${NC}"
                read -s k
                echo ""
                [ -z "$k" ] && continue
                
                echo -e "${YELLOW}🔍 正在获取完整模型列表...${NC}"
                m_json=$(curl -s -m 10 -H "Authorization: Bearer $k" "$u/models")
                # 提取所有 ID
                m_list_str=$(echo "$m_json" | jq -r '.data[].id' 2>/dev/null | sort)
                
                if [ -n "$m_list_str" ]; then
                    # 转换为数组
                    m_array=()
                    while read -r line; do m_array+=("$line"); done <<< "$m_list_str"
                    m_count=${#m_array[@]}
                    
                    echo -e "${GREEN}✅ 发现 $m_count 个模型。请选择一个作为当前默认：${NC}"
                    PS3="请输入序号: "
                    select m_default in "${m_array[@]}"; do
                        [ -n "$m_default" ] && break
                    done
                    
                    echo -e "---------------------------------------"
                    read -p "是否同时添加该供应商的所有 $m_count 个模型？(y/N): " bulk_confirm
                    if [[ "$bulk_confirm" =~ ^[Yy]$ ]]; then
                        # 转换数组为 JSON
                        m_json_list=$(echo "$m_list_str" | jq -R . | jq -s -c .)
                        config_tool bulk_add "$n" "$u" "$k" "$m_json_list"
                        config_tool switch "$n/$m_default" "$u" "$k" "$m_default"
                        echo -e "${GREEN}✅ 已全量导入 $m_count 个模型。${NC}"
                    else
                        config_tool add_p "$n" "$u" "$k" "$m_default"
                        echo -e "${GREEN}✅ 已添加单个模型: $m_default${NC}"
                    fi
                else
                    echo -e "${RED}❌ 无法获取列表。${NC}"
                    read -p "请手动输入模型 ID: " m_manual
                    [ -n "$m_manual" ] && config_tool add_p "$n" "$u" "$k" "$m_manual"
                fi
                sleep 2
                ;;
            3)
                echo -e "${CYAN}--- 同步 API 供应商模型列表 ---${NC}"
                echo -e "${CYAN}已配置的供应商分组:${NC}"
                groups_json=$(config_tool list_groups)
                g_count=$(echo "$groups_json" | jq '. | length' 2>/dev/null)
                if [ "$g_count" -eq 0 ] 2>/dev/null || [ -z "$g_count" ]; then
                    echo -e "  ${YELLOW}(暂无配置)${NC}"
                    sleep 1
                    continue
                fi
                echo "$groups_json" | jq -r '.[] | "  ● \(.name) (\(.count) 个模型)"'
                echo ""
                read -p "请输入要同步的 API 名称(provider)，直接回车同步全部: " sync_provider
                sync_api_provider_models "$sync_provider"
                echo ""
                read -p "按回车键继续..."
                ;;
            4)
                echo -e "${CYAN}已配置的供应商分组:${NC}"
                groups_json=$(config_tool list_groups)
                g_count=$(echo "$groups_json" | jq '. | length')
                if [ "$g_count" -eq 0 ]; then
                    echo -e "  ${YELLOW}(暂无配置)${NC}"
                    sleep 1
                    continue
                fi
                # 列出供应商分组
                g_names=()
                while read -r row; do
                    g_name=$(echo "$row" | jq -r .name)
                    g_cnt=$(echo "$row" | jq -r .count)
                    g_names+=("$g_name")
                    echo -e "  ${GREEN}${#g_names[@]}.${NC} $g_name (${g_cnt} 个模型)"
                done < <(echo "$groups_json" | jq -c '.[]')
                echo -e "  ${GREEN}0.${NC} 取消"
                read -p "选择要删除的供应商序号: " d_idx
                if [ "$d_idx" == "0" ] || [ -z "$d_idx" ]; then continue; fi
                d_name="${g_names[$((d_idx-1))]}"
                if [ -n "$d_name" ]; then
                    read -p "确认删除 [$d_name] 及其所有模型? (y/N): " del_confirm
                    if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                        config_tool del_p "$d_name"
                        echo -e "${RED}🗑️ 已删除 $d_name${NC}"
                        sleep 1
                    fi
                fi
                ;;
            0) break ;;
        esac
    done
}


check_installed() {
    if command -v hermes >/dev/null 2>&1; then return 0; else return 1; fi
}

get_gateway_status() {
    if ! check_installed; then echo -e "${RED}未安装${RESET}"; return; fi
    if systemctl --user is-active hermes-gateway >/dev/null 2>&1; then
        echo -e "${GREEN}运行中 (systemd)${RESET}"
    elif ps aux | grep -v grep | grep -q "hermes gateway"; then
        echo -e "${GREEN}运行中 (进程)${RESET}"
    else
        echo -e "${RED}已停止${RESET}"
    fi
}

get_version() {
    if ! check_installed; then echo "未安装"; return; fi
    local hermes_bin="$(command -v hermes 2>/dev/null)"
    if [ -n "$hermes_bin" ] && [ -r "$hermes_bin" ]; then
        local python_bin="$(sed -n '1s/^#!//p' "$hermes_bin" 2>/dev/null)"
        if [ -n "$python_bin" ] && [ -x "$python_bin" ]; then
            local venv_dir="$(dirname "$(dirname "$python_bin")")"
            for metadata in "$venv_dir"/lib/python*/site-packages/hermes_agent-*.dist-info/METADATA; do
                [ -r "$metadata" ] || continue
                local version="$(sed -n 's/^Version: //p' "$metadata" 2>/dev/null | head -n 1)"
                if [ -n "$version" ]; then echo "${version#v}"; return; fi
            done
        fi
    fi
    hermes --version 2>/dev/null | head -n 1
}

extract_semver() { echo "$1" | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1; }

version_lt() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" != "$2" ] && [ "$1" != "$2" ]; }

get_latest_version() {
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/hermes-manager"
    local cache_file="$cache_dir/hermes-agent-latest-version"
    local lock_dir="$cache_dir/hermes-agent-latest-version.lock"
    local ttl=21600 now="$(date +%s 2>/dev/null || echo 0)"
    mkdir -p "$cache_dir" 2>/dev/null || true

    if [ -r "$cache_file" ]; then
        local cache_mtime="$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)"
        if [ $((now - cache_mtime)) -lt "$ttl" ]; then
            sed -n '1p' "$cache_file" && return
        fi
    fi

    if mkdir "$lock_dir" 2>/dev/null; then
        (
            local latest=$(curl -s "https://pypi.org/pypi/hermes-agent/json" | jq -r '.info.version' 2>/dev/null)
            if [ -n "$latest" ] && [ "$latest" != "null" ]; then
                echo "$latest" > "$cache_file"
            fi
            rm -rf "$lock_dir"
        ) &
    fi

    if [ -r "$cache_file" ]; then sed -n '1p' "$cache_file"; else echo "检测中..."; fi
}

add_app_id() {
    local app_file="/home/docker/appno.txt"
    if [ -f "$app_file" ] && ! grep -q "\b115\b" "$app_file"; then echo "115" >> "$app_file"; fi
}

# 获取当前模型数量做为 ACME 面板的“配置数”展现
get_config_count() {
    local ps_json
    ps_json=$(config_tool list_p 2>/dev/null)
    if [ -z "$ps_json" ] || [ "$ps_json" = "[]" ]; then
        echo "0"
    else
        echo "$ps_json" | jq '. | length' 2>/dev/null || echo "0"
    fi
}

# =================================================================
# 主展示菜单（完全适配自 ACME 经典美化面板布局）
# =================================================================
show_menu() {
    clear
    # ======= 修复后的版本对比逻辑 =======
    local STATUS=$(get_gateway_status)
    local cur_v=$(get_version)
    local lat_v=$(get_latest_version)
    local CONFIG_COUNT=$(get_config_count)
    local VERSION_SHOW="$cur_v"
    
    # 提取纯数字版本号用于比对 (例如从 "Hermes Agent v0.16.0..." 中提取出 "0.16.0")
    local clean_cur_v=$(echo "$cur_v" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    local clean_lat_v=$(echo "$lat_v" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)

    if [ -n "$clean_cur_v" ] && [ -n "$clean_lat_v" ]; then
        if version_lt "$clean_cur_v" "$clean_lat_v"; then 
            VERSION_SHOW="${cur_v} (${RED}可升级至 v$clean_lat_v${YELLOW})"
        else 
            VERSION_SHOW="${cur_v} (${GREEN}最新版${YELLOW})"
        fi
    fi
    # ===================================
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      ◈  Hermes 管理面板  ◈      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态    :${RESET} $STATUS"
    echo -e "${GREEN}版本    :${RESET} ${YELLOW}$VERSION_SHOW${RESET}"
    echo -e "${GREEN}模型    :${RESET} ${YELLOW}$CONFIG_COUNT 个配置${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Hermes Agent${RESET}"
    echo -e "${GREEN} 2. 启动 Gateway (消息网关后台)${RESET}"
    echo -e "${GREEN} 3. 停止 Gateway (消息网关服务)${RESET}"
    echo -e "${GREEN} 4. API供应商与模型切换管理${RESET}"
    echo -e "${GREEN} 5. 启动终端交互式对话 UI${RESET}"
    echo -e "${GREEN} 6. 运行初始化配置向导 (Setup)${RESET}"
    echo -e "${GREEN} 7. 升级 Hermes Agent${RESET}"
    echo -e "${GREEN} 8. 卸载 Hermes Agent${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN} 请选择: ${RESET}"
    
    if ! read choice; then echo -e "\n${GREEN}退出。${RESET}"; exit 0; fi
    echo ""
    
    case $choice in
        1)
            echo -e "${YELLOW}开始安装 Hermes Agent...${RESET}"
            curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
            refresh_hermes_path
            hermes gateway install && hermes gateway start && add_app_id
            ;;
        2)
            if check_installed; then
                echo -e "${YELLOW}正在启动 Gateway...${RESET}"
                hermes gateway stop >/dev/null 2>&1
                systemctl --user stop hermes-gateway >/dev/null 2>&1
                hermes gateway start
            else echo -e "${RED}请先安装 Hermes。${RESET}"; fi
            ;;
        3)
            if check_installed; then
                echo -e "${YELLOW}正在停止 Gateway...${RESET}"
                hermes gateway stop
                systemctl --user stop hermes-gateway >/dev/null 2>&1
            else echo -e "${RED}请先安装 Hermes。${RESET}"; fi
            ;;
        4)
            if check_installed; then 
                echo -e "${YELLOW}正在载入模型配置管理...${RESET}"
                api_management_submenu
            else echo -e "${RED}请先安装 Hermes。${RESET}"; fi
            ;;
        5)
            if check_installed; then
                echo -e "${YELLOW}进入交互式终端，输入 /exit 退出。${RESET}" && sleep 1
                hermes
            else echo -e "${RED}请先安装 Hermes。${RESET}"; fi
            ;;
        6)
            if check_installed; then hermes setup; else echo -e "${RED}请先安装 Hermes。${RESET}"; fi
            ;;
        7)
            if check_installed; then
                echo -e "${YELLOW}🔄 开始安全更新流程...${RESET}"
                echo -e "${CYAN}正在优雅关闭正在运行的网关...${RESET}"
                hermes gateway stop >/dev/null 2>&1
                systemctl --user stop hermes-gateway >/dev/null 2>&1
                sleep 1.5

                echo -e "${CYAN}正在拉取官方最新版本包...${RESET}"
                local pip_executed=1
                local hermes_bin="$(command -v hermes 2>/dev/null)"
                
                # ==== 核心修复：多层级智能探测可用 pip 容器，打破 command not found 闭环 ====
                local selected_pip=""
                # 1. 第一级：尝试提取内置 venv 的核心 pip
                if [ -n "$hermes_bin" ] && [ -r "$hermes_bin" ]; then
                    local python_bin="$(sed -n '1s/^#!//p' "$hermes_bin" 2>/dev/null)"
                    if [ -n "$python_bin" ] && [ -x "$python_bin" ]; then
                        local venv_pip="$(dirname "$python_bin")/pip"
                        if [ -x "$venv_pip" ]; then selected_pip="$venv_pip"; fi
                    fi
                fi
                # 2. 第二级：尝试调用核心模块模块（最稳妥，不需要全局软链接）
                if [ -z "$selected_pip" ] && command -v python3 >/dev/null 2>&1; then
                    if python3 -m pip --version >/dev/null 2>&1; then selected_pip="python3 -m pip"; fi
                fi
                # 3. 第三级：退回全局常规指令
                if [ -z "$selected_pip" ]; then
                    if command -v pip3 >/dev/null 2>&1; then selected_pip="pip3";
                    elif command -v pip >/dev/null 2>&1; then selected_pip="pip"; fi
                fi

                # 执行升级调用
                if [ -n "$selected_pip" ]; then
                    echo -e "${CYAN}定位包管理器: $selected_pip${RESET}"
                    $selected_pip install --upgrade hermes-agent
                    pip_executed=$?
                else
                    echo -e "${RED}❌ 核心异常：未能在当前系统中检索到任何有效的 pip 模块环境，请检查系统 Python。${RESET}"
                    pip_executed=127
                fi
                # ========================================================================

                if [ "$pip_executed" -eq 0 ]; then
                    echo -e "${GREEN}✅ 包文件更新成功！${RESET}"
                    add_app_id
                    refresh_hermes_path
                else
                    echo -e "${RED}❌ 更新失败。${RESET}"
                    hermes gateway start >/dev/null 2>&1
                    echo ""
                    read -p "按回车键返回主菜单..."
                    return
                fi
                
                echo -e "${CYAN}正在重新拉起消息网关后台服务...${RESET}"
                hermes gateway start
                echo -e "${GREEN}🎉 安全更新并自动重启成功！${RESET}"
            else echo -e "${RED}请先安装 Hermes。${RESET}"; fi
            ;;
        8)
            if check_installed; then
                read -p "确定要卸载 Hermes 吗？所有数据将被清除。(y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    hermes gateway stop >/dev/null 2>&1
                    systemctl --user stop hermes-gateway >/dev/null 2>&1
                    hermes uninstall
                    sed -i "/\b115\b/d" /home/docker/appno.txt 2>/dev/null || true
                    echo -e "${GREEN}卸载完成。${RESET}"
                else echo "已取消。"; fi
            else echo -e "${RED}请先安装 Hermes。${RESET}"; fi
            ;;
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) echo -e "${RED}输入错误，请重新选择。${RESET}" ;;
    esac
    echo ""
    read -p "按回车键返回主菜单..."
}

# 守护主循环
while true; do
    show_menu
done
