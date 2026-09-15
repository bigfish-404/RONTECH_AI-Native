Set-StrictMode -Version Latest

function Write-ServerLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    [void][IO.Directory]::CreateDirectory((Split-Path $logPath -Parent))
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message`r`n"
    [IO.File]::AppendAllText($logPath, $line, [Text.UTF8Encoding]::new($false))
}

function Start-FolderSelection {
    param([string]$CurrentPath)

    $initialPath = if (-not [string]::IsNullOrWhiteSpace($CurrentPath) -and (Test-Path -LiteralPath $CurrentPath -PathType Container)) {
        [IO.Path]::GetFullPath($CurrentPath)
    }
    else {
        $defaultFolderRoot
    }

    [void][IO.Directory]::CreateDirectory($folderSelectionRoot)
    $selectionId = [guid]::NewGuid().ToString('N')
    $resultPath = Join-Path $folderSelectionRoot "$selectionId.json"
    $escapedInitialPath = $initialPath.Replace("'", "''")
    $escapedResultPath = $resultPath.Replace("'", "''")
    $pickerScript = @'
Add-Type -AssemblyName System.Windows.Forms
$owner = [System.Windows.Forms.Form]::new()
$dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
try {
    $owner.Text = '月次提出チェック'
    $owner.ShowInTaskbar = $false
    $owner.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
    $owner.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $owner.Size = [Drawing.Size]::new(1, 1)
    $owner.Opacity = 0
    $owner.TopMost = $true
    $owner.Show()
    $owner.Activate()
    $dialog.Description = '勤務表・交通費申請書が入っているフォルダを選択してください。'
    $dialog.SelectedPath = '__INITIAL_PATH__'
    $dialog.ShowNewFolderButton = $false
    $dialogResult = $dialog.ShowDialog($owner)
    $result = if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        @{ cancelled = $false; path = [IO.Path]::GetFullPath($dialog.SelectedPath); error = '' }
    } else {
        @{ cancelled = $true; path = ''; error = '' }
    }
}
catch {
    $result = @{ cancelled = $true; path = ''; error = $_.Exception.Message }
}
finally {
    $dialog.Dispose()
    $owner.Close()
    $owner.Dispose()
}
$json = $result | ConvertTo-Json -Compress
$resultTemporaryPath = '__RESULT_PATH__.tmp'
[IO.File]::WriteAllText($resultTemporaryPath, $json, [Text.UTF8Encoding]::new($false))
[IO.File]::Move($resultTemporaryPath, '__RESULT_PATH__')
'@
    $pickerScript = $pickerScript.Replace('__INITIAL_PATH__', $escapedInitialPath).Replace('__RESULT_PATH__', $escapedResultPath)
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pickerScript))
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = "-NoProfile -STA -WindowStyle Hidden -EncodedCommand $encodedCommand"
    $startInfo.UseShellExecute = $false
    $pickerProcess = [Diagnostics.Process]::Start($startInfo)
    $script:folderSelections[$selectionId] = @{
        ResultPath = $resultPath
        Process = $pickerProcess
        StartedAt = [datetime]::UtcNow
    }

    return $selectionId
}

function Get-FolderSelection {
    param([Parameter(Mandatory = $true)][string]$SelectionId)

    if ($SelectionId -notmatch '^[0-9a-f]{32}$' -or -not $script:folderSelections.ContainsKey($SelectionId)) {
        throw 'フォルダ選択の識別情報が正しくありません。'
    }
    $selection = $script:folderSelections[$SelectionId]
    $resultPath = [string]$selection.ResultPath
    $pickerProcess = [Diagnostics.Process]$selection.Process
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        if ($pickerProcess.HasExited) {
            Remove-Item -LiteralPath "$resultPath.tmp" -Force -ErrorAction SilentlyContinue
            $pickerProcess.Dispose()
            $script:folderSelections.Remove($SelectionId)
            throw 'フォルダ選択画面を開始できませんでした。もう一度お試しください。'
        }
        if (([datetime]::UtcNow - [datetime]$selection.StartedAt).TotalMinutes -gt 10) {
            try {
                if (-not $pickerProcess.HasExited) {
                    $pickerProcess.Kill()
                }
            }
            catch {
                # The picker may exit naturally between the status check and cleanup.
            }
            Remove-Item -LiteralPath "$resultPath.tmp" -Force -ErrorAction SilentlyContinue
            $pickerProcess.Dispose()
            $script:folderSelections.Remove($SelectionId)
            throw 'フォルダの選択がタイムアウトしました。'
        }
        return [pscustomobject]@{ pending = $true; cancelled = $false; path = '' }
    }

    $result = [IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Remove-Item -LiteralPath $resultPath -Force
    $pickerProcess.Dispose()
    $script:folderSelections.Remove($SelectionId)
    $errorProperty = $result.PSObject.Properties['error']
    if ($null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)) {
        throw "フォルダ選択画面でエラーが発生しました: $([string]$errorProperty.Value)"
    }
    return [pscustomobject]@{
        pending = $false
        cancelled = [bool]$result.cancelled
        path = [string]$result.path
    }
}

