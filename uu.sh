#!/bin/bash
# ================== 颜色定义 ==================
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"
BOLD="\033[1m"
ORANGE='\033[38;5;208m'

# ================== 脚本路径 ==================
SCRIPT_PATH="/root/store.sh"
SCRIPT_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Store.sh"
BIN_LINK_DIR="/usr/local/bin"

# ================== 首次运行自动安装 ==================
if [ ! -f "$SCRIPT_PATH" ]; then
    curl -fsSL -o "$SCRIPT_PATH" "$SCRIPT_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 安装失败，请检查网络或 URL${RESET}"
        exit 1
    fi
    chmod +x "$SCRIPT_PATH"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/d"
    ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/D"
    echo -e "${GREEN}✅ 安装完成${RESET}"
    echo -e "${GREEN}✅ 快捷键已添加：d 或 D 可快速启动${RESET}"
fi

# ================== 一级菜单分类 ==================
declare -A categories=(
    [1]="Docker管理"
    [2]="数据证书"
    [3]="订阅通知"
    [4]="监控项目"
    [5]="管理面板"
    [6]="媒体服务"
    [7]="图床项目"
    [8]="实用工具"
    [9]="交易商店"
    [10]="文件管理"
    [11]="机器人工具"
    [12]="AI项目"
    [13]="游戏项目"
)

