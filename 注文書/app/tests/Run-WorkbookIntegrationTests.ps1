param([string]$AppDirectory = (Split-Path $PSScriptRoot -Parent))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appPath = [IO.Path]::GetFullPath($AppDirectory)
$templatePath = Join-Path $appPath 'templates\order\注文書テンプレート_統合.xlsx'
. (Join-Path $appPath 'modules\order\OrderWorkbook.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestRecord {
    param(
        [string]$Company,
        [string]$Subject,
        [string]$BusinessContent,
        [string]$Engineer,
        [string]$Fixed = 'N'
    )
    return [pscustomobject][ordered]@{
        宛先会社名 = $Company
        出力フォルダ名 = ''
        件名 = $Subject
        業務内容 = $BusinessContent
        工程範囲 = '設計・開発・テスト'
        技術者名 = $Engineer
        単価 = '500000'
        固定契約 = $Fixed
        下限時間 = '140'
        上限時間 = '180'
        弊社責任者 = '試験責任者'
        備考 = ''
    }
}

function Invoke-TestGeneration {
    param([string]$Name, [object[]]$Records, [int]$ExpectedCompanies)
    $caseRoot = Join-Path $script:testRoot $Name
    [void][IO.Directory]::CreateDirectory($caseRoot)
    $data = [pscustomobject]@{ targetMonth = '2026-10'; records = $Records }
    $generationOutput = @(Invoke-OrderWorkbookGeneration -AppDirectory $appPath -OrderData $data -WorkingOutputRoot $caseRoot -TemplatePath $templatePath)
    $generatedDirectories = @(
        $generationOutput |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Container) } |
            Select-Object -Last 1
    )
    Assert-True ($generatedDirectories.Count -eq 1) "${Name}: Generated month directory was not returned."
    $monthDirectory = [string]$generatedDirectories[0]
    $xlsxFiles = @(Get-ChildItem -LiteralPath $monthDirectory -Recurse -File -Filter '*.xlsx')
    $pdfFiles = @(Get-ChildItem -LiteralPath $monthDirectory -Recurse -File -Filter '*.pdf')
    Assert-True ($xlsxFiles.Count -eq $ExpectedCompanies) "${Name}: Excel file count mismatch."
    Assert-True ($pdfFiles.Count -eq $ExpectedCompanies) "${Name}: PDF file count mismatch."
    foreach ($pdfFile in $pdfFiles) {
        Assert-True ($pdfFile.Directory.Name -eq $pdfFile.BaseName) "${Name}: PDF is not inside its own named folder."
        Assert-True ($pdfFile.Directory.Parent.FullName -eq (Split-Path ($xlsxFiles | Where-Object BaseName -eq $pdfFile.BaseName | Select-Object -First 1).FullName -Parent)) "${Name}: Excel/PDF company folder mismatch."
    }
    return [pscustomobject]@{ MonthDirectory = $monthDirectory; Excel = $xlsxFiles; Pdf = $pdfFiles }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('RontechWorkbookTests\' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    Write-Host '[1/4] Single selection'
    [void](Invoke-TestGeneration -Name 'single' -Records @(
        (New-TestRecord -Company '単一選択株式会社' -Subject '件名A' -BusinessContent '業務内容A' -Engineer '技術者A')
    ) -ExpectedCompanies 1)

    Write-Host '[2/4] Multiple selection'
    [void](Invoke-TestGeneration -Name 'multiple' -Records @(
        (New-TestRecord -Company '複数選択株式会社' -Subject '件名B' -BusinessContent '業務内容B' -Engineer '技術者B1'),
        (New-TestRecord -Company '複数選択株式会社' -Subject '件名B' -BusinessContent '業務内容B' -Engineer '技術者B2' -Fixed 'Y')
    ) -ExpectedCompanies 1)

    Write-Host '[3/4] Select all, mixed contracts, and multiple pages'
    $allRecords = [System.Collections.Generic.List[object]]::new()
    for ($index = 1; $index -le 8; $index++) {
        $fixed = if ($index % 2 -eq 0) { 'Y' } else { 'N' }
        $allRecords.Add((New-TestRecord -Company '全選択株式会社' -Subject '分離された件名' -BusinessContent '分離された業務内容' -Engineer "技術者C$index" -Fixed $fixed))
    }
    $allRecords.Add((New-TestRecord -Company '全選択株式会社' -Subject '別件名' -BusinessContent '別業務内容' -Engineer '技術者D'))
    $allRecords.Add((New-TestRecord -Company '第二株式会社' -Subject '第二件名' -BusinessContent '第二業務内容' -Engineer '技術者E' -Fixed 'Y'))
    $allResult = Invoke-TestGeneration -Name 'all' -Records @($allRecords) -ExpectedCompanies 2

    Write-Host '[4/4] Workbook fields, fonts, and atomic page breaks'
    $targetWorkbookPath = ($allResult.Excel | Where-Object Name -Like '全選択株式会社*').FullName
    Assert-True (-not [string]::IsNullOrWhiteSpace($targetWorkbookPath)) 'Workbook for detailed inspection was not found.'
    $excel = $null
    $workbook = $null
    $worksheet = $null
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $workbook = $excel.Workbooks.Open($targetWorkbookPath, 0, $true)
        Assert-True ($workbook.Worksheets.Count -eq 2) 'Subjects were not separated into two worksheets.'
        $worksheet = $workbook.Worksheets.Item('分離された件名')
        Assert-True (([string]$worksheet.Range('A6').Value2) -match '分離された件名') 'The subject was not written to A6.'
        Assert-True (([string]$worksheet.Range('C18').Value2) -eq '分離された業務内容') 'The business content was not written to C18.'
        Assert-True ([string]::IsNullOrWhiteSpace([string]$worksheet.PageSetup.PrintTitleRows)) 'Print title rows still repeat on later pages.'
        Assert-True ([double]$worksheet.Range('A17:I21').Font.Size -eq 10) 'Detail body font is not 10pt.'
        Assert-True ([double]$worksheet.Range('J22:Q53').Font.Size -eq 10) 'Engineer body font is not 10pt.'

        $blocks = [System.Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt 8; $index++) {
            $start = 22 + (4 * $index)
            $end = if (($index + 1) % 2 -eq 0) { $start + 1 } else { $start + 3 }
            $blocks.Add([pscustomobject]@{ Start = $start; End = $end })
            Assert-True (([string]$worksheet.Range("A$start").Value2) -eq '技術者') "Engineer label is incorrect at row $start."
        }
        $breakRows = @(Get-HorizontalPageBreakRows -Worksheet $worksheet)
        Assert-True ($breakRows.Count -gt 0) 'The multi-page case did not create a page break.'
        foreach ($block in $blocks) {
            $split = @($breakRows | Where-Object { $_ -gt $block.Start -and $_ -le $block.End })
            Assert-True ($split.Count -eq 0) "An engineer block was split across pages: $($block.Start)-$($block.End)."
        }
    }
    finally {
        if ($null -ne $workbook) { $workbook.Close($false) }
        Release-ComObject -Object $worksheet
        Release-ComObject -Object $workbook
        if ($null -ne $excel) { $excel.Quit() }
        Release-ComObject -Object $excel
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'All workbook integration tests passed.'
