#!/bin/bash

# ================== 颜色 ==================
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
skyblue="\033[36m"
purple="\033[35m"
re="\033[0m"

# ================== 系统检测 ==================
detect_os() {
    OS=$(grep -o -E "Debian|Ubuntu|CentOS|Alpine|Fedora|Rocky|AlmaLinux|Amazon" /etc/os-release 2>/dev/null | head -n 1)
    if [[ -z $OS ]]; then
        echo -e "${red}不支持的系统！${re}"
        exit 1
    else
        echo -e "${green}检测到系统：${yellow}${OS}${re}"
    fi
}

# ================== 基础依赖 ==================
install_deps() {
    case $OS in
        Debian|Ubuntu)
            apt update -y
            apt install -y wget tar build-essential libreadline-dev libncursesw5-dev libssl-dev libsqlite3-dev tk-dev libgdbm-dev libc6-dev libbz2-dev libffi-dev zlib1g-dev curl jq software-properties-common
            ;;
        CentOS)
            yum update -y
            yum groupinstall -y "development tools"
            yum install -y wget tar openssl-devel bzip2-devel libffi-devel zlib-devel curl jq epel-release yum-utils
            ;;
        Fedora|Rocky|AlmaLinux|Amazon)
            dnf update -y
            dnf groupinstall -y "development tools"
            dnf install -y wget tar openssl-devel bzip2-devel libffi-devel zlib-devel curl jq epel-release yum-utils
            ;;
        Alpine)
            apk update
            apk add wget tar build-base openssl-dev bzip2-dev libffi-dev zlib-dev curl jq
            ;;
    esac
}

# ================== 系统架构 ==================
get_arch() {
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) ARCH="amd64" ;;
        x86) ARCH="386" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) echo -e "${red}不支持的架构: $arch${re}"; exit 1 ;;
    esac
}

# ================== Python ==================
install_python() {
    latest_version=$(curl -s https://www.python.org/ftp/python/ | grep -oP '(?<=href=")[0-9.]+(?=/")' | sort -V | tail -n1)
    if command -v python3 &>/dev/null; then
        current_version=$(python3 -V 2>&1 | awk '{print $2}')
        if [[ $current_version == $latest_version ]]; then
            echo -e "${green}Python 已是最新版本: ${yellow}${latest_version}${re}"
            return
        fi
        read -p "检测到 Python 版本 $current_version, 升级到 $latest_version？[y/n]: " confirm
        [[ ! $confirm =~ ^[Yy]$ ]] && return
        remove_python
    fi
    install_deps
    cd /tmp
    wget https://www.python.org/ftp/python/${latest_version}/Python-${latest_version}.tgz
    tar -zxf Python-${latest_version}.tgz
    cd Python-${latest_version}
    ./configure --prefix=/usr/local/python3
    make -j $(nproc)
    make install
    ln -sf /usr/local/python3/bin/python3 /usr/bin/python3
    ln -sf /usr/local/python3/bin/pip3 /usr/bin/pip3
    echo -e "${green}Python ${latest_version} 安装成功${re}"
    cd /tmp && rm -rf Python-${latest_version}*
}

remove_python() {
    echo -e "${yellow}卸载 Python...${re}"
    case $OS in
        Debian|Ubuntu) apt purge -y python3 python3-pip ;;
        CentOS|Fedora|Rocky|AlmaLinux|Amazon) yum remove -y python3 ;;
        Alpine) apk del python3 py3-pip ;;
    esac
    rm -rf /usr/local/python3 /usr/bin/python3 /usr/bin/pip3
    echo -e "${green}Python 卸载完成${re}"
}

# ================== Node.js ==================
install_node() {
    get_arch
    latest_version=$(curl -s https://nodejs.org/dist/index.json | jq -r '.[] | select(.lts != null) | .version' | head -1 | sed 's/^v//')
    if command -v node &>/dev/null; then
        current_version=$(node -v | sed 's/^v//')
        [[ $current_version == $latest_version ]] && { echo -e "${green}Node.js 已是最新版: $latest_version${re}"; return; }
        read -p "检测到 Node.js 版本 $current_version, 升级到 $latest_version？[y/n]: " confirm
        [[ ! $confirm =~ ^[Yy]$ ]] && return
        remove_node
    fi
    install_deps
    NODE_TAR="node-v${latest_version}-linux-${ARCH}.tar.xz"
    wget -O /tmp/$NODE_TAR https://nodejs.org/dist/v${latest_version}/$NODE_TAR
    rm -rf /usr/local/nodejs
    tar -C /usr/local -xf /tmp/$NODE_TAR
    ln -sf /usr/local/node-v${latest_version}-linux-${ARCH} /usr/local/nodejs
    ln -sf /usr/local/nodejs/bin/node /usr/bin/node
    ln -sf /usr/local/nodejs/bin/npm /usr/bin/npm
    echo -e "${green}Node.js ${latest_version} 安装成功${re}"
}

remove_node() {
    echo -e "${yellow}卸载 Node.js...${re}"
    rm -rf /usr/local/nodejs /usr/local/node-v* /usr/bin/node /usr/bin/npm
    echo -e "${green}Node.js 卸载完成${re}"
}

# ================== Go ==================
install_go() {
    get_arch
    html=$(curl -s https://go.dev/dl/)
    latest_version=$(echo "$html" | grep -oP 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    latest_version_num=${latest_version/go/}
    if command -v go &>/dev/null; then
        current_version=$(go version | grep -oE 'go[0-9]+\.[0-9]+\.[0-9]+' | cut -c3-)
        [[ $current_version == $latest_version_num ]] && { echo -e "${green}Go 已是最新版: $current_version${re}"; return; }
        read -p "检测到 Go 版本 $current_version, 升级到 $latest_version_num？[y/n]: " confirm
        [[ ! $confirm =~ ^[Yy]$ ]] && return
        remove_go
    fi
    wget -O /tmp/go_latest.tar.gz "https://golang.org/dl/${latest_version}.linux-${ARCH}.tar.gz"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go_latest.tar.gz
    echo "export PATH=/usr/local/go/bin:\$PATH" > /etc/profile.d/go.sh
    source /etc/profile.d/go.sh
    echo -e "${green}Go 安装完成，当前版本: $(go version)${re}"
}

remove_go() {
    echo -e "${yellow}卸载 Go...${re}"
    rm -rf /usr/local/go
    sed -i '/\/usr\/local\/go\/bin/d' /etc/profile
    echo -e "${green}Go 卸载完成${re}"
}

# ================== Java ==================
install_java() {
    get_arch
    latest_version="17.0.10"
    if command -v java &>/dev/null; then
        current_version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
        [[ $current_version == $latest_version ]] && { echo -e "${green}Java 已是最新版: $latest_version${re}"; return; }
        read -p "检测到 Java 版本 $current_version, 升级到 $latest_version？[y/n]: " confirm
        [[ ! $confirm =~ ^[Yy]$ ]] && return
        remove_java
    fi
    case $OS in
        Debian|Ubuntu) apt install -y openjdk-17-jdk ;;
        CentOS|Fedora|Rocky|AlmaLinux|Amazon) yum install -y java-17-openjdk java-17-openjdk-devel ;;
        Alpine) apk add openjdk17 ;;
    esac
    echo -e "${green}Java 安装完成，版本: $(java -version 2>&1 | head -n1)${re}"
}

