<#
  买 VPS 前/后检测 IP 是否被墙（在【国内 Windows】上运行最准）
  用法：
    .\testip.ps1 -Ips 1.2.3.4,5.6.7.8
    .\testip.ps1 -Ips 1.2.3.4 -Ports 22,80,443,8443
#>
param(
    [Parameter(Mandatory = $true)][string[]]$Ips,
    [int[]]$Ports = @(22, 80, 443, 8443)
)

function Test-OneIp {
    param([string]$Ip, [int[]]$Ports)

    $ping = Test-Connection -ComputerName $Ip -Count 2 -Quiet -ErrorAction SilentlyContinue

    $rows = foreach ($p in $Ports) {
        $r = Test-NetConnection -ComputerName $Ip -Port $p -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        [pscustomobject]@{ Port = $p; Ok = [bool]$r.TcpTestSucceeded }
    }
    $okCount = @($rows | Where-Object { $_.Ok }).Count

    if ($okCount -eq $Ports.Count) {
        $verdict = "OK 全通，IP 干净"
        $color = 'Green'
    } elseif ($okCount -eq 0) {
        if ($ping) { $verdict = "BAD ICMP通但TCP全封 => IP 被墙"; $color = 'Red' }
        else { $verdict = "BAD ICMP与TCP全不通 => IP 段被封/机器不通"; $color = 'Red' }
    } else {
        $verdict = "WARN 部分端口不通（可能是端口级封锁）"
        $color = 'Yellow'
    }

    Write-Host ""
    Write-Host ("IP {0}   ICMP: {1}" -f $Ip, $(if ($ping) { "通" } else { "不通" })) -ForegroundColor Cyan
    foreach ($r in $rows) {
        $mark = if ($r.Ok) { "通" } else { "不通" }
        $c = if ($r.Ok) { 'Green' } else { 'Red' }
        Write-Host ("    TCP {0,-6} {1}" -f $r.Port, $mark) -ForegroundColor $c
    }
    Write-Host ("    => {0}" -f $verdict) -ForegroundColor $color
}

Write-Host "==== VPS IP 被墙检测（国内网络下最有参考价值）====" -ForegroundColor White
foreach ($ip in $Ips) { Test-OneIp -Ip $ip.Trim() -Ports $Ports }
Write-Host ""
Write-Host "判读标准：" -ForegroundColor White
Write-Host "  全通          => 可用"
Write-Host "  ICMP通+TCP全封 => 被墙（换端口无用，只能换 IP 或用 CDN 中转）"
Write-Host "  部分端口不通   => 端口级封锁（换端口可能有效）"
Write-Host ""
Write-Host "补充：再用国内多节点工具交叉验证" -ForegroundColor White
Write-Host "  https://www.itdog.cn/tcping/    (TCPing，全国节点)"
Write-Host "  https://ping.chinaz.com/        (多节点 ping/TCP)"
Write-Host "  https://ping.pe/                (含中国电信/联通/移动节点)"
