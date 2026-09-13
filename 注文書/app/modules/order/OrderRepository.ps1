Set-StrictMode -Version Latest

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

    $errors = @(Test-OrderData -Data $Data -RequireRecords)
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
    $temporaryPath = Join-Path (Split-Path $csvPath -Parent) ('.注文データ_' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporaryPath, $csvContent, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $csvPath -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $csvPath, $backupPath, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $csvPath)
            $backupPath = ''
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }

    return $backupPath
}