remove_java() {
    echo -e "${yellow}卸载 Java...${re}"
    case $OS in
        Debian|Ubuntu) apt remove -y openjdk-* && apt autoremove -y ;;
        CentOS|Fedora|Rocky|AlmaLinux|Amazon) yum remove -y java* && yum autoremove -y ;;
        Alpine) apk del openjdk17 ;;
    esac
    rm -rf /usr/lib/jvm/java-* /usr/local/java /opt/java
    echo -e "${green}Java 卸载完成${re}"
}

# ================== PHP ==================
install_php() {
    case $OS in
        Debian|Ubuntu)
            apt update -y
            add-apt-repository -y ppa:ondrej/php
            apt update -y
            latest_version=$(apt-cache pkgnames | grep -oP '^php[0-9]+\.[0-9]+$' | sort -V | tail -1)
            apt install -y $latest_version $latest_version-cli $latest_version-fpm $latest_version-mysql $latest_version-xml $latest_version-curl $latest_version-mbstring $latest_version-zip
            ;;
        CentOS|Fedora|Rocky|AlmaLinux|Amazon)
            yum install -y epel-release yum-utils
            yum install -y https://rpms.remirepo.net/enterprise/remi-release-7.rpm
            yum-config-manager --enable remi-php74   # 可修改为最新支持版本
            yum install -y php php-cli php-fpm php-mysqlnd php-xml php-mbstring php-curl php-zip
            ;;
        Alpine)
            apk add --no-cache php php-cli php-fpm php-mysqli php-curl php-xml php-mbstring php-zip
            ;;
    esac
    echo -e "${green}PHP 安装完成，版本: $(php -v | head -n1)${re}"
}

remove_php() {
    echo -e "${yellow}卸载 PHP...${re}"
    case $OS in
        Debian|Ubuntu) apt purge -y php* && apt autoremove -y ;;
        CentOS|Fedora|Rocky|AlmaLinux|Amazon) yum remove -y php* && yum autoremove -y ;;
        Alpine) apk del php php-cli php-fpm php-mysqli php-curl php-xml php-mbstring php-zip ;;
    esac
    echo -e "${green}PHP 卸载完成${re}"
}

# ================== 主菜单 ==================
main_menu() {
    detect_os
    while true; do
        clear
        echo -e "${green} 常用环境管理${re}"
        echo "------------------------"
        echo -e "${green} 1. 一键安装Python最新版${re}"
        echo -e "${green} 2. 一键安装Nodejs最新版${re}"
        echo -e "${green} 3. 一键安装Golang最新版${re}"
        echo -e "${green} 4. 一键安装Java最新版${re}"
        echo -e "${green} 5. 一键安装PHP最新版${re}"
        echo "------------------------"
        echo -e "${red} 6. 一键卸载Python${re}"
        echo -e "${red} 7. 一键卸载Nodejs${re}"
        echo -e "${red} 8. 一键卸载Golang${re}"
        echo -e "${red} 9. 一键卸载Java${re}"
        echo -e "${red}10. 一键卸载PHP${re}"
        echo "------------------------"
        echo -e "${green} 0. 退出${re}"
        echo "------------------------"
        read -p $'\033[1;91m请输入你的选择: \033[0m' choice

        case $choice in
            1) install_python ;;
            2) install_node ;;
            3) install_go ;;
            4) install_java ;;
            5) install_php ;;
            6) remove_pyth9 ;;
            7) remove_node ;;
            8) remove_go ;;
            9) remove_java ;;
            10) remove_php ;;
            0) exit 0 ;;
            *) echo -e "${yellow}无效输入！${re}"; sleep 1 ;;
        esac
        read -p "按任意键返回菜单..." dummy
    done
}

# ================== 启动菜单 ==================
main_menu
