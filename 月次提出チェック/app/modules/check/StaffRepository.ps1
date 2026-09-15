Set-StrictMode -Version Latest

$staffCsvHeaders = @('氏名', '定期券')

function ConvertTo-NameKey {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrEmpty($Name)) {
        return ''
    }
    # NFKC folds full-width brackets, digits and spaces into their half-width forms.
    $normalized = $Name.Normalize([Text.NormalizationForm]::FormKC)
    return ([regex]::Replace($normalized, '\s+', '')).ToLowerInvariant()
}

function ConvertTo-CommuterPassFlag {
    param([AllowEmptyString()][string]$Value)

    $normalized = ConvertTo-NameKey -Name $Value
    return $normalized -in @('○', '◯', '〇', '1', 'true', 'yes', 'y', '有', 'あり', '定期券')
}

function Read-CsvRows {
    param([Parameter(Mandatory = $true)][string]$Path)

    Add-Type -AssemblyName Microsoft.VisualBasic
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($Path, [Text.Encoding]::UTF8, $true)
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

function Read-StaffList {
    if (-not (Test-Path -LiteralPath $staffCsvPath -PathType Leaf)) {
        return
    }
    $rows = @(Read-CsvRows -Path $staffCsvPath)
    if ($rows.Count -eq 0) {
        return
    }
    $headers = @($rows[0] | ForEach-Object { ([string]$_).Trim().TrimStart([char]0xFEFF) })
    $nameIndex = [Array]::IndexOf($headers, '氏名')
    if ($nameIndex -lt 0) {
        throw '人員リスト.csv の1行目に「氏名」列がありません。'
    }
    $passIndex = [Array]::IndexOf($headers, '定期券')

    for ($rowIndex = 1; $rowIndex -lt $rows.Count; $rowIndex++) {
        $row = @($rows[$rowIndex])
        $name = if ($nameIndex -lt $row.Count) { ([string]$row[$nameIndex]).Trim() } else { '' }
        if (-not $name) {
            continue
        }
        $passText = if ($passIndex -ge 0 -and $passIndex -lt $row.Count) { [string]$row[$passIndex] } else { '' }
        [pscustomobject][ordered]@{
            氏名 = $name
            定期券 = [bool](ConvertTo-CommuterPassFlag -Value $passText)
        }
    }
}

function Test-StaffList {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Staff)

    $errors = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    for ($index = 0; $index -lt $Staff.Count; $index++) {
        $name = Get-PropertyText -Object $Staff[$index] -Name '氏名'
        $position = $index + 1
        if (-not $name) {
            $errors.Add("${position}行目: 氏名を入力してください。")
            continue
        }
        $key = ConvertTo-NameKey -Name $name
        if ($seen.ContainsKey($key)) {
            $errors.Add("${position}行目: 「$name」は $($seen[$key])行目と重複しています。")
            continue
        }
        $seen[$key] = $position
    }
    return $errors.ToArray()
}

function Convert-ToCsvField {
    param([AllowEmptyString()][string]$Value)

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($text.IndexOfAny([char[]]@(',', '"', "`r", "`n")) -ge 0) {
        return '"' + $text.Replace('"', '""') + '"'
    }
    return $text
}

function Save-StaffList {
    param([Parameter(Mandatory = $true)][object]$Data)

    $staffProperty = $Data.PSObject.Properties['staff']
    if ($null -eq $staffProperty) {
        throw '人員リストの送信内容が正しくありません。'
    }
    $staff = @($staffProperty.Value | Where-Object { $null -ne $_ })
    $errors = @(Test-StaffList -Staff $staff)
    if ($errors.Count -gt 0) {
        throw ($errors -join "`n")
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(($staffCsvHeaders | ForEach-Object { Convert-ToCsvField -Value $_ }) -join ',')
    foreach ($person in $staff) {
        $name = Get-PropertyText -Object $person -Name '氏名'
        $pass = ConvertTo-CommuterPassFlag -Value (Get-PropertyText -Object $person -Name '定期券')
        $lines.Add((Convert-ToCsvField -Value $name) + ',' + $(if ($pass) { '○' } else { '' }))
    }
    $csvContent = ([string]::Join("`r`n", $lines)) + "`r`n"

    $excelCompatibleUtf8 = [Text.UTF8Encoding]::new($true)
    $csvDirectory = Split-Path $staffCsvPath -Parent
    [void][IO.Directory]::CreateDirectory($csvDirectory)
    [void][IO.Directory]::CreateDirectory($staffBackupRoot)
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $backupPath = Join-Path $staffBackupRoot "人員リスト_${timestamp}.csv"
    $operationId = [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $csvDirectory ".人員リスト_$operationId.tmp"
    $backupTemporaryPath = Join-Path $staffBackupRoot ".人員リスト_backup_$operationId.tmp"
    $replaceBackupPath = Join-Path $csvDirectory ".人員リスト_replace_$operationId.tmp"
    try {
        [IO.File]::WriteAllText($temporaryPath, $csvContent, $excelCompatibleUtf8)
        if (Test-Path -LiteralPath $staffCsvPath -PathType Leaf) {
            $previousContent = [IO.File]::ReadAllText($staffCsvPath, [Text.Encoding]::UTF8)
            [IO.File]::WriteAllText($backupTemporaryPath, $previousContent, $excelCompatibleUtf8)
            [IO.File]::Move($backupTemporaryPath, $backupPath)
            [IO.File]::Replace($temporaryPath, $staffCsvPath, $replaceBackupPath, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $staffCsvPath)
            $backupPath = ''
        }
    }
    finally {
        foreach ($leftover in @($temporaryPath, $backupTemporaryPath, $replaceBackupPath)) {
            if (Test-Path -LiteralPath $leftover -PathType Leaf) {
                Remove-Item -LiteralPath $leftover -Force
            }
        }
    }
    return $backupPath
}
