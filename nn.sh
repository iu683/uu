#!/bin/bash
# =========================================
# 一键部署/管理脚本（Debian/Ubuntu 兼容，IPv4+IPv6 双栈）
# 适用场景：VPS 已自带 Nginx，直接配置自定义证书
# 彻底修复版：采用静态 HTML 渲染，完美解决 Nginx 单引号闭合报错
# =========================================

WEB_ROOT="/var/www/html"
LOG_FILE="/var/log/nginx/tim_access.log"
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

show_menu() {
    clear
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}         vps短链脚本管理菜单                ${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}1) 部署脚本 (使用已有 Nginx + 自定义证书)${RESET}"
    echo -e "${GREEN}2) 卸载脚本${RESET}"
    echo -e "${GREEN}3) 更新脚本${RESET}"
    echo -e "${GREEN}4) 查看访问日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
}

install_tim() {
    read -p "请输入你的域名： " DOMAIN
    read -p "请输入脚本 URL（可选，留空默认不下载）： " TIM_URL
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    # 提示输入自定义证书路径并检查是否存在
    echo -e "${GREEN}--- 自定义证书设置 ---${RESET}"
    while true; do
        read -p "请输入您的 SSL 证书(.crt/.pem) 绝对路径: " CERT_PATH
        if [ -f "$CERT_PATH" ]; then
            break
        else
            echo -e "${RED}❌ 文件不存在，请重新输入！${RESET}"
        fi
    done

    while true; do
        read -p "请输入您的 SSL 私钥(.key) 绝对路径: " KEY_PATH
        if [ -f "$KEY_PATH" ]; then
            break
        else
            echo -e "${RED}❌ 文件不存在，请重新输入！${RESET}"
        fi
    done

    # 仅安装基础检测工具
    echo -e "${GREEN}检查基础依赖: curl, dnsutils...${RESET}"
    apt update && apt install -y curl dnsutils

    # 检查域名解析 (IPv4 + IPv6) 并仅做友好提示
    VPS_IPv4=$(curl -s4 https://ifconfig.co || true)
    VPS_IPv6=$(curl -s6 https://ifconfig.co || true)
    DOMAIN_A=$(dig +short A "$DOMAIN" | tail -n1)
    DOMAIN_AAAA=$(dig +short AAAA "$DOMAIN" | tail -n1)

    echo -e "${GREEN}VPS IPv4: $VPS_IPv4${RESET}"
    echo -e "${GREEN}VPS IPv6: $VPS_IPv6${RESET}"
    echo -e "${GREEN}域名 A 记录: $DOMAIN_A${RESET}"
    echo -e "${GREEN}域名 AAAA 记录: $DOMAIN_AAAA${RESET}"

    if [[ "$VPS_IPv4" == "$DOMAIN_A" || "$VPS_IPv6" == "$DOMAIN_AAAA" ]]; then
        echo -e "${GREEN}✅ 域名解析正确，继续安装...${RESET}"
    else
        echo -e "${RED}⚠️  提示：本地检测到域名解析与当前公网 IP 不一致（可能由于 DNS 延迟或启用了 Cloudflare 代理节点）。${RESET}"
        echo -e "${GREEN}ℹ️  已跳过拦截，正在强制继续安装...${RESET}"
    fi

    # 创建目录
    mkdir -p "$WEB_ROOT"
    mkdir -p "$LOCAL_DIR"
    chmod 700 "$LOCAL_DIR"

    # 下载脚本（可选）
    if [[ -n "$TIM_URL" ]]; then
        curl -fsSL "$TIM_URL" -o "$WEB_ROOT/$DOMAIN"
        chmod +x "$WEB_ROOT/$DOMAIN"
        cp "$WEB_ROOT/$DOMAIN" "$LOCAL_DIR/$DOMAIN"
    fi

    # 1. 独立生成前端静态 HTML 文件，避免写入 Nginx 规则导致的符号冲突
    # 在 cat << 'EOF' 中，外层的单引号会让里面所有的内容保持原样，不再需要任何特殊转义
    cat > "$WEB_ROOT/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Toolbox</title>
<link rel="icon" href="https://cdn.nodeimage.com/i/YLJpfjcyQYlgczKJdxpi7EHzIksXPeW8.webp" type="image/png">
<style>
html, body {margin:0; padding:0; height:100%;}
body {
  display:flex;
  justify-content:center;
  align-items:center;
  font-family:Arial,sans-serif;
  transition: background 0.3s, color 0.3s;
}
body[data-theme="dark"] {
  background: #1e1e1e url("https://t.alcy.cc/ycy") no-repeat center/cover;
  color: #eee;
}
body[data-theme="light"] {
  background: #ffffff url("https://t.alcy.cc/ycy") no-repeat center/cover;
  color: #000;
}
.card {
  backdrop-filter:blur(15px);
  -webkit-backdrop-filter:blur(15px);
  border-radius:20px;
  padding:40px 60px;
  text-align:center;
  box-shadow:0 8px 32px rgba(0,0,0,0.1);
  max-width:90%;
  position:relative;
  transition: background 0.3s, color 0.3s;
}
body[data-theme="dark"] .card { background:rgba(40,40,40,0.6); }
body[data-theme="light"] .card { background:rgba(255,255,255,0.4); }
h1{font-size:2.5rem; margin-bottom:20px;}
#cmd{
  font-size:1.5rem; font-weight:bold;
  background:rgba(255,255,255,0.25);
  padding:15px 25px; border-radius:12px;
  cursor:pointer; user-select:all;
  border:1px solid rgba(255,255,255,0.3);
  word-break:break-all;
}
#hint{margin-top:15px; font-size:1rem; color:#555;}
body[data-theme="dark"] #hint{color:#ccc;}
.footer-extra{margin-top:25px; font-size:14px;}
@media (max-width:600px){
  .card{padding:30px 20px;}
  h1{font-size:1.8rem;}
  #cmd{font-size:1.1rem; padding:12px 15px;}
}

/* 圆形切换按钮 + 动画 */
#theme-toggle {
  position:absolute;
  top:15px;
  right:15px;
  width:36px;
  height:36px;
  line-height:36px;
  background:rgba(255,255,255,0.3);
  border-radius:50%;
  cursor:pointer;
  border:1px solid rgba(255,255,255,0.5);
  user-select:none;
  font-size:1.2rem;
  text-align:center;
  transition: transform 0.3s ease, background 0.3s ease;
}
#theme-toggle.active {
  transform: rotate(360deg);
  background: rgba(255,255,255,0.6);
}
@media (max-width:600px){
  #theme-toggle{
    width:30px;
    height:30px;
    line-height:30px;
    font-size:1rem;
    top:10px;
    right:10px;
  }
}
</style>
</head>
<body>
<div class="card">
  <div id="theme-toggle">🌓</div>
  <h1>⚡ Toolbox工具箱</h1>
  <div id="cmd">bash <(curl -fsSL DOMAIN_PLACEHOLDER)</div>
  <div id="hint">点击命令即可复制到剪贴板</div>
  <div class="footer-extra">
    <p>😊Toolbox🎉累计访问人次💻：</p>
    <img src="https://count.getloli.com/@:DOMAIN_PLACEHOLDER?name=DOMAIN_PLACEHOLDER&theme=rule34&padding=7&offset=0&align=center&scale=1&pixelated=1&darkmode=auto" 
         alt="访问计数器" style="margin:10px 0;max-width:100%;"/>
    <p><span id="runtime_span">⏲️ 加载中... ⏲️</span></p>
  </div>
