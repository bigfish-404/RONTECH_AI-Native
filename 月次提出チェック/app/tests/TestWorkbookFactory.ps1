Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression

# Builds minimal .xlsx/.xlsm files in TEMP so the tests never depend on real submissions.

function ConvertTo-ColumnNumber {
    param([Parameter(Mandatory = $true)][string]$Letters)
    $number = 0
    foreach ($character in $Letters.ToCharArray()) {
        $number = $number * 26 + ([int]$character - 64)
    }
    return $number
}

function ConvertTo-TestSheetXml {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$Cells,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$SharedStrings,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$SharedIndex
    )

    $entries = foreach ($reference in $Cells.Keys) {
        if ($reference -notmatch '^([A-Z]+)(\d+)$') {
            throw "Invalid cell reference: $reference"
        }
        [pscustomobject]@{ Reference = $reference; Column = ConvertTo-ColumnNumber -Letters $Matches[1]; Row = [int]$Matches[2]; Value = $Cells[$reference] }
    }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
    foreach ($rowGroup in ($entries | Group-Object Row | Sort-Object { [int]$_.Name })) {
        [void]$builder.Append("<row r=`"$($rowGroup.Name)`">")
        foreach ($entry in ($rowGroup.Group | Sort-Object Column)) {
            if ($entry.Value -is [int] -or $entry.Value -is [double]) {
                $number = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $entry.Value)
                [void]$builder.Append("<c r=`"$($entry.Reference)`"><v>$number</v></c>")
            }
            else {
                $text = [string]$entry.Value
                if (-not $SharedIndex.ContainsKey($text)) {
                    $SharedIndex[$text] = $SharedStrings.Count
                    $SharedStrings.Add($text)
                }
                [void]$builder.Append("<c r=`"$($entry.Reference)`" t=`"s`"><v>$($SharedIndex[$text])</v></c>")
            }
        }
        # A styled empty cell, as Excel writes for formatted blanks.
        [void]$builder.Append("<c r=`"Z$($rowGroup.Name)`" s=`"1`"/>")
        [void]$builder.Append('</row>')
    }
    [void]$builder.Append('</sheetData></worksheet>')
    return $builder.ToString()
}

