# Yatori 一行命令在线高速引导安装脚本
# 高速自建入口: irm https://wszgmt.online/install.ps1 | iex
# 永久备用入口: irm https://gitee.com/shuaibwang07-beep/yatori/raw/master/install.ps1 | iex

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$expectedSha256 = "af5a49b54dd1288d6dada768621418d8d9941662bdba2dfbd459f019f21d8635"
$assetName = "Yatori-Installer.exe"
$customMirrorUrl = "https://wszgmt.online/yatori/installer/$assetName"
$giteeUrl = "https://gitee.com/shuaibwang07-beep/yatori/releases/download/installer/$assetName"
$githubUrl = "https://github.com/shuaibwang07-beep/yatori/releases/download/installer/$assetName"
$candidateUrls = @(
    @{ Name = "wszgmt.online (自建高速直连)"; Url = $customMirrorUrl; Direct = $true; HeaderTimeoutSec = 8 },
    @{ Name = "gitee.com (国内直连)"; Url = $giteeUrl; Direct = $true; HeaderTimeoutSec = 15 },
    @{ Name = "github.com (官方源)"; Url = $githubUrl; Direct = $false; HeaderTimeoutSec = 15 },
    @{ Name = "ghfast.top (镜像加速)"; Url = "https://ghfast.top/$githubUrl"; Direct = $false; HeaderTimeoutSec = 15 },
    @{ Name = "gh-proxy.com (镜像加速)"; Url = "https://gh-proxy.com/$githubUrl"; Direct = $false; HeaderTimeoutSec = 15 }
)

Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "    Yatori 一键在线高速引导安装 · Cloud Bootstrap" -ForegroundColor Cyan
Write-Host "  ================================================================" -ForegroundColor Cyan

# 智能确定默认基准目录：若处于 Windows 系统目录（如以管理员打开默认在 System32），自动切换至用户目录避免污染系统目录
$baseDir = (Get-Location).Path
$winDir = $env:SystemRoot
if (-not [string]::IsNullOrWhiteSpace($winDir) -and $baseDir.StartsWith($winDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    $baseDir = Join-Path $HOME "Yatori"
    Write-Host "  [提示] 检测到当前处于系统目录，已自动将默认安装目录切换为: $baseDir" -ForegroundColor Yellow
}

# 选择可写的引导程序落盘目录（优先用户本机可写缓存目录，安装结束后立即删除）
$bootDir = Join-Path $env:LOCALAPPDATA "YatoriBootstrap"
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $bootDir = $baseDir
}
New-Item -ItemType Directory -Path $bootDir -Force | Out-Null
$bootExe = Join-Path $bootDir ("yatori_bootstrap_" + [DateTimeOffset]::Now.ToUnixTimeSeconds() + ".exe")

function Get-FileSha256Hex {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Download-BootstrapFile {
    param(
        [string]$Url,
        [string]$OutPath,
        [bool]$BypassProxy,
        [int]$HeaderTimeoutSec = 12
    )
    $handler = New-Object System.Net.Http.HttpClientHandler
    if ($BypassProxy) {
        $handler.UseProxy = $false
    }
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(5)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("Yatori-OneLine-Bootstrap/1.1")
    $cts = New-Object System.Threading.CancellationTokenSource([TimeSpan]::FromSeconds($HeaderTimeoutSec))
    try {
        $resp = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            throw "HTTP $([int]$resp.StatusCode)"
        }
        $total = $resp.Content.Headers.ContentLength
        $inStream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try {
            $outStream = [System.IO.File]::Create($OutPath)
            try {
                $buf = New-Object byte[] (128 * 1024)
                $readTotal = [long]0
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $lastDraw = [long]-500
                while (($n = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
                    $outStream.Write($buf, 0, $n)
                    $readTotal += $n
                    $ms = $sw.ElapsedMilliseconds
                    if ($total -and $total -gt 0 -and (($ms - $lastDraw) -ge 150 -or $readTotal -ge $total)) {
                        $lastDraw = $ms
                        $pct = [Math]::Min(100.0, [Math]::Round($readTotal * 100.0 / $total, 1))
                        $dlMB = [Math]::Round($readTotal / 1MB, 1)
                        $totMB = [Math]::Round($total / 1MB, 1)
                        $spd = [Math]::Round(($readTotal / [Math]::Max(0.1, $sw.Elapsed.TotalSeconds)) / 1MB, 1)
                        $fill = [int][Math]::Round($pct / 100.0 * 16)
                        $bar = ("#" * $fill) + ("-" * (16 - $fill))
                        Write-Host ("`r  [引导下载] [$bar] {0,5:N1}% | {1}/{2}M | {3}M/s   " -f $pct, $dlMB, $totMB, $spd) -NoNewline -ForegroundColor Green
                    }
                }
                Write-Host ""
            } finally {
                $outStream.Dispose()
            }
        } finally {
            $inStream.Dispose()
        }
    } finally {
        $cts.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

Add-Type -AssemblyName System.Net.Http

$downloaded = $false
try {
    foreach ($src in $candidateUrls) {
        Write-Host "  -> 正在拉取高速引导安装器: $($src.Name)..." -ForegroundColor Yellow
        try {
            $timeoutSec = if ($src.HeaderTimeoutSec) { [int]$src.HeaderTimeoutSec } else { 12 }
            Download-BootstrapFile -Url $src.Url -OutPath $bootExe -BypassProxy ([bool]$src.Direct) -HeaderTimeoutSec $timeoutSec
            $gotHash = Get-FileSha256Hex -Path $bootExe
            if (-not [string]::IsNullOrWhiteSpace($expectedSha256) -and ($gotHash -ne $expectedSha256.ToLowerInvariant())) {
                Write-Host "  [警告] SHA-256 校验不匹配 ($($gotHash.Substring(0,12)))，自动切换备用节点..." -ForegroundColor Red
                Remove-Item -Path $bootExe -Force -ErrorAction SilentlyContinue
                continue
            }
            Write-Host "  [OK] 引导安装器校验通过 (SHA-256 ✓)，即将进入主安装界面..." -ForegroundColor Green
            $downloaded = $true
            break
        } catch {
            Write-Host "  [回退] $($src.Name) 暂不可用 ($($_.Exception.Message))，尝试下一个源..." -ForegroundColor DarkGray
            Remove-Item -Path $bootExe -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $downloaded) {
        throw "所有下载源均无法获取引导安装器，请检查网络连接后重试。"
    }

    & $bootExe --default-dir $baseDir
} finally {
    if (Test-Path $bootExe) {
        Remove-Item -Path $bootExe -Force -ErrorAction SilentlyContinue
    }
}
