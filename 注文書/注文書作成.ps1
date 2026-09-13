param(
    [Parameter(Mandatory = $true)]
    [string]$BaseDirectory,
    [Parameter(Mandatory = $true)]
    [object]$OrderData,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        [Parameter(Mandatory = $true)][int]$DataRowNumber
    )

    $value = $Text.Trim()
    if ($value -match '\s') {
        throw "生成データ $DataRowNumber 行目の単価に途中の空白またはタブがあります: $Text"
    }

    $normalized = $value -replace '[,￥¥]', ''
    [decimal]$price = 0
    $parsed = [decimal]::TryParse(
        $normalized,
        [Globalization.NumberStyles]::Number,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$price
    )

    if (-not $parsed -or $price -lt 0) {
        throw "生成データ $DataRowNumber 行目の単価が正しくありません: $Text"
    }

    return $price
}

function Convert-ToBaseHour {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [Parameter(Mandatory = $true)][int]$DataRowNumber
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
        throw "生成データ $DataRowNumber 行目の「$FieldName」が正しくありません: $Text"
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
        throw "ファイル名またはフォルダ名に使用できる文字がありません: $Name"
    }

    if ($safeName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        $safeName = "_$safeName"
    }

    return $safeName
}

function Get-BaseSheetName {
    param([Parameter(Mandatory = $true)][string]$ProjectName)

    $name = ($ProjectName -replace '[:\\/?*\[\]]', '_').Trim("'").Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "シート名に使用できる業務内容がありません: $ProjectName"
    }

    return $name.Substring(0, [Math]::Min($name.Length, 31))
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

