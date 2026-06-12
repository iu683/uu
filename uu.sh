#!/bin/bash

# =========================================
# 系统更新源切换菜单脚本
# 支持 Ubuntu / Debian / CentOS / Alpine / RHEL 等
# =========================================

# 1. 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m❌ 错误：请使用 root 权限或 sudo 运行此脚本！\033[0m"
    exit 1
fi

# 2. 颜色定义
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

# 3. 获取系统信息
if [ -f /etc/os-release ]; then
    . /etc/os-release  # 使用 . 代替 source，完美兼容所有 POSIX Shell
    OS_ID="${NAME} ${VERSION_ID}"
else
    OS_ID="Unknown Linux"
    ID="unknown"
fi

# 4. 获取系统 codename 或版本标识
get_codename() {
    if command -v lsb_release >/dev/null 2>&1; then
        codename=$(lsb_release -cs)
    elif [ -n "$VERSION_CODENAME" ]; then
        codename=$VERSION_CODENAME
    elif [ "$ID" = "alpine" ]; then
        # 兼容 Alpine 环境获取版本
        if [ -z "$VERSION_ID" ] && [ -f /etc/alpine-release ]; then
            VERSION_ID=$(cat /etc/alpine-release)
        fi

        if [[ "$VERSION_ID" == *"_alpha"* || "$VERSION_ID" == *"_beta"* || "$VERSION_ID" == *"_rc"* || "$VERSION_ID" == "edge" ]]; then
            codename="edge"
        elif [ -n "$VERSION_ID" ]; then
            local major_version=$(echo "$VERSION_ID" | cut -d. -f1-2)
            codename="v${major_version}"
        else
            codename="edge"
        fi
    elif [ -n "$VERSION_ID" ]; then
        case "$ID" in
            ubuntu)
                case "$VERSION_ID" in
                    "18.04") codename="bionic" ;;
                    "20.04") codename="focal" ;;
                    "22.04") codename="jammy" ;;
                    "24.04") codename="noble" ;;
                    *) codename="noble" ;; # 默认最新长期支持版
                esac
                ;;
            debian)
                case "$VERSION_ID" in
                    "10") codename="buster" ;;
                    "11") codename="bullseye" ;;
                    "12") codename="bookworm" ;;
                    "13") codename="trixie" ;;
                    *) codename="bookworm" ;;
                esac
                ;;
            centos|rhel|rocky|almalinux)
                codename="el${VERSION_ID%%.*}"
                ;;
        esac
    else
        codename="stable"
    fi

    # 防止 n/a 或空值保底
    if [ -z "$codename" ] || [ "$codename" = "n/a" ]; then
        [ "$ID" = "alpine" ] && codename="edge" || codename="stable"
    fi
}
get_codename

# 5. 定义更新源链接
aliyun_ubuntu_source="http://mirrors.aliyun.com/ubuntu/"
official_ubuntu_source="http://archive.ubuntu.com/ubuntu/"
tsinghua_ubuntu_source="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"

aliyun_debian_source="http://mirrors.aliyun.com/debian/"
official_debian_source="http://deb.debian.org/debian/"
tsinghua_debian_source="https://mirrors.tuna.tsinghua.edu.cn/debian/"

aliyun_centos_source="mirrors.aliyun.com"
official_centos_source="mirror.centos.org"
tsinghua_centos_source="mirrors.tuna.tsinghua.edu.cn"

aliyun_alpine_source="https://mirrors.aliyun.com/alpine/"
official_alpine_source="https://dl-cdn.alpinelinux.org/alpine/"
tsinghua_alpine_source="https://mirrors.tuna.tsinghua.edu.cn/alpine/"

