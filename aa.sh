#!/usr/bin/env bash
set -e

#################################
# 基础信息
#################################
APP="naive"
ROOT="/naive"
COMPOSE="$ROOT/docker-compose.yml"
CONFIG="$ROOT/config/naive.json"
INFO="$ROOT/config/info.conf"

#################################
# 颜色
#################################
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

#################################
# Docker检查
#################################
check_docker() {

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}正在安装 Docker...${RESET}"
        curl -fsSL https://get.docker.com | bash
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}Docker Compose 不存在${RESET}"
        exit 1
    fi
}

#################################
# 安装
#################################
install_naive() {

    check_docker

    mkdir -p $ROOT/{config,html,data}

    echo -e "${GREEN}请输入配置信息${RESET}"

    read -rp "域名: " DOMAIN
    read -rp "邮箱: " EMAIL
    read -rp "用户名: " USER
    read -rsp "密码: " PASS
    echo
    read -rp "端口 [443]: " PORT
    PORT=${PORT:-443}
    read -rp "节点名 [DE]: " NODE
    NODE=${NODE:-DE}

    AUTH=$(printf "%s:%s" "$USER" "$PASS" | base64 -w0)

    cat > "$INFO" <<EOF
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
USER="$USER"
PASS="$PASS"
PORT="$PORT"
NODE="$NODE"
EOF

cat > "$COMPOSE" <<EOF
services:
  naive:
    container_name: naive
    image: jonssonyan/naive
    restart: always
    network_mode: host
    volumes:
      - /naive/config:/naive/config
      - /naive/html:/naive/html
      - /naive/data:/naive/data
    command: ./naive run --config /naive/config/naive.json
EOF

cat > "$CONFIG" <<EOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    }
  },
  "storage": {
    "module": "file_system",
    "root": "/naive/data/file_system"
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [
            ":$PORT"
          ],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "handler": "forward_proxy",
                          "auth_credentials": [
                            "$AUTH"
                          ],
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": [
                            "$DOMAIN"
                          ]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "/naive/html",
                          "index_names": [
                            "index.html"
                          ]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "automatic_https": {
            "disable": true
          }
        }
      }
    },
    "tls": {
      "certificates": {
        "automate": [
          "$DOMAIN"
        ]
      },
      "automation": {
        "policies": [
          {
            "issuers": [
              {
                "module": "acme",
                "email": "$EMAIL"
              }
            ]
          }
        ]
      }
    }
  }
}
EOF

cat > "$ROOT/html/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Global Infrastructure Group</title>
  <meta name="description"
        content="Global Infrastructure Group edge delivery platform." />
  <meta name="theme-color" content="#0f172a" />

  <link rel="icon"
        href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 64 64%22><rect width=%2264%22 height=%2264%22 rx=%2216%22 fill=%22%230ea5e9%22/></svg>">

  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect"
        href="https://fonts.gstatic.com"
        crossorigin>

  <link rel="stylesheet"
        href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap">

  <style>
    :root{
      --text-main:#f8fafc;
      --text-soft:rgba(248,250,252,.72);
      --card-bg:rgba(255,255,255,.12);
      --card-border:rgba(255,255,255,.18);
      --success:#86efac;
      --shadow:0 24px 70px rgba(15,23,42,.25);
    }

    *{box-sizing:border-box}

    body{
      min-height:100vh;
      margin:0;
      font-family:"Inter",-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
      color:var(--text-main);
      background:
      linear-gradient(rgba(15,23,42,.72),rgba(15,23,42,.72)),
      url("https://images.unsplash.com/photo-1451187580459-43490279c0fa?auto=format&fit=crop&w=1600&q=80");
      background-size:cover;
      background-position:center;
      background-attachment:fixed;
    }

    .page{
      max-width:1180px;
      margin:auto;
      padding:28px;
    }

    .nav-bar{
      display:flex;
      justify-content:space-between;
      align-items:center;
      padding:14px 18px;
      border-radius:999px;
      border:1px solid var(--card-border);
      background:rgba(15,23,42,.3);
      backdrop-filter:blur(18px);
      box-shadow:var(--shadow);
    }

    .brand{
      display:flex;
      align-items:center;
      gap:10px;
      font-weight:700;
    }

    .brand-mark{
      width:30px;
      height:30px;
      border-radius:10px;
      background:linear-gradient(135deg,#67e8f9,#3b82f6);
    }

    .status-pill{
      display:flex;
      align-items:center;
      gap:8px;
      padding:8px 12px;
      border-radius:999px;
      background:rgba(134,239,172,.12);
      border:1px solid rgba(134,239,172,.24);
    }

    .status-dot{
      width:8px;
      height:8px;
      border-radius:50%;
      background:var(--success);
    }

    .hero{
      display:grid;
      grid-template-columns:1fr 420px;
      gap:44px;
      align-items:center;
      padding:110px 0 72px;
    }

    h1{
      margin:0;
      font-size:clamp(42px,7vw,78px);
      line-height:.98;
      letter-spacing:-.065em;
    }

    .hero-copy{
      color:var(--text-soft);
      font-size:20px;
      line-height:1.7;
      margin-top:24px;
    }

    .panel,
    .item{
      background:var(--card-bg);
      border:1px solid var(--card-border);
      backdrop-filter:blur(22px);
      box-shadow:var(--shadow);
    }

    .panel{
      padding:24px;
      border-radius:30px;
    }

    .metric{
      margin-top:18px;
      padding:22px;
      border-radius:22px;
      background:rgba(255,255,255,.08);
    }

    .metric-label{
      color:var(--text-soft);
      font-size:14px;
    }

    .metric-value{
      margin-top:8px;
      font-size:22px;
      font-weight:700;
    }

    .features{
      display:grid;
      grid-template-columns:repeat(3,1fr);
      gap:18px;
      margin:12px 0 72px;
    }

    .item{
      padding:26px;
      border-radius:26px;
    }

    .item p{
      color:var(--text-soft);
      line-height:1.7;
    }

    footer{
      padding:24px 0 8px;
      color:rgba(248,250,252,.56);
      font-size:13px;
      display:flex;
      justify-content:space-between;
    }

    @media(max-width:900px){
      .hero{grid-template-columns:1fr}
      .features{grid-template-columns:1fr}
    }
  </style>
</head>

<body>

<div class="page">

<header class="nav-bar">
  <div class="brand">
    <span class="brand-mark"></span>
    <span>Global Infrastructure Group</span>
  </div>

  <div class="status-pill">
    <span class="status-dot"></span>
    Operational
  </div>
</header>

<section class="hero">

<div>
  <h1>分布式边缘网络</h1>

  <p class="hero-copy">
    为全球用户提供高速、稳定的静态资源调度服务。
    通过智能路径优化、缓存策略与区域化接入能力，
    持续提升内容访问体验。
  </p>
</div>

<aside class="panel">

<h2>Realtime Metrics</h2>

<div class="metric">
  <div class="metric-label">Average Response</div>
  <div class="metric-value">28ms</div>
</div>

<div class="metric">
  <div class="metric-label">Cache Hit Ratio</div>
  <div class="metric-value">96.4%</div>
</div>

<div class="metric">
  <div class="metric-label">Regional Capacity</div>
  <div class="metric-value">82%</div>
</div>

</aside>

</section>

<section class="features">

<article class="item">
<h3>低延迟响应</h3>
<p>基于多区域接入与缓存命中策略，减少重复回源并提升资源加载速度。</p>
</article>

<article class="item">
<h3>高可用架构</h3>
<p>采用多节点冗余与健康检查机制，在异常情况下自动切换。</p>
</article>

<article class="item">
<h3>自动化调度</h3>
<p>持续分析链路质量与区域容量，动态优化访问路径。</p>
</article>

</section>

<footer>
<span>© 2026 Global Infrastructure Group.</span>
<span>Node Status: Operational</span>
</footer>

</div>

</body>
</html>
EOF

    docker compose -f "$COMPOSE" up -d

    echo
    echo -e "${GREEN}安装完成${RESET}"
    echo

    show_info
}