</div>

<script>
// 命令复制
const cmdDiv=document.getElementById("cmd");
cmdDiv.onclick=async()=>{
  try{
    await navigator.clipboard.writeText("bash <(curl -fsSL DOMAIN_PLACEHOLDER)");
    cmdDiv.innerText="✅ 已复制！";
    setTimeout(()=>{cmdDiv.innerText="bash <(curl -fsSL DOMAIN_PLACEHOLDER)";},1500);
  }catch(err){ alert("复制失败，请手动复制命令"); }
}

// 运行时间显示
const runtime_span=document.getElementById("runtime_span");
function show_runtime(){
  const now=new Date();
  const start=new Date("2026-03-15T00:00:00");
  const diff=now-start;
  const days=Math.floor(diff/(24*60*60*1000));
  const hours=Math.floor((diff/(60*60*1000))%24);
  const minutes=Math.floor((diff/(60*1000))%60);
  const seconds=Math.floor((diff/1000)%60);
  runtime_span.textContent=`⏲️ Toolbox已运行 ${days}天 | ${hours}小时 | ${minutes}分 | ${seconds}秒 ⏲️`;
}
setInterval(show_runtime,1000);
show_runtime();

// 夜间/白天切换 + 点击动画
const themeToggle = document.getElementById("theme-toggle");
themeToggle.onclick = () => {
  themeToggle.classList.add('active');
  setTimeout(()=>themeToggle.classList.remove('active'), 300);

  if(document.body.dataset.theme === 'dark'){
    document.body.dataset.theme = 'light';
    localStorage.setItem('theme','light');
  } else {
    document.body.dataset.theme = 'dark';
    localStorage.setItem('theme','dark');
  }
};

