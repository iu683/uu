#!/bin/bash
# ==========================================
# MiGate 一键管理菜单脚本 
# ==========================================

# 颜色定义
GREEN='\033[0;32m'
YELLOW="\033[33m"
RED='\033[0;31m'
NC='\033[0m'
RESET='\033[0m'

# 检查 mg 命令是否可用
check_mg() {
    if ! command -v mg &> /dev/null; then
        echo -e "${RED}错误：未找到 mg 命令，请确认是否已成功安装。${NC}"
        return 1
    fi
    return 0
}

while true; do
    clear
    # 检测安装状态
    if [ -f "/usr/local/bin/migate" ] || [ -f "/usr/local/bin/mg" ]; then
        MSTATUS="${YELLOW}[已安装]${NC}"
    else
        MSTATUS="${RED}[未安装]${NC}"
    fi
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  MiGate 管理工具  ◈      ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 当前状态: ${MSTATUS}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 MiGate${NC}"
    echo -e "${GREEN} 2. 查看 服务状态${NC}"
    echo -e "${GREEN} 3. 查看 实时日志${NC}"
    echo -e "${GREEN} 4. 运行 系统体检${NC}"
    echo -e "${GREEN} 5. 重启 MiGate${NC}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN} 6. 检查 新版本${NC}"
    echo -e "${GREEN} 7. 升级 MiGate${NC}"
    echo -e "${GREEN} 8. 备份 数据${NC}"
    echo -e "${GREEN} 9. 恢复 数据${NC}"
    echo -e "${GREEN}--------------------------------${RESET}"
    echo -e "${GREEN}10. 卸载 MiGate${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${GREEN}================================${RESET}"
    read -rp "$(echo -e "${GREEN}请输入编号:${NC} ")" choice

    case $choice in
        1|01)
            echo -e "${YELLOW}开始下载并安装 MiGate...${NC}"
            bash <(curl -Ls https://raw.githubusercontent.com/imzyb/MiGate/main/packaging/install.sh)
            ;;
        2|02)
            echo -e "${YELLOW}--- MiGate 主服务状态 ---${NC}"
            systemctl status migate --no-pager
            echo -e "${YELLOW}--- Xray 核心状态 ---${NC}"
            systemctl status migate-xray --no-pager 2>/dev/null || echo "Xray 服务未运行或未启用"
            echo -e "${YELLOW}--- sing-box 核心状态 ---${NC}"
            systemctl status migate-sing-box --no-pager 2>/dev/null || echo "sing-box 服务未运行或未启用"
            ;;
        3|03)
            echo -e "${YELLOW}正在查看实时日志，按 Ctrl+C 退出日志查看...${NC}"
            journalctl -u migate -f
            ;;
        4|04)
            check_mg && mg doctor
            ;;
        5|05)
            echo -e "${YELLOW}正在重启 MiGate 服务...${NC}"
            if command -v mg &> /dev/null; then
                mg restart
            else
                systemctl restart migate
                echo -e "${GREEN}服务已尝试重启。${NC}"
            fi
            ;;
        6|06)
            echo -e "${YELLOW}正在检查是否有新版本...${NC}"
            check_mg && mg update --check
            ;;
        7|07)
            echo -e "${YELLOW}正在升级 MiGate...${NC}"
            check_mg && mg update
            ;;
        8|08)
            echo -e "${YELLOW}正在创建系统备份...${NC}"
            check_mg && mg backup
            ;;
        9|09)
            if check_mg; then
                BACKUP_DIR="/var/lib/migate/backups"
                if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
                    echo -e "${RED}未找到任何备份文件！备份目录 $BACKUP_DIR 为空。${NC}"
                else
                    echo -e "${YELLOW}发现以下备份文件：${NC}"
                    echo -e "${GREEN}------------------------------------------------${RESET}"
                    
                    # 将备份文件存入数组
                    shopt -s nullglob
                    backups=("$BACKUP_DIR"/*.tar.gz)
                    shopt -u nullglob
                    
                    for i in "${!backups[@]}"; do
                        echo -e "${GREEN}$((i+1)). $(basename "${backups[$i]}")${NC}"
                    done
                    echo -e "${GREEN}------------------------------------------------${RESET}"
                    read -rp "请选择要恢复的备份编号 (输入 0 取消): " b_choice
                    
                    if [[ "$b_choice" -gt 0 && "$b_choice" -le "${#backups[@]}" ]]; then
                        selected_backup="${backups[$((b_choice-1))]}"
                        echo -e "${YELLOW}正在从以下文件恢复数据: $(basename "$selected_backup")${NC}"
                        mg restore "$selected_backup"
                    else
                        echo -e "${YELLOW}已取消恢复操作。${NC}"
                    fi
                fi
            fi
            ;;
        10)
            echo -e "${RED}警告：即将卸载 MiGate 及其所有数据！${NC}"
            read -rp "确认卸载吗？(y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                if [ -f "/usr/local/bin/migate-uninstall" ]; then
                    echo -e "${YELLOW}调用自带卸载器进行卸载...${NC}"
                    /usr/local/bin/migate-uninstall
                elif command -v mg &> /dev/null; then
                    echo -e "${YELLOW}使用 CLI 卸载...${NC}"
                    mg uninstall
                else
                    echo -e "${YELLOW}未找到卸载器，执行本地暴力强制清理...${NC}"
                    sudo systemctl disable --now migate migate-xray migate-sing-box 2>/dev/null || true
                    sudo rm -f /etc/systemd/system/migate.service /etc/systemd/system/migate-xray.service /etc/systemd/system/migate-sing-box.service
                    sudo systemctl daemon-reload
                    sudo rm -rf /usr/local/bin/migate /usr/local/bin/mg /usr/local/bin/migate-install /usr/local/bin/migate-uninstall
                    sudo rm -rf /var/lib/migate /etc/migate
                    echo -e "${GREEN}强制清理残留完成！${NC}"
                fi
            else
                echo -e "${GREEN}已取消卸载。${NC}"
            fi
            ;;
        0|00)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入。${NC}"
            ;;
    esac

    echo
    read -p "$(echo -e "${GREEN}按回车返回菜单...${RESET}")" temp
done