#################################
# 连接信息
#################################
show_info() {

    if [ -f "$INFO" ]; then

        source "$INFO"

        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${GREEN}      NaiveProxy 连接信息${RESET}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

        echo -e "${CYAN}域名:${RESET} $DOMAIN"
        echo -e "${CYAN}端口:${RESET} $PORT"
        echo -e "${CYAN}用户名:${RESET} $USER"
        echo -e "${CYAN}密码:${RESET} $PASS"
        echo -e "${CYAN}节点:${RESET} $NODE"

        echo
        echo -e "${GREEN}naive+https://$USER:$PASS@$DOMAIN:$PORT#$NODE${RESET}"
        echo

        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    else
        echo -e "${RED}未找到连接信息${RESET}"
    fi
}

#################################
# 卸载
#################################
uninstall_naive() {

    docker compose -f "$COMPOSE" down 2>/dev/null || true
    rm -rf "$ROOT"

    echo -e "${GREEN}已卸载 NaiveProxy${RESET}"
}

#################################
# 查看配置
#################################
view_config() {

    if [ -f "$CONFIG" ]; then
        cat "$CONFIG"
    else
        echo -e "${RED}配置不存在${RESET}"
    fi
}

#################################
# 重启
#################################
restart_naive() {

    docker restart naive
    echo -e "${GREEN}已重启${RESET}"
}

#################################
# 停止
#################################
stop_naive() {

    docker stop naive
    echo -e "${GREEN}已停止${RESET}"
}

#################################
# 状态
#################################
status_naive() {

    docker ps -a | grep naive || true
}

#################################
# 日志
#################################
logs_naive() {

    docker logs -f naive
}

#################################
# 更新
#################################
update_naive() {

    echo -e "${GREEN}更新镜像中...${RESET}"

    docker pull jonssonyan/naive
    docker compose -f "$COMPOSE" up -d

    echo -e "${GREEN}更新完成${RESET}"
}

#################################
# 菜单
#################################
menu() {

while true
do
clear

echo -e "${GREEN}"
echo "================================="
echo "      NaiveProxy 管理菜单"
echo "================================="
echo "1. 安装 NaiveProxy"
echo "2. 卸载 NaiveProxy"
echo "3. 查看配置"
echo "4. 重启服务"
echo "5. 停止服务"
echo "6. 查看状态"
echo "7. 查看日志"
echo "8. 更新镜像"
echo "9. 连接信息"
echo "0. 退出"
echo "================================="
echo -ne "请选择: "
echo -e "${RESET}"

read num

case "$num" in
1)
    install_naive
    ;;
2)
    uninstall_naive
    ;;
3)
    view_config
    ;;
4)
    restart_naive
    ;;
5)
    stop_naive
    ;;
6)
    status_naive
    ;;
7)
    logs_naive
    ;;
8)
    update_naive
    ;;
9)
    show_info
    ;;
0)
    exit 0
    ;;
*)
    echo -e "${RED}输入错误${RESET}"
    ;;
esac

echo
read -n 1 -s -r -p "按任意键返回..."
done
}

menu
