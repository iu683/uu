#!/bin/bash

# =============================================================================
# 颜色变量定义
# =============================================================================
gl_kjlan='\033[1;36m' # 亮蓝色/科幻蓝
gl_bai='\033[0m'      # 恢复白色/重置
gl_huang('\033[1;33m')# 黄色
gl_lv='\033[1;32m'    # 绿色
gl_hong='\033[1;31m'  # 红色

# 确保有些终端能正常解析颜色
gl_huang='\033[1;33m'

# =============================================================================
# Realm 转发首连超时修复
# =============================================================================
realm_fix_timeout() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}        Realm 转发首连超时修复                     ${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_huang}功能说明：${gl_bai}"
    echo "  • 连接跟踪模块加载 + 容量扩展（转发必需）"
    echo "  • 强制 IPv4 + nodelay + reuse_port（优化 Realm 配置）"
    echo "  • 提升 realm.service 文件句柄限制"
    echo ""
    
    # 检测是否为非交互式环境（比如自动化部署）
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

    # 备份目录
    BACKUP_DIR="/root/.realm_fix_backup/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    echo -e "${gl_lv}[1/4] 创建备份目录：$BACKUP_DIR${gl_bai}"

    # 加载并持久化 nf_conntrack
    echo -e "${gl_lv}[2/4] 加载/持久化 nf_conntrack（连接跟踪）${gl_bai}"
    if command -v modprobe >/dev/null 2>&1; then
        modprobe nf_conntrack 2>/dev/null || true
    fi
    mkdir -p /etc/modules-load.d
    if ! grep -q '^nf_conntrack$' /etc/modules-load.d/conntrack.conf 2>/dev/null; then
        echo nf_conntrack >> /etc/modules-load.d/conntrack.conf
    fi

    # 写入 Realm 专属 sysctl 配置（仅 conntrack_max）
    cat >/etc/sysctl.d/60-realm-tune.conf <<'SYSC'
# Realm 转发专属优化

# 连接跟踪容量（转发必需）
net.netfilter.nf_conntrack_max = 262144
SYSC
    sysctl --system >/dev/null 2>&1
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
            echo -e "${gl_huang}  未安装 jq，使用文本方式修改（推荐安装 jq）${gl_bai}"
            if ! grep -q '"resolve"' "$realm_cfg"; then
                sed -i.bak '0,/{/s//{\n  "resolve": "ipv4",/' "$realm_cfg" || true
            fi
            if ! grep -q '"nodelay"' "$realm_cfg"; then
                sed -i.bak '0,/{/s//{\n  "nodelay": true,/' "$realm_cfg" || true
            fi
            if ! grep -q '"reuse_port"' "$realm_cfg"; then
                sed -i.bak '0,/{/s//{\n  "reuse_port": true,/' "$realm_cfg" || true
            fi
        fi

        # 统一用文本替换确保 IPv6 监听改为 IPv4
        sed -i.bak -E 's/"listen"\s*:\s*":::([0-9]+)"/"listen": "0.0.0.0:\1"/g' "$realm_cfg" 2>/dev/null || true
        sed -i.bak -E 's/"listen"\s*:\s*"\[::\]:([0-9]+)"/"listen": "0.0.0.0:\1"/g' "$realm_cfg" 2>/dev/null || true
        sed -i.bak 's/:::/0.0.0.0:/g' "$realm_cfg" 2>/dev/null || true
        echo -e "${gl_lv}  ✓ Realm 配置已优化${gl_bai}"
    else
        echo -e "${gl_huang}  未找到 $realm_cfg，跳过 Realm 配置修改${gl_bai}"
    fi

    # realm.service 文件句柄限制
    echo -e "${gl_lv}[4/4] 提升 realm.service 文件句柄限制${gl_bai}"
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
