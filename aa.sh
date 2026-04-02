#!/bin/bash

# ================== 颜色 ==================
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
skyblue="\033[36m"
purple="\033[35m"
re="\033[0m"
BLUE="\033[34m"

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

    latest_version="3.14.3"

    if command -v python3 &>/dev/null; then
        current_version=$(python3 -V 2>&1 | awk '{print $2}')

        if [[ "$current_version" == "$latest_version" ]]; then
            echo -e "${green}Python 已是指定版本: ${yellow}${latest_version}${re}"
            return
        fi

        read -rp "检测到当前版本 ${current_version}, 是否安装 Python ${latest_version}？[y/n]: " confirm
        [[ ! $confirm =~ ^[Yy]$ ]] && return
    fi

    install_deps

    cd /tmp || exit

    echo -e "${yellow}正在下载 Python ${latest_version}...${re}"

    wget -q --show-progress -c \
    https://www.python.org/ftp/python/${latest_version}/Python-${latest_version}.tar.xz

    if [[ ! -f Python-${latest_version}.tar.xz ]]; then
        echo -e "${red}Python 下载失败${re}"
        return
    fi

    tar -xf Python-${latest_version}.tar.xz
    cd Python-${latest_version} || exit

    echo -e "${yellow}开始编译安装...${re}"

    ./configure --prefix=/usr/local/python3
    make -j$(nproc 2>/dev/null || echo 2)
    make altinstall

    PY_BIN=$(find /usr/local/python3/bin -name "python3.*" | sort -V | tail -n1)
    PIP_BIN=$(find /usr/local/python3/bin -name "pip3*" | head -n1)

    ln -sf "$PY_BIN" /usr/local/bin/python3
    ln -sf "$PIP_BIN" /usr/local/bin/pip3

    python3 -m ensurepip --upgrade
    python3 -m pip install --upgrade pip

    echo -e "${green}Python ${latest_version} 安装成功${re}"

    cd /tmp
    rm -rf Python-${latest_version}*
}

remove_python() {

    echo -e "${yellow}卸载 Python (仅删除手动安装版本)...${re}"

    rm -rf /usr/local/python3
    rm -f /usr/local/bin/python3*
    rm -f /usr/local/bin/pip3*

    echo -e "${green}Python 卸载完成${re}"
}

# ================== Node.js ==================
install_node() {

if command -v node &>/dev/null; then
    echo -e "${yellow}Node.js 已安装: $(node -v)${re}"
    return
fi

echo -e "${green}安装 Node.js...${re}"

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo -e "${green}Node版本: $(node -v)${re}"
echo -e "${green}NPM版本: $(npm -v)${re}"

}

remove_node() {
    echo -e "${yellow}卸载 Node.js...${re}"

    apt purge -y nodejs
    apt autoremove -y

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
        [[ $current_version == $latest_version_num ]] && {
            echo -e "${green}Go 已是最新版: $current_version${re}"
            return
        }

        read -p "检测到 Go 版本 $current_version, 升级到 $latest_version_num？[y/n]: " confirm
        [[ ! $confirm =~ ^[Yy]$ ]] && return

        remove_go
    fi

    echo -e "${yellow}下载 Go ${latest_version_num}...${re}"

    wget -O /tmp/go_latest.tar.gz "https://go.dev/dl/${latest_version}.linux-${ARCH}.tar.gz" || {
        echo -e "${red}Go 下载失败${re}"
        return
    }

    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go_latest.tar.gz

    echo "export PATH=/usr/local/go/bin:\$PATH" > /etc/profile.d/go.sh
    source /etc/profile.d/go.sh
    hash -r

    rm -f /tmp/go_latest.tar.gz

    echo -e "${green}Go 安装完成，当前版本: $(go version)${re}"
}

remove_go() {
    echo -e "${yellow}卸载 Go...${re}"

    rm -rf /usr/local/go
    rm -f /etc/profile.d/go.sh

    hash -r

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
        echo -e "${yellow}===== 常用环境安装管理=====${re}"
        echo -e "${green} 1.安装Python${re}"
        echo -e "${green} 2.安装Nodejs${re}"
        echo -e "${green} 3.安装Golang${re}"
        echo -e "${green} 4.安装Java${re}"
        echo -e "${green} 5.安装PHP${re}"
        echo -e "${yellow}===== 常用环境卸载管理=====${re}"
        echo -e "${green} 6.卸载Python${re}"
        echo -e "${green} 7.卸载Nodejs${re}"
        echo -e "${green} 8.卸载Golang${re}"
        echo -e "${green} 9.卸载Java${re}"
        echo -e "${green}10.卸载PHP${re}"
        echo -e "${green} 0.退出${re}"
        read -p "$(echo -e ${green} 请输入选项: ${re})" choice

        case $choice in
            1) install_python ;;
            2) install_node ;;
            3) install_go ;;
            4) install_java ;;
            5) install_php ;;
            6) remove_python ;;
            7) remove_node ;;
            8) remove_go ;;
            9) remove_java ;;
            10) remove_php ;;
            0) exit 0 ;;
            *) echo -e "${yellow}无效输入！${re}"; sleep 1 ;;
        esac
        read -p "$(echo -e ${GREEN}按任意键返回菜单...${RESET})" dummy
    done
}

# ================== 启动菜单 ==================
main_menu
