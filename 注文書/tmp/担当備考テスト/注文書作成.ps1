param(
    [Parameter(Mandatory = $true)]
    [string]$BaseDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
            $fields = $parser.ReadFields()
            $rows.Add($fields)
        }

        return $rows.ToArray()
    }
    finally {
        $parser.Close()
    }
}

function Convert-ToTargetMonth {
    param([Parameter(Mandatory = $true)][string]$Text)

    $value = $Text.Trim()
    $year = 0
    $month = 0

    if ($value -match '^(?<year>\d{4})[-/](?<month>\d{1,2})$') {
        $year = [int]$Matches.year
        $month = [int]$Matches.month
    }
    elseif ($value -match '^(?<year>\d{4})(?<month>\d{2})$') {
        $year = [int]$Matches.year
        $month = [int]$Matches.month
    }
    elseif ($value -match '^(?<year>\d{4})年(?<month>\d{1,2})月$') {
        $year = [int]$Matches.year
        $month = [int]$Matches.month
    }
    else {
        throw "対象年月の形式が正しくありません: $Text（例: 2026-10）"
    }

    if ($month -lt 1 -or $month -gt 12) {
        throw "対象年月の月が正しくありません: $Text"
    }

    return [datetime]::new($year, $month, 1)
}

function Convert-ToUnitPrice {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$CsvRowNumber
    )

    $normalized = $Text -replace '[,\s￥¥]', ''
    [decimal]$price = 0
    $parsed = [decimal]::TryParse(
        $normalized,
        [Globalization.NumberStyles]::Number,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$price
    )

    if (-not $parsed -or $price -lt 0) {
        throw "CSV $CsvRowNumber 行目の単価が正しくありません: $Text"
    }

    return $price
}

function Convert-ToBaseHour {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [Parameter(Mandatory = $true)][int]$CsvRowNumber
    )

    $normalized = $Text -replace '[\s,hHｈ時間]', ''
    [decimal]$hours = 0
    $parsed = [decimal]::TryParse(
        $normalized,
        [Globalization.NumberStyles]::Number,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$hours
    )

    if (-not $parsed -or $hours -le 0) {
        throw "CSV $CsvRowNumber 行目の「$FieldName」が正しくありません: $Text"
    }

    return $hours
}

function Get-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $safeName = $Name.Trim()
    foreach ($character in [IO.Path]::GetInvalidFileNameChars()) {
        $safeName = $safeName.Replace([string]$character, '_')
    }
    $safeName = $safeName.TrimEnd([char]'.', [char]' ')

    if ([string]::IsNullOrWhiteSpace($safeName)) {
        throw "ファイル名に使用できる会社名がありません: $Name"
    }

    if ($safeName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        $safeName = "_$safeName"
    }

    return $safeName
}

function Get-BaseSheetName {
    param(
        [Parameter(Mandatory = $true)][string]$CompanyName,
        [Parameter(Mandatory = $true)][string]$EngineerName
    )

    $company = ($CompanyName -replace '[:\\/?*\[\]]', '_').Trim("'")
    $engineer = ($EngineerName -replace '[:\\/?*\[\]]', '_').Trim("'")
    $fullName = "${company}_${engineer}"

    if ($fullName.Length -le 31) {
        return $fullName
    }

    $engineerLength = [Math]::Min($engineer.Length, 12)
    $companyLength = 31 - 1 - $engineerLength
    if ($companyLength -lt 1) {
        $companyLength = 1
    }

    $companyPart = $company.Substring(0, [Math]::Min($company.Length, $companyLength))
    $engineerPart = $engineer.Substring(0, $engineerLength)
    return "${companyPart}_${engineerPart}"
}

function Get-UniqueSheetName {
    param(
        [Parameter(Mandatory = $true)][string]$BaseName,
        [Parameter(Mandatory = $true)][hashtable]$UsedNames
    )

    $name = $BaseName
    $number = 2
    while ($UsedNames.ContainsKey($name.ToLowerInvariant())) {
        $suffix = "_$number"
        $bodyLength = 31 - $suffix.Length
        $body = $BaseName.Substring(0, [Math]::Min($BaseName.Length, $bodyLength))
        $name = "$body$suffix"
        $number++
    }

    $UsedNames[$name.ToLowerInvariant()] = $true
    return $name
}

