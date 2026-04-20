# ================= 配置区 =================
$USERNAME = "admin"        # 你的树莓派账号
$PASSWORD = "123456"       # 你的树莓派密码
$PORT = 22                 # SSH端口，默认22
# ==========================================

Write-Host "[*] 正在获取本机局域网 IP..." -ForegroundColor Cyan

# 获取本地活跃网卡（非虚拟机的活动网卡倾向于默认路由）
$netAdapter = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.InterfaceAlias -notmatch "Loopback|vEthernet|VMware|Virtual" -and $_.IPAddress -like "192.168.*" -or $_.IPAddress -like "10.*" -or $_.IPAddress -like "172.*"
} | Select-Object -First 1

if (-not $netAdapter) {
    # 退化为获取任意有效IPv4
    $netAdapter = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback" } | Select-Object -First 1
}

if (-not $netAdapter) {
    Write-Host "[-] 无法获取局域网IP，请检查网络连接。" -ForegroundColor Red
    exit
}

$localIp = $netAdapter.IPAddress
Write-Host "[*] 当前设备局域网 IP: $localIp" -ForegroundColor Cyan

# 提取网段前三位
$subnet = $localIp.Substring(0, $localIp.LastIndexOf('.'))
Write-Host "[*] 开始扫描当前网段: $subnet.0/24" -ForegroundColor Cyan
Write-Host "[*] 正在并行扫描开放 $PORT 端口的主机，约耗时2秒..." -ForegroundColor Yellow

# 构建要测的IP列表
$ips = 1..254 | ForEach-Object { "$subnet.$_" }

# 使用异步并发测算TCP端口开放状态，这里借用 .NET 的 Sockets 类库
$scriptBlock = {
    param($Ip, $Port)
    $timeout = 500 # 超时时间 500ms
    $tcp = New-Object Net.Sockets.TcpClient
    $ar = $tcp.BeginConnect($Ip, $Port, $null, $null)
    $wait = $ar.AsyncWaitHandle.WaitOne($timeout, $false)
    $isOpen = $tcp.Connected
    if ($isOpen) {
        $tcp.EndConnect($ar)
    }
    $tcp.Close()
    
    if ($isOpen) {
        return $Ip
    }
    return $null
}

# 并发执行 (由于原生PowerShell版本兼容要求，这里使用 RunspacePool 加速)
$runspacePool = [runspacefactory]::CreateRunspacePool(1, 100)
$runspacePool.Open()
$jobs = @()

foreach ($target in $ips) {
    # 自分配排除本机
    if ($target -ne $localIp) {
        $powershell = [powershell]::Create().AddScript($scriptBlock).AddArgument($target).AddArgument($PORT)
        $powershell.RunspacePool = $runspacePool
        $jobs += [PSCustomObject]@{
            Ip = $target
            Job = $powershell.BeginInvoke()
            Ps = $powershell
        }
    }
}

$aliveHosts = @()
# 等待结果
foreach ($jobConfig in $jobs) {
    $jobConfig.Job.AsyncWaitHandle.WaitOne() | Out-Null
    $result = $jobConfig.Ps.EndInvoke($jobConfig.Job)
    if ($result) {
        $aliveHosts += $result
    }
    $jobConfig.Ps.Dispose()
}

$runspacePool.Close()
$runspacePool.Dispose()

if ($aliveHosts.Count -eq 0) {
    Write-Host "[-] 当前网段未发现开放 SSH ($PORT) 端口的主机。" -ForegroundColor Red
    exit
}

Write-Host "[*] 发现疑似设备: $($aliveHosts -join ', ')" -ForegroundColor Cyan
$targetPi = $aliveHosts[0]
Write-Host "[+] 成功定位到目标树莓派！IP地址为: $targetPi" -ForegroundColor Green

Write-Host "[*] 准备连接到 ${USERNAME}@${targetPi} ..." -ForegroundColor Cyan

# Windows 复制密码到剪贴板，方便用户在SSH终端中右键粘贴
Set-Clipboard -Value $PASSWORD
Write-Host "[!] 提醒: $PASSWORD (密码已自动保存到剪贴板)，遇到密码输入提示请直接鼠标“右键”粘贴并按回车！" -ForegroundColor Yellow

# Windows 10/11 原生已内置 OpenSSH Client，直接在此处拉起即可
ssh -o StrictHostKeyChecking=no -p $PORT "${USERNAME}@${targetPi}"