# ================== 二级菜单应用 ==================
declare -A apps=(
    [1,1]="安装管理Docker"
    [1,2]="Dockercompose项目管理"
    [1,3]="Dockercompose备份恢复"
    [1,4]="Dockercompose自动更新"
    [1,5]="NGINXV4反代"
    [2,1]="MySQL数据管理"
    [2,2]="caddy证书管理"
    [2,3]="NginxProxyManager可视化面板"
    [2,4]="ALLinSSL证书管理"
    [2,5]="彩虹聚合DNS管理系统(MySQL)"
    [2,6]="彩虹聚合DNS管理系统"
    [2,7]="DDNS-GO动态DNS管理工具"
    [2,8]="Lucky内网穿透"
    [2,9]="CFGuardCloudflaredns管理面板"
    [2,10]="Redis数据"
    [2,11]="MongoDB数据"
    [2,12]="AdguardHomeDNSDoH"
    [3,1]="Sub-store节点订阅管理"
    [3,2]="subwebmodify节点订阅转换"
    [3,3]="Wallos个人财务管理工具"
    [3,4]="Vaultwarden密码管理"
    [3,5]="妙妙屋流量监控管理系统"
    [3,6]="subs-check订阅检测转换工具"
    [3,7]="Apprise通知"
    [3,8]="NodeCtl节点管理"
    [3,9]="SublinkWorker订阅管理"
    [3,10]="DockerNotify容器状态监听"
    [3,11]="SublinkPro订阅管理"
    [4,1]="Kuma-Mieru监控工具"
    [4,2]="Komari监控"
    [4,3]="哪吒V1监控"
    [4,4]="uptime-kuma监控工具"
    [4,5]="NodeSeeker关键词监控"
    [4,6]="Beszel服务器监控"
    [4,7]="XTrafficDash3XUI面板流量监控"
    [4,8]="哪吒V0监控"
    [4,9]="Changedetection网页监控"
    [4,10]="Pulse监控"
    [4,11]="pika监控"
    [4,12]="KULA监控"
    [4,13]="vStats监控"
    [4,14]="Collei监控"
    [4,15]="DStatus监控"
    [5,1]="运维面板"
    [5,2]="Sun-Panel导航面板"
    [5,3]="WebSSH网页版SSH连接工具"
    [5,4]="NexusTerminal远程连接工具"
    [5,5]="Poste.io邮局"
    [5,6]="OneNav书签管理"
    [5,7]="青龙面板定时任务管理平台"
    [5,8]="Termix远程连接工具"
    [5,9]="VPS剩余价值计算器"
    [5,10]="Trilium笔记"
    [5,11]="firefox浏览器"
    [5,12]="moments微信朋友圈"
    [5,13]="searxng聚合搜索站"
    [5,14]="甲骨文云Y探长"
    [5,15]="dpanelDocker可视化面板系统"
    [5,16]="网页QQ"
    [5,17]="网页微信"
    [5,18]="eooceWebSSH"
    [5,19]="Navlink聚合导航与插件化管理系统"
    [5,20]="EasyNodeSSH终端"
    [5,21]="Epic游戏领取"
    [5,22]="AssppWebApple应用下载"
    [5,23]="wxchat微信转发代理"
    [5,24]="Lottery彩票开奖信息"
    [5,25]="homepage自托管服务仪表盘"
    [5,26]="GMSSH远程工具"
    [5,27]="VoceChat多人在线聊天系统"
    [5,28]="Umami网站统计工具"
    [5,29]="思源笔记"
    [5,30]="Ubuntu远程桌面网页版"
    [5,31]="WUD Docker更新监控"
    [5,32]="Backrest(restic)备份"
    [5,33]="WatchtowerDocker自动更新"
    [5,34]="FOSSBilling VPS托管业务"
    [5,35]="网页Telegram"
    [5,36]="Ech0笔记"
    [5,37]="WebSSHGateway"
    [5,38]="DockerCopilot容器管理工具"
    [5,39]="GiftWishlist礼物愿望清单"
    [5,40]="OutlookEmailPlus邮箱管理"
    [5,41]="OpenFlare CDN加速"
    [5,42]="WindowsDocker"
    [5,43]="联通余量"
    [5,44]="NodeTerminalSSH"
    [5,45]="1ShellSSH"
    [5,46]="白虎面板"
    [5,47]="ShadowSSH"
    [6,1]="koodoreader阅读"
    [6,2]="LrcApi音乐数据"
    [6,3]="OpenList多存储文件列表程序"
    [6,4]="SPlayer网页音乐播放器"
    [6,5]="AutoBangumi全自动追番"
    [6,6]="MoviePilot媒体库自动化管理工具"
    [6,7]="qBittorrentBT磁力下载面板"
    [6,8]="Vertex PT刷流管理工具"
    [6,9]="yt-dlpweb 视频下载工具"
    [6,10]="libretv私有影视"
    [6,11]="MoonTV私有影视"
    [6,12]="Emby开心版(AMD)"
    [6,13]="Emby开心版(ARM)"
    [6,14]="Emby官方版(AMD)"
    [6,15]="Emby官方版(ARM)"
    [6,16]="Jellyfiny多媒体管理系统 "
    [6,17]="metatube刮削插件"
    [6,18]="Navidrome音乐管理系统"
    [6,19]="musictagweb音乐数据刮削"
    [6,20]="qmediasync(strm+302)网盘观影"
    [6,21]="LogVar弹幕API"
    [6,22]="music-player网页音乐播放器"
    [6,23]="MDC-NG AV刮削"
    [6,24]="Melody音乐精灵"
    [6,25]="SyncTV一起看"
    [6,26]="Emby签到保活"
    [6,27]="御坂网络弹幕服务"
    [6,28]="ANI-RSS追番"
    [6,29]="DecoTV影视"
    [6,30]="Kavita漫画"
    [6,31]="MHTI里番刮削"
    [6,32]="MoonTVPlus私有影视"
    [6,33]="Lxserver"
    [6,34]="yt-dlp-webui"
    [6,35]="mytube视频下载"
    [6,36]="global-radio在线电台"
    [6,37]="EmbyPulse管理面板"
    [6,38]="AMMDS个人影视数据管理平台"
    [6,39]="FlareSolverr绕过Cloudflare反爬虫保护"
    [6,40]="IYUU辅种"
    [6,41]="go-webdav-virtual"
    [6,42]="WebDAV"
    [6,43]="Komga图书"
    [6,44]="IPTVtool"
    [6,45]="MeridianEmby反代"
    [6,46]="TgtoDrive网盘资源"
    [6,47]="Transmission"
    [6,48]="Audiobookshelf有声书播客"
    [6,49]="Audiobookshelf喜马拉雅元数据"
    [6,50]="Emby-proxy-go"
    [6,51]="EmbyPulse-Pro管理面板"
    [6,52]="amuleED2K"
    [6,53]="ReClip视频音频下载器"
    [6,54]="馒头保号"
    [7,1]="Foxel图片管理"
    [7,2]="兰空图床(MySQL)"
    [7,3]="兰空图床"
    [7,4]="图片API(兰空图床)"
    [7,5]="简单图床"
    [7,6]="随机图片API"
    [7,7]="EasyImg图床"
    [7,8]="初春图床"
    [7,9]="nodeimage图床"
    [7,10]="Telegram云图床Pro"
    [7,11]="xg-icons-hub图标"
    [7,12]="HD-Icons图标"
    [7,13]="immich图片管理"
    [7,14]="PhotoPrism图片管理"
    [8,1]="2FAuth自托管二步验证器"
    [8,2]="gh-proxyGithub文件加速"
    [8,3]="HubP轻量级Docker镜像加速"
    [8,4]="HubProxyDockerGitHub加速代理"
    [8,5]="Zurl短链接系统"
    [8,6]="vue-color-avatar头像生成网站"
    [8,7]="msgboard实时留言板"
    [8,8]="it-tools工具箱"
    [8,9]="LibreSpeed测速工具"
    [8,10]="libretranslate在线翻译服务器"
    [8,11]="linkwarden书签管理"
    [8,12]="LookingGlass 服务器测速"
    [8,13]="StirlingPDF工具大全"
    [8,14]="super-clipboard在线剪贴板"
    [8,15]="TTS文本转语音大模型"
    [8,16]="excalidraw开源白板工具"
    [8,17]="Drawnix开源白板工具"
    [8,18]="Karakeep书签管理"
    [8,19]="Navigation书签管理"
    [8,20]="translateWeb翻译工具"
    [8,21]="VanNav导航站"
    [8,22]="NavDashboard导航"
    [8,23]="多种风格可选的萌萌计数器"
    [8,24]="Memos说说"
    [8,25]="Twikoo网站评论系统"
    [8,26]="Utilsfun工具箱"
    [8,27]="问卷调查"
    [8,28]="MagicResume简历"
    [8,29]="ForgejoGit服务托管"
    [9,1]="异次元商城(MySQL)"
    [9,2]="异次元商城"
    [9,3]="萌次元商城"
    [9,4]="UPAYPRO"
    [9,5]="独角数卡"
    [10,1]="Cloudreve网盘"
    [10,2]="ZdirPro多功能文件分享"
    [10,3]="fastsend文件快传"
    [10,4]="FileTransferGo文件快传"
    [10,5]="send文件快传"
    [10,6]="pairdrop文件快传"
    [10,7]="Gopeed高速下载工具"
    [10,8]="Syncthing点对点文件同步工具"
    [10,9]="迅雷离线下载工具"
    [10,10]="Enclosed阅后即焚"
    [10,11]="PanSou网盘搜索"
    [10,12]="Dufs极简静态文件服务器"
    [10,13]="ConvertX多格式文件转换工具"
    [10,14]="百度网盘Docker"
    [10,15]="Linkit文件分享"
    [11,1]="SaveAnyBot(TG转存)"
    [11,2]="TeleBoxTG机器人"
    [11,3]="TGBotRSS RSS订阅工具"
    [11,4]="messageTG消息转发机器人"
    [11,5]="AstrBot聊天机器人"
    [11,6]="Miaospeed测速后端"
    [11,7]="NapcatQQ机器人"
    [11,8]="Koipy测速机器人"
    [11,9]="TG群组签到"
    [11,10]="LangBot聊天机器人"
    [11,11]="Sakura-embyboss emby开号机器人"
    [11,12]="TelegramPanel多账户管理面板"
    [11,13]="QQbot消息通知"
    [11,14]="TeleRelayTelegram私聊中转机器人"
    [11,15]="NodeSeek关键词监控Bot"
    [11,16]="LuckyLilliaBot"
    [11,17]="LowEndTalk监控"
    [12,1]="ONEAPI(MSQL)大模型资产管理"
    [12,2]="ONEAPI大模型资产管理"
    [12,3]="NEWAPI(MSQL)大模型资产管理"
    [12,4]="NEWAPI大模型资产管理"
    [12,5]="AntigravityTools "
    [12,6]="CLIProxyAPI"
    [12,7]="OpenClaw"
    [12,8]="gcli2api"
    [12,9]="Sub2API"
    [12,10]="octopusAPI聚合"
    [12,11]="AIClient2API"
    [12,12]="Codeg"
    [12,13]="三省六部Edict"
    [12,14]="ModelStatus模型监控"
    [12,15]="codex-console注册机"
    [12,16]="Hermes Agent"
    [12,17]="ClaudeCode"
    [12,18]="GeminiCLI"
    [12,19]="CodexCLI"
    [13,1]="星露谷物语开服联机"
    [13,2]="MCSManager"
    [13,3]="桃花源文字游戏"

)

