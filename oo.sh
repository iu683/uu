#!/bin/bash

# ================== 颜色定义 ==================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ================== 自定义基础配置 ==================
WEB_ROOT="/var/www/vps_gate"                    # 存放时钟网页和安装脚本的自定义目录
NGINX_CONF_DIR="/etc/nginx/conf.d"              # 你现有的 Nginx 配置目录
LOG_ACCESS="/var/log/nginx/gate_access.log"     # 独立的访问日志路径

# 原本的工具箱脚本 GitHub 下载后缀
SCRIPT_URL_SUFFIX="raw.githubusercontent.com/sistarry/toolbox/main/tool/vps-toolbox.sh"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请以 root 用户运行此脚本！${RESET}"
    exit 1
fi

# ================== 功能函数 ==================

# 1. 配置并启动 (自定义域名 + 自定义 SSL)
install_gate() {
    echo -e "${GREEN}====== 🛠️ 自定义配置向导 ======${RESET}"
    
    # 1.1 输入自定义域名
    echo -n "🌐 请输入你的自定义域名 (例如 tool.wwwo.eu.cc): "
    read -r DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}❌ 域名不能为空！${RESET}"
        return
    fi

    # 1.2 输入证书路径
    echo -n "🔑 请输入该域名的 SSL 证书 (.crt / .pem) 绝对路径: "
    read -r CERT_PATH
    echo -n "🔑 请输入该域名的 SSL 密钥 (.key) 绝对路径: "
    read -r KEY_PATH

    # 简单校验文件是否存在
    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
        echo -e "${RED}❌ 证书或密钥文件不存在！请检查路径是否正确。${RESET}"
        return
    fi

    echo -e "${YELLOW}🔄 开始为域名 [${DOMAIN}] 配置分流环境...${RESET}"

    # 定义该域名专属的配置文件名
    CONF_FILE="${NGINX_CONF_DIR}/gate_${DOMAIN}.conf"

    # 自动创建自定义网页目录并生成时钟与脚本
    mkdir -p "$WEB_ROOT"

    # 生成 网页时钟 (clock.html)
    cat << 'EOF' > "$WEB_ROOT/clock.html"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VPS 炫酷数字时钟</title>
    <style>
        body { background-color: #050505; color: #00ff66; font-family: 'Courier New', monospace; display: flex; flex-direction: column; justify-content: center; align-items: center; height: 100vh; margin: 0; overflow: hidden; }
        .clock-container { text-align: center; padding: 30px; border: 2px solid #00ff66; border-radius: 15px; box-shadow: 0 0 30px rgba(0, 255, 102, 0.3); background: rgba(0,0,0,0.8); }
        #clock { font-size: 8vw; font-weight: bold; text-shadow: 0 0 20px #00ff66; margin-bottom: 10px; }
    </style>
</head>
<body>
    <div class="clock-container">
        <div id="clock">00:00:00</div>
    </div>
    <script>
        setInterval(() => { document.getElementById('clock').textContent = new Date().toTimeString().split(' ')[0]; }, 1000);
    </script>
</body>
</html>
EOF

    # 生成 客户端执行的安装脚本 (install.sh)
    cat << EOF > "$WEB_ROOT/install.sh"
#!/bin/bash
GREEN="\\033[32m"
YELLOW="\\033[33m"
RED="\\033[31m"
RESET="\\033[0m"

SCRIPT_PATH="/root/vps-toolbox.sh"
SCRIPT_URL_SUFFIX="${SCRIPT_URL_SUFFIX}"
BIN_LINK_DIR="/usr/local/bin"

GITHUB_PROXY=('', 'https://v6.gh-proxy.org/', 'https://gh-proxy.com/', 'https://hub.glowp.xyz/', 'https://proxy.vvvv.ee/', 'https://ghproxy.lvedong.eu.org/')

if [ ! -f "\$SCRIPT_PATH" ]; then
    SUCCESS=false
    for proxy in "\${GITHUB_PROXY[@]}"; do
        FULL_URL="\${proxy}\${SCRIPT_URL_SUFFIX}"
        if [ -n "\$proxy" ]; then echo -e "\${YELLOW}🔄 正在通过代理安装... \${RESET}"; else echo -e "\${YELLOW}🔄 正在通过直连安装... \${RESET}"; fi
        curl -fsSL --connect-timeout 5 -o "\$SCRIPT_PATH" "\$FULL_URL"
        if [ \$? -eq 0 ] && [ -s "\$SCRIPT_PATH" ]; then SUCCESS=true; break; fi
    done
    if [ "\$SUCCESS" = false ]; then echo -e "\${RED}❌ 所有代理节点均安装失败\${RESET}"; exit 1; fi
    chmod +x "\$SCRIPT_PATH"
    ln -sf "\$SCRIPT_PATH" "$BIN_LINK_DIR/m"
    ln -sf "\$SCRIPT_PATH" "$BIN_LINK_DIR/M"
    echo -e "\${GREEN}✅ 安装完成，输入 m 或 M 运行\${RESET}"
fi
exec "\$SCRIPT_PATH"
EOF

    # 生成包含自动 HTTPS 的 Nginx 配置文件
    cat << EOF > "$CONF_FILE"
# HTTP 80 端口配置
server {
    listen 80;
    server_name $DOMAIN;
    
    # HTTP 状态下的 curl 智能分流
    location / {
        if (\$http_user_agent ~* "curl") {
            root $WEB_ROOT;
            rewrite ^/\$ /install.sh last;
        }
        
        # 浏览器访问则强制重定向到 HTTPS
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS 443 端口配置
server {
    listen 443 ssl;
    server_name $DOMAIN;

    # 动态导入自定义证书
    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    ssl_session_timeout 5m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:HIGH:!aNULL:!MD5:!RC4:!DHE;
    ssl_prefer_server_ciphers on;

    root $WEB_ROOT;
    access_log $LOG_ACCESS;

    location / {
        index clock.html;

        # HTTPS 状态下的 curl 智能分流
        if (\$http_user_agent ~* "curl") {
            rewrite ^/\$ /install.sh last;
        }
    }
}
EOF

    # 检查 Nginx 配置语法
    nginx -t &>/dev/null
    if [ $? -eq 0 ]; then
        # 仅仅平滑重载 Nginx，不影响现有其他网站
        nginx -s reload
        # 将当前配置的域名记录到一个本地临时文件，方便卸载和菜单显示
        echo "$DOMAIN" > "${WEB_ROOT}/current_domain.txt"
        echo -e "${GREEN}✅ 分流配置成功应用！${RESET}"
        echo -e "${GREEN}🌐 浏览器打开查看时钟: ${YELLOW}https://${DOMAIN}${RESET}"
        echo -e "${GREEN}💻 其它 VPS 一键执行命令: ${YELLOW}bash <(curl -fsSL ${DOMAIN})${RESET}"
    else
        echo -e "${RED}❌ Nginx 语法检查失败，可能是证书路径不匹配或冲突，请重新检查！${RESET}"
        rm -f "$CONF_FILE"
    fi
}

# 2. 查看独立的访问日志
view_logs() {
    if [ ! -f "$LOG_ACCESS" ] || [ ! -s "$LOG_ACCESS" ]; then
        echo -e "${RED}❌ 暂无客户端访问或安装日志。${RESET}"
        return
    fi
    echo -e "${YELLOW}👀 正在实时监听独立日志流 (按 Ctrl+C 退出)...${RESET}"
    echo -e "${YELLOW}------------------------------------------------------------------${RESET}"
    tail -f "$LOG_ACCESS"
}

# 3. 卸载清除
uninstall_gate() {
    # 自动读取当前正在生效的自定义域名
    if [ -f "${WEB_ROOT}/current_domain.txt" ]; then
        CURRENT_DOMAIN=$(cat "${WEB_ROOT}/current_domain.txt")
    else
        echo -n "❓ 未检测到默认配置记录，请输入要卸载的域名: "
        read -r CURRENT_DOMAIN
    fi

    if [ -z "$CURRENT_DOMAIN" ]; then
        echo -e "${RED}❌ 未输入域名，取消卸载。${RESET}"
        return
    fi

    CONF_FILE="${NGINX_CONF_DIR}/gate_${CURRENT_DOMAIN}.conf"

    echo -e "${RED}⚠️ 确定要清除域名 [${CURRENT_DOMAIN}] 的所有分流配置和网页文件吗？(y/n)${RESET}"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$CONF_FILE"
        rm -rf "$WEB_ROOT"
        nginx -s reload
        echo -e "${GREEN}✅ 卸载完成，域名 [${CURRENT_DOMAIN}] 的规则已成功剥离并重载 Nginx！${RESET}"
    else
        echo -e "${YELLOW}❌ 已取消卸载。${RESET}"
    fi
}

# ================== 菜单主循环 ==================
while true; do
    clear
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${GREEN}   🌐 Nginx · 全自定义域名与 SSL 分流管理菜单   ${RESET}"
    echo -e "${GREEN}================================================${RESET}"
    
    # 动态获取当前运行的域名状态
    if [ -f "${WEB_ROOT}/current_domain.txt" ]; then
        RUNNING_DOMAIN=$(cat "${WEB_ROOT}/current_domain.txt")
        echo -e " 当前状态: ${GREEN}已启用 ➡️  https://${RUNNING_DOMAIN}${RESET}"
    else
        echo -e " 当前状态: ${RED}未启用 / 已停用${RESET}"
    fi
    
    echo -e "${GREEN}================================================${RESET}"
    echo -e "${YELLOW} 1. ${RESET} 配置并启动 (手动输入自定义域名 + 自定义SSL证书)"
    echo -e "${YELLOW} 2. ${RESET} 查看 客户端访问与安装日志 (实时监控)"
    echo -e "${YELLOW} 3. ${RESET} 卸载 / 清除 现有分流配置"
    echo -e "${YELLOW} 4. ${RESET} 退出脚本"
    echo -e "${GREEN}================================================${RESET}"
    echo -n " 请输入数字 [1-4]: "
    read -r choice

    case $choice in
        1) install_gate ;;
        2) view_logs ;;
        3) uninstall_gate ;;
        4) echo -e "${GREEN}👋 再见！${RESET}" && exit 0 ;;
        *) echo -e "${RED}❌ 输入错误！${RESET}" ;;
    esac
    echo
    echo -n "按回车键返回菜单..."
    read -r
done