function Add-TestZipEntry {
    param(
        [Parameter(Mandatory = $true)][IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $writer = [IO.StreamWriter]::new($Archive.CreateEntry($Name).Open(), [Text.UTF8Encoding]::new($false))
    try {
        $writer.Write($Content)
    }
    finally {
        $writer.Dispose()
    }
}

function New-TestWorkbook {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SheetName,
        [Parameter(Mandatory = $true)][hashtable]$Cells,
        [hashtable]$Phonetic = @{},
        [string]$LeadingSheetName = '',
        [hashtable]$LeadingCells = @{},
        [object[]]$Validations = @()
    )

    $sharedStrings = [System.Collections.Generic.List[string]]::new()
    $sharedIndex = @{}
    $sheets = [System.Collections.Generic.List[object]]::new()
    if ($LeadingSheetName) {
        $sheets.Add([pscustomobject]@{ Name = $LeadingSheetName; Xml = ConvertTo-TestSheetXml -Cells $LeadingCells -SharedStrings $sharedStrings -SharedIndex $sharedIndex })
    }
    $mainXml = ConvertTo-TestSheetXml -Cells $Cells -SharedStrings $sharedStrings -SharedIndex $sharedIndex
    if ($Validations.Count -gt 0) {
        # Validations: @{ Sqref = 'K10:K40'; Formula = '$K$132:$K$135' }, written the way Excel stores a dropdown list.
        $validationXml = ($Validations | ForEach-Object {
            "<dataValidation type=`"list`" allowBlank=`"1`" showInputMessage=`"1`" showErrorMessage=`"1`" sqref=`"$($_.Sqref)`"><formula1>$([Security.SecurityElement]::Escape($_.Formula))</formula1></dataValidation>"
        }) -join ''
        $mainXml = $mainXml.Replace('</sheetData></worksheet>', "</sheetData><dataValidations count=`"$($Validations.Count)`">$validationXml</dataValidations></worksheet>")
    }
    $sheets.Add([pscustomobject]@{ Name = $SheetName; Xml = $mainXml })

    $mainNamespace = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $relationNamespace = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $sheetEntries = [Text.StringBuilder]::new()
    $relationEntries = [Text.StringBuilder]::new()
    $overrides = [Text.StringBuilder]::new()
    for ($index = 0; $index -lt $sheets.Count; $index++) {
        $number = $index + 1
        [void]$sheetEntries.Append("<sheet name=`"$([Security.SecurityElement]::Escape($sheets[$index].Name))`" sheetId=`"$number`" r:id=`"rId$number`"/>")
        [void]$relationEntries.Append("<Relationship Id=`"rId$number`" Type=`"$relationNamespace/worksheet`" Target=`"worksheets/sheet$number.xml`"/>")
        [void]$overrides.Append("<Override PartName=`"/xl/worksheets/sheet$number.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/>")
    }
    $stringItems = [Text.StringBuilder]::new()
    foreach ($text in $sharedStrings) {
        $escaped = [Security.SecurityElement]::Escape($text)
        if ($Phonetic.ContainsKey($text)) {
            [void]$stringItems.Append("<si><t>$escaped</t><rPh sb=`"0`" eb=`"1`"><t>$([Security.SecurityElement]::Escape($Phonetic[$text]))</t></rPh></si>")
        }
        else {
            [void]$stringItems.Append("<si><t xml:space=`"preserve`">$escaped</t></si>")
        }
    }

    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    $fileStream = [IO.File]::Create($Path)
    try {
        $archive = [IO.Compression.ZipArchive]::new($fileStream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            Add-TestZipEntry -Archive $archive -Name '[Content_Types].xml' -Content ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' + $overrides.ToString() + '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>')
            Add-TestZipEntry -Archive $archive -Name '_rels/.rels' -Content '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
            Add-TestZipEntry -Archive $archive -Name 'xl/workbook.xml' -Content "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><workbook xmlns=`"$mainNamespace`" xmlns:r=`"$relationNamespace`"><sheets>$($sheetEntries.ToString())</sheets></workbook>"
            Add-TestZipEntry -Archive $archive -Name 'xl/_rels/workbook.xml.rels' -Content ("<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`">" + $relationEntries.ToString() + "<Relationship Id=`"rIdStrings`" Type=`"$relationNamespace/sharedStrings`" Target=`"sharedStrings.xml`"/></Relationships>")
            Add-TestZipEntry -Archive $archive -Name 'xl/sharedStrings.xml' -Content "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><sst xmlns=`"$mainNamespace`" count=`"$($sharedStrings.Count)`" uniqueCount=`"$($sharedStrings.Count)`">$($stringItems.ToString())</sst>"
            for ($index = 0; $index -lt $sheets.Count; $index++) {
                Add-TestZipEntry -Archive $archive -Name "xl/worksheets/sheet$($index + 1).xml" -Content $sheets[$index].Xml
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }
}

function New-KinmuCells {
    param(
        [Parameter(Mandatory = $true)][int]$Year,
        [Parameter(Mandatory = $true)][int]$Month,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$WorkDays
    )

    # WorkDays: day number -> 勤務場所 ('' = attended but 勤務場所 left blank).
    $cells = @{ A1 = $Year; D1 = $Month; A4 = '氏　　　名'; E4 = $Name; A9 = '日'; C9 = '出勤'; K9 = '勤務場所' }
    $firstDay = [datetime]::new($Year, $Month, 1)
    for ($row = 10; $row -le 40; $row++) {
        $date = $firstDay.AddDays($row - 10)
        if ($date.Month -ne $Month) {
            continue
        }
        $cells["A$row"] = [double]$date.ToOADate()
        if ($WorkDays.ContainsKey($date.Day)) {
            $cells["C$row"] = 0.375
            $cells["D$row"] = 0.75
            if ($WorkDays[$date.Day]) {
                $cells["K$row"] = [string]$WorkDays[$date.Day]
            }
        }
    }
    # The 勤務場所 dropdown source, placed where the real template keeps it.
    $placeList = @('客先出勤', '田町本社', '大阪支店', '在宅')
    for ($index = 0; $index -lt $placeList.Count; $index++) {
        $cells["K$(132 + $index)"] = $placeList[$index]
    }
    return $cells
}

function New-KotsuCells {
    param(
        [AllowNull()][object]$MonthValue,
        [Parameter(Mandatory = $true)][string]$Applicant,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows
    )

    # Rows: @{ Date = <serial double or text>; Kind = '交通費' / '会議費' / '' }
    $cells = @{ C2 = 'ロンテック交通宿費泊申請書'; C4 = '部属'; G4 = '申請年月'; G5 = '申請者'; H5 = $Applicant; C8 = '日付'; H8 = '類型'; L8 = '合計金額' }
    if ($null -ne $MonthValue) {
        $cells.H4 = $MonthValue
    }
    $row = 9
    foreach ($detail in $Rows) {
        $cells["C$row"] = $detail.Date
        $cells["D$row"] = 'JR'
        $cells["E$row"] = '田町～品川'
        if ($detail.Kind) {
            $cells["H$row"] = $detail.Kind
        }
        $cells["L$row"] = 400
        $row++
    }
    $totalRow = [Math]::Max($row, 19)
    $cells["C$totalRow"] = '件        数'
    $cells["L$totalRow"] = 0
    return $cells
}

function Get-TestSerial {
    param([int]$Year, [int]$Month, [int]$Day)
    return [double][datetime]::new($Year, $Month, $Day).ToOADate()
}