# 6. 获取当前软件源状态（Ubuntu 与 Debian 已完全分离独立检查）
get_current_source_status() {
    case "$ID" in
        ubuntu)
            local file="/etc/apt/sources.list"
            # Ubuntu 24.04+ 优先检测新版源文件路径
            if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
                file="/etc/apt/sources.list.d/ubuntu.sources"
            fi
            
            if [ -f "$file" ]; then
                # 精准提取 URIs: 或 deb 后的 Ubuntu 软件源域名
                local raw_line=$(grep -v '^#' "$file" | grep -E -i 'deb https?://|URIs:\s*https?://' | head -n 1)
                if [ -n "$raw_line" ]; then
                    echo "$raw_line" | sed -E 's|.*https?://([^/ ]+).*|\1|'
                else
                    echo "未检测到有效 Ubuntu 源"
                fi
            else
                echo "未找到 Ubuntu 软件源配置文件"
            fi
            ;;

        debian)
            local file="/etc/apt/sources.list"
            # 只有当新版源文件存在且里面确实有非注释的源内容时，才采用它
            if [ -f /etc/apt/sources.list.d/debian.sources ] && grep -v '^#' /etc/apt/sources.list.d/debian.sources | grep -E -q -i 'deb |URIs:'; then
                file="/etc/apt/sources.list.d/debian.sources"
            fi
            
            if [ -f "$file" ]; then
                local raw_line=$(grep -v '^#' "$file" | grep -E -i 'deb https?://|URIs:\s*https?://' | head -n 1)
                if [ -n "$raw_line" ]; then
                    echo "$raw_line" | sed -E 's|.*https?://([^/ ]+).*|\1|'
                else
                    echo "未检测到有效 Debian 源"
                fi
            else
                echo "未找到 Debian 软件源配置文件"
            fi
            ;;
            
        centos|rhel|rocky|almalinux)
            local repo_file=""
            for f in /etc/yum.repos.d/*.repo; do
                if [ -f "$f" ] && grep -q -E '^baseurl=|^mirrorlist=' "$f"; then
                    repo_file="$f"
                    break
                fi
            done
            if [ -n "$repo_file" ]; then
                local main_url=$(grep -E '^baseurl=|^mirrorlist=' "$repo_file" | head -n 1 | cut -d= -f2)
                [ -z "$main_url" ] && echo "未检测到有效源" || echo "$main_url" | sed -e 's|http://||' -e 's|https://||' -e 's|/.*||'
            else
                echo "未找到有效 repo 配置文件"
            fi
            ;;

        alpine)
            if [ -f /etc/apk/repositories ]; then
                local main_url=$(grep -v '^#' /etc/apk/repositories | head -n 1)
                [ -z "$main_url" ] && echo "未检测到有效源" || echo "$main_url" | sed -e 's|http://||' -e 's|https://||' -e 's|/.*||'
            else
                echo "repositories 不存在"
            fi
            ;;

        *)
            echo "不支持的系统"
            ;;
    esac
}
# 7. 备份当前源
backup_sources() {
    case "$ID" in
        ubuntu|debian)
            [ -f /etc/apt/sources.list ] && cp -f /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null
            [ -f /etc/apt/sources.list.d/ubuntu.sources ] && cp -f /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak 2>/dev/null
            ;;
        centos|rhel|rocky|almalinux)
            mkdir -p /etc/yum.repos.d/bak 2>/dev/null
            if [ -z "$(ls -A /etc/yum.repos.d/bak 2>/dev/null)" ]; then
                cp -f /etc/yum.repos.d/*.repo /etc/yum.repos.d/bak/ 2>/dev/null
            fi
            ;;
        alpine)
            [ -f /etc/apk/repositories ] && cp -f /etc/apk/repositories /etc/apk/repositories.bak 2>/dev/null
            ;;
    esac
    echo -e "${GREEN}已完成当前更新源备份${RESET}"
}

# 8. 还原初始源
restore_sources() {
    case "$ID" in
        ubuntu|debian)
            if [ -f /etc/apt/sources.list.bak ] || [ -f /etc/apt/sources.list.d/ubuntu.sources.bak ]; then
                [ -f /etc/apt/sources.list.bak ] && cp -f /etc/apt/sources.list.bak /etc/apt/sources.list
                [ -f /etc/apt/sources.list.d/ubuntu.sources.bak ] && cp -f /etc/apt/sources.list.d/ubuntu.sources.bak /etc/apt/sources.list.d/ubuntu.sources
                echo -e "${GREEN}已还原初始更新源${RESET}"
            else
                echo -e "${RED}❌ 备份文件不存在，无法还原${RESET}"; return 1
            fi
            ;;
        centos|rhel|rocky|almalinux)
            if [ -d /etc/yum.repos.d/bak ] && [ "$(ls -A /etc/yum.repos.d/bak 2>/dev/null)" ]; then
                cp -f /etc/yum.repos.d/bak/*.repo /etc/yum.repos.d/
                echo -e "${GREEN}已还原初始更新源${RESET}"
            else
                echo -e "${RED}❌ 备份文件不存在，无法还原${RESET}"; return 1
            fi
            ;;
        alpine)
            if [ -f /etc/apk/repositories.bak ]; then
                cp -f /etc/apk/repositories.bak /etc/apk/repositories
                echo -e "${GREEN}已还原初始更新源${RESET}"
            else
                echo -e "${RED}❌ 备份文件不存在，无法还原${RESET}"; return 1
            fi
            ;;
    esac
}

# 9. 切换 Ubuntu/Debian 源
switch_apt_source() {
    local new_source="$1"
    local source_name="$2"

    if [ "$ID" = "debian" ]; then
        local sec_url="http://security.debian.org/debian-security"
        [[ "$new_source" == *"aliyun"* ]] && sec_url="http://mirrors.aliyun.com/debian-security"
        [[ "$new_source" == *"tsinghua"* ]] && sec_url="https://mirrors.tuna.tsinghua.edu.cn/debian-security"

        cat > /etc/apt/sources.list <<EOF
deb ${new_source} ${codename} main contrib non-free non-free-firmware
deb ${new_source} ${codename}-updates main contrib non-free non-free-firmware
deb ${new_source} ${codename}-backports main contrib non-free non-free-firmware
deb ${sec_url} ${codename}-security main contrib non-free non-free-firmware
EOF
        echo -e "${GREEN}✅ 已切换到 ${source_name} Debian 源（${codename}）${RESET}"

    elif [ "$ID" = "ubuntu" ]; then
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ] || [ "$VERSION_ID" = "24.04" ]; then
            # Ubuntu 24.04+ 新版 DEB822 规范
            cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: ${new_source}
Suites: ${codename} ${codename}-updates ${codename}-backports ${codename}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
            echo "# 软件源已移至 sources.list.d/ubuntu.sources" > /etc/apt/sources.list
            echo -e "${GREEN}✅ 已切换到 ${source_name} Ubuntu 新版源（DEB822 格式）${RESET}"
        else
            # Ubuntu 22.04 及以下旧版规范
            [ -f /etc/apt/sources.list.d/ubuntu.sources ] && rm -f /etc/apt/sources.list.d/ubuntu.sources
            cat > /etc/apt/sources.list <<EOF
deb ${new_source} ${codename} main restricted universe multiverse
deb ${new_source} ${codename}-updates main restricted universe multiverse
deb ${new_source} ${codename}-backports main restricted universe multiverse
deb ${new_source} ${codename}-security main restricted universe multiverse
EOF
            echo -e "${GREEN}✅ 已切换到 ${source_name} Ubuntu 传统源（${codename}）${RESET}"
        fi
    fi
}

# 10. 切换 CentOS / RHEL / Rocky / Alma 源（在此处补齐补全）
switch_yum_source() {
    local new_source="$1"
    local source_name="$2"
    
    if ls /etc/yum.repos.d/CentOS-*.repo >/dev/null 2>&1; then
        sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/CentOS-*.repo
        sed -i 's|^#baseurl=|baseurl=|g' /etc/yum.repos.d/CentOS-*.repo
        sed -i "s|mirror.centos.org|$new_source|g" /etc/yum.repos.d/CentOS-*.repo
        sed -i "s|mirrors.aliyun.com|$new_source|g" /etc/yum.repos.d/CentOS-*.repo
        sed -i "s|mirrors.tuna.tsinghua.edu.cn|$new_source|g" /etc/yum.repos.d/CentOS-*.repo
    else
        sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/*.repo 2>/dev/null
        sed -i 's|^#baseurl=|baseurl=|g' /etc/yum.repos.d/*.repo 2>/dev/null
        sed -i -E "s|dl.rockylinux.org|$new_source|g" /etc/yum.repos.d/*.repo 2>/dev/null
        sed -i -E "s|repo.almalinux.org|$new_source|g" /etc/yum.repos.d/*.repo 2>/dev/null
        sed -i -E "s|mirrors.aliyun.com|$new_source|g" /etc/yum.repos.d/*.repo 2>/dev/null
        sed -i -E "s|mirrors.tuna.tsinghua.edu.cn|$new_source|g" /etc/yum.repos.d/*.repo 2>/dev/null
    fi
    echo -e "${GREEN}✅ 已切换到 ${source_name} YUM 源${RESET}"
}

# 11. 切换 Alpine 源
switch_alpine_source() {
    local new_source="$1"
    local source_name="$2"
    
    cat > /etc/apk/repositories <<EOF
${new_source}${codename}/main
${new_source}${codename}/community
EOF
    echo -e "${GREEN}✅ 已切换到 ${source_name} Alpine 源（${codename}）${RESET}"
}

# 12. 更新缓存
update_cache() {
    case "$ID" in
        ubuntu|debian)
            echo -e "${YELLOW}正在更新 apt 缓存...${RESET}"
            apt-get update -y
            ;;
        centos|rhel|rocky|almalinux)
            echo -e "${YELLOW}正在生成 yum/dnf 缓存...${RESET}"
            if command -v dnf >/dev/null 2>&1; then
                dnf clean all && dnf makecache -y
            else
                yum clean all && yum makecache -y
            fi
            ;;
        alpine)
            echo -e "${YELLOW}正在更新 apk 缓存...${RESET}"
            apk update --no-cache
            ;;
    esac
    echo -e "${GREEN}缓存更新完成${RESET}"
}

# 13. 暂停函数
pause() {
    read -rp "$(echo -e "${YELLOW}按回车键继续...${RESET}")"
}

# 14. 显示国内/国外推荐源列表
show_recommended_sources() {
    clear
    echo -e "${GREEN}正在获取外部推荐源脚本...${RESET}"
    if command -v curl >/dev/null 2>&1; then
        bash <(curl -sSL https://linuxmirrors.cn/main.sh)
    elif command -v wget >/dev/null 2>&1; then
        bash <(wget -qO- https://linuxmirrors.cn/main.sh)
    else
        echo -e "${RED}未检测到 curl 或 wget 命令！${RESET}"
        if [ "$ID" = "alpine" ]; then
            echo -e "${YELLOW}提示：Alpine 系统请先运行: apk add curl${RESET}"
        fi
    fi
    pause
}

# 15. 主菜单展示
show_menu() {
    clear
    STATUS=$(get_current_source_status)
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}      ◈    系统更新源管理面板    ◈     ${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN} 系统环境  : ${YELLOW}${OS_ID}${RESET}"
    echo -e "${GREEN} 当前源状态: ${YELLOW}${STATUS}${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -e "${GREEN}  1. 切换到 阿里云源 (国内推荐)${RESET}"
    echo -e "${GREEN}  2. 切换到 官方原生源 (海外推荐)${RESET}"
    echo -e "${GREEN}  3. 切换到 清华大学源 (高校教育网)${RESET}"
    echo -e "${GREEN}  4. 备份当前源文件副本${RESET}"
    echo -e "${GREEN}  5. 还原初始更新源 (并自动刷新缓存)${RESET}"
    echo -e "${GREEN}  6. 国内/国外推荐源一键通 (LinuxMirrors)${RESET}"
    echo -e "${GREEN}  0. 退出${RESET}"
    echo -e "${GREEN}=======================================${RESET}"
    echo -ne "${GREEN} 请输入操作编号: ${RESET}"
}

# 16. 主循环
while true; do
    show_menu
    read -r choice
    case "$choice" in
        1)
            backup_sources
            case "$ID" in
                ubuntu) switch_apt_source "$aliyun_ubuntu_source" "阿里云" ;;
                debian) switch_apt_source "$aliyun_debian_source" "阿里云" ;;
                centos|rhel|rocky|almalinux) switch_yum_source "$aliyun_centos_source" "阿里云" ;;
                alpine) switch_alpine_source "$aliyun_alpine_source" "阿里云" ;;
            esac
            update_cache
            pause
            ;;
        2)
            backup_sources
            case "$ID" in
                ubuntu) switch_apt_source "$official_ubuntu_source" "官方" ;;
                debian) switch_apt_source "$official_debian_source" "官方" ;;
                centos|rhel|rocky|almalinux) switch_yum_source "$official_centos_source" "官方" ;;
                alpine) switch_alpine_source "$official_alpine_source" "官方" ;;
            esac
            update_cache
            pause
            ;;
        3)
            backup_sources
            case "$ID" in
                ubuntu) switch_apt_source "$tsinghua_ubuntu_source" "清华" ;;
                debian) switch_apt_source "$tsinghua_debian_source" "清华" ;;
                centos|rhel|rocky|almalinux) switch_yum_source "$tsinghua_centos_source" "清华" ;;
                alpine) switch_alpine_source "$tsinghua_alpine_source" "清华" ;;
            esac
            update_cache
            pause
            ;;
        4)
            backup_sources
            pause
            ;;
        5)
            if restore_sources; then
                update_cache
            fi
            pause
            ;;
        6)
            show_recommended_sources
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            break
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入${RESET}"
            sleep 1
            ;;
    esac
done
