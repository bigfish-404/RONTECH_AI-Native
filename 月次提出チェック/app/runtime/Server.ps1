param(
    [Parameter(Mandatory = $true)]
    [string]$AppDirectory,
    [int]$Port = 4200,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appPath = [IO.Path]::GetFullPath($AppDirectory)
$pathRoot = [IO.Path]::GetPathRoot($appPath)
if ($appPath.Length -gt $pathRoot.Length) {
    $appPath = $appPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}
$webRoot = Join-Path $appPath 'web'
$staffCsvPath = Join-Path $appPath 'data\staff\人員リスト.csv'
$staffBackupRoot = Join-Path $appPath 'backup\staff'
$logPath = Join-Path $appPath 'logs\application.log'
$settingsPath = Join-Path $appPath 'config\settings.json'
$defaultFolderRoot = [Environment]::GetFolderPath('MyDocuments')
$serverPort = $Port
$serverUrl = "http://127.0.0.1:${serverPort}/"
$serverOrigin = "http://127.0.0.1:${serverPort}"
$appToken = [guid]::NewGuid().ToString('N')
$toolSignature = 'rontech-monthly-check-v1'
$script:serverRunning = $true
$script:folderSelections = @{}
$folderSelectionRoot = Join-Path ([IO.Path]::GetTempPath()) 'rontech-monthly-check-folder-picker'

. (Join-Path $appPath 'modules\common\Http.ps1')
. (Join-Path $appPath 'modules\common\SettingsStore.ps1')
. (Join-Path $appPath 'modules\check\XlsxReader.ps1')
. (Join-Path $appPath 'modules\check\WorkbookParsers.ps1')
. (Join-Path $appPath 'modules\check\StaffRepository.ps1')
. (Join-Path $appPath 'modules\check\SubmissionScanner.ps1')
. (Join-Path $appPath 'modules\check\CheckRules.ps1')
. (Join-Path $appPath 'modules\check\CheckApi.ps1')
if (-not (Test-Path -LiteralPath $webRoot -PathType Container)) {
    throw 'web フォルダが見つかりません。'
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $serverPort)
try {
    try {
        $listener.Start()
    }
    catch {
        $listenerError = $_.Exception.Message
        $existingIsSameTool = $false
        try {
            $health = Invoke-RestMethod -Uri ($serverUrl + 'api/health') -Method Get -TimeoutSec 2
            $existingIsSameTool = ($health.signature -eq $toolSignature -and $health.basePath -eq $appPath)
        }
        catch {
            $existingIsSameTool = $false
        }
        if ($existingIsSameTool) {
            if (-not $NoBrowser) {
                Start-Process $serverUrl
            }
        }
        else {
            Write-ServerLog -Message "起動エラー: ポート $serverPort を使用できません。$listenerError"
            if (-not $NoBrowser) {
                Add-Type -AssemblyName System.Windows.Forms
                [void][System.Windows.Forms.MessageBox]::Show(
                    "月次提出チェックを起動できませんでした。`nほかのプログラムがポート $serverPort を使用しています。",
                    '月次提出チェック',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        }
        return
    }

    Write-ServerLog -Message "サーバーを開始しました: $serverUrl"
    if (-not $NoBrowser) {
        Start-Process $serverUrl
    }

    $jsonRoutes = @('/api/staff', '/api/check', '/api/folder-path', '/api/select-folder', '/api/folder-selection')
    while ($script:serverRunning) {
        $client = $null
        try {
            $client = $listener.AcceptTcpClient()
            $client.ReceiveTimeout = 30000
            $client.SendTimeout = 30000
            $stream = $client.GetStream()
            $request = Read-HttpRequest -Stream $stream
            if ($null -eq $request) {
                continue
            }

            try {
                $expectedHost = "127.0.0.1:$serverPort"
                $hostHeader = if ($request.Headers.ContainsKey('Host')) { $request.Headers['Host'] } else { '' }
                if ($hostHeader -ne $expectedHost) {
                    throw 'このアドレスからの接続は許可されていません。'
                }
                $isApiRequest = $request.Path.StartsWith('/api/', [StringComparison]::Ordinal)
                if ($isApiRequest -and $request.Path -ne '/api/health') {
                    $requestToken = if ($request.Headers.ContainsKey('X-Check-Tool-Token')) { $request.Headers['X-Check-Tool-Token'] } else { '' }
                    if ($requestToken -ne $appToken) {
                        throw '画面の認証情報が正しくありません。ツールを再起動してください。'
                    }
                }
                if ($request.Method -eq 'POST') {
                    $origin = if ($request.Headers.ContainsKey('Origin')) { $request.Headers['Origin'].TrimEnd('/') } else { '' }
                    if ($origin -and $origin -ne $serverOrigin) {
                        throw 'ほかの画面からの操作は許可されていません。'
                    }
                    if ($request.Path -in $jsonRoutes) {
                        $contentType = if ($request.Headers.ContainsKey('Content-Type')) { $request.Headers['Content-Type'] } else { '' }
                        if (-not $contentType.StartsWith('application/json', [StringComparison]::OrdinalIgnoreCase)) {
                            throw '送信形式が正しくありません。'
                        }
                    }
                }
                $route = "$($request.Method) $($request.Path)"
                switch ($route) {
                    'GET /api/health' {
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true; name = '月次提出チェック'; signature = $toolSignature; basePath = $appPath }
                    }
                    'GET /api/data' {
                        $data = Get-CheckInitialData
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true; staff = $data.staff; folderPath = $data.folderPath; targetMonth = $data.targetMonth }
                    }
                    'POST /api/staff' {
                        $payload = $request.Body | ConvertFrom-Json
                        $backupPath = Save-StaffList -Data $payload
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true; backupPath = $backupPath; staff = @(Read-StaffList) }
                    }
                    'POST /api/check' {
                        $payload = $request.Body | ConvertFrom-Json
                        $report = Invoke-SubmissionCheck -Data $payload
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true; report = $report }
                    }
                    'POST /api/folder-path' {
                        $payload = $request.Body | ConvertFrom-Json
                        $savedPath = Set-CheckFolderPath -FolderPath (Get-PropertyText -Object $payload -Name 'path')
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true; path = $savedPath }
                    }
                    'POST /api/select-folder' {
                        $payload = $request.Body | ConvertFrom-Json
                        $selectionId = Start-FolderSelection -CurrentPath (Get-PropertyText -Object $payload -Name 'currentPath')
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true; selectionId = $selectionId }
                    }
                    'POST /api/folder-selection' {
                        $payload = $request.Body | ConvertFrom-Json
                        $selection = Get-FolderSelection -SelectionId (Get-PropertyText -Object $payload -Name 'selectionId')
                        if (-not $selection.pending -and -not $selection.cancelled) {
                            $selection.path = Set-CheckFolderPath -FolderPath $selection.path
                        }
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true; pending = $selection.pending; cancelled = $selection.cancelled; path = $selection.path }
                    }
                    'POST /api/shutdown' {
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true }
                        $script:serverRunning = $false
                    }
                    default {
                        if ($request.Method -ne 'GET') {
                            Send-JsonResponse -Stream $stream -StatusCode 405 -Data @{ ok = $false; error = '許可されていない操作です。' }
                            break
                        }
                        $staticFile = Get-StaticFile -RequestPath $request.Path
                        if ($null -eq $staticFile -or -not (Test-Path -LiteralPath $staticFile -PathType Leaf)) {
                            Send-HttpResponse -Stream $stream -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Body 'Not Found'
                            break
                        }
                        $contentType = Get-StaticContentType -Path $staticFile
                        $content = [IO.File]::ReadAllText($staticFile, [Text.Encoding]::UTF8)
                        if ($staticFile.EndsWith('index.html', [StringComparison]::OrdinalIgnoreCase)) {
                            $content = $content.Replace('__APP_TOKEN__', $appToken)
                        }
                        Send-HttpResponse -Stream $stream -StatusCode 200 -ContentType $contentType -Body $content
                    }
                }
            }
            catch {
                Write-ServerLog -Message "リクエスト処理エラー: $($_.Exception.Message)"
                Send-JsonResponse -Stream $stream -StatusCode 400 -Data @{
                    ok = $false
                    message = $_.Exception.Message
                    error = $_.Exception.Message
                }
            }
        }
        catch {
            Write-ServerLog -Message "通信エラー: $($_.Exception.Message)"
        }
        finally {
            if ($null -ne $client) {
                $client.Close()
            }
        }
    }
}
finally {
    $listener.Stop()
    Write-ServerLog -Message 'サーバーを終了しました。'
}
