Set-StrictMode -Version Latest

# Serial numbers below 2000-01-01 are treated as plain numbers (e.g. a year typed as 2026).
$minimumDateSerial = 36526

function Get-CellText {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Cells,
        [Parameter(Mandatory = $true)][string]$Reference
    )
    if ($Cells.ContainsKey($Reference)) {
        return ([string]$Cells[$Reference]).Trim()
    }
    return ''
}

function ConvertTo-IntOrNull {
    param([AllowEmptyString()][string]$Value)

    $number = 0.0
    if ([double]::TryParse($Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and
        $number -eq [Math]::Floor($number)) {
        return [int]$number
    }
    return $null
}

function ConvertFrom-ExcelSerialDate {
    param([AllowEmptyString()][string]$Value)

    $number = 0.0
    if (-not [double]::TryParse($Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $null
    }
    if ($number -lt $minimumDateSerial -or $number -ge 2958466) {
        return $null
    }
    return [DateTime]::FromOADate([Math]::Floor($number)).Date
}

function ConvertTo-CompactText {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }
    return [regex]::Replace($Value.Normalize([Text.NormalizationForm]::FormKC), '\s+', '')
}

function ConvertFrom-JapaneseDateText {
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][int]$DefaultYear
    )

    $text = ConvertTo-CompactText -Value $Value
    if ($text -match '^(?:R|令和)(\d{1,2})[./\-年](\d{1,2})[./\-月](\d{1,2})日?$') {
        $year = 2018 + [int]$Matches[1]
    }
    elseif ($text -match '^(\d{4})[./\-年](\d{1,2})[./\-月](\d{1,2})日?$') {
        $year = [int]$Matches[1]
    }
    elseif ($text -match '^(\d{4})(\d{2})(\d{2})$') {
        # 20260804 style, typed either as a number or as text.
        $year = [int]$Matches[1]
    }
    elseif ($text -match '^()(\d{1,2})[./\-月](\d{1,2})日?$') {
        $year = $DefaultYear
    }
    else {
        return $null
    }
    try {
        return [datetime]::new($year, [int]$Matches[2], [int]$Matches[3])
    }
    catch {
        return $null
    }
}

function ConvertFrom-YearMonthValue {
    param([AllowEmptyString()][string]$Value)

    $date = ConvertFrom-ExcelSerialDate -Value $Value
    if ($null -ne $date) {
        return [pscustomobject]@{ Year = $date.Year; Month = $date.Month }
    }
    $text = ConvertTo-CompactText -Value $Value
    if ($text -match '^(?:R|令和)(\d{1,2})[./\-年](\d{1,2})月?') {
        $year = 2018 + [int]$Matches[1]
    }
    elseif ($text -match '^(\d{4})[./\-年](\d{1,2})月?') {
        $year = [int]$Matches[1]
    }
    else {
        return $null
    }
    $month = [int]$Matches[2]
    if ($month -lt 1 -or $month -gt 12) {
        return $null
    }
    return [pscustomobject]@{ Year = $year; Month = $month }
}

function Read-KinmuhyoWorkbook {
    param([Parameter(Mandatory = $true)][string]$Path)

    # The whole sheet is read because the 勤務場所 dropdown list lives below the calendar (K132:K135 in the template).
    $sheet = Read-XlsxSheetValues -Path $Path -SheetNames @('勤務表')
    $cells = $sheet.Cells
    $days = [System.Collections.Generic.List[object]]::new()
    # Rows 10-40 hold one day each; column A carries the date the template calculates from A1/D1.
    for ($row = 10; $row -le 40; $row++) {
        $date = ConvertFrom-ExcelSerialDate -Value (Get-CellText -Cells $cells -Reference "A$row")
        $dayNumber = if ($null -ne $date) { $date.Day } else { $row - 9 }
        $start = Get-CellText -Cells $cells -Reference "C$row"
        $end = Get-CellText -Cells $cells -Reference "D$row"
        $days.Add([pscustomobject]@{
            Row = $row
            Day = $dayNumber
            HasAttendance = (($start -ne '' -and $start -ne '0') -or ($end -ne '' -and $end -ne '0'))
            Place = Get-CellText -Cells $cells -Reference "K$row"
        })
    }
    $name = Get-CellText -Cells $cells -Reference 'E4'
    if (-not $name) {
        $name = Get-CellText -Cells $cells -Reference 'D4'
    }
    $placeOptions = Get-XlsxListOptions -Sheet $sheet -Column 'K' -Row 10
    return [pscustomobject]@{
        SheetName = $sheet.SheetName
        Year = ConvertTo-IntOrNull -Value (Get-CellText -Cells $cells -Reference 'A1')
        Month = ConvertTo-IntOrNull -Value (Get-CellText -Cells $cells -Reference 'D1')
        Name = $name
        PlaceOptions = $placeOptions
        Days = $days.ToArray()
    }
}

function Read-KotsuhiWorkbook {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sheet = Read-XlsxSheetValues -Path $Path -SheetNames @('交通宿泊申請') -MaxRow 300
    $cells = $sheet.Cells
    $rows = [System.Collections.Generic.List[object]]::new()
    # Detail rows start at row 9 and end at the 「件数」 total row, which moves when rows are inserted.
    for ($row = 9; $row -le 300; $row++) {
        $dateText = Get-CellText -Cells $cells -Reference "C$row"
        if ((ConvertTo-CompactText -Value $dateText) -eq '件数') {
            break
        }
        $organization = Get-CellText -Cells $cells -Reference "D$row"
        $section = Get-CellText -Cells $cells -Reference "E$row"
        $kind = Get-CellText -Cells $cells -Reference "H$row"
        $amount = Get-CellText -Cells $cells -Reference "L$row"
        if ($amount -eq '0') {
            $amount = ''
        }
        if (-not ($dateText -or $organization -or $section -or $kind -or $amount)) {
            continue
        }
        $rows.Add([pscustomobject]@{
            Row = $row
            DateText = $dateText
            Organization = $organization
            Section = $section
            Way = Get-CellText -Cells $cells -Reference "G$row"
            Kind = $kind
            Amount = $amount
        })
    }
    return [pscustomobject]@{
        SheetName = $sheet.SheetName
        MonthValue = Get-CellText -Cells $cells -Reference 'H4'
        Applicant = Get-CellText -Cells $cells -Reference 'H5'
        Rows = $rows.ToArray()
    }
}
