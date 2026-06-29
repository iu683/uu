generate_link() {
    local instance="$1"
    local file="${CONFIG_DIR}/config_${instance}.json"
    [[ ! -f "$file" ]] && return 1
    
    local ip uuid port domain shortid pubkey display_ip hostname
    ip=$(get_public_ip)
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$file" 2>/dev/null || echo "")
    port=$(jq -r '.inbounds[0].port' "$file" 2>/dev/null || echo "")
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$file" 2>/dev/null || echo "")
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$file" 2>/dev/null || echo "")
    pubkey=$(jq -r '._meta.pubkey' "$file" 2>/dev/null || echo "")
    
    display_ip="$ip"; [[ "$ip" =~ ":" ]] && display_ip="[$ip]"
    hostname=$(hostname -s 2>/dev/null || echo "Xray")
    
    cat > "${LINK_DIR}/xray_${instance}.txt" <<EOF
vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${pubkey}&sid=${shortid}&spx=%2F#${hostname}-${instance}-Reality
EOF
}

print_node_summary() {
    local instance="$1"
    local file="${CONFIG_DIR}/config_${instance}.json"
    if [ ! -f "$file" ]; then return; fi

    generate_link "$instance"

    echo -e "\n${GREEN}== Xray 实例${RESET}${YELLOW} [ ${instance} ]${RESET} ${GREEN}配置详情 ==${RESET}"
    echo -e "${GREEN}实例协议     :${RESET} ${YELLOW}VLESS-REALITY (TCP + Vision)${RESET}"
    echo -e "${GREEN}外网绑定 IP  :${RESET} $(get_public_ip)"
    echo -e "${GREEN}监听端口     :${RESET} $(jq -r '.inbounds[0].port' "$file" 2>/dev/null)"
    echo -e "${GREEN}用户凭证UUID :${RESET} $(jq -r '.inbounds[0].settings.clients[0].id' "$file" 2>/dev/null)"
    echo -e "${GREEN}伪装SNI域名  :${RESET} $(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$file" 2>/dev/null)"
    echo -e "${GREEN}公钥 PBK     :${RESET} $(jq -r '._meta.pubkey' "$file" 2>/dev/null)"
    echo -e "${GREEN}ShortID      :${RESET} $(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$file" 2>/dev/null)"
    echo -e "${GREEN}配置文件路径 :${RESET} ${file}"
    echo -e "${GREEN}--------------------------------------------${RESET}"
    if [[ -f "${LINK_DIR}/xray_${instance}.txt" ]]; then
        echo -e "${GREEN}👉 标准通用分享链接:${RESET}"
        echo -e "${YELLOW}$(cat "${LINK_DIR}/xray_${instance}.txt")${RESET}"
    fi
    echo ""
}