function Release-ComObject {
    param([object]$Object)
    if ($null -ne $Object -and [Runtime.InteropServices.Marshal]::IsComObject($Object)) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Object)
    }
}

function New-VersionedMonthDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $true)][string]$MonthName
    )

    [void][IO.Directory]::CreateDirectory($OutputRoot)
    $candidate = Join-Path $OutputRoot $MonthName
    $version = 2

    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $OutputRoot "${MonthName}（${version}）"
        $version++
    }

    [void][IO.Directory]::CreateDirectory($candidate)
    return $candidate
}

$basePath = [IO.Path]::GetFullPath($BaseDirectory)
$csvPath = Join-Path $basePath '注文データ.csv'
$fixedTemplatePath = Join-Path $basePath 'template\注文書テンプレート.xlsx'
$settlementTemplatePath = Join-Path $basePath 'template\注文書テンプレート_時間精算.xlsx'
$outputRoot = Join-Path $basePath '成果物'

if (-not (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
    throw "注文データ.csv が見つかりません: $csvPath"
}
if (-not (Test-Path -LiteralPath $fixedTemplatePath -PathType Leaf)) {
    throw "固定契約用テンプレートが見つかりません: $fixedTemplatePath"
}
if (-not (Test-Path -LiteralPath $settlementTemplatePath -PathType Leaf)) {
    throw "時間精算用テンプレートが見つかりません: $settlementTemplatePath"
}

$csvRows = @(Read-CsvRows -Path $csvPath)
if ($csvRows.Count -lt 3) {
    throw '注文データ.csv に必要な行がありません。'
}

$firstKey = ([string]$csvRows[0][0]).TrimStart([char]0xFEFF).Trim()
if ($firstKey -ne '対象年月' -or $csvRows[0].Count -lt 2) {
    throw 'CSVの1行目は「対象年月,2026-10」の形式で入力してください。'
}
$targetMonth = Convert-ToTargetMonth -Text ([string]$csvRows[0][1])
$monthKey = $targetMonth.ToString('yyyyMM')
$monthName = $targetMonth.ToString('yyyy-MM')

$headerIndex = -1
for ($index = 1; $index -lt $csvRows.Count; $index++) {
    if ($csvRows[$index].Count -gt 0 -and ([string]$csvRows[$index][0]).Trim() -eq '宛先会社名') {
        $headerIndex = $index
        break
    }
}
if ($headerIndex -lt 0) {
    throw '注文データの見出し行が見つかりません。'
}

$headerMap = @{}
for ($column = 0; $column -lt $csvRows[$headerIndex].Count; $column++) {
    $headerName = ([string]$csvRows[$headerIndex][$column]).Trim()
    if (-not [string]::IsNullOrWhiteSpace($headerName)) {
        $headerMap[$headerName] = $column
    }
}

$requiredHeaders = @('宛先会社名', '業務内容', '工程範囲', '技術者名', '単価', '固定契約', '下限時間', '上限時間', '弊社責任者', '備考')
$commonRequiredHeaders = @('宛先会社名', '業務内容', '工程範囲', '技術者名', '単価', '固定契約', '弊社責任者')
foreach ($requiredHeader in $requiredHeaders) {
    if (-not $headerMap.ContainsKey($requiredHeader)) {
        throw "CSVに必要な列がありません: $requiredHeader"
    }
}

$records = [System.Collections.Generic.List[object]]::new()
for ($index = $headerIndex + 1; $index -lt $csvRows.Count; $index++) {
    $row = $csvRows[$index]
    $hasValue = $false
    foreach ($field in $row) {
        if (-not [string]::IsNullOrWhiteSpace([string]$field)) {
            $hasValue = $true
            break
        }
    }
    if (-not $hasValue) {
        continue
    }

    $csvRowNumber = $index + 1
    $values = @{}
    foreach ($requiredHeader in $requiredHeaders) {
        $columnIndex = $headerMap[$requiredHeader]
        $value = if ($columnIndex -lt $row.Count) { ([string]$row[$columnIndex]).Trim() } else { '' }
        if ($commonRequiredHeaders -contains $requiredHeader -and [string]::IsNullOrWhiteSpace($value)) {
            throw "CSV $csvRowNumber 行目の「$requiredHeader」が未入力です。"
        }
        $values[$requiredHeader] = $value
    }

    $contractType = $values['固定契約'].ToUpperInvariant()
    if ($contractType -ne 'Y' -and $contractType -ne 'N') {
        throw "CSV $csvRowNumber 行目の「固定契約」は Y または N を入力してください: $($values['固定契約'])"
    }

    $lowerHours = $null
    $upperHours = $null
    if ($contractType -eq 'N') {
        if ([string]::IsNullOrWhiteSpace($values['下限時間'])) {
            throw "CSV $csvRowNumber 行目の「下限時間」が未入力です。固定契約が N の場合は入力してください。"
        }
        if ([string]::IsNullOrWhiteSpace($values['上限時間'])) {
            throw "CSV $csvRowNumber 行目の「上限時間」が未入力です。固定契約が N の場合は入力してください。"
        }

        $lowerHours = Convert-ToBaseHour -Text $values['下限時間'] -FieldName '下限時間' -CsvRowNumber $csvRowNumber
        $upperHours = Convert-ToBaseHour -Text $values['上限時間'] -FieldName '上限時間' -CsvRowNumber $csvRowNumber
        if ($lowerHours -ge $upperHours) {
            throw "CSV $csvRowNumber 行目は下限時間を上限時間より小さくしてください: $lowerHours / $upperHours"
        }
    }

    $records.Add([pscustomobject]@{
        順序       = $records.Count
        宛先会社名 = $values['宛先会社名']
        業務内容   = $values['業務内容']
        工程範囲   = $values['工程範囲']
        技術者名   = $values['技術者名']
        単価       = Convert-ToUnitPrice -Text $values['単価'] -CsvRowNumber $csvRowNumber
        固定契約   = $contractType
        下限時間   = $lowerHours
        上限時間   = $upperHours
        弊社責任者 = $values['弊社責任者']
        備考       = $values['備考']
    })
}

if ($records.Count -eq 0) {
    throw '注文データが1件もありません。'
}

$monthDirectory = New-VersionedMonthDirectory -OutputRoot $outputRoot -MonthName $monthName

$excel = $null
$workbooks = $null
try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.ScreenUpdating = $false
    $excel.EnableEvents = $false
    $workbooks = $excel.Workbooks

    $companyGroups = @($records | Group-Object -Property 宛先会社名)
    foreach ($companyGroup in $companyGroups) {
        $companyName = [string]$companyGroup.Name
        $safeCompanyName = Get-SafeFileName -Name $companyName
        $companyDirectory = Join-Path $monthDirectory $safeCompanyName
        [void][IO.Directory]::CreateDirectory($companyDirectory)

        $outputBaseName = "${safeCompanyName}様向け注文書_${monthKey}"
        $xlsxPath = Join-Path $companyDirectory "$outputBaseName.xlsx"
        $pdfPath = Join-Path $companyDirectory "$outputBaseName.pdf"

        $companyRecords = @($companyGroup.Group | Sort-Object -Property 順序)
        $firstTemplatePath = if ($companyRecords[0].固定契約 -eq 'Y') {
            $fixedTemplatePath
        }
        else {
            $settlementTemplatePath
        }

        Copy-Item -LiteralPath $firstTemplatePath -Destination $xlsxPath

        $workbook = $null
        $templateSheet = $null
        $sheetObjects = [System.Collections.Generic.List[object]]::new()
        try {
            $workbook = $workbooks.Open($xlsxPath)
            if ($workbook.Worksheets.Count -ne 1) {
                throw 'テンプレートのワークシートは1枚だけにしてください。'
            }

            $templateSheet = $workbook.Worksheets.Item(1)
            $sheetObjects.Add($templateSheet)

            for ($personIndex = 1; $personIndex -lt $companyRecords.Count; $personIndex++) {
                $record = $companyRecords[$personIndex]
                $personTemplatePath = if ($record.固定契約 -eq 'Y') {
                    $fixedTemplatePath
                }
                else {
                    $settlementTemplatePath
                }

                $sourceWorkbook = $null
                $sourceSheet = $null
                $lastSheet = $null
                try {
                    $sourceWorkbook = $workbooks.Open($personTemplatePath, 0, $true)
                    if ($sourceWorkbook.Worksheets.Count -ne 1) {
                        throw "テンプレートのワークシートは1枚だけにしてください: $personTemplatePath"
                    }

                    $sourceSheet = $sourceWorkbook.Worksheets.Item(1)
                    $lastSheet = $workbook.Worksheets.Item($workbook.Worksheets.Count)
                    $sourceSheet.Copy([Type]::Missing, $lastSheet)
                    $copiedSheet = $excel.ActiveSheet
                    $sheetObjects.Add($copiedSheet)
                }
                finally {
                    Release-ComObject -Object $sourceSheet
                    if ($null -ne $sourceWorkbook) {
                        $sourceWorkbook.Close($false)
                    }
                    Release-ComObject -Object $sourceWorkbook
                }
            }

            $usedSheetNames = @{}
            for ($personIndex = 0; $personIndex -lt $companyRecords.Count; $personIndex++) {
                $record = $companyRecords[$personIndex]
                $worksheet = $sheetObjects[$personIndex]
                $baseSheetName = Get-BaseSheetName -CompanyName $record.宛先会社名 -EngineerName $record.技術者名
                $worksheet.Name = Get-UniqueSheetName -BaseName $baseSheetName -UsedNames $usedSheetNames
                $worksheet.Visible = -1

                $worksheet.Range('A3').Value2 = $record.宛先会社名
                $worksheet.Range('C17').Formula = "=DATE($($targetMonth.Year),$($targetMonth.Month),1)"
                $worksheet.Range('C18').Value2 = $record.業務内容
                $worksheet.Range('C19').Value2 = $record.工程範囲
                $worksheet.Range('M12').Value2 = $record.弊社責任者
                if ($record.固定契約 -eq 'Y') {
                    $worksheet.Range('C21').Value2 = $record.技術者名
                    $worksheet.Range('L21').Value2 = [double]$record.単価
                    $worksheet.Range('C25').Value2 = $record.弊社責任者
                    $worksheet.Range('C33').Value2 = $record.備考
                }
                else {
                    $lowerHoursText = $record.下限時間.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
                    $upperHoursText = $record.上限時間.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)

                    $worksheet.Range('C22').Value2 = $record.技術者名
                    $worksheet.Range('A23').Value2 = "基本時間　${lowerHoursText}h～${upperHoursText}h"
                    $worksheet.Range('A24').Value2 = "超過単価（${upperHoursText}h超過分）※10円未満切捨"
                    $worksheet.Range('A25').Value2 = "控除単価（${lowerHoursText}h不足分）※10円未満切捨"
                    $worksheet.Range('L23').Value2 = [double]$record.単価
                    $worksheet.Range('S24').Value2 = [double]$record.下限時間
                    $worksheet.Range('T24').Value2 = [double]$record.上限時間
                    $worksheet.Range('C32').Value2 = $record.弊社責任者
                    $worksheet.Range('C37').Value2 = $record.備考
                }
            }

            $excel.CalculateFullRebuild()
            $workbook.Save()

            if ($workbook.Worksheets.Count -ne $companyRecords.Count) {
                throw "ワークシート数と技術者数が一致しません: $companyName"
            }

            $workbook.ExportAsFixedFormat(0, $pdfPath)

            $workbook.Close($false)
            Write-Host "作成完了: $companyName（$($companyRecords.Count)名）"
            Write-Host "  Excel: $xlsxPath"
            Write-Host "  PDF  : $pdfPath"
        }
        catch {
            if ($null -ne $workbook) {
                $workbook.Close($false)
            }
            throw
        }
        finally {
            foreach ($sheetObject in $sheetObjects) {
                Release-ComObject -Object $sheetObject
            }
            Release-ComObject -Object $workbook
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
        }
    }
}
finally {
    Release-ComObject -Object $workbooks
    if ($null -ne $excel) {
        $excel.Quit()
    }
    Release-ComObject -Object $excel
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

Write-Host ''
Write-Host "全ての注文書を作成しました: $monthDirectory"