# ================== 二级菜单命令 ==================
declare -A commands=(
    [1,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Docker.sh)'
    [1,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/dockercompose.sh)'
    [1,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Dockcompbauck.sh)'
    [1,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/dockerupdate.sh)'
    [1,5]='bash <(curl -fsSL https://raw.githubusercontent.com/sistarry/toolbox/main/VPS/ngixv4.sh)'
    [2,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/msql.sh)'
    [2,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/CaddyDocker.sh)'
    [2,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NginxProxy.sh)'
    [2,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/ALLSSL.sh)'
    [2,5]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/DNSMgrdb.sh)'
    [2,6]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/DNSMgr.sh)'
    [2,7]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/DDNS-GO.sh)'
    [2,8]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/CN/Lucky.sh)'
    [2,9]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/CFServer.sh)'
    [2,10]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Redis.sh)'
    [2,11]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/MongoDB.sh)'
    [2,12]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/AdGuardHome.sh)'
    [3,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/sub-store.sh)'
    [3,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/subzh.sh)'
    [3,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/wallos.sh)'
    [3,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/vaultwarden.sh)'
    [3,5]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/miaomiaowu.sh)'
    [3,6]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/SubsCheck.sh)'
    [3,7]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Apprise.sh)'
    [3,8]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NodeCtl.sh)'
    [3,9]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/SublinkWorker.sh)'
    [3,10]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/DockerRunNotify.sh)'
    [3,11]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/SubLinkPro.sh)'
    [4,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/kuma-mieru.sh)'
    [4,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/komarigl.sh)'
    [4,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/aznezha.sh)'
    [4,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/UptimeKuma.sh)'
    [4,5]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NodeSeeker.sh)'
    [4,6]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Beszel.sh)'
    [4,7]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/xtrafficdash.sh)'
    [4,8]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/nezhav0Argo.sh)'
    [4,9]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/changedetection.sh)'
    [4,10]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Pulse.sh)'
    [4,11]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Pika.sh)'
    [4,12]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Kula.sh)'
    [4,13]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/VStats.sh)'
    [4,14]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Collei.sh)'
    [4,15]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Dstatus.sh)'
    [5,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Panel/panel.sh)'
    [5,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/sun-panel.sh)'
    [5,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/webssh.sh)'
    [5,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/nexus-terminal.sh)'
    [5,5]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/posteio.sh)'
    [5,6]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/onenav.sh)'
    [5,7]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/qlmb.sh)'
    [5,8]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Termix.sh)'
    [5,9]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/vps-value.sh)'
    [5,10]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Trilium.sh)'
    [5,11]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/firefox.sh)'
    [5,12]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/moments.sh)'
    [5,13]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/searxng.sh)'
    [5,14]='bash <(wget -qO- https://github.com/Yohann0617/oci-helper/releases/latest/download/sh_oci-helper_install.sh)'
    [5,15]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/dpanel.sh)'
    [5,16]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/QQ.sh)'
    [5,17]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/WeChat.sh)'
    [5,18]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/eoossh.sh)'
    [5,19]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Navlink.sh)'
    [5,20]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/EasyNode.sh)'
    [5,21]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Epicgamer.sh)'
    [5,22]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/AssppWeb.sh)'
    [5,23]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/WxChatDL.sh)'
    [5,24]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Lottery.sh)'
    [5,25]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/homepage.sh)'
    [5,26]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/GMSSH.sh)'
    [5,27]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/VoceChat.sh)'
    [5,28]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Umami.sh)'
    [5,29]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Siyuan.sh)'
    [5,30]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/WebtopUbuntu.sh)'
    [5,31]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/WUD.sh)'
    [5,32]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Backrest.sh)'
    [5,33]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Watchtower.sh)'
    [5,34]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/FOSSBilling.sh)'
    [5,35]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/TelegramD.sh)'
    [5,36]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Ech0.sh)'
    [5,37]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/WebSSHGateway.sh)'
    [5,38]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/DockerCopilot.sh)'
    [5,39]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/GiftList.sh)'
    [5,40]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/OutlookEmailPlus.sh)'
    [5,41]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/OpenFlare.sh)'
    [5,42]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/WindowsD.sh)'
    [5,43]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/LTnetworkpanel.sh)'
    [5,44]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NodeTerminal.sh)'
    [5,45]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/1shell.sh)'
    [5,46]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/baihu.sh)'
    [5,47]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/ShadowSSH.sh)'
    [6,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/koodoreader.sh)'
    [6,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/lacapi.sh)'
    [6,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Openlist.sh)'
    [6,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/splayer.sh)'
    [6,5]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Autobangumi.sh)'
    [6,6]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/movpv2.sh)'
    [6,7]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/qBittorrentoo.sh)'
    [6,8]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/vertex.sh)'
    [6,9]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/ytdlpweb.sh)'
    [6,10]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/libretv.sh)'
    [6,11]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/mootv.sh)'
    [6,12]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/kxembyamd.sh)'
    [6,13]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/kxembyarm.sh)'
    [6,14]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/embyamd.sh)'
    [6,15]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/embyarm.sh)'
    [6,16]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Jellyfin.sh)'
    [6,17]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/metadata.sh)'
    [6,18]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/navidrome.sh)'
    [6,19]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/musictw.sh)'
    [6,20]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/qmediasync.sh)'
    [6,21]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/danmu.sh)'
    [6,22]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/mplayer.sh)'
    [6,23]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/MDCNG.sh)'
    [6,24]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Melody.sh)'
    [6,25]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/synctv.sh)'
    [6,26]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/embykeeper.sh)'
    [6,27]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/misakadanmu.sh)'
    [6,28]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/ASSRSS.sh)'
    [6,29]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/DecoTV.sh)'
    [6,30]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Kavita.sh)'
    [6,31]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/MHTI.sh)'
    [6,32]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/MoontvPlus.sh)'
    [6,33]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Lxserver.sh)'
    [6,34]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/YTDLPWebUI.sh)'
    [6,35]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/MyTube.sh)'
    [6,36]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/GlobalRadio.sh)'
    [6,37]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/EmbyPulse.sh)'
    [6,38]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/AMMDS.sh)'
    [6,39]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/FlareSolverr.sh)'
    [6,40]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/IYUUPlus.sh)'
    [6,41]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/gowdd.sh)'
    [6,42]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/WebDAV.sh)'
    [6,43]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Komga.sh)'
    [6,44]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/IPTVtool.sh)'
    [6,45]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Meridian.sh)'
    [6,46]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/TgToDrive.sh)'
    [6,47]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Transmission.sh)'
    [6,48]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Audiobookshelf.sh)'
    [6,49]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/ABSXimalaya.sh)'
    [6,50]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/EmbyProxyGo.sh)'
    [6,51]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/EmbyPulsePro.sh)'
    [6,52]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/amule.sh)'
    [6,53]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/ReClip.sh)'
    [6,54]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/PT/MTLogin.sh)'
    [7,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/foxel.sh)'
    [7,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/lskyprodb.sh)'
    [7,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/lskypro.sh)'
    [7,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/apitu.sh)'
    [7,5]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/EasyImage.sh)'
    [7,6]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/tuapi.sh)'
    [7,7]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/EasyImg.sh)'
    [7,8]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/OneImg.sh)'
    [7,9]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NodeImage.sh)'
    [7,10]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/TelegramImageBed.sh)'
    [7,11]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/XGIconsHub.sh)'
    [7,12]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/HDIcons.sh)'
    [7,13]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Immich.sh)'
    [7,14]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/PhotoPrism.sh)'
    [8,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/2fauth.sh)'
    [8,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/fdgit.sh)'
    [8,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/dockhub.sh)'
    [8,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/hubproxy.sh)'
    [8,5]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Zurl.sh)'
    [8,6]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Colo.sh)'
    [8,7]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/MsgBoard.sh)'
    [8,8]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/it-tools.sh)'
    [8,9]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/LibreSpeed.sh)'
    [8,10]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/libretranslate.sh)'
    [8,11]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Linkwarden.sh)'
    [8,12]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/lookingglass.sh)'
    [8,13]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/StirlingPDF.sh)'
    [8,14]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/super.sh)'
    [8,15]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/cosyvoice.sh)'
    [8,16]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Excalidraw.sh)'
    [8,17]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Drawnix.sh)'
    [8,18]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Karakeep.sh)'
    [8,19]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Navigation.sh)'
    [8,20]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Translate.sh)'
    [8,21]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/VanNav.sh)'
    [8,22]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NavDashboard.sh)'
    [8,23]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/MoeCounter.sh)'
    [8,24]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Memos.sh)'
    [8,25]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Twikoo.sh)'
    [8,26]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Utilsfun.sh)'
    [8,27]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/XiaojuSurvey.sh)'
    [8,28]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Magicresum.sh)'
    [8,29]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Forgejo.sh)'
    [9,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/ACGFakadb.sh)'
    [9,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/ACGFaka.sh)'
    [9,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/mcygl.sh)'
    [9,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/UPayPro.sh)'
    [9,5]='bash <(curl -fsSL https://raw.githubusercontent.com/dujiao-next/community-projects/main/scripts/langge-dujiao-next-install/dujiao-next-install.sh)'
    [10,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Cloudreve.sh)'
    [10,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Zdir.sh)'
    [10,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/FastSend.sh)'
    [10,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/FileTransfer.sh)'
    [10,5]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/send.sh)'
    [10,6]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/pairdrop.sh)'
    [10,7]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/gopeed.sh)'
    [10,8]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/syncthing.sh)'
    [10,9]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/xunlei.sh)'
    [10,10]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Enclosed.sh)'
    [10,11]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Pansou.sh)'
    [10,12]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/DUFS.sh)'
    [10,13]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/ConvertX.sh)'
    [10,14]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/BaiduPCSRust.sh)'
    [10,15]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/LinkIt.sh)'
    [11,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/SaveAnyBot.sh)'
    [11,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/TeleBox.sh)'
    [11,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/TGRSSBot.sh)'
    [11,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/TelegramBot.sh)'
    [11,5]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Astrbot.sh)'
    [11,6]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Miaospeed.sh)'
    [11,7]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Napcat.sh)'
    [11,8]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Koipy.sh)'
    [11,9]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/TGsignpulse.sh)'
    [11,10]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/LangBot.sh)'
    [11,11]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Sakuraembyboss.sh)'
    [11,12]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/TelegramPanel.sh)'
    [11,13]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/23QQBot.sh)'
    [11,14]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/TeleRelay.sh)'
    [11,15]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NodeSeekRSSbot.sh)'
    [11,16]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/LuckyLilliaBot.sh)'
    [11,17]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/LETBOT.sh)'
    [12,1]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/OneAPIdb.sh)'
    [12,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/OneAPI.sh)'
    [12,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NewAPIdb.sh)'
    [12,4]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/NewAPI.sh)'
    [12,5]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/AntigravityManager.sh)'
    [12,6]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/CLIProxyAPI.sh)'
    [12,7]='bash <(curl -sL kejilion.sh) app openclaw'
    [12,8]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/gcli2api.sh)'
    [12,9]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/sub2api.sh)'
    [12,10]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Octopus.sh)'
    [12,11]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/AIClient2API.sh)'
    [12,12]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/CodeG.sh)'
    [12,13]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/SXEdict.sh)'
    [12,14]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/ModelStatus.sh)'
    [12,15]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/CodexConsole.sh)'
    [12,16]='bash <(curl -sL kejilion.sh) app hermes'
    [12,17]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/AI/AZClaudeCode.sh)'
    [12,18]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/AI/AZGeminiCLI.sh)'
    [12,19]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/AI/AZCodexCLI.sh)'
    [13,1]='curl -sSL https://raw.githubusercontent.com/truman-world/puppy-stardew-server/main/quick-start-zh.sh | bash'
    [13,2]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/MCSManager.sh)'
    [13,3]='bash <(curl -sL https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/Taoyuan.sh)'
)

