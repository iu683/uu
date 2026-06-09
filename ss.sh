#!/bin/bash
# Hermes Agent 终端管理脚本 


# 颜色定义 (严格适配 ACME 风格命名)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
RESET='\033[0m'

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

# --- 核心配置管理 API 工具 ---
CONFIG_FILE="$HOME/.hermes/config.yaml"

config_tool() {
    if [ ! -f "$CONFIG_FILE" ]; then
        local p
        for p in "/root/.hermes/config.yaml" /home/*/.hermes/config.yaml; do
            if [ -f "$p" ]; then CONFIG_FILE="$p"; break; fi
        done
    fi

    local python_bin=""
    local hermes_cmd
    hermes_cmd=$(command -v hermes)
    if [ -n "$hermes_cmd" ] && [ -f "$hermes_cmd" ]; then
        local shebang
        shebang=$(head -n 1 "$hermes_cmd" 2>/dev/null)
        if [[ "$shebang" =~ ^#\! ]]; then
            local potential_py="${shebang#\#!}"
            if [ -f "$potential_py" ] && "$potential_py" -c "import yaml" >/dev/null 2>&1; then
                python_bin="$potential_py"
            fi
        fi
    fi

    if [ -z "$python_bin" ]; then
        local paths=(
            "$HOME/.hermes/hermes-agent/venv/bin/python3"
            "/root/.hermes/hermes-agent/venv/bin/python3"
            "/usr/local/lib/hermes-agent/venv/bin/python3"
            "/usr/lib/hermes-agent/venv/bin/python3"
        )
        local p
        for p in "${paths[@]}"; do
            if [ -f "$p" ] && "$p" -c "import yaml" >/dev/null 2>&1; then python_bin="$p"; break; fi
        done
    fi

    if [ -z "$python_bin" ]; then
        if command -v python3 >/dev/null 2>&1; then python_bin="python3"; else python_bin="python"; fi
    fi

    $python_bin - "$CONFIG_FILE" "$@" <<'EOF'
import sys, yaml, json, os
path = sys.argv[1]
action = sys.argv[2]

def load():
    if not os.path.exists(path): return {}
    try:
        with open(path, 'r', encoding='utf-8') as f: return yaml.safe_load(f) or {}
    except: return {}

def save(d):
    with open(path, 'w', encoding='utf-8') as f: yaml.dump(d, f, sort_keys=False, allow_unicode=True)

try:
    data = load()
    if action == "get_info":
        m = data.get('model', {})
        print(json.dumps({"m": m.get('default', '-'), "p": m.get('provider', '-'), "u": m.get('base_url', '-move')}))
    elif action == "list_p":
        print(json.dumps(data.get('custom_providers', [])))
    elif action == "add_p":
        n, u, k, m = sys.argv[3:7]
        ps = data.get('custom_providers', []) or []
        ps = [p for p in ps if p.get('name') != n]
        ps.append({"name": n, "base_url": u, "api_key": k, "model": m})
        data['custom_providers'] = ps
        save(data)
    elif action == "bulk_add":
        n_base, u, k, models_json = sys.argv[3:7]
        new_m_ids = json.loads(models_json)
        ps = data.get('custom_providers', []) or []
        ps = [p for p in ps if not (isinstance(p, dict) and p.get('name', '').startswith(n_base + "/")) and p.get('name') != n_base]
        for m_id in new_m_ids: ps.append({"name": f"{n_base}/{m_id}", "base_url": u, "api_key": k, "model": m_id})
        data['custom_providers'] = ps
        save(data)
    elif action == "del_p":
        n = sys.argv[3]
        ps = data.get('custom_providers', []) or []
        data['custom_providers'] = [p for p in ps if p.get('name') != n and not p.get('name', '').startswith(n + "/")]
        save(data)
    elif action == "list_groups":
        ps = data.get('custom_providers', []) or []
        groups, seen = [], set()
        for p in ps:
            name = p.get('name', '')
            g = name.split('/')[0] if '/' in name else name
            if g and g not in seen:
                seen.add(g)
                cnt = sum(1 for x in ps if x.get('name', '') == g or x.get('name', '').startswith(g + '/'))
                groups.append({"name": g, "count": cnt})
        print(json.dumps(groups))
    elif action == "list_groups_latency":
        import threading, urllib.request, time
        ps = data.get('custom_providers', []) or []
        groups = {}
        for p in ps:
            name = p.get('name', '')
            g = name.split('/')[0] if '/' in name else name
            if g not in groups: groups[g] = {'name': g, 'base_url': p.get('base_url', ''), 'api_key': p.get('api_key', ''), 'count': 0}
            groups[g]['count'] += 1
        results = {}
        def worker(g, url, key):
            if not url or not (url.startswith('http://') or url.startswith('https://')): results[g] = "N/A"; return
            start = time.time()
            try:
                req = urllib.request.Request(url.rstrip('/') + '/models', headers={'Authorization': f'Bearer {key}'} if key else {})
                with urllib.request.urlopen(req, timeout=1.5) as r: r.read()
                results[g] = f"{int((time.time() - start) * 1000)}ms"
            except: results[g] = "timeout"
        threads = [threading.Thread(target=worker, args=(g, info['base_url'], info['api_key'])) for g, info in groups.items()]
        for t in threads: t.start()
        for t in threads: t.join()
        print(json.dumps([{'name': g, 'base_url': info['base_url'], 'count': info['count'], 'latency': results.get(g, 'N/A')} for g, info in groups.items()]))
    elif action == "switch":
        n, u, k, m = sys.argv[3:7]
        data['model'] = {"default": m, "provider": "custom", "base_url": u, "api_key": k}
        save(data)
except Exception as e:
    print(json.dumps([]))
    sys.exit(1)
EOF
}

# 绿色免 APT 污染 Gum 安装器
install_gum() {
    if command -v gum >/dev/null 2>&1; then return 0; fi
    
    local arch=$(uname -m)
    local g_arch="amd64"
    if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then g_arch="arm64"; fi

    local gum_version="0.14.5"
    local tmp_dir="/tmp/gum_install"
    mkdir -p "$tmp_dir"
    
    curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v${gum_version}/gum_${gum_version}_Linux_${g_arch}.tar.gz" -o "$tmp_dir/gum.tar.gz" >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        tar -zxf "$tmp_dir/gum.tar.gz" -C "$tmp_dir" >/dev/null 2>&1
        mv "$tmp_dir/gum_${gum_version}_Linux_${g_arch}/gum" /usr/local/bin/ 2>/dev/null || mv "$tmp_dir/gum" /usr/local/bin/ 2>/dev/null
        chmod +x /usr/local/bin/gum 2>/dev/null
        rm -rf "$tmp_dir"
        if command -v gum >/dev/null 2>&1; then return 0; fi
    fi
    return 1
}

check_installed() { if command -v hermes >/dev/null 2>&1; then return 0; else return 1; fi; }

get_gateway_status() {
    if ! check_installed; then echo -e "${RED}未安装${RESET}"; return; fi
    if systemctl --user is-active hermes-gateway >/dev/null 2>&1; then echo -e "${GREEN}运行中 (systemd)${RESET}"
    elif ps aux | grep -v grep | grep -q "hermes gateway"; then echo -e "${GREEN}运行中 (进程)${RESET}"
    else echo -e "${RED}已停止${RESET}"; fi
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

version_lt() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" != "$2" ] && [ "$1" != "$2" ]; }

get_latest_version() {
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/hermes-manager"
    local cache_file="$cache_dir/hermes-agent-latest-version"
    mkdir -p "$cache_dir" 2>/dev/null
    if [ -r "$cache_file" ] && [ $(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0))) -lt 21600 ]; then
        sed -n '1p' "$cache_file" && return
    fi
    (
        local latest=$(curl -s --connect-timeout 2 "https://pypi.org/pypi/hermes-agent/json" | jq -r '.info.version' 2>/dev/null)
        if [ -n "$latest" ] && [ "$latest" != "null" ]; then echo "$latest" > "$cache_file"; fi
    ) &
    if [ -r "$cache_file" ]; then sed -n '1p' "$cache_file"; else echo "检测中..."; fi
}

add_app_id() {
    local app_file="/home/docker/appno.txt"
    if [ -f "$app_file" ] && ! grep -q "\b115\b" "$app_file"; then echo "115" >> "$app_file"; fi
}

get_config_count() {
    local ps_json=$(config_tool list_p 2>/dev/null)
    if [ -z "$ps_json" ] || [ "$ps_json" = "[]" ]; then echo "0"; else echo "$ps_json" | jq '. | length' 2>/dev/null || echo "0"; fi
}

# =================================================================
# 子菜单：API 与模型管理 (完全 ACME 风格化重构)
# =================================================================
api_management_submenu() {
    while true; do
        clear
        info=$(config_tool get_info)
        local active_model=$(echo "$info" | jq -r .m)
        [ -z "$active_model" ] || [ "$active_model" = "null" ] && active_model="- "

        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}      ◈  API & 模型管理  ◈      ${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}当前激活 :${RESET} ${YELLOW}${active_model}${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN}已配置 API 列表:${RESET}"
        
        local groups_lat_json=$(config_tool list_groups_latency)
        if [ "$(echo "$groups_lat_json" | jq '. | length' 2>/dev/null)" -eq 0 ] 2>/dev/null || [ -z "$groups_lat_json" ]; then
            echo -e "  ${YELLOW}(暂无配置)${RESET}"
        else
            while read -r row; do
                local g_name=$(echo "$row" | jq -r .name)
                local g_url=$(echo "$row" | jq -r .base_url)
                local g_count=$(echo "$row" | jq -r .count)
                local g_latency=$(echo "$row" | jq -r .latency)
                local lat_color="${GREEN}"
                if [ "$g_latency" = "timeout" ] || [ "$g_latency" = "N/A" ]; then lat_color="${RED}"
                elif [[ "$g_latency" =~ ^[0-9]+ms$ ]]; then
                    local lat_num=$(echo "$g_latency" | tr -d 'ms')
                    if [ "$lat_num" -gt 800 ]; then lat_color="${RED}"; elif [ "$lat_num" -gt 300 ]; then lat_color="${YELLOW}"; fi
                fi
                echo -e "  ${CYAN}●${RESET} [${g_name}] (${g_count}个模型) | 延迟: ${lat_color}${g_latency}${RESET} | ${g_url}"
            done < <(echo "$groups_lat_json" | jq -c '.[]')
        fi
        
        echo -e "${GREEN}================================${RESET}"
        echo -e "${GREEN} 1. 切换模型 (带测速)${RESET}"
        echo -e "${GREEN} 2. 添加 API 供应商 (自动同步)${RESET}"
        echo -e "${GREEN} 3. 同步 API 供应商模型列表${RESET}"
        echo -e "${GREEN} 4. 删除 API 供应商${RESET}"
        echo -e "${GREEN} 0. 返回主菜单${RESET}"
        echo -e "${GREEN}================================${RESET}"
        echo -ne "${GREEN} 请选择: ${RESET}"
        if ! read sub_choice; then break; fi
        echo ""
        
        case "$sub_choice" in
            1)
                local orange="#FF8C00"
                local ps_json=$(config_tool list_p)
                local model_count=$(echo "$ps_json" | jq '. | length')
                if [ "$model_count" -eq 0 ] 2>/dev/null || [ -z "$model_count" ]; then
                    echo -e "${RED}无 API 配置! 请先添加供应商。${RESET}" && sleep 1 && continue
                fi
                local models_list=$(echo "$ps_json" | jq -r '.[].name' | awk '{print "(" NR ") " $0}')
                local default_model=$(config_tool get_info | jq -r .m)

                while true; do
                    clear
                    install_gum >/dev/null 2>&1
                    if ! command -v gum >/dev/null 2>&1; then
                        echo -e "${GREEN}================================${RESET}"
                        echo -e "${GREEN}      ◈  模型管理 (普通模式)  ◈      ${RESET}"
                        echo -e "${GREEN}================================${RESET}"
                        echo -e "${CYAN}当前可用模型：${RESET}"
                        echo "$models_list" | sed 's/^/  /'
                        echo -e "--------------------------------"
                        echo -e "${CYAN}当前默认：${RESET}${YELLOW}${default_model}${RESET}"
                        echo -e "${GREEN}================================${RESET}"
                        read -e -p "请输入模型编号或名称 (输入 0 退出): " selected_model
                        if [ "$selected_model" = "0" ] || [ -z "$selected_model" ]; then break; fi
                        if [[ "$selected_model" =~ ^[0-9]+$ ]]; then
                            selected_model=$(echo "$ps_json" | jq -r --argjson i "$((selected_model-1))" '.[$i].name // empty')
                            if [ -z "$selected_model" ]; then echo -e "${RED}❌ 序号无效。${RESET}" && sleep 1 && continue; fi
                        fi
                        break
                    else
                        gum style --foreground "$orange" --bold "◈ 模型管理 (高级模式)"
                        gum style --foreground "$orange" "可用模型：${model_count} | 当前默认：${default_model}"
                        echo ""
                        selected_model=$(echo "$models_list" | gum filter --placeholder "搜索模型..." --prompt "选择模型 > " --height 15)
                        if [ -z "$selected_model" ] || echo "$selected_model" | head -n 1 | grep -iqE '^(error|usage|gum:)'; then break; fi
                        break
                    fi
                done

                [ -z "$selected_model" ] || [ "$selected_model" = "0" ] && continue
                selected_model=$(echo "$selected_model" | sed -E 's/^\([0-9]+\)[[:space:]]+//')
                
                echo -e "正在切换模型为: $selected_model ..."
                local entry_data=$(echo "$ps_json" | jq -c --arg n "$selected_model" '.[] | select(.name == $n)')
                config_tool switch "$selected_model" "$(echo "$entry_data" | jq -r .base_url)" "$(echo "$entry_data" | jq -r .api_key)" "$(echo "$entry_data" | jq -r .model)"
                hermes gateway stop >/dev/null 2>&1 && hermes gateway start >/dev/null 2>&1
                echo -e "${GREEN}✅ 模型已成功切换！${RESET}" && sleep 1.5
                ;;
            2)
                echo -e "${CYAN}--- 添加新 API 供应商 ---${RESET}"
                read -p "请输入供应商名称 (如: DeepSeek): " n
                [ -z "$n" ] && continue
                read -p "请输入 Base URL: " u
                [ -z "$u" ] && continue
                u="${u%/}"
                echo -ne "${YELLOW}请输入 API Key (输入隐藏): ${RESET}"
                read -s k
                echo ""
                [ -z "$k" ] && continue
                
                echo -e "${YELLOW}🔍 正在获取完整模型列表...${RESET}"
                local m_json=$(curl -s -m 10 -H "Authorization: Bearer $k" "$u/models")
                local m_list_str=$(echo "$m_json" | jq -r '.data[].id' 2>/dev/null | sort)
                if [ -n "$m_list_str" ]; then
                    m_array=()
                    while read -r line; do m_array+=("$line"); done <<< "$m_list_str"
                    echo -e "${GREEN}✅ 发现 ${#m_array[@]} 个模型。请选择一个作为当前默认：${RESET}"
                    PS3="请输入序号: "
                    select m_default in "${m_array[@]}"; do [ -n "$m_default" ] && break; done
                    read -p "是否同时添加所有模型？(y/N): " bulk_confirm
                    if [[ "$bulk_confirm" =~ ^[Yy]$ ]]; then
                        config_tool bulk_add "$n" "$u" "$k" "$(echo "$m_list_str" | jq -R . | jq -s -c .)"
                        config_tool switch "$n/$m_default" "$u" "$k" "$m_default"
                    else
                        config_tool add_p "$n" "$u" "$k" "$m_default"
                    fi
                    echo -e "${GREEN}✅ 导入完成。${RESET}"
                else
                    read -p "❌ 无法自动拉取。请手动输入默认模型 ID: " m_manual
                    [ -n "$m_manual" ] && config_tool add_p "$n" "$u" "$k" "$m_manual"
                fi
                sleep 1.5
                ;;
            3)
                echo -e "${CYAN}--- 同步模型列表 ---${RESET}"
                read -p "请输入要同步的 API 供应商名称(直接回车同步全部): " sync_provider
                if command -v sync_api_provider_models >/dev/null 2>&1; then sync_api_provider_models "$sync_provider"; fi
                read -p "同步指令已下发，按回车键继续..."
                ;;
            4)
                echo -e "${CYAN}已配置的供应商分组:${RESET}"
                local groups_json=$(config_tool list_groups)
                if [ "$(echo "$groups_json" | jq '. | length')" -eq 0 ]; then echo -e "  ${YELLOW}(暂无配置)${RESET}" && sleep 1 && continue; fi
                g_names=()
                while read -r row; do
                    local g_name=$(echo "$row" | jq -r .name)
                    g_names+=("$g_name")
                    echo -e "  ${GREEN}${#g_names[@]}.${RESET} $g_name ($(echo "$row" | jq -r .count) 个模型)"
                done < <(echo "$groups_json" | jq -c '.[]')
                read -p "选择要删除的供应商序号 (0取消): " d_idx
                if [ "$d_idx" == "0" ] || [ -z "$d_idx" ]; then continue; fi
                local d_name="${g_names[$((d_idx-1))]}"
                if [ -n "$d_name" ]; then
                    read -p "确认删除 [$d_name] 及其所有模型? (y/N): " del_confirm
                    if [[ "$del_confirm" =~ ^[Yy]$ ]]; then config_tool del_p "$d_name" && echo -e "${RED}🗑️ 已删除${RESET}" && sleep 1; fi
                fi
                ;;
            0) break ;;
        esac
    done
}

# =================================================================
# 主展示菜单 (完全适配自 ACME 经典美化面板布局)
# =================================================================
show_menu() {
    clear
    local STATUS=$(get_gateway_status)
    local cur_v=$(get_version)
    local lat_v=$(get_latest_version)
    local CONFIG_COUNT=$(get_config_count)
    
    local clean_cur_v=$(echo "$cur_v" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    local clean_lat_v=$(echo "$lat_v" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)

    local VERSION_SHOW="v$clean_cur_v"
    [ -z "$clean_cur_v" ] && VERSION_SHOW="$cur_v"
    
    if [ -n "$clean_cur_v" ] && [ -n "$clean_lat_v" ]; then
        if version_lt "$clean_cur_v" "$clean_lat_v"; then 
            VERSION_SHOW="${VERSION_SHOW} (${RED}可升级至 v$clean_lat_v${YELLOW})"
        else 
            VERSION_SHOW="${VERSION_SHOW} (${GREEN}最新版${YELLOW})"
        fi
    fi

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
            if check_installed; then api_management_submenu; else echo -e "${RED}请先安装 Hermes。${RESET}"; fi
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
                hermes gateway stop >/dev/null 2>&1
                systemctl --user stop hermes-gateway >/dev/null 2>&1
                
                local pip_executed=1
                local hermes_bin="$(command -v hermes 2>/dev/null)"
                if [ -n "$hermes_bin" ] && [ -r "$hermes_bin" ]; then
                    local python_bin="$(sed -n '1s/^#!//p' "$hermes_bin" 2>/dev/null)"
                    if [ -n "$python_bin" ] && [ -x "$python_bin" ]; then
                        local venv_pip="$(dirname "$python_bin")/pip"
                        if [ -x "$venv_pip" ]; then "$venv_pip" install --upgrade hermes-agent; pip_executed=$?; fi
                    fi
                fi
                if [ "$pip_executed" -ne 0 ]; then pip install --upgrade hermes-agent; pip_executed=$?; fi

                if [ "$pip_executed" -eq 0 ]; then
                    echo -e "${GREEN}✅ 更新成功！${RESET}" && add_app_id && refresh_hermes_path
                else
                    echo -e "${RED}❌ 更新失败。${RESET}"
                fi
                hermes gateway start >/dev/null 2>&1
            else echo -e "${RED}请先安装 Hermes。${RESET}"; fi
            ;;
        8)
            if check_installed; then
                read -p "确定要卸载 Hermes 吗？(y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    hermes gateway stop >/dev/null 2>&1
                    systemctl --user stop hermes-gateway >/dev/null 2>&1
                    hermes uninstall
                    sed -i "/\b115\b/d" /home/docker/appno.txt 2>/dev/null || true
                    echo -e "${GREEN}卸载完成。${RESET}"
                fi
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
