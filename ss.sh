#!/bin/bash
# =========================================================================
#       ◈ 多语言开发环境通用安装/卸载智控面板 ◈
# =========================================================================

# 权限校验
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m❌ 错误：请使用 root 权限运行此脚本！\033[0m"
    exit 1
fi

green="\033[32m"
yellow="\033[33m"
red="\033[31m"
skyblue="\033[36m"
purple="\033[35m"
re="\033[0m"

# ================== 系统动态精准检测 ==================
detect_os() {
    if [ -f /etc/os-release ]; then
        OS=$(grep -o -E "Debian|Ubuntu|CentOS|Alpine|Fedora|Rocky|AlmaLinux|Amazon" /etc/os-release | head -n 1)
    fi
    if [ -z "$OS" ]; then
        echo -e "${red}❌ 不支持的系统架构！${re}"
        exit 1
    else
        echo -e "${green}当前检测到宿主系统：${yellow}${OS}${re}"
    fi
}

# ================== 自动化依赖环境补全 ==================
install_deps() {
    echo -e "${yellow}⚙️ 正在为您自动同步系统基础依赖包...${re}"
    case "$OS" in
        Debian|Ubuntu)
            apt-get update -y >/dev/null 2>&1
            apt-get install -y wget tar build-essential libreadline-dev libncursesw5-dev libssl-dev libsqlite3-dev tk-dev libgdbm-dev libc6-dev libbz2-dev libffi-dev zlib1g-dev curl jq software-properties-common ca-certificates gnupg >/dev/null 2>&1
            ;;
        CentOS)
            yum update -y >/dev/null 2>&1
            yum groupinstall -y "Development Tools" >/dev/null 2>&1
            yum install -y wget tar openssl-devel bzip2-devel libffi-devel zlib-devel curl jq epel-release yum-utils >/dev/null 2>&1
            ;;
        Fedora|Rocky|AlmaLinux|Amazon)
            dnf update -y >/dev/null 2>&1
            dnf groupinstall -y "Development Tools" >/dev/null 2>&1
            dnf install -y wget tar openssl-devel bzip2-devel libffi-devel zlib-devel curl jq epel-release yum-utils >/dev/null 2>&1
            ;;
        Alpine)
            apk update >/dev/null 2>&1
            apk add wget tar build-base openssl-dev bzip2-dev libffi-dev zlib-dev curl jq >/dev/null 2>&1
            ;;
    esac
}

get_arch() {
    local arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64) ARCH="amd64" ;;
        x86) ARCH="386" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) echo -e "${red}❌ 不支持的硬件架构: $arch_raw${re}"; exit 1 ;;
    esac
}

# ================== Python 3.14+ 编译环境 ==================
install_python() {
    local latest_version="3.14.3"
    if command -v python3 >/dev/null 2>&1; then
        local current_version=$(python3 -V 2>&1 | awk '{print $2}')
        if [ "$current_version" = "$latest_version" ]; then
            echo -e "${green}✓ Python 已是指定编译版本: ${yellow}${latest_version}${re}"
            return
        fi
        echo -ne "${yellow}检测到当前已存在版本 ${current_version}, 是否继续编译安装 Python ${latest_version}？[y/n]: ${re}"
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then return; fi
    fi

    install_deps
    cd /tmp || exit 1
    echo -e "${yellow}🚀 正在从官网拉取 Python ${latest_version} 源码包...${re}"
    wget -c "https://www.python.org/ftp/python/${latest_version}/Python-${latest_version}.tar.xz"

    if [ ! -f "Python-${latest_version}.tar.xz" ]; then
        echo -e "${red}❌ Python 源码下载失败${re}"
        return
    fi

    tar -xf "Python-${latest_version}.tar.xz" && cd "Python-${latest_version}" || exit 1
    echo -e "${yellow}⚙️ 正在为您配置安全编译环境 (Prefix: /usr/local/python3)...${re}"
    ./configure --prefix=/usr/local/python3 >/dev/null 2>&1
    
    echo -e "${yellow}🛠️ 正在多核并行编译中，请耐心等待...${re}"
    make -j$(nproc 2>/dev/null || echo 2) >/dev/null 2>&1
    make altinstall >/dev/null 2>&1

    local PY_BIN=$(find /usr/local/python3/bin -name "python3.*" | sort -V | tail -n1)
    local PIP_BIN=$(find /usr/local/python3/bin -name "pip3*" | head -n1)

    ln -sf "$PY_BIN" /usr/local/bin/python3
    ln -sf "$PIP_BIN" /usr/local/bin/pip3

    python3 -m ensurepip --upgrade >/dev/null 2>&1
    python3 -m pip install --upgrade pip >/dev/null 2>&1

    echo -e "${green}✅ Python ${latest_version} 环境已在全局无缝就绪！${re}"
    cd /tmp && rm -rf "Python-${latest_version}"*
}