# ================== 菜单显示函数 ==================
show_category_menu() {
    clear
    echo -e "${ORANGE}${BOLD}╔══════════════════════════════╗${RESET}"
    echo -e "${ORANGE}${BOLD}   应用分类菜单(快捷指令:D/d)    ${RESET}"
    echo -e "${ORANGE}${BOLD}╚══════════════════════════════╝${RESET}"

    for i in $(seq 1 ${#categories[@]}); do
        printf "${YELLOW}[%02d] %-20s${RESET}\n" "$i" "${categories[$i]}"
    done

    printf "${GREEN}[%02d] %-20s${RESET}\n" 88 "更新脚本"
    printf "${GREEN}[%02d] %-20s${RESET}\n" 99 "卸载脚本"
    printf "${YELLOW}[%02d] %-20s${RESET}\n" 0  "退出脚本"
}

show_app_menu() {
    local cat=$1
    echo -e "${ORANGE}${BOLD}╔═════════════════════════════╗${RESET}"
    echo -e "${ORANGE}${BOLD}           ${categories[$cat]} ${RESET}"
    echo -e "${ORANGE}${BOLD}╚═════════════════════════════╝${RESET}"

    local i=1
    declare -gA menu_map
    menu_map=()

    keys=()
    for key in "${!apps[@]}"; do
        if [[ $key == $cat,* ]]; then
            keys+=("$key")
        fi
    done

    IFS=$'\n' sorted_keys=($(sort -t, -k2n <<<"${keys[*]}"))
    unset IFS

    for key in "${sorted_keys[@]}"; do
        menu_map[$i]=$key
        printf "${YELLOW}[%02d] %-25s${RESET}\n" "$i" "${apps[$key]}"
        ((i++))
    done

    # 返回上一级菜单
    printf "${GREEN}[0] %-25s${RESET}\n" " 返回"

    # 退出脚本
    printf "${GREEN}[X] %-25s${RESET}\n" " 退出"
}


category_menu_handler() {
    while true; do
        show_category_menu
        read -rp "$(echo -e "${RED}请输入分类编号:${RESET}")" cat_choice
        cat_choice=$(echo "$cat_choice" | xargs)  # 去掉前后空格

        # 检查是否为数字（允许前导零）
        if ! [[ "$cat_choice" =~ ^0*[0-9]+$ ]]; then
            echo -e "${RED}无效选择，请输入数字!${RESET}"
            sleep 1
            continue
        fi

        case "$cat_choice" in
            0|00) exit 0 ;;           # 支持 0 或 00
            88) update_script ;;
            99) uninstall_script ;;
            *)
                if [[ -n "${categories[$cat_choice]}" ]]; then
                    app_menu_handler "$cat_choice"
                else
                    echo -e "${RED}无效选择，请重新输入!${RESET}"
                    sleep 1
                fi
            ;;
        esac
    done
}

