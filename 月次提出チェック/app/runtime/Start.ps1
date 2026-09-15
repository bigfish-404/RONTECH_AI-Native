param([Parameter(Mandatory = $true)][string]$AppDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appPath = [IO.Path]::GetFullPath($AppDirectory)
$serverPath = Join-Path $appPath 'runtime\Server.ps1'
if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
    throw "Server.ps1 が見つかりません: $serverPath"
}

function Test-PortAvailable {
    param([Parameter(Mandatory = $true)][int]$Port)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        $listener.Stop()
    }
}

$selectedPort = 0
foreach ($port in 4200..4226) {
    $url = "http://127.0.0.1:$port/"
    try {
        $health = Invoke-RestMethod -Uri ($url + 'api/health') -Method Get -TimeoutSec 1
        if ($health.signature -eq 'rontech-monthly-check-v1' -and
            ([IO.Path]::GetFullPath([string]$health.basePath)).Equals($appPath, [StringComparison]::OrdinalIgnoreCase)) {
            Start-Process $url
            return
        }
    }
    catch {
        # A free or unrelated port is checked below.
    }
    if (Test-PortAvailable -Port $port) {
        $selectedPort = $port
        break
    }
}

if ($selectedPort -eq 0) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        '月次提出チェックを起動できるポートが見つかりませんでした。',
        '月次提出チェック',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    return
}

& $serverPath -AppDirectory $appPath -Port $selectedPort
