#!/bin/bash

# ================= 配置区 =================
USERNAME="admin"        # 你的树莓派账号
PASSWORD="123456"       # 你的树莓派密码
PORT=22                 # SSH端口，默认22
# ==========================================

echo "[*] 获取本机局域网 IP..."
# 尝试通过默认路由获取 IP
LOCAL_IP=$(ip route get 8.8.8.8 2>/dev/null | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')

# 如果上一步失败，使用 hostname 获取
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP=$(hostname -I | awk '{print $1}')
fi

if [ -z "$LOCAL_IP" ]; then
    echo "[-] 无法获取局域网IP，请检查网络连接。"
    exit 1
fi

echo "[*] 当前设备局域网 IP: $LOCAL_IP"

# 截取网段 前三个数字 (例如 192.168.1)
SUBNET=$(echo "$LOCAL_IP" | cut -d. -f1-3)
echo "[*] 开始扫描当前网段: $SUBNET.0/24"

# 创建临时文件记录开放了端口的IP
TMP_FILE=$(mktemp)

echo "[*] 正在并行扫描开放 ${PORT} 端口的主机，可能需要数秒钟..."

# 并发扫描函数（依赖 bash 自带的 /dev/tcp 特性，无需额外安装 nmap 或 nc）
check_port() {
    local TARGET_IP=$1
    # 设置超时并在后台静默探测端口
    if timeout 0.5 bash -c "</dev/tcp/$TARGET_IP/$PORT" 2>/dev/null; then
        if [ "$TARGET_IP" != "$LOCAL_IP" ]; then
            echo "$TARGET_IP" >> "$TMP_FILE"
        fi
    fi
}

# 循环 1~254 发起后台任务并行扫描
for i in {1..254}; do
    check_port "$SUBNET.$i" &
done

# 等待所有后台任务完成
wait

# 判断是否找到IP
if [ ! -s "$TMP_FILE" ]; then
    echo "[-] 当前网段未发现开放 SSH ($PORT) 端口的主机。"
    rm -f "$TMP_FILE"
    exit 1
fi

# 按行读取到数组中
mapfile -t ALIVE_HOSTS < "$TMP_FILE"
rm -f "$TMP_FILE"

# 将数组元素转为逗号分隔打印
HOSTS_STR=$(IFS=', '; echo "${ALIVE_HOSTS[*]}")
echo "[*] 发现疑似设备: ${HOSTS_STR}"

# 取第一个IP作为目标
TARGET_PI=${ALIVE_HOSTS[0]}
echo "[+] 成功定位到目标树莓派！IP地址为: $TARGET_PI"

echo "[*] 准备连接到 ${USERNAME}@${TARGET_PI} ..."

# 类 Unix 系统自动登录检查
if command -v sshpass >/dev/null 2>&1; then
    echo "[*] 成功检测到 sshpass，正在执行全自动登录..."
    export SSHPASS="$PASSWORD"
    sshpass -e ssh -o StrictHostKeyChecking=no -p "$PORT" "${USERNAME}@${TARGET_PI}"
else
    echo "[!] 未能在环境中检测到 sshpass 工具！"
    echo "[!] 若需全自动免密连接，请安装 sshpass (例如: sudo apt install sshpass)"
    echo -e "\n[!] 正在直接调起 ssh，稍后请手动输入密码: \033[31m${PASSWORD}\033[0m"
    ssh -o StrictHostKeyChecking=no -p "$PORT" "${USERNAME}@${TARGET_PI}"
fi
