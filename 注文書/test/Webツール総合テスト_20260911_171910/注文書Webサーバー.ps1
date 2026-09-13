param(
    [Parameter(Mandatory = $true)]
    [string]$BaseDirectory,
    [int]$Port = 4173,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$basePath = [IO.Path]::GetFullPath($BaseDirectory)
$webRoot = Join-Path $basePath 'web'
$csvPath = Join-Path $basePath '注文データ.csv'
$generatorPath = Join-Path $basePath '注文書作成.ps1'
$outputRoot = Join-Path $basePath '成果物'
$backupRoot = Join-Path $basePath 'backup'
$logPath = Join-Path $basePath '注文書Webサーバー.log'
$serverPort = $Port
$serverUrl = "http://127.0.0.1:${serverPort}/"
$script:serverRunning = $true

$csvHeaders = @(
    '宛先会社名',
    '出力フォルダ名',
    '業務内容',
    '工程範囲',
    '技術者名',
    '単価',
    '固定契約',
    '下限時間',
    '上限時間',
    '弊社責任者',
    '備考'
)

function Write-ServerLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message`r`n"
    [IO.File]::AppendAllText($logPath, $line, [Text.UTF8Encoding]::new($false))
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

function Read-CsvRows {
    param([Parameter(Mandatory = $true)][string]$Path)

    Add-Type -AssemblyName Microsoft.VisualBasic
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new(
        $Path,
        [Text.Encoding]::UTF8,
        $true
    )
    try {
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $rows = [System.Collections.Generic.List[object]]::new()
        while (-not $parser.EndOfData) {
            $rows.Add($parser.ReadFields())
        }
        return $rows.ToArray()
    }
    finally {
        $parser.Close()
    }
}

function Read-OrderData {
    if (-not (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
        throw '注文データ.csv が見つかりません。'
    }

    $rows = @(Read-CsvRows -Path $csvPath)
    if ($rows.Count -lt 2 -or $rows[0].Count -lt 2 -or ([string]$rows[0][0]).Trim() -ne '対象年月') {
        throw 'CSVの1行目は「対象年月,2026-10」の形式で入力してください。'
    }

    $headerIndex = -1
    for ($index = 1; $index -lt $rows.Count; $index++) {
        if ($rows[$index].Count -gt 0 -and ([string]$rows[$index][0]).Trim() -eq '宛先会社名') {
            $headerIndex = $index
            break
        }
    }
    if ($headerIndex -lt 0) {
        throw 'CSVの見出し行が見つかりません。'
    }

    $headers = @($rows[$headerIndex] | ForEach-Object { ([string]$_).Trim() })
    foreach ($requiredHeader in $csvHeaders) {
        if ([Array]::IndexOf($headers, $requiredHeader) -lt 0) {
            throw "CSVに「$requiredHeader」列がありません。"
        }
    }

    $records = [System.Collections.Generic.List[object]]::new()
    for ($rowIndex = $headerIndex + 1; $rowIndex -lt $rows.Count; $rowIndex++) {
        $sourceRow = $rows[$rowIndex]
        $hasValue = $false
        foreach ($field in $sourceRow) {
            if (-not [string]::IsNullOrWhiteSpace([string]$field)) {
                $hasValue = $true
                break
            }
        }
        if (-not $hasValue) {
            continue
        }

        $record = [ordered]@{}
        foreach ($header in $csvHeaders) {
            $columnIndex = [Array]::IndexOf($headers, $header)
            $value = if ($columnIndex -lt $sourceRow.Count) { [string]$sourceRow[$columnIndex] } else { '' }
            $record[$header] = $value
        }
        $records.Add([pscustomobject]$record)
    }

    return [pscustomobject]@{
        targetMonth = ([string]$rows[0][1]).Trim()
        records = @($records)
    }
}

function Convert-ToDecimalValue {
    param([string]$Text)
    $normalized = $Text.Trim() -replace '[,￥¥]', ''
    [decimal]$value = 0
    $parsed = [decimal]::TryParse(
        $normalized,
        [Globalization.NumberStyles]::Number,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$value
    )
    if (-not $parsed) {
        return $null
    }
    return $value
}

function Convert-ToHourValue {
    param([string]$Text)
    $normalized = $Text -replace '[\s,hHｈ時間]', ''
    return Convert-ToDecimalValue -Text $normalized
}

function Test-OrderData {
    param(
        [Parameter(Mandatory = $true)][object]$Data,
        [switch]$RequireRecords
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $targetMonth = Get-PropertyText -Object $Data -Name 'targetMonth'
    if ($targetMonth -notmatch '^\d{4}-(0[1-9]|1[0-2])$') {
        $errors.Add('対象年月は「2026-10」の形式で入力してください。')
    }

    $recordsProperty = $Data.PSObject.Properties['records']
    $records = if ($null -eq $recordsProperty -or $null -eq $recordsProperty.Value) { @() } else { @($recordsProperty.Value) }
    if ($RequireRecords -and $records.Count -eq 0) {
        $errors.Add('注文データが1件もありません。')
    }

    $requiredFields = @('宛先会社名', '業務内容', '工程範囲', '技術者名', '単価', '固定契約', '下限時間', '上限時間', '弊社責任者')
    $duplicateKeys = @{}
    $companyFolders = @{}
    $projectValues = @{}
    $separator = [char]31

    for ($index = 0; $index -lt $records.Count; $index++) {
        $record = $records[$index]
        $displayRow = $index + 1
        foreach ($fieldName in $requiredFields) {
            if ([string]::IsNullOrWhiteSpace((Get-PropertyText -Object $record -Name $fieldName))) {
                $errors.Add("${displayRow}行目の「$fieldName」が未入力です。")
            }
        }

        $companyName = Get-PropertyText -Object $record -Name '宛先会社名'
        $folderName = Get-PropertyText -Object $record -Name '出力フォルダ名'
        $projectName = Get-PropertyText -Object $record -Name '業務内容'
        $engineerName = Get-PropertyText -Object $record -Name '技術者名'
        $contractType = (Get-PropertyText -Object $record -Name '固定契約').ToUpperInvariant()

        if ($contractType -ne 'Y' -and $contractType -ne 'N') {
            $errors.Add("${displayRow}行目の「固定契約」は Y または N を入力してください。")
        }

        $priceText = Get-PropertyText -Object $record -Name '単価'
        if ($priceText -match '\s') {
            $errors.Add("${displayRow}行目の「単価」に途中の空白またはタブがあります。")
        }
        $price = Convert-ToDecimalValue -Text $priceText
        if ($null -eq $price -or $price -lt 0) {
            $errors.Add("${displayRow}行目の「単価」が正しくありません。")
        }

        $lowerHours = Convert-ToHourValue -Text (Get-PropertyText -Object $record -Name '下限時間')
        $upperHours = Convert-ToHourValue -Text (Get-PropertyText -Object $record -Name '上限時間')
        if ($null -eq $lowerHours -or $lowerHours -le 0) {
            $errors.Add("${displayRow}行目の「下限時間」が正しくありません。")
        }
        if ($null -eq $upperHours -or $upperHours -le 0) {
            $errors.Add("${displayRow}行目の「上限時間」が正しくありません。")
        }
        if ($null -ne $lowerHours -and $null -ne $upperHours -and $lowerHours -ge $upperHours) {
            $errors.Add("${displayRow}行目は下限時間を上限時間より小さくしてください。")
        }

        if (-not [string]::IsNullOrWhiteSpace($companyName) -and -not [string]::IsNullOrWhiteSpace($projectName) -and -not [string]::IsNullOrWhiteSpace($engineerName)) {
            $duplicateKey = ($companyName + $separator + $projectName + $separator + $engineerName).ToLowerInvariant()
            if ($duplicateKeys.ContainsKey($duplicateKey)) {
                $errors.Add("${displayRow}行目は$($duplicateKeys[$duplicateKey])行目と同じ会社・業務内容・技術者名です。")
            }
            else {
                $duplicateKeys[$duplicateKey] = $displayRow
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($companyName) -and -not [string]::IsNullOrWhiteSpace($folderName)) {
            $companyKey = $companyName.ToLowerInvariant()
            if (-not $companyFolders.ContainsKey($companyKey)) {
                $companyFolders[$companyKey] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            }
            [void]$companyFolders[$companyKey].Add($folderName)
        }

        if (-not [string]::IsNullOrWhiteSpace($companyName) -and -not [string]::IsNullOrWhiteSpace($projectName)) {
            $projectKey = ($companyName + $separator + $projectName).ToLowerInvariant()
            if (-not $projectValues.ContainsKey($projectKey)) {
                $projectValues[$projectKey] = @{
                    Company = $companyName
                    Project = $projectName
                    工程範囲 = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    弊社責任者 = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    備考 = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                }
            }
            foreach ($commonField in @('工程範囲', '弊社責任者', '備考')) {
                $commonValue = Get-PropertyText -Object $record -Name $commonField
                if (-not [string]::IsNullOrWhiteSpace($commonValue)) {
                    [void]$projectValues[$projectKey][$commonField].Add($commonValue)
                }
            }
        }
    }

    foreach ($companyKey in $companyFolders.Keys) {
        if ($companyFolders[$companyKey].Count -gt 1) {
            $errors.Add("同一会社の「出力フォルダ名」を統一してください。")
        }
    }

    $folderOwners = @{}
    $companyNames = @($records | ForEach-Object { Get-PropertyText -Object $_ -Name '宛先会社名' } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($companyName in $companyNames) {
        $companyKey = $companyName.ToLowerInvariant()
        $folderName = if ($companyFolders.ContainsKey($companyKey) -and $companyFolders[$companyKey].Count -eq 1) {
            [string]($companyFolders[$companyKey] | Select-Object -First 1)
        }
        else {
            $companyName
        }
        $folderKey = $folderName.ToLowerInvariant()
        if ($folderOwners.ContainsKey($folderKey) -and $folderOwners[$folderKey] -ne $companyName) {
            $errors.Add("異なる会社で同じ「出力フォルダ名」は使用できません: $($folderOwners[$folderKey]) / $companyName")
        }
        else {
            $folderOwners[$folderKey] = $companyName
        }
    }

    foreach ($projectKey in $projectValues.Keys) {
        foreach ($commonField in @('工程範囲', '弊社責任者', '備考')) {
            if ($projectValues[$projectKey][$commonField].Count -gt 1) {
                $errors.Add("同一会社・同一業務内容の「$commonField」を統一してください: $($projectValues[$projectKey].Company) / $($projectValues[$projectKey].Project)")
            }
        }
    }

    return @($errors)
}

function Convert-ToCsvField {
    param([string]$Value)
    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($text.IndexOfAny([char[]]@(',', '"', "`r", "`n")) -ge 0) {
        return '"' + $text.Replace('"', '""') + '"'
    }
    return $text
}

function Save-OrderData {
    param([Parameter(Mandatory = $true)][object]$Data)

    $errors = @(Test-OrderData -Data $Data)
    if ($errors.Count -gt 0) {
        throw ($errors -join "`n")
    }

    [void][IO.Directory]::CreateDirectory($backupRoot)
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $backupPath = Join-Path $backupRoot "注文データ_${timestamp}.csv"

    $lines = [System.Collections.Generic.List[string]]::new()
    $targetMonth = Get-PropertyText -Object $Data -Name 'targetMonth'
    $lines.Add("対象年月,$(Convert-ToCsvField -Value $targetMonth)")
    $lines.Add('')
    $lines.Add(($csvHeaders | ForEach-Object { Convert-ToCsvField -Value $_ }) -join ',')

    $records = @($Data.PSObject.Properties['records'].Value)
    foreach ($record in $records) {
        $values = @(
            $csvHeaders | ForEach-Object {
                Convert-ToCsvField -Value (Get-PropertyText -Object $record -Name $_)
            }
        )
        $lines.Add($values -join ',')
    }

    $csvContent = ([string]::Join("`r`n", $lines)) + "`r`n"
    $temporaryPath = Join-Path $basePath ('.注文データ_' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporaryPath, $csvContent, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $csvPath -PathType Leaf) {
        [IO.File]::Replace($temporaryPath, $csvPath, $backupPath, $true)
    }
    else {
        [IO.File]::Move($temporaryPath, $csvPath)
        $backupPath = ''
    }

    return $backupPath
}

function Invoke-OrderGeneration {
    if (-not (Test-Path -LiteralPath $generatorPath -PathType Leaf)) {
        throw '注文書作成.ps1 が見つかりません。'
    }

    $currentData = Read-OrderData
    $errors = @(Test-OrderData -Data $currentData -RequireRecords)
    if ($errors.Count -gt 0) {
        throw ($errors -join "`n")
    }

    $scriptText = [IO.File]::ReadAllText($generatorPath, [Text.Encoding]::UTF8)
    $scriptBlock = [ScriptBlock]::Create($scriptText)
    $messages = [System.Collections.Generic.List[string]]::new()
    try {
        $generatedOutput = @(& $scriptBlock -BaseDirectory $basePath 6>&1 5>&1 4>&1 3>&1 2>&1)
        foreach ($message in $generatedOutput) {
            $messages.Add([string]$message)
        }
    }
    catch {
        $messages.Add($_.Exception.Message)
        throw ($messages -join "`n")
    }

    $log = $messages -join "`n"
    $outputPath = ''
    $match = [regex]::Match($log, '(?m)^全ての注文書を作成しました:\s*(.+?)\s*$')
    if ($match.Success) {
        $outputPath = $match.Groups[1].Value.Trim()
    }
    elseif (Test-Path -LiteralPath $outputRoot -PathType Container) {
        $latestDirectory = Get-ChildItem -LiteralPath $outputRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $latestDirectory) {
            $outputPath = $latestDirectory.FullName
        }
    }

    return [pscustomobject]@{
        log = $log
        outputPath = $outputPath
    }
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

function Get-StaticFile {
    param([Parameter(Mandatory = $true)][string]$RequestPath)
    $fileName = switch ($RequestPath) {
        '/' { 'index.html' }
        '/index.html' { 'index.html' }
        '/app.js' { 'app.js' }
        '/style.css' { 'style.css' }
        default { '' }
    }
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        return $null
    }
    return Join-Path $webRoot $fileName
}

if (-not (Test-Path -LiteralPath $webRoot -PathType Container)) {
    throw 'web フォルダが見つかりません。'
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $serverPort)
try {
    try {
        $listener.Start()
    }
    catch {
        if (-not $NoBrowser) {
            Start-Process $serverUrl
        }
        return
    }

    Write-ServerLog -Message "サーバーを開始しました: $serverUrl"
    if (-not $NoBrowser) {
        Start-Process $serverUrl
    }

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
                $route = "$($request.Method) $($request.Path)"
                switch ($route) {
                    'GET /api/health' {
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true; name = '注文書作成ツール' }
                    }
                    'GET /api/data' {
                        $data = Read-OrderData
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true; targetMonth = $data.targetMonth; records = $data.records }
                    }
                    'POST /api/save' {
                        $payload = $request.Body | ConvertFrom-Json
                        $backupPath = Save-OrderData -Data $payload
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true; backupPath = $backupPath }
                    }
                    'POST /api/generate' {
                        $result = Invoke-OrderGeneration
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true; log = $result.log; outputPath = $result.outputPath }
                    }
                    'POST /api/open-output' {
                        $payload = $request.Body | ConvertFrom-Json
                        $requestedPath = Get-PropertyText -Object $payload -Name 'path'
                        if ([string]::IsNullOrWhiteSpace($requestedPath)) {
                            throw '成果物フォルダが指定されていません。'
                        }
                        $fullOutputRoot = [IO.Path]::GetFullPath($outputRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                        $fullRequestedPath = [IO.Path]::GetFullPath($requestedPath)
                        if (-not $fullRequestedPath.StartsWith($fullOutputRoot, [StringComparison]::OrdinalIgnoreCase) -or
                            -not (Test-Path -LiteralPath $fullRequestedPath -PathType Container)) {
                            throw '成果物フォルダの指定が正しくありません。'
                        }
                        Start-Process 'explorer.exe' -ArgumentList @($fullRequestedPath)
                        Send-JsonResponse -Stream $stream -StatusCode 200 -Data @{ ok = $true }
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
                        $contentType = if ($staticFile.EndsWith('.js')) { 'text/javascript; charset=utf-8' } elseif ($staticFile.EndsWith('.css')) { 'text/css; charset=utf-8' } else { 'text/html; charset=utf-8' }
                        $content = [IO.File]::ReadAllText($staticFile, [Text.Encoding]::UTF8)
                        Send-HttpResponse -Stream $stream -StatusCode 200 -ContentType $contentType -Body $content
                    }
                }
            }
            catch {
                Write-ServerLog -Message "リクエスト処理エラー: $($_.Exception.Message)"
                Send-JsonResponse -Stream $stream -StatusCode 400 -Data @{ ok = $false; error = $_.Exception.Message }
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
