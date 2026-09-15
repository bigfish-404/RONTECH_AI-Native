Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression

function Read-ZipEntryXml {
    param(
        [Parameter(Mandatory = $true)][IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    $entry = $Archive.GetEntry($EntryName)
    if ($null -eq $entry) {
        return $null
    }
    $readerSettings = [Xml.XmlReaderSettings]::new()
    $readerSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $readerSettings.XmlResolver = $null
    $entryStream = $entry.Open()
    try {
        $xmlReader = [Xml.XmlReader]::Create($entryStream, $readerSettings)
        try {
            $document = [Xml.XmlDocument]::new()
            $document.XmlResolver = $null
            $document.Load($xmlReader)
        }
        finally {
            $xmlReader.Dispose()
        }
    }
    finally {
        $entryStream.Dispose()
    }
    # XmlDocument is enumerable; the comma keeps PowerShell from unrolling it into child nodes.
    return , $document
}

function Resolve-XlsxPartName {
    param([Parameter(Mandatory = $true)][string]$Target)

    $normalized = $Target.Replace('\', '/')
    if ($normalized.StartsWith('/')) {
        return $normalized.TrimStart('/')
    }
    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($segment in ('xl/' + $normalized).Split('/')) {
        if ($segment -eq '..') {
            if ($segments.Count -gt 0) {
                $segments.RemoveAt($segments.Count - 1)
            }
        }
        elseif ($segment -and $segment -ne '.') {
            $segments.Add($segment)
        }
    }
    return ($segments -join '/')
}

function Find-XlsxWorksheetPart {
    param(
        [Parameter(Mandatory = $true)][IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string[]]$SheetNames
    )

    $workbook = Read-ZipEntryXml -Archive $Archive -EntryName 'xl/workbook.xml'
    if ($null -eq $workbook) {
        throw 'Excelファイルの構造を読み取れません。'
    }
    $relations = Read-ZipEntryXml -Archive $Archive -EntryName 'xl/_rels/workbook.xml.rels'
    $targets = @{}
    $sharedStringsPart = 'xl/sharedStrings.xml'
    if ($null -ne $relations) {
        foreach ($relation in $relations.GetElementsByTagName('Relationship', '*')) {
            $targets[$relation.GetAttribute('Id')] = $relation.GetAttribute('Target')
            if ($relation.GetAttribute('Type').EndsWith('/sharedStrings')) {
                $sharedStringsPart = Resolve-XlsxPartName -Target $relation.GetAttribute('Target')
            }
        }
    }

    $sheets = [System.Collections.Generic.List[object]]::new()
    foreach ($sheet in $workbook.GetElementsByTagName('sheet', '*')) {
        $relationId = ''
        foreach ($attribute in $sheet.Attributes) {
            if ($attribute.LocalName -eq 'id' -and $attribute.NamespaceURI) {
                $relationId = $attribute.Value
            }
        }
        $sheets.Add([pscustomobject]@{ Name = $sheet.GetAttribute('name'); RelationId = $relationId })
    }
    if ($sheets.Count -eq 0) {
        throw 'Excelファイルにシートがありません。'
    }

    $selected = $null
    foreach ($sheetName in $SheetNames) {
        $selected = $sheets | Where-Object { $_.Name -eq $sheetName } | Select-Object -First 1
        if ($null -ne $selected) {
            break
        }
    }
    if ($null -eq $selected) {
        $selected = $sheets[0]
    }
    if (-not $targets.ContainsKey($selected.RelationId)) {
        throw "シート「$($selected.Name)」の場所を特定できません。"
    }
    return [pscustomobject]@{
        SheetName = $selected.Name
        PartName = Resolve-XlsxPartName -Target $targets[$selected.RelationId]
        SharedStringsPart = $sharedStringsPart
    }
}

function Get-XlsxRichText {
    param([Parameter(Mandatory = $true)][Xml.XmlElement]$Node)

    $builder = [Text.StringBuilder]::new()
    foreach ($textNode in $Node.GetElementsByTagName('t', '*')) {
        # rPh holds furigana; Excel does not display it as part of the cell text.
        if ($textNode.ParentNode.LocalName -ne 'rPh') {
            [void]$builder.Append($textNode.InnerText)
        }
    }
    return $builder.ToString()
}

function Read-XlsxSharedStrings {
    param(
        [Parameter(Mandatory = $true)][IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory = $true)][string]$PartName
    )

    $strings = [System.Collections.Generic.List[string]]::new()
    $document = Read-ZipEntryXml -Archive $Archive -EntryName $PartName
    if ($null -ne $document) {
        foreach ($item in $document.GetElementsByTagName('si', '*')) {
            $strings.Add((Get-XlsxRichText -Node $item))
        }
    }
    return , $strings
}

function Get-XlsxCellValue {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlElement]$Cell,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$SharedStrings
    )

    $valueNode = $null
    $inlineNode = $null
    foreach ($child in $Cell.ChildNodes) {
        if ($child.LocalName -eq 'v') {
            $valueNode = $child
        }
        elseif ($child.LocalName -eq 'is') {
            $inlineNode = $child
        }
    }
    switch ($Cell.GetAttribute('t')) {
        's' {
            if ($null -eq $valueNode) { return '' }
            $index = [int]$valueNode.InnerText
            if ($index -ge 0 -and $index -lt $SharedStrings.Count) { return $SharedStrings[$index] }
            return ''
        }
        'inlineStr' {
            if ($null -eq $inlineNode) { return '' }
            return (Get-XlsxRichText -Node $inlineNode)
        }
        'e' {
            return ''
        }
        default {
            if ($null -eq $valueNode) { return '' }
            return $valueNode.InnerText
        }
    }
}