remove_python() {
    echo -e "${yellow}⚡ 正在清除自定义编译的 Python 环境...${re}"
    rm -rf /usr/local/python3
    rm -f /usr/local/bin/python3* /usr/local/bin/pip3*
    echo -e "${green}✓ Python 卸载完成${re}"
}

# ================== Node.js 跨平台全自动适配 ==================
install_node() {
    if command -v node >/dev/null 2>&1; then
        echo -e "${yellow}✓ Node.js 已存在，当前版本: $(node -v)${re}"
        return
    fi
    echo -e "${yellow}🚀 正在为您部署跨平台 Node.js 环境...${re}"
    
    case "$OS" in
        Ubuntu|Debian)
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
            apt-get install -y nodejs >/dev/null 2>&1
            ;;
        CentOS|Fedora|Rocky|AlmaLinux|Amazon)
            curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
            dnf install -y nodejs >/dev/null 2>&1 || yum install -y nodejs >/dev/null 2>&1
            ;;
        Alpine)
            apk add --no-cache nodejs npm >/dev/null 2>&1
            ;;
    esac

    if command -v node >/dev/null 2>&1; then
        echo -e "${green}✅ Node.js 安装成功！【Node: $(node -v) | NPM: $(npm -v 2>/dev/null || echo 'N/A')】${re}"
    else
        echo -e "${red}❌ Node.js 部署失败，请检查网路！${re}"
    fi
}

remove_node() {
    echo -e "${yellow}⚡ 正在卸载 Node.js 环境...${re}"
    case "$OS" in
        Ubuntu|Debian) apt-get purge -y nodejs >/dev/null 2>&1 && apt-get autoremove -y >/dev/null 2>&1 ;;
        CentOS|Fedora|Rocky|AlmaLinux|Amazon) yum remove -y nodejs >/dev/null 2>&1 || dnf remove -y nodejs >/dev/null 2>&1 ;;
        Alpine) apk del nodejs npm >/dev/null 2>&1 ;;
    esac
    echo -e "${green}✓ Node.js 清洗完成${re}"
}

