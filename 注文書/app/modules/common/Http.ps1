Set-StrictMode -Version Latest

function Write-ServerLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message`r`n"
    [IO.File]::AppendAllText($logPath, $line, [Text.UTF8Encoding]::new($false))
}
function Start-OutputFolderSelection {
    param([string]$CurrentPath)

    $initialPath = if (-not [string]::IsNullOrWhiteSpace($CurrentPath) -and (Test-Path -LiteralPath $CurrentPath -PathType Container)) {
        [IO.Path]::GetFullPath($CurrentPath)
    }
    else {
        [void][IO.Directory]::CreateDirectory($outputRoot)
        $outputRoot
    }

    [void][IO.Directory]::CreateDirectory($outputFolderSelectionRoot)
    $selectionId = [guid]::NewGuid().ToString('N')
    $resultPath = Join-Path $outputFolderSelectionRoot "$selectionId.json"
    $escapedInitialPath = $initialPath.Replace("'", "''")
    $escapedResultPath = $resultPath.Replace("'", "''")
    $pickerScript = @'
Add-Type -AssemblyName System.Windows.Forms
$dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
try {
    $dialog.Description = '注文書の出力先を選択してください。'
    $dialog.SelectedPath = '__INITIAL_PATH__'
    $dialog.ShowNewFolderButton = $true
    $dialogResult = $dialog.ShowDialog()
    $result = if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        @{ cancelled = $false; path = [IO.Path]::GetFullPath($dialog.SelectedPath) }
    } else {
        @{ cancelled = $true; path = '' }
    }
    $json = $result | ConvertTo-Json -Compress
    [IO.File]::WriteAllText('__RESULT_PATH__', $json, [Text.UTF8Encoding]::new($false))
}
finally {
    $dialog.Dispose()
}
'@
    $pickerScript = $pickerScript.Replace('__INITIAL_PATH__', $escapedInitialPath).Replace('__RESULT_PATH__', $escapedResultPath)
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($pickerScript))
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = "-NoProfile -STA -WindowStyle Hidden -EncodedCommand $encodedCommand"
    $startInfo.UseShellExecute = $false
    [void][Diagnostics.Process]::Start($startInfo)
    $script:outputFolderSelections[$selectionId] = @{
        ResultPath = $resultPath
        StartedAt = [datetime]::UtcNow
    }

    return $selectionId
}

function Get-OutputFolderSelection {
    param([Parameter(Mandatory = $true)][string]$SelectionId)

    if ($SelectionId -notmatch '^[0-9a-f]{32}$' -or -not $script:outputFolderSelections.ContainsKey($SelectionId)) {
        throw '出力先選択の識別情報が正しくありません。'
    }
    $selection = $script:outputFolderSelections[$SelectionId]
    $resultPath = [string]$selection.ResultPath
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        if (([datetime]::UtcNow - [datetime]$selection.StartedAt).TotalMinutes -gt 10) {
            $script:outputFolderSelections.Remove($SelectionId)
            throw '出力先の選択がタイムアウトしました。'
        }
        return [pscustomobject]@{ pending = $true; cancelled = $false; path = '' }
    }

    $result = [IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Remove-Item -LiteralPath $resultPath -Force
    $script:outputFolderSelections.Remove($SelectionId)
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
        [Parameter(Mandatory = $true)][string]$Body
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