function Get-XlsxColumnNumber {
    param([Parameter(Mandatory = $true)][string]$Letters)
    $number = 0
    foreach ($character in $Letters.ToUpperInvariant().ToCharArray()) {
        $number = $number * 26 + ([int]$character - 64)
    }
    return $number
}

function ConvertTo-XlsxColumnLetters {
    param([Parameter(Mandatory = $true)][int]$Number)
    $letters = ''
    while ($Number -gt 0) {
        $remainder = ($Number - 1) % 26
        $letters = [string][char](65 + $remainder) + $letters
        $Number = [int][Math]::Floor(($Number - 1) / 26)
    }
    return $letters
}

function Test-XlsxRangeContains {
    param(
        [AllowEmptyString()][string]$Range,
        [Parameter(Mandatory = $true)][string]$Column,
        [Parameter(Mandatory = $true)][int]$Row
    )

    # Range is an sqref such as "K10:K40" or several areas separated by spaces.
    $target = Get-XlsxColumnNumber -Letters $Column
    foreach ($area in ($Range -split '\s+')) {
        if ($area.Replace('$', '') -notmatch '^([A-Z]+)(\d+)(?::([A-Z]+)(\d+))?$') {
            continue
        }
        $firstColumn = Get-XlsxColumnNumber -Letters $Matches[1]
        $firstRow = [int]$Matches[2]
        $lastColumn = if ($Matches[3]) { Get-XlsxColumnNumber -Letters $Matches[3] } else { $firstColumn }
        $lastRow = if ($Matches[4]) { [int]$Matches[4] } else { $firstRow }
        if ($target -ge $firstColumn -and $target -le $lastColumn -and $Row -ge $firstRow -and $Row -le $lastRow) {
            return $true
        }
    }
    return $false
}