// 页面加载时应用保存的主题
const savedTheme = localStorage.getItem('theme') || (window.matchMedia("(prefers-color-scheme: dark)").matches ? 'dark' : 'light');
document.body.dataset.theme = savedTheme;
</script>
</body>
</html>
EOF

    # 将占位符动态替换为用户实际输入的域名
    sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" "$WEB_ROOT/index.html"

    # 2. 配置极致清爽、完全不会出错的 Nginx 规则
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    # HTTP 自动跳转 HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    root $WEB_ROOT;
    index index.html;

    # 配置自定义证书
    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    # SSL 基础安全调优
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location = / {
        # 核心逻辑：如果是命令行工具，直接去读取并返回下载的脚本内容
        if (\$http_user_agent ~* "(curl|wget|fetch|httpie|Go-http-client|python-requests|bash)") {
            rewrite ^ /"$DOMAIN" break;
        }
        # 如果是普通浏览器，则直接渲染 index.html 网页
        try_files /index.html =404;
    }

    access_log $LOG_FILE combined;
}
EOF

    # 启用配置
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    
    # 测试并重载已有的 Nginx 服务
    echo -e "${GREEN}测试 Nginx 配置并重载服务...${RESET}"
    nginx -t && systemctl reload nginx || {
        echo -e "${RED}❌ Nginx 配置重载失败，请检查上面输出的错误提示。${RESET}"
        return
    }

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}部署完成！${RESET}"
    echo -e "${GREEN}本地脚本已保存到：$LOCAL_DIR/$DOMAIN${RESET}"
    echo -e "${GREEN}HTTPS 已启用 https://$DOMAIN${RESET}"
    echo -e "${GREEN}访问日志：$LOG_FILE${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
}

uninstall_tim() {
    read -p "请输入你的域名 ： " DOMAIN
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    echo -e "${GREEN}清理 Nginx 站点配置...${RESET}"
    rm -f /etc/nginx/sites-available/"$DOMAIN"
    rm -f /etc/nginx/sites-enabled/"$DOMAIN"

    echo -e "${GREEN}删除本地、网页及静态主页文件...${RESET}"
    rm -rf "$LOCAL_DIR"
    rm -f "$WEB_ROOT/$DOMAIN"
    rm -f "$WEB_ROOT/index.html"

    echo -e "${GREEN}重载 Nginx 使配置生效...${RESET}"
    systemctl reload nginx

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}卸载完成！${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
}

update_tim() {
    read -p "请输入最新脚本 URL： " TIM_URL
    read -p "请输入 VPS 本地脚本存放目录（默认 /root/tim）： " LOCAL_DIR
    LOCAL_DIR=${LOCAL_DIR:-/root/tim}

    if [[ -z "$DOMAIN" ]]; then
        read -p "请输入域名（用于生成文件名）： " DOMAIN
    fi

    mkdir -p "$LOCAL_DIR"
    curl -fsSL "$TIM_URL" -o "$LOCAL_DIR/$DOMAIN" || { 
        echo -e "${RED}❌ 下载脚本失败，请检查 URL${RESET}"
        return
    }
    chmod +x "$LOCAL_DIR/$DOMAIN"

    cp -f "$LOCAL_DIR/$DOMAIN" "$WEB_ROOT/$DOMAIN"
    echo -e "${GREEN}✅ 更新完成！短链脚本已同步最新版本${RESET}"
}

view_logs() {
    if [ -f "$LOG_FILE" ]; then
        echo -e "${GREEN}显示最近 20 条访问记录：${RESET}"
        tail -n 20 "$LOG_FILE"
        echo -e "${GREEN}统计不同 IP (IPv4/IPv6) 访问次数：${RESET}"
        awk '{print $1}' "$LOG_FILE" | sort | uniq -c | sort -nr
    else
        echo -e "${RED}日志文件不存在${RESET}"
    fi
}

while true; do
    show_menu
    read -p "$(echo -e ${GREEN}请输入选项: ${RESET})" choice
    case $choice in
        1) install_tim ;;
        2) uninstall_tim ;;
        3) update_tim ;;
        4) view_logs ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入有效选项${RESET}" ;;
    esac
    read -p "按回车返回菜单..."
done