function Get-StaticFile {
    param([Parameter(Mandatory = $true)][string]$RequestPath)

    $relativePath = if ($RequestPath -eq '/' -or $RequestPath -eq '/index.html') {
        'index.html'
    }
    else {
        $RequestPath.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
    }
    if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath.IndexOf([char]0) -ge 0) {
        return $null
    }

    $candidate = [IO.Path]::GetFullPath((Join-Path $webRoot $relativePath))
    $webPrefix = $webRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($webPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if ([IO.Path]::GetExtension($candidate).ToLowerInvariant() -notin @('.html', '.js', '.css')) {
        return $null
    }
    return $candidate
}

function Get-StaticContentType {
    param([Parameter(Mandatory = $true)][string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.js' { return 'text/javascript; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        default { return 'text/html; charset=utf-8' }
    }
}

function Get-PropertyText {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }
    return ([string]$property.Value).Trim()
}

function Read-HttpRequest {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)

    $headerBytes = [System.Collections.Generic.List[byte]]::new()
    while ($headerBytes.Count -lt 65536) {
        $nextByte = $Stream.ReadByte()
        if ($nextByte -lt 0) {
            break
        }
        $headerBytes.Add([byte]$nextByte)
        $count = $headerBytes.Count
        if ($count -ge 4 -and
            $headerBytes[$count - 4] -eq 13 -and
            $headerBytes[$count - 3] -eq 10 -and
            $headerBytes[$count - 2] -eq 13 -and
            $headerBytes[$count - 1] -eq 10) {
            break
        }
    }

    if ($headerBytes.Count -eq 0) {
        return $null
    }
    $headerText = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $headerLines = $headerText -split "`r`n"
    $requestParts = $headerLines[0].Split(' ')
    if ($requestParts.Count -lt 2) {
        throw 'HTTPリクエストが正しくありません。'
    }

    $headers = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($index = 1; $index -lt $headerLines.Count; $index++) {
        $line = $headerLines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $separatorIndex = $line.IndexOf(':')
        if ($separatorIndex -gt 0) {
            $headers[$line.Substring(0, $separatorIndex).Trim()] = $line.Substring($separatorIndex + 1).Trim()
        }
    }

    $contentLength = 0
    if ($headers.ContainsKey('Content-Length')) {
        [void][int]::TryParse($headers['Content-Length'], [ref]$contentLength)
    }
    if ($contentLength -gt 2MB) {
        throw 'リクエストのサイズが大きすぎます。'
    }

    $bodyBytes = [byte[]]::new($contentLength)
    $offset = 0
    while ($offset -lt $contentLength) {
        $readCount = $Stream.Read($bodyBytes, $offset, $contentLength - $offset)
        if ($readCount -le 0) {
            break
        }
        $offset += $readCount
    }

    $rawTarget = $requestParts[1]
    $path = [Uri]::UnescapeDataString(($rawTarget -split '\?')[0])
    return [pscustomobject]@{
        Method = $requestParts[0].ToUpperInvariant()
        Path = $path
        Headers = $headers
        Body = [Text.Encoding]::UTF8.GetString($bodyBytes, 0, $offset)
    }
}

function Send-HttpResponse {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$ContentType,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body
    )

    $reason = switch ($StatusCode) {
        200 { 'OK' }
        400 { 'Bad Request' }
        404 { 'Not Found' }
        405 { 'Method Not Allowed' }
        default { 'Internal Server Error' }
    }
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $header = "HTTP/1.1 $StatusCode $reason`r`n" +
        "Content-Type: $ContentType`r`n" +
        "Content-Length: $($bodyBytes.Length)`r`n" +
        "Cache-Control: no-store`r`n" +
        "X-Content-Type-Options: nosniff`r`n" +
        "X-Frame-Options: DENY`r`n" +
        "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'`r`n" +
        "Connection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $Stream.Flush()
}

function Send-JsonResponse {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][object]$Data
    )
    $json = $Data | ConvertTo-Json -Depth 12 -Compress
    Send-HttpResponse -Stream $Stream -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Body $json
}