function Get-ProjectCommonValue {
    param(
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [Parameter(Mandatory = $true)][string]$CompanyName,
        [Parameter(Mandatory = $true)][string]$ProjectName
    )

    $values = @(
        $Records |
            ForEach-Object { ([string]$_.PSObject.Properties[$FieldName].Value).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if ($values.Count -gt 1) {
        throw "同一会社・同一業務内容の「$FieldName」を統一してください: $CompanyName / $ProjectName"
    }

    if ($values.Count -eq 0) {
        return ''
    }

    return [string]$values[0]
}

function Get-CompanyOutputFolderName {
    param(
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $true)][string]$CompanyName
    )

    $folderNames = @(
        $Records |
            ForEach-Object { ([string]$_.出力フォルダ名).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if ($folderNames.Count -gt 1) {
        throw "同一会社の「出力フォルダ名」を統一してください: $CompanyName"
    }

    $folderName = if ($folderNames.Count -eq 0) { $CompanyName } else { [string]$folderNames[0] }
    return Get-SafeFileName -Name $folderName
}

function Find-LabelRow {
    param(
        [Parameter(Mandatory = $true)][object]$Worksheet,
        [Parameter(Mandatory = $true)][int]$ColumnNumber,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $column = $null
    $found = $null
    try {
        $column = $Worksheet.Columns.Item($ColumnNumber)
        $found = $column.Find($Label, [Type]::Missing, -4163, 1)
        if ($null -eq $found) {
            throw "テンプレート内に「$Label」が見つかりません。"
        }
        return [int]$found.Row
    }
    finally {
        Release-ComObject -Object $found
        Release-ComObject -Object $column
    }
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
$unifiedTemplatePath = Join-Path $basePath 'template\注文書テンプレート_統合.xlsx'
$outputRoot = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $basePath '成果物'
}
else {
    [IO.Path]::GetFullPath($OutputDirectory)
}

if (-not (Test-Path -LiteralPath $unifiedTemplatePath -PathType Leaf)) {
    throw "統合テンプレートが見つかりません: $unifiedTemplatePath"
}

$targetMonthProperty = $OrderData.PSObject.Properties['targetMonth']
if ($null -eq $targetMonthProperty) {
    throw '生成データに対象年月がありません。'
}
$targetMonth = Convert-ToTargetMonth -Text ([string]$targetMonthProperty.Value)
$monthKey = $targetMonth.ToString('yyyyMM')
$monthName = '{0}年{1}月' -f $targetMonth.Year, $targetMonth.Month

$requiredHeaders = @('宛先会社名', '出力フォルダ名', '業務内容', '工程範囲', '技術者名', '単価', '固定契約', '下限時間', '上限時間', '弊社責任者', '備考')
$commonRequiredHeaders = @('宛先会社名', '業務内容', '工程範囲', '技術者名', '単価', '固定契約', '弊社責任者')
$recordsProperty = $OrderData.PSObject.Properties['records']
$inputRecords = if ($null -eq $recordsProperty -or $null -eq $recordsProperty.Value) { @() } else { @($recordsProperty.Value) }

$records = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $inputRecords.Count; $index++) {
    $inputRecord = $inputRecords[$index]
    $displayRow = $index + 1
    $values = @{}
    foreach ($requiredHeader in $requiredHeaders) {
        $property = $inputRecord.PSObject.Properties[$requiredHeader]
        $value = if ($null -eq $property -or $null -eq $property.Value) { '' } else { ([string]$property.Value).Trim() }
        if ($commonRequiredHeaders -contains $requiredHeader -and [string]::IsNullOrWhiteSpace($value)) {
            throw "生成データ $displayRow 行目の「$requiredHeader」が未入力です。"
        }
        $values[$requiredHeader] = $value
    }

    $contractType = $values['固定契約'].ToUpperInvariant()
    if ($contractType -ne 'Y' -and $contractType -ne 'N') {
        throw "生成データ $displayRow 行目の「固定契約」は Y または N を入力してください: $($values['固定契約'])"
    }

    if ([string]::IsNullOrWhiteSpace($values['下限時間'])) {
        throw "生成データ $displayRow 行目の「下限時間」が未入力です。固定契約が Y / N のどちらでも入力してください。"
    }
    if ([string]::IsNullOrWhiteSpace($values['上限時間'])) {
        throw "生成データ $displayRow 行目の「上限時間」が未入力です。固定契約が Y / N のどちらでも入力してください。"
    }

    $lowerHours = Convert-ToBaseHour -Text $values['下限時間'] -FieldName '下限時間' -DataRowNumber $displayRow
    $upperHours = Convert-ToBaseHour -Text $values['上限時間'] -FieldName '上限時間' -DataRowNumber $displayRow
    if ($lowerHours -ge $upperHours) {
        throw "生成データ $displayRow 行目は下限時間を上限時間より小さくしてください: $lowerHours / $upperHours"
    }

    $records.Add([pscustomobject]@{
        データ行   = $displayRow
        順序       = $records.Count
        宛先会社名 = $values['宛先会社名']
        出力フォルダ名 = $values['出力フォルダ名']
        業務内容   = $values['業務内容']
        工程範囲   = $values['工程範囲']
        技術者名   = $values['技術者名']
        単価       = Convert-ToUnitPrice -Text $values['単価'] -DataRowNumber $displayRow
        固定契約   = $contractType
        下限時間   = $lowerHours
        上限時間   = $upperHours
        弊社責任者 = $values['弊社責任者']
        備考       = $values['備考']
    })
}

if ($records.Count -eq 0) {
    throw '生成する注文データが1件もありません。'
}

$recordKeys = @{}
$recordKeySeparator = [char]31
foreach ($record in $records) {
    $recordKey = ($record.宛先会社名 + $recordKeySeparator + $record.業務内容 + $recordKeySeparator + $record.技術者名).ToLowerInvariant()
    if ($recordKeys.ContainsKey($recordKey)) {
        throw "同一会社・同一業務内容・同一技術者名が重複しています: 生成データ $($recordKeys[$recordKey]) 行目 / $($record.データ行) 行目"
    }
    $recordKeys[$recordKey] = $record.データ行
}

$companyGroups = @($records | Group-Object -Property 宛先会社名)
$companyOutputFolders = @{}
$usedOutputFolders = @{}
foreach ($companyGroup in $companyGroups) {
    $companyName = [string]$companyGroup.Name
    $companyRecords = @($companyGroup.Group | Sort-Object -Property 順序)
    $safeOutputFolderName = Get-CompanyOutputFolderName -Records $companyRecords -CompanyName $companyName
    $outputFolderKey = $safeOutputFolderName.ToLowerInvariant()
    if ($usedOutputFolders.ContainsKey($outputFolderKey)) {
        throw "異なる会社で同じ「出力フォルダ名」は使用できません: $($usedOutputFolders[$outputFolderKey]) / $companyName / $safeOutputFolderName"
    }
    $usedOutputFolders[$outputFolderKey] = $companyName
    $companyOutputFolders[$companyName.ToLowerInvariant()] = $safeOutputFolderName
    $projectGroups = @($companyRecords | Group-Object -Property 業務内容)
    foreach ($projectGroup in $projectGroups) {
        $projectName = [string]$projectGroup.Name
        $projectRecords = @($projectGroup.Group | Sort-Object -Property 順序)
        [void](Get-ProjectCommonValue -Records $projectRecords -FieldName '工程範囲' -CompanyName $companyName -ProjectName $projectName)
        [void](Get-ProjectCommonValue -Records $projectRecords -FieldName '弊社責任者' -CompanyName $companyName -ProjectName $projectName)
        [void](Get-ProjectCommonValue -Records $projectRecords -FieldName '備考' -CompanyName $companyName -ProjectName $projectName)
    }
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

    foreach ($companyGroup in $companyGroups) {
        $companyName = [string]$companyGroup.Name
        $safeCompanyName = Get-SafeFileName -Name $companyName
        $safeOutputFolderName = [string]$companyOutputFolders[$companyName.ToLowerInvariant()]
        $companyDirectory = Join-Path $monthDirectory $safeOutputFolderName
        [void][IO.Directory]::CreateDirectory($companyDirectory)

        $outputBaseName = "${safeCompanyName}様向け注文書_${monthKey}"
        $xlsxPath = Join-Path $companyDirectory "$outputBaseName.xlsx"
        $pdfPath = Join-Path $companyDirectory "$outputBaseName.pdf"

        $companyRecords = @($companyGroup.Group | Sort-Object -Property 順序)
        $projectGroups = @($companyRecords | Group-Object -Property 業務内容)
        Copy-Item -LiteralPath $unifiedTemplatePath -Destination $xlsxPath

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

            for ($projectIndex = 1; $projectIndex -lt $projectGroups.Count; $projectIndex++) {
                $lastSheet = $null
                try {
                    $lastSheet = $workbook.Worksheets.Item($workbook.Worksheets.Count)
                    $lastSheet.Copy([Type]::Missing, $lastSheet)
                    $copiedSheet = $excel.ActiveSheet
                    $sheetObjects.Add($copiedSheet)
                }
                finally {
                    $lastSheet = $null
                }
            }

            $usedSheetNames = @{}
            for ($projectIndex = 0; $projectIndex -lt $projectGroups.Count; $projectIndex++) {
                $projectGroup = $projectGroups[$projectIndex]
                $projectName = [string]$projectGroup.Name
                $projectRecords = @($projectGroup.Group | Sort-Object -Property 順序)
                $projectRange = Get-ProjectCommonValue -Records $projectRecords -FieldName '工程範囲' -CompanyName $companyName -ProjectName $projectName
                $projectManager = Get-ProjectCommonValue -Records $projectRecords -FieldName '弊社責任者' -CompanyName $companyName -ProjectName $projectName
                $projectNote = Get-ProjectCommonValue -Records $projectRecords -FieldName '備考' -CompanyName $companyName -ProjectName $projectName

                $worksheet = $sheetObjects[$projectIndex]
                $baseSheetName = Get-BaseSheetName -ProjectName $projectName
                $worksheet.Name = Get-UniqueSheetName -BaseName $baseSheetName -UsedNames $usedSheetNames
                $worksheet.Visible = -1

                $worksheet.Range('A3').Value2 = $companyName
                $worksheet.Range('C17').Formula = "=DATE($($targetMonth.Year),$($targetMonth.Month),1)"
                $worksheet.Range('C17').NumberFormatLocal = 'yyyy"年"m"月"d"日"'
                $worksheet.Range('F17').NumberFormatLocal = 'yyyy"年"m"月"d"日"'
                $worksheet.Range('C18').Value2 = $projectName
                $worksheet.Range('C19').Value2 = $projectRange
                $worksheet.Range('M12').Value2 = $projectManager

                for ($personIndex = 1; $personIndex -lt $projectRecords.Count; $personIndex++) {
                    $insertRow = 22 + (4 * $personIndex)
                    $sourceRows = $null
                    $targetRows = $null
                    try {
                        $sourceRows = $worksheet.Rows('22:25')
                        [void]$sourceRows.Copy()
                        $targetRows = $worksheet.Rows("${insertRow}:$($insertRow + 3)")
                        [void]$targetRows.Insert(-4121)
                    }
                    finally {
                        Release-ComObject -Object $targetRows
                        Release-ComObject -Object $sourceRows
                    }
                }

                $containsSettlement = $false
                for ($personIndex = 0; $personIndex -lt $projectRecords.Count; $personIndex++) {
                    $record = $projectRecords[$personIndex]
                    $blockStart = 22 + (4 * $personIndex)
                    $blockEnd = $blockStart + 3
                    $lowerHoursText = $record.下限時間.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
                    $upperHoursText = $record.上限時間.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
                    $personRange = $worksheet.Range("A${blockStart}:T${blockEnd}")
                    $personRange.ClearContents()
                    $personRange.EntireRow.Hidden = $false
                    Release-ComObject -Object $personRange

                    if ($record.固定契約 -eq 'Y') {
                        $fixedTimeRow = $blockStart + 1
                        $unusedStart = $blockStart + 2

                        $priceFormats = $worksheet.Range("J${fixedTimeRow}:Q${fixedTimeRow}")
                        $priceTarget = $worksheet.Range("J${blockStart}:Q${blockStart}")
                        [void]$priceFormats.Copy()
                        [void]$priceTarget.PasteSpecial(-4122)
                        Release-ComObject -Object $priceTarget
                        Release-ComObject -Object $priceFormats

                        $fixedTextRange = $worksheet.Range("A${fixedTimeRow}:I${fixedTimeRow}")
                        $fixedTextRange.UnMerge()
                        Release-ComObject -Object $fixedTextRange
                        $worksheet.Range("A${fixedTimeRow}:B${fixedTimeRow}").Merge()
                        $worksheet.Range("C${fixedTimeRow}:I${fixedTimeRow}").Merge()

                        $worksheet.Range("A${blockStart}").Value2 = '技術者、料金'
                        $worksheet.Range("C${blockStart}").Value2 = $record.技術者名
                        $worksheet.Range("J${blockStart}").Value2 = 1
                        $worksheet.Range("K${blockStart}").Value2 = '人月'
                        $worksheet.Range("L${blockStart}").Value2 = [double]$record.単価
                        $worksheet.Range("O${blockStart}").Formula = "=J${blockStart}*L${blockStart}"
                        $worksheet.Range("A${fixedTimeRow}").Value2 = '基準時間'
                        $worksheet.Range("C${fixedTimeRow}").Value2 = "月基準作業時間（${lowerHoursText}h～${upperHoursText}h）`n過不足あった場合は別途調整`n※作業時間が${upperHoursText}時間超えそうな場合には、事前にPMへ報告願います"
                        $worksheet.Range("C${fixedTimeRow}").WrapText = $true
                        $worksheet.Range("C${fixedTimeRow}").Font.Size = 8
                        $worksheet.Rows.Item($fixedTimeRow).RowHeight = 48
                        $worksheet.Rows("${unusedStart}:$($unusedStart + 1)").Hidden = $true
                    }
                    else {
                        $containsSettlement = $true
                        $priceRow = $blockStart + 1
                        $overRow = $blockStart + 2
                        $deductRow = $blockStart + 3
                        $worksheet.Range("A${blockStart}").Value2 = '技術者'
                        $worksheet.Range("C${blockStart}").Value2 = $record.技術者名
                        $worksheet.Range("A${priceRow}").Value2 = "基本時間　${lowerHoursText}h～${upperHoursText}h"
                        $worksheet.Range("J${priceRow}").Value2 = 1
                        $worksheet.Range("K${priceRow}").Value2 = '人月'
                        $worksheet.Range("L${priceRow}").Value2 = [double]$record.単価
                        $worksheet.Range("O${priceRow}").Formula = "=J${priceRow}*L${priceRow}"
                        $worksheet.Range("A${overRow}").Value2 = "超過単価（${upperHoursText}h超過分）※10円未満切捨"
                        $worksheet.Range("K${overRow}").Value2 = '時間'
                        $worksheet.Range("S${overRow}").Value2 = [double]$record.下限時間
                        $worksheet.Range("T${overRow}").Value2 = [double]$record.上限時間
                        $worksheet.Range("L${overRow}").Formula = ('=ROUNDDOWN(L{0}/$T${1},-1)' -f $priceRow, $overRow)
                        $worksheet.Range("A${deductRow}").Value2 = "控除単価（${lowerHoursText}h不足分）※10円未満切捨"
                        $worksheet.Range("K${deductRow}").Value2 = '時間'
                        $worksheet.Range("L${deductRow}").Formula = ('=ROUNDDOWN(-L{0}/$S${1},-1)' -f $priceRow, $overRow)
                    }
                }

                $noteRow = 26 + (4 * ($projectRecords.Count - 1))
                if ($containsSettlement) {
                    $worksheet.Rows("${noteRow}:$($noteRow + 1)").Hidden = $false
                    $worksheet.Range("A${noteRow}").Value2 = '※過不足の場合は別途調整、下限時間：営業日20日未満の場合は営業日×8時間となります。'
                }
                else {
                    $worksheet.Rows("${noteRow}:$($noteRow + 1)").Hidden = $true
                }

                $responsibleRow = Find-LabelRow -Worksheet $worksheet -ColumnNumber 1 -Label '弊社責任者'
                $remarkRow = Find-LabelRow -Worksheet $worksheet -ColumnNumber 1 -Label '備考'
                $subtotalRow = Find-LabelRow -Worksheet $worksheet -ColumnNumber 10 -Label '小計'
                $taxRow = Find-LabelRow -Worksheet $worksheet -ColumnNumber 10 -Label '消費税(10%)'
                $totalRow = Find-LabelRow -Worksheet $worksheet -ColumnNumber 10 -Label '合計'

                $worksheet.Range("C${responsibleRow}").Value2 = $projectManager
                $worksheet.Range("C${remarkRow}").Value2 = $projectNote
                $remarkArea = $worksheet.Range("C${remarkRow}:Q$($remarkRow + 1)")
                $remarkArea.WrapText = $true
                $remarkArea.VerticalAlignment = -4160
                if (-not [string]::IsNullOrWhiteSpace($projectNote)) {
                    $estimatedRemarkLines = 0
                    foreach ($noteLine in ($projectNote -split '\r?\n')) {
                        $estimatedRemarkLines += [Math]::Max(1, [Math]::Ceiling($noteLine.Length / 55.0))
                    }
                    $remarkRowHeight = [Math]::Min(72, [Math]::Max(18.6, ($estimatedRemarkLines * 18.0) / 2.0))
                    $worksheet.Rows("${remarkRow}:$($remarkRow + 1)").RowHeight = $remarkRowHeight
                }
                Release-ComObject -Object $remarkArea

                $worksheet.Range("L${subtotalRow}").Formula = "=SUM(O22:O$($noteRow - 1))"
                $worksheet.Range("L${taxRow}").Formula = "=L${subtotalRow}*`$T`$6"
                $worksheet.Range("L${totalRow}").Formula = "=L${subtotalRow}+L${taxRow}"
                $worksheet.Range('D14').Formula = "=L${totalRow}"

                $worksheet.Activate()
                $worksheet.PageSetup.PrintArea = "`$A`$1:`$Q`$$($remarkRow + 3)"
                $worksheet.PageSetup.Zoom = $false
                $worksheet.PageSetup.FitToPagesWide = 1
                if ($projectRecords.Count -le 2) {
                    $worksheet.PageSetup.FitToPagesTall = 1
                }
                else {
                    $worksheet.PageSetup.FitToPagesTall = $false
                    $worksheet.PageSetup.TopMargin = $excel.InchesToPoints(0.3)
                    $worksheet.PageSetup.BottomMargin = $excel.InchesToPoints(0.3)
                    for ($pagePersonIndex = 2; $pagePersonIndex -lt $projectRecords.Count; $pagePersonIndex += 2) {
                        $pageBreakCell = $null
                        try {
                            $pageBreakCell = $worksheet.Range("A$(22 + (4 * $pagePersonIndex))")
                            $pageBreakCell.PageBreak = -4135
                        }
                        finally {
                            Release-ComObject -Object $pageBreakCell
                        }
                    }
                    $worksheet.PageSetup.PrintTitleRows = '$1:$21'
                }
            }

            $excel.CalculateFullRebuild()
            $workbook.Save()

            if ($workbook.Worksheets.Count -ne $projectGroups.Count) {
                throw "ワークシート数と業務内容数が一致しません: $companyName"
            }

            $workbook.ExportAsFixedFormat(0, $pdfPath)

            $workbook.Close($false)
            Write-Host "作成完了: $companyName（$($projectGroups.Count)案件 / $($companyRecords.Count)名）"
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
