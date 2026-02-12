#!/bin/sh
# =========================================
# Alpine Linux 语言一键切换工具
# 1=中文  2=English  3=查看状态
# =========================================

GREEN="\033[32m"
RESET="\033[0m"

PROFILE="/etc/profile"

info() { echo -e "${GREEN}[INFO] $1${RESET}"; }

install_locale() {
    apk add --no-cache musl-locales musl-locales-lang fontconfig ttf-dejavu >/dev/null 2>&1
}

clean_lang() {
    sed -i '/LANG=/d' "$PROFILE"
    sed -i '/LANGUAGE=/d' "$PROFILE"
    sed -i '/LC_ALL=/d' "$PROFILE"
    sed -i '/zh_CN/d' "$PROFILE"
    sed -i '/en_US/d' "$PROFILE"
}

set_zh() {
    info "切换中文环境..."
    install_locale
    clean_lang
    cat >> "$PROFILE" <<EOF

export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
EOF
    exec sh -l
}

set_en() {
    info "Switching to English..."
    install_locale
    clean_lang
    cat >> "$PROFILE" <<EOF

export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8
EOF
    exec sh -l
}

show_status() {
    echo
    info "当前语言:"
    locale | grep -E 'LANG=|LC_ALL='
    echo
}

while true; do
    echo -e "${GREEN}===切换字体菜单===${RESET}"
    echo -e "${GREEN}1) 中文 zh_CN${RESET}"
    echo -e "${GREEN}2) English en_US${RESET}"
    echo -e "${GREEN}3) 查看当前语言${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"
    printf "${GREEN}请选择: ${RESET}"
    read opt

    case $opt in
        1) set_zh ;;
        2) set_en ;;
        3) show_status ;;
        0) exit 0 ;;
        *) echo -e "${GREEN}无效选项${RESET}" ;;
    esac
done