app_menu_handler() {
    local cat=$1
    while true; do
        show_app_menu "$cat"
        read -rp "$(echo -e "${RED}请输入应用编号:${RESET}")" app_choice
        app_choice=$(echo "$app_choice" | xargs)

        # X/x 直接退出脚本
        if [[ "$app_choice" =~ ^[xX]$ ]]; then
            exit 0
        fi

        # 检查是否为数字（允许前导零）
        if ! [[ "$app_choice" =~ ^0*[0-9]+$ ]]; then
            echo -e "${RED}无效选择，请输入数字!${RESET}"
            sleep 1
            continue
        fi

        # 支持 0 或 00 返回上一级
        if [[ "$app_choice" == "0" || "$app_choice" == "00" ]]; then
            break
        elif [[ -n "${menu_map[$app_choice]}" ]]; then
            key="${menu_map[$app_choice]}"
            bash -c "${commands[$key]}"
        else
            echo -e "${RED}无效选择，请重新输入!${RESET}"
            sleep 1
        fi

        read -rp $'\033[33m按回车返回应用菜单...\033[0m'
    done
}


# ================== 脚本更新与卸载 ==================
update_script() {
    echo -e "${YELLOW}正在更新脚本...${RESET}"

    if curl -fsSL -o "$SCRIPT_PATH.new" "$SCRIPT_URL"; then
        chmod +x "$SCRIPT_PATH.new"
        mv -f "$SCRIPT_PATH.new" "$SCRIPT_PATH"

        ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/d"
        ln -sf "$SCRIPT_PATH" "$BIN_LINK_DIR/D"

        echo -e "${GREEN}更新完成！${RESET}"
        sleep 1

        exec "$SCRIPT_PATH"
        exit 0
    else
        echo -e "${RED}更新失败，请检查网络！${RESET}"
    fi
}

uninstall_script() {
    echo -e "${YELLOW}正在卸载脚本...${RESET}"
    rm -f "$SCRIPT_PATH"
    rm -f "$BIN_LINK_DIR/d" "$BIN_LINK_DIR/D"
    echo -e "${RED}卸载完成!${RESET}"
    exit 0
}

# ================== 主循环 ==================
while true; do
    category_menu_handler
done