# ================== Golang 极致通用升级版 ==================
install_go() {
    get_arch
    echo -e "${yellow}🔍 🔍 正在检索 Go 官网最新长期支持版...${re}"
    local latest_version=$(curl -s https://go.dev/dl/ | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
    local latest_version_num=${latest_version#go}

    if command -v go >/dev/null 2>&1; then
        local current_version=$(go version | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
        current_version=${current_version#go}
        if [ "$current_version" = "$latest_version_num" ]; then
            echo -e "${green}✓ Go 当前已是最新长期支持版: $current_version${re}"
            return
        fi
        echo -ne "${yellow}当前版本为 $current_version, 是否一键平滑升级至 $latest_version_num？[y/n]: ${re}"
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then return; fi
        remove_go
    fi

    echo -e "${yellow}🚀 正在下载 Golang 内核: ${latest_version_num}...${re}"
    wget -O /tmp/go_latest.tar.gz "https://go.dev/dl/${latest_version}.linux-${ARCH}.tar.gz"

    if [ ! -f /tmp/go_latest.tar.gz ]; then
        echo -e "${red}❌ Go 二进制包拉取失败${re}"
        return
    fi

    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go_latest.tar.gz
    rm -f /tmp/go_latest.tar.gz

    # 环境持久化同步
    if [ ! -f /etc/profile.d/go.sh ]; then
        echo "export PATH=/usr/local/go/bin:\$PATH" > /etc/profile.d/go.sh
    fi
    
    export PATH=/usr/local/go/bin:$PATH
    echo -e "${green}✅ Go 环境部署完成！当前内核: $(/usr/local/go/bin/go version)${re}"
}

remove_go() {
    echo -e "${yellow}⚡ 正在清除系统级别 Go 语言环境...${re}"
    rm -rf /usr/local/go
    rm -f /etc/profile.d/go.sh
    echo -e "${green}✓ Go 卸载完成${re}"
}

# ================== Java LTS 21 生产适配 ==================
install_java() {
    if command -v java >/dev/null 2>&1; then
        echo -e "${yellow}✓ 检查到系统已存在 Java 版本: $(java -version 2>&1 | head -n1)${re}"
        echo -ne "${yellow}是否执意重置并重新安装 OpenJDK 21？ [y/N]: ${re}"
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then return; fi
        remove_java
    fi

    echo -e "${yellow}🚀 正在为您匹配最适合当前系统的 OpenJDK 21...${re}"
    case "$OS" in
        Debian|Ubuntu)
            apt-get update -y >/dev/null 2>&1
            if grep -qi "bookworm" /etc/os-release; then
                apt-get install -y wget gpg ca-certificates >/dev/null 2>&1
                mkdir -p /etc/apt/keyrings
                wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg >/dev/null 2>&1
                echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" > /etc/apt/sources.list.d/adoptium.list
                apt-get update -y >/dev/null 2>&1
                apt-get install -y temurin-21-jdk >/dev/null 2>&1
            else
                apt-get install -y openjdk-21-jdk >/dev/null 2>&1
            fi
            ;;
        CentOS|Fedora|Rocky|AlmaLinux|Amazon)
            yum install -y java-21-openjdk java-21-openjdk-devel >/dev/null 2>&1 || dnf install -y java-21-openjdk java-21-openjdk-devel >/dev/null 2>&1
            ;;
        Alpine)
            apk add openjdk21 >/dev/null 2>&1
            ;;
    esac

    if command -v java >/dev/null 2>&1; then
        echo -e "${green}✅ Java 21 安装成功！环境快照：${re}"
        java -version
    else
        echo -e "${red}❌ Java 安装因环境原因遭遇阻碍${re}"
    fi
}

remove_java() {
    echo -e "${yellow}⚡ 正在清除 OpenJDK / Temurin 系统组件...${re}"
    case "$OS" in
        Debian|Ubuntu)
            apt-get remove -y 'openjdk-*' 'temurin-*' >/dev/null 2>&1
            apt-get autoremove -y >/dev/null 2>&1
            rm -f /etc/apt/sources.list.d/adoptium.list /etc/apt/keyrings/adoptium.gpg
            ;;
        CentOS|Fedora|Rocky|AlmaLinux|Amazon)
            yum remove -y java-21-openjdk* >/dev/null 2>&1 || dnf remove -y java-21-openjdk* >/dev/null 2>&1
            ;;
        Alpine)
            apk del openjdk21 >/dev/null 2>&1
            ;;
    esac
    rm -rf /usr/lib/jvm /usr/local/java
    echo -e "${green}✓ Java 环境卸载成功${re}"
}

