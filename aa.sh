#!/bin/bash
# ==================================================
# ArgoSBX 一键安装脚本（自定义变量版，固定 argo=vmpt）
# ==================================================
# 提示用户输入参数，如果直接回车则使用默认值
read -p "请输入URL端口(默认 8443): " vmpt
vmpt=${vmpt:-8443}

# 固定 Argo 变量
argo="vmpt"

read -p "请输入解析的CF域名(例如example.com): " agn
agn=${agn:-example.com}

read -p "请输入CFToken: " agk
# 必填项，不可为空
if [[ -z "$agk" ]]; then
    echo "CF Token 不能为空！"
    exit 1
fi

# 显示确认信息
echo "----------------------------------------"
echo "配置如下："
echo "URL端口: $vmpt"
echo "Argo变量: $argo"
echo "CF域名: $agn"
echo "CFToken: $agk"
echo "----------------------------------------"

# 导出变量，以便远程脚本使用
export vmpt argo agn agk

# 执行 ArgoSBX 脚本
bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/argosbx/main/argosbx.sh)