function Get-XlsxListOptions {
    param(
        [Parameter(Mandatory = $true)][object]$Sheet,
        [Parameter(Mandatory = $true)][string]$Column,
        [Parameter(Mandatory = $true)][int]$Row
    )

    # Returns the values of the dropdown list covering the cell, or nothing when the list cannot be resolved
    # (no list, or a list that points to another sheet or a defined name).
    foreach ($validation in $Sheet.Validations) {
        if ($validation.Type -ne 'list' -or -not (Test-XlsxRangeContains -Range $validation.Sqref -Column $Column -Row $Row)) {
            continue
        }
        $formula = $validation.Formula
        if ($formula.StartsWith('"')) {
            return @($formula.Trim('"').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        if ($formula.Replace('$', '') -notmatch '^([A-Z]+)(\d+):([A-Z]+)(\d+)$') {
            return
        }
        $firstColumn = Get-XlsxColumnNumber -Letters $Matches[1]
        $firstRow = [int]$Matches[2]
        $lastColumn = Get-XlsxColumnNumber -Letters $Matches[3]
        $lastRow = [int]$Matches[4]
        $values = [System.Collections.Generic.List[string]]::new()
        for ($listRow = $firstRow; $listRow -le $lastRow; $listRow++) {
            for ($listColumn = $firstColumn; $listColumn -le $lastColumn; $listColumn++) {
                $reference = (ConvertTo-XlsxColumnLetters -Number $listColumn) + $listRow
                if ($Sheet.Cells.ContainsKey($reference) -and ([string]$Sheet.Cells[$reference]).Trim()) {
                    $values.Add(([string]$Sheet.Cells[$reference]).Trim())
                }
            }
        }
        return $values.ToArray()
    }
}

function Read-XlsxSheetValues {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$SheetNames,
        [int]$MaxRow = 1048576
    )

    if ([IO.Path]::GetExtension($Path) -ieq '.xls') {
        throw '旧形式（.xls）のExcelファイルは読み込めません。.xlsx または .xlsm で保存し直してください。'
    }
    # Submitted files are often still open in Excel, so allow other processes to keep writing.
    $fileStream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try {
        try {
            $archive = [IO.Compression.ZipArchive]::new($fileStream, [IO.Compression.ZipArchiveMode]::Read, $true)
        }
        catch {
            throw 'Excelファイルとして開けません。ファイルが壊れているか、パスワードで保護されています。'
        }
        try {
            $part = Find-XlsxWorksheetPart -Archive $archive -SheetNames $SheetNames
            $sharedStrings = Read-XlsxSharedStrings -Archive $archive -PartName $part.SharedStringsPart
            $sheet = Read-ZipEntryXml -Archive $archive -EntryName $part.PartName
            if ($null -eq $sheet) {
                throw "シート「$($part.SheetName)」を読み取れません。"
            }
            $cells = @{}
            $sheetData = $sheet.GetElementsByTagName('sheetData', '*') | Select-Object -First 1
            if ($null -ne $sheetData) {
                foreach ($row in $sheetData.ChildNodes) {
                    if ($row.LocalName -ne 'row') {
                        continue
                    }
                    $rowNumberText = $row.GetAttribute('r')
                    if ($rowNumberText -and [int]$rowNumberText -gt $MaxRow) {
                        break
                    }
                    foreach ($cell in $row.ChildNodes) {
                        if ($cell.LocalName -ne 'c' -or -not $cell.HasChildNodes) {
                            continue
                        }
                        $reference = $cell.GetAttribute('r')
                        if (-not $reference) {
                            continue
                        }
                        $value = Get-XlsxCellValue -Cell $cell -SharedStrings $sharedStrings
                        if ($value -ne '') {
                            $cells[$reference] = $value
                        }
                    }
                }
            }
            # Data validations (dropdown lists); x14 extensions keep sqref and formula in child elements.
            $validations = [System.Collections.Generic.List[object]]::new()
            foreach ($validation in $sheet.GetElementsByTagName('dataValidation', '*')) {
                $sqref = $validation.GetAttribute('sqref')
                $formula = ''
                foreach ($child in $validation.ChildNodes) {
                    if ($child.LocalName -eq 'sqref' -and -not $sqref) {
                        $sqref = $child.InnerText
                    }
                    elseif ($child.LocalName -eq 'formula1') {
                        $formula = $child.InnerText
                    }
                }
                $validations.Add([pscustomobject]@{ Type = $validation.GetAttribute('type'); Sqref = $sqref.Trim(); Formula = $formula.Trim() })
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }
    return [pscustomobject]@{
        SheetName = $part.SheetName
        Cells = $cells
        Validations = $validations.ToArray()
    }
}