# ================== PHP 安全稳定运行版 ==================
install_php() {
    echo -e "${yellow}🚀 正在为您接入并拉取适用于 ${OS} 的 PHP 环境...${re}"
    case "$OS" in
        Ubuntu)
            apt-get install -y software-properties-common >/dev/null 2>&1
            add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1
            apt-get update -y >/dev/null 2>&1
            apt-get install -y php php-cli php-fpm php-mysql php-xml php-curl php-mbstring php-zip >/dev/null 2>&1
            ;;
        Debian)
            # Debian 原生极其稳定，默认源直接安装长期支持版
            apt-get update -y >/dev/null 2>&1
            apt-get install -y php php-cli php-fpm php-mysql php-xml php-curl php-mbstring php-zip >/dev/null 2>&1
            ;;
        CentOS|Fedora|Rocky|AlmaLinux|Amazon)
            # 兼容企业级全系 Linux
            dnf install -y php php-cli php-fpm php-mysqlnd php-xml php-mbstring php-curl php-zip >/dev/null 2>&1 || \
            yum install -y php php-cli php-fpm php-mysqlnd php-xml php-mbstring php-curl php-zip >/dev/null 2>&1
            ;;
        Alpine)
            apk add --no-cache php php-cli php-fpm php-mysqli php-curl php-xml php-mbstring php-zip >/dev/null 2>&1
            ;;
    esac
    
    if command -v php >/dev/null 2>&1; then
        echo -e "${green}✅ PHP 部署完成！版本快照: $(php -v | head -n1)${re}"
    else
        echo -e "${red}❌ PHP 环境安装失败，请检查源配置${re}"
    fi
}

remove_php() {
    echo -e "${yellow}⚡ 正在清除 PHP 组件及相关扩展依赖...${re}"
    case "$OS" in
        Debian|Ubuntu) apt-get purge -y php* >/dev/null 2>&1 && apt-get autoremove -y >/dev/null 2>&1 ;;
        CentOS|Fedora|Rocky|AlmaLinux|Amazon) yum remove -y php* >/dev/null 2>&1 || dnf remove -y php* >/dev/null 2>&1 ;;
        Alpine) apk del php php-cli php-fpm php-mysqli php-curl php-xml php-mbstring php-zip >/dev/null 2>&1 ;;
    esac
    echo -e "${green}✓ PHP 全线环境卸载完成${re}"
}

# ================== 核心可交互式大面板 ==================
main_menu() {
    detect_os
    while true; do
        clear
        echo -e "${skyblue}=======================================${re}"
        echo -e "${skyblue}      ◈ 开发语言环境一键智控面板 ◈      ${re}"
        echo -e "${skyblue}=======================================${re}"
        echo -e "${purple} 系统架构 :${re} ${purple}$(uname -m)${re}" 
        echo -e "${purple} 宿主系统 :${re} ${purple}${OS}${re}"
        echo -e "${skyblue}---------------------------------------${re}"
        echo -e "${green}  1) 一键安装 Python 3.14+ (源码编译)${re}"
        echo -e "${green}  2) 一键安装 Node.js LTS  (官方多端适配)${re}"
        echo -e "${green}  3) 一键安装 Golang 最新版 (全局自适应)${re}"
        echo -e "${green}  4) 一键安装 Java LTS 21  (多端生产级)${re}"
        echo -e "${green}  5) 一键安装 PHP 服务环境 (轻量运行组件)${re}"
        echo -e "${skyblue}---------------------------------------${re}"
        echo -e "${red}  6) 一键御载 Python 环境${re}"
        echo -e "${red}  7) 一键御载 Node.js 环境${re}"
        echo -e "${red}  8) 一键御载 Golang 环境${re}"
        echo -e "${red}  9) 一键御载 Java 运行环境${re}"
        echo -e "${red} 10) 一键御载 PHP 服务环境${re}"
        echo -e "${skyblue}---------------------------------------${re}"
        echo -e "${green}  0) 退出"
        echo -e "${skyblue}=======================================${re}"
        
        echo -ne "${green}请输入操作指令编号: ${re}"
        read -r choice

        case "$choice" in
            1) install_python ;;
            2) install_node ;;
            3) install_go ;;
            4) java_out=$(install_java) ;;
            5) install_php ;;
            6) remove_python ;;
            7) remove_node ;;
            8) remove_go ;;
            9) remove_java ;;
            10) remove_php ;;
            0) exit 0 ;;
            *) echo -e "${red}❌ 输入无效，请重新选择！${re}"; sleep 1; continue ;;
        esac
        
        echo ""
        echo -ne "${skyblue}👉 操作已执行完毕，按 [回车键] 重回主菜单...${re}"
        read -r dummy
    done
}

# 启动面板入口
main_menu
