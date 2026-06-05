#!/bin/bash

# =============================================================================
# 颜色变量定义
# =============================================================================
gl_kjlan='\033[1;36m' # 亮蓝色/科幻蓝
gl_bai='\033[0m'      # 恢复白色/重置
gl_huang='\033[1;33m'  # 黄色
gl_lv='\033[1;32m'    # 绿色
gl_hong='\033[1;31m'  # 红色

# =============================================================================
# Realm 转发首连超时修复
# =============================================================================
realm_fix_timeout() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}            Realm 转发首连超时修复 (含Alpine适配)   ${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_huang}功能说明：${gl_bai}"
    echo "  • 连接跟踪模块加载 + 容量扩展（转发必需）"
    echo "  • 强制 IPv4 + nodelay + reuse_port（优化 Realm 配置）"
    echo "  • 提升 Realm 进程文件句柄限制 (Systemd/OpenRC)"
    echo ""
    
    # 检测是否为非交互式环境
    if [ "$AUTO_MODE" = "1" ] || [ ! -t 0 ]; then
        confirm=y
    else
        read -e -p "是否继续执行修复？(y/n): " confirm
    fi

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${gl_huang}已取消操作${gl_bai}"
        return
    fi

    # 检查 root 权限
    if [[ ${EUID:-0} -ne 0 ]]; then
        echo -e "${gl_hong}错误：请以 root 身份运行（sudo -i 或 sudo bash）${gl_bai}"
        exit 1
    fi

    # 检测系统类型
    IS_ALPINE=0
    if [ -f /etc/alpine-release ]; then
        IS_ALPINE=1
    fi

    # 备份目录
    BACKUP_DIR="/etc/.realm_fix_backup/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    echo -e "${gl_lv}[1/4] 创建备份目录：$BACKUP_DIR${gl_bai}"

    # 加载并持久化 nf_conntrack
    echo -e "${gl_lv}[2/4] 加载/持久化 nf_conntrack（连接跟踪）${gl_bai}"
    
    # Alpine 尝试安装内核扩展（如果需要）
    if [ "$IS_ALPINE" -eq 1 ]; then
        apk add --no-cache iptables >/dev/null 2>&1 || true
    fi

    if command -v modprobe >/dev/null 2>&1; then
        modprobe nf_conntrack 2>/dev/null || true
    fi

    # 持久化模块加载
    if [ "$IS_ALPINE" -eq 1 ]; then
        if ! grep -q '^nf_conntrack$' /etc/modules 2>/dev/null; then
            echo "nf_conntrack" >> /etc/modules
        fi
    else
        mkdir -p /etc/modules-load.d
        if ! grep -q '^nf_conntrack$' /etc/modules-load.d/conntrack.conf 2>/dev/null; then
            echo nf_conntrack >> /etc/modules-load.d/conntrack.conf
        fi
    fi

    # 写入 Realm 专属 sysctl 配置
    mkdir -p /etc/sysctl.d
    cat >/etc/sysctl.d/60-realm-tune.conf <<'SYSC'
