#!/bin/bash

GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
YELLOW="\033[33m"
RED="\033[31m"
NC='\033[0;0m' # 无颜色

INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/genguzzz/sbpanel/main/install.sh"

# 菜单主循环
while true; do
    clear
    # 检测 sbpanel 运行/安装状态（若实际安装路径不同，可修改此处检测条件）
    if curl -fsSL "$INSTALL_SCRIPT_URL" | sh -s -- status >/dev/null 2>&1; then
        STATUS="${YELLOW}[运行中 / 已安装]${NC}"
    elif [ -d "/opt/sbpanel" ]; then
        STATUS="${YELLOW}[已安装]${NC}"
    else
        STATUS="${RED}[未安装]${NC}"
    fi

    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN}    ◈  sbpanel 管理菜单  ◈       ${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} 当前状态: ${STATUS}"
    echo -e "${GREEN}=================================${NC}"
    echo -e "${GREEN} 1. 安装 sbpanel (master)${NC}"
    echo -e "${GREEN} 2. 升级 sbpanel${NC}"
    echo -e "${GREEN} 3. 卸载 sbpanel (master/node/all)${NC}"
    echo -e "${GREEN} 4. 查看状态${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${GREEN}=================================${NC}"
    echo -e -n "${GREEN} 请输入选项: ${NC}"
    read -r opt

    case $opt in
        1)
            echo -e "\n${GREEN}开始配置并安装 sbpanel (master)...${NC}\n"
            read -r -p "请输入 Web 监听地址 [默认 127.0.0.1:8080]: " web_addr
            web_addr=${web_addr:-127.0.0.1:8080}

            read -r -p "请输入 gRPC 监听端口 [默认 :9443]: " grpc_addr
            grpc_addr=${grpc_addr:-:9443}

            read -r -p "请输入公网 gRPC 地址 [默认 panel.example.com:9443]: " public_grpc
            public_grpc=${public_grpc:-panel.example.com:9443}

            echo -e "\n${YELLOW}执行安装命令：${NC}"
            echo "curl -fsSL $INSTALL_SCRIPT_URL | sh -s -- master --web \"$web_addr\" --grpc \"$grpc_addr\" --public-grpc \"$public_grpc\""
            echo ""

            curl -fsSL "$INSTALL_SCRIPT_URL" | sh -s -- master \
                --web "$web_addr" \
                --grpc "$grpc_addr" \
                --public-grpc "$public_grpc"

            echo -e "\n${GREEN}安装流程结束（请留意上方输出的初始管理员密码，并配置反代与防火墙）${NC}"
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        2)
            echo -e "\n${GREEN}开始升级 sbpanel...${NC}\n"
            curl -fsSL "$INSTALL_SCRIPT_URL" | sh -s -- upgrade
            echo -e "\n${GREEN}升级完成${NC}"
            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        4)
            echo -e "\n${GREEN}正在获取 sbpanel 状态...${NC}\n"
            curl -fsSL "$INSTALL_SCRIPT_URL" | sh -s -- status
            echo -e "\n${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        3)
            echo -e "\n${YELLOW}请选择要卸载的目标类型：${NC}"
            echo -e "  1) master面板"
            echo -e "  2) node节点"
            echo -e "  3) all全部"
            echo -e "  0) 取消返回"
            read -r -p "请输入选项 [默认 2 (节点)]: " target_opt
            target_opt=${target_opt:-2}

            case $target_opt in
                1) uninstall_target="master" ;;
                2) uninstall_target="node" ;;
                3) uninstall_target="all" ;;
                0)
                    echo -e "\n${YELLOW}已取消卸载${NC}"
                    echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
                    read -n 1 -s
                    continue
                    ;;
                *)
                    echo -e "\n${RED}无效目标选项，已取消卸载${NC}"
                    echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
                    read -n 1 -s
                    continue
                    ;;
            esac

            read -r -p "是否同时删除数据 (--purge)？输入 y 删除数据，其他键保留数据 [默认保留]: " purge_opt
            if [ "$purge_opt" = "y" ] || [ "$purge_opt" = "Y" ]; then
                purge_flag="--purge"
                echo -e "\n${RED}警告：将执行 uninstall ${uninstall_target} --purge（会删除相关数据）！${NC}"
            else
                purge_flag=""
                echo -e "\n${YELLOW}将执行 uninstall ${uninstall_target}（保留数据）${NC}"
            fi

            read -r -p "确认执行上述卸载操作？输入 y 确认，其他键取消: " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo -e "\n${GREEN}开始卸载...${NC}\n"
                if [ -n "$purge_flag" ]; then
                    curl -fsSL "$INSTALL_SCRIPT_URL" | sh -s -- uninstall "$uninstall_target" "$purge_flag"
                else
                    curl -fsSL "$INSTALL_SCRIPT_URL" | sh -s -- uninstall "$uninstall_target"
                fi
                echo -e "\n${GREEN}卸载流程结束${NC}"
            else
                echo -e "\n${YELLOW}已取消卸载${NC}"
            fi

            echo -e -n "${LIGHT_GREEN}按任意键返回菜单...${NC}"
            read -n 1 -s
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "\n${GREEN}无效选项，请重新输入${NC}"
            sleep 2
            ;;
    esac
done