# Realm 转发专属优化
net.netfilter.nf_conntrack_max = 262144
SYSC
    
    # 兼容 Alpine 的 sysctl 刷新
    if [ "$IS_ALPINE" -eq 1 ]; then
        sysctl -p /etc/sysctl.d/60-realm-tune.conf >/dev/null 2>&1 || true
    else
        sysctl --system >/dev/null 2>&1 || true
    fi
    echo -e "${gl_lv}  ✓ nf_conntrack_max = 262144 已生效${gl_bai}"

    # 修改 Realm 配置
    echo -e "${gl_lv}[3/4] 优化 Realm 配置（IPv4 + nodelay + reuse_port）${gl_bai}"
    realm_cfg="/etc/realm/config.json"
    if [[ -f "$realm_cfg" ]]; then
        cp -a "$realm_cfg" "$BACKUP_DIR/"

        if command -v jq >/dev/null 2>&1; then
            tmpfile=$(mktemp)
            jq '.resolve = "ipv4" | .nodelay = true | .reuse_port = true' \
                "$realm_cfg" >"$tmpfile" && mv "$tmpfile" "$realm_cfg"
        else
            echo -e "${gl_huang}  未安装 jq，使用文本方式修改${gl_bai}"
            # 兼容 BusyBox sed 的写法，避免使用复杂的 0,/{/ 语法
            # 简单粗暴地在第一行后面追加配置（假设符合标准JSON开头）
            sed -i 's/^[[:space:]]*{/{\n  "resolve": "ipv4",\n  "nodelay": true,\n  "reuse_port": true,/' "$realm_cfg" 2>/dev/null || true
        fi

        # 统一用文本替换确保 IPv6 监听改为 IPv4 (移除了不兼容的 .bak 后缀)
        sed -i -E 's/"listen"\s*:\s*":::([0-9]+)"/"listen": "0.0.0.0:\1"/g' "$realm_cfg" 2>/dev/null || true
        sed -i -E 's/"listen"\s*:\s*"\[::\]:([0-9]+)"/"listen": "0.0.0.0:\1"/g' "$realm_cfg" 2>/dev/null || true
        sed -i 's/:::/0.0.0.0:/g' "$realm_cfg" 2>/dev/null || true
        echo -e "${gl_lv}  ✓ Realm 配置已优化${gl_bai}"
    else
        echo -e "${gl_huang}  未找到 $realm_cfg，跳过 Realm 配置修改${gl_bai}"
    fi

    # realm 服务文件句柄限制 (兼容 Systemd 和 OpenRC)
    echo -e "${gl_lv}[4/4] 提升 Realm 服务文件句柄限制${gl_bai}"
    
    if [ "$IS_ALPINE" -eq 1 ]; then
        # Alpine OpenRC 环境
        if [ -f /etc/init.d/realm ]; then
            # 在 OpenRC 脚本或配置文件中加上限制
            if [ -f /etc/conf.d/realm ]; then
                if ! grep -q 'rc_ulimit' /etc/conf.d/realm; then
                    echo 'rc_ulimit="-n 1048576"' >> /etc/conf.d/realm
                fi
            else
                mkdir -p /etc/conf.d
                echo 'rc_ulimit="-n 1048576"' > /etc/conf.d/realm
            fi
            rc-service realm restart >/dev/null 2>&1 || echo -e "${gl_huang}  ⚠ realm 重启失败，请手动检查${gl_bai}"
            echo -e "${gl_lv}  ✓ OpenRC ulimit 限制已生效${gl_bai}"
        else
            echo -e "${gl_huang}  未发现 /etc/init.d/realm 服务，跳过句柄限制${gl_bai}"
        fi
    else
        # 传统的 Systemd 环境
        if systemctl list-unit-files 2>/dev/null | grep -q '^realm\.service'; then
            mkdir -p /etc/systemd/system/realm.service.d
            cat >/etc/systemd/system/realm.service.d/override.conf <<'OVR'
[Service]
LimitNOFILE=1048576
OVR
            systemctl daemon-reload
            systemctl restart realm 2>/dev/null || echo -e "${gl_huang}  ⚠ realm 重启失败，请手动检查${gl_bai}"
            echo -e "${gl_lv}  ✓ LimitNOFILE=1048576 已生效${gl_bai}"
        else
            echo -e "${gl_huang}  未发现 realm.service，跳过${gl_bai}"
        fi
    fi

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}            ✅ Realm 优化完成！${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_huang}📋 备份位置：${gl_bai}$BACKUP_DIR"
    echo ""
    echo -e "${gl_huang}🔍 快速验证：${gl_bai}"
    echo "  • Realm 监听：   ss -tlnp | grep realm"
    echo "  • conntrack：   sysctl net.netfilter.nf_conntrack_max"
    echo "  • Realm 配置：   cat /etc/realm/config.json | grep -E 'resolve|nodelay|reuse_port'"
    echo ""
    echo -e "${gl_lv}💯 重启服务器后所有配置依然生效，无需重复执行！${gl_bai}"
    echo ""
}

# =============================================================================
# 脚本执行入口
# =============================================================================
realm_fix_timeout
