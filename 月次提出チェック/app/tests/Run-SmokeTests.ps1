param([string]$AppDirectory = (Split-Path $PSScriptRoot -Parent))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appPath = [IO.Path]::GetFullPath($AppDirectory)
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-True $threw $Message
}

Write-Host '[1/7] PowerShell syntax'
Get-ChildItem -LiteralPath $appPath -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "PowerShell syntax error: $($_.FullName) / $($errors[0].Message)"
    }
    $prefix = [IO.File]::ReadAllBytes($_.FullName)
    Assert-True ($prefix.Length -ge 3 -and $prefix[0] -eq 0xEF -and $prefix[1] -eq 0xBB -and $prefix[2] -eq 0xBF) "PowerShell file is not UTF-8 BOM: $($_.FullName)"
}

Write-Host '[2/7] JavaScript syntax'
$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -ne $node) {
    Get-ChildItem -LiteralPath (Join-Path $appPath 'web') -Recurse -Filter '*.js' | ForEach-Object {
        & $node.Source --check $_.FullName
        Assert-True ($LASTEXITCODE -eq 0) "JavaScript syntax error: $($_.FullName)"
    }
}
else {
    Write-Host '  Node.js is unavailable; skipped (not required at runtime).'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('RontechMonthlyCheckTests\' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $settingsPath = Join-Path $testRoot 'config\settings.json'
    $staffCsvPath = Join-Path $testRoot 'data\staff\人員リスト.csv'
    $staffBackupRoot = Join-Path $testRoot 'backup\staff'
    $logPath = Join-Path $testRoot 'logs\application.log'
    . (Join-Path $appPath 'modules\common\Http.ps1')
    . (Join-Path $appPath 'modules\common\SettingsStore.ps1')
    . (Join-Path $appPath 'modules\check\XlsxReader.ps1')
    . (Join-Path $appPath 'modules\check\WorkbookParsers.ps1')
    . (Join-Path $appPath 'modules\check\StaffRepository.ps1')
    . (Join-Path $appPath 'modules\check\SubmissionScanner.ps1')
    . (Join-Path $appPath 'modules\check\CheckRules.ps1')
    . (Join-Path $appPath 'modules\check\CheckApi.ps1')
    . (Join-Path $PSScriptRoot 'TestWorkbookFactory.ps1')

    Write-Host '[3/7] Settings round trip'
    $folder = Join-Path $testRoot 'submissions'
    [void][IO.Directory]::CreateDirectory($folder)
    Assert-True ((Get-CheckSetting -Name 'folderPath') -eq '') 'A missing settings file should read as empty.'
    Assert-True ((Set-CheckFolderPath -FolderPath "  `"$folder`"  ") -eq $folder) 'Quoted folder path was not normalized.'
    Assert-True ((Get-CheckSetting -Name 'folderPath') -eq $folder) 'Folder path was not persisted.'
    Assert-Throws { Set-CheckFolderPath -FolderPath 'relative\folder' } 'A relative folder path was accepted.'
    Set-CheckSetting -Name 'targetMonth' -Value '2026-09'
    Assert-True ((Get-CheckSetting -Name 'targetMonth') -eq '2026-09') 'Target month was not persisted.'

    Write-Host '[4/7] Staff list CSV'
    Assert-True (@(Read-StaffList).Count -eq 0) 'A missing staff CSV should read as an empty list.'
    $staffPayload = [pscustomobject]@{ staff = @(
        [pscustomobject]@{ 氏名 = '山田太郎'; 定期券 = $false }
        [pscustomobject]@{ 氏名 = '佐藤花子'; 定期券 = $false }
        [pscustomobject]@{ 氏名 = '鈴木一郎'; 定期券 = $true }
        [pscustomobject]@{ 氏名 = '高橋誠'; 定期券 = $false }
        [pscustomobject]@{ 氏名 = '田中美咲'; 定期券 = $false }
        [pscustomobject]@{ 氏名 = '小林優'; 定期券 = $false }
    ) }
    Assert-True ((Save-StaffList -Data $staffPayload) -eq '') 'The first save should not create a backup.'
    $loadedStaff = @(Read-StaffList)
    Assert-True ($loadedStaff.Count -eq 6) 'Staff list was not saved and reloaded.'
    Assert-True ($loadedStaff[2].定期券 -and -not $loadedStaff[0].定期券) 'Commuter pass flags were not preserved.'
    $prefix = [IO.File]::ReadAllBytes($staffCsvPath)
    Assert-True ($prefix[0] -eq 0xEF -and $prefix[1] -eq 0xBB -and $prefix[2] -eq 0xBF) 'Staff CSV is not Excel-compatible UTF-8 BOM.'
    $backup = Save-StaffList -Data $staffPayload
    Assert-True (Test-Path -LiteralPath $backup -PathType Leaf) 'Staff CSV backup was not created.'
    $duplicatePayload = [pscustomobject]@{ staff = @([pscustomobject]@{ 氏名 = '佐藤花子' }, [pscustomobject]@{ 氏名 = '佐藤　花子' }) }
    Assert-Throws { Save-StaffList -Data $duplicatePayload } 'Duplicate names differing only by width/space were accepted.'

    Write-Host '[5/7] Workbook reading'
    $placeValidation = @(@{ Sqref = 'K10:K40'; Formula = '$K$132:$K$135' })
    $yamadaKinmu = Join-Path $folder 'ロンテック勤務表_(2026年9月)(山田太郎).xlsm'
    New-TestWorkbook -Path $yamadaKinmu -SheetName '勤務表' -Validations $placeValidation -Phonetic @{ '山田太郎' = 'ヤマダタロウ' } `
        -Cells (New-KinmuCells -Year 2026 -Month 9 -Name '山田太郎' -WorkDays @{ 3 = '田町本社'; 4 = '在宅'; 7 = '在宅'; 10 = '田町本社' })
    $kinmu = Read-KinmuhyoWorkbook -Path $yamadaKinmu
    Assert-True ($kinmu.Name -eq '山田太郎') "Furigana leaked into the name: $($kinmu.Name)"
    Assert-True ($kinmu.Year -eq 2026 -and $kinmu.Month -eq 9) 'Year/month cells were not read.'
    Assert-True (@($kinmu.Days | Where-Object { $_.Place }).Count -eq 4) '勤務場所 days were not read.'
    Assert-True (@($kinmu.Days | Where-Object { $_.HasAttendance }).Count -eq 4) '出勤・退勤 were not read.'
    Assert-True ((@($kinmu.PlaceOptions) -join ',') -eq '客先出勤,田町本社,大阪支店,在宅') "勤務場所 dropdown list was not read: $(@($kinmu.PlaceOptions) -join ',')"
    Assert-True (@($kinmu.Days | Where-Object { $_.Day -eq 3 })[0].Place -eq '田町本社') '勤務場所 was not read.'
    $excelLock = [IO.File]::Open($yamadaKinmu, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try {
        Assert-True ((Read-KinmuhyoWorkbook -Path $yamadaKinmu).Name -eq '山田太郎') 'A workbook held open by another process could not be read.'
    }
    finally {
        $excelLock.Dispose()
    }
    # Excel keeps an empty shared string whenever a cell held an empty text; reading must not fail on it.
    $emptyStringWorkbook = Join-Path $testRoot 'reader\empty-string.xlsx'
    New-TestWorkbook -Path $emptyStringWorkbook -SheetName '勤務表' -Cells @{ A1 = 2026; D1 = 9; E4 = ''; K10 = '田町本社' }
    Assert-True ((Read-XlsxSheetValues -Path $emptyStringWorkbook -SheetNames @('勤務表')).Cells['K10'] -eq '田町本社') 'A workbook containing an empty string could not be read.'
    Assert-True ((ConvertFrom-JapaneseDateText -Value 'R8.9.10' -DefaultYear 2026) -eq [datetime]'2026-09-10') '和暦 date text was not parsed.'
    Assert-True ((ConvertFrom-JapaneseDateText -Value '９／１０' -DefaultYear 2026) -eq [datetime]'2026-09-10') 'Full-width date text was not parsed.'
    Assert-True ((ConvertFrom-JapaneseDateText -Value '20260910' -DefaultYear 2026) -eq [datetime]'2026-09-10') 'yyyymmdd date text was not parsed.'
    Assert-True ($null -eq (ConvertFrom-JapaneseDateText -Value '2026/9/31' -DefaultYear 2026)) 'An impossible date was accepted.'
    $reiwaMonth = ConvertFrom-YearMonthValue -Value '令和8年9月'
    Assert-True ($reiwaMonth.Year -eq 2026 -and $reiwaMonth.Month -eq 9) '和暦 year/month was not parsed.'
    Assert-True ($null -eq (ConvertFrom-YearMonthValue -Value '2026')) 'A bare year was read as a date serial.'

    Write-Host '[6/7] Submission check rules'
    $september = { param($day) Get-TestSerial -Year 2026 -Month 9 -Day $day }
    New-TestWorkbook -Path (Join-Path $folder 'ロンテック交通宿泊費申請書(2026年9月)(山田太郎).xlsx') -SheetName '交通宿泊申請' `
        -LeadingSheetName '記入例' -LeadingCells @{ H4 = (Get-TestSerial -Year 2024 -Month 1 -Day 1); H5 = '名前' } `
        -Cells (New-KotsuCells -MonthValue (& $september 1) -Applicant '山田 太郎' -Rows @(
            @{ Date = (& $september 3); Kind = '交通費' }
            @{ Date = (& $september 10); Kind = '交通費' }
            @{ Date = (& $september 10); Kind = '' }
            @{ Date = (& $september 12); Kind = '会議費' }
            @{ Date = '20260903'; Kind = '交通費' }
            @{ Date = '20260830'; Kind = '他の費用' }
        ))
    # 佐藤花子: 4 = attended with 勤務場所 blank, 10 = 勤務場所 outside the dropdown list (still a commuting day).
    New-TestWorkbook -Path (Join-Path $folder 'ロンテック勤務表_（2026年9月）（佐藤 花子）.xlsx') -SheetName '勤務表' -Validations $placeValidation `
        -Cells (New-KinmuCells -Year 2026 -Month 9 -Name '佐藤花子' -WorkDays @{ 3 = '客先出勤'; 4 = ''; 7 = '客先出勤'; 9 = '在宅'; 10 = '本社' })
    New-TestWorkbook -Path (Join-Path $folder 'ロンテック交通宿泊費申請書(2026年8月)(佐藤花子).xlsx') -SheetName '交通宿泊申請' `
        -Cells (New-KotsuCells -MonthValue '2026年8月' -Applicant '佐藤花子' -Rows @(
            @{ Date = (& $september 3); Kind = '交通費' }
            @{ Date = '9/9'; Kind = '交通費' }
            @{ Date = (& $september 5); Kind = '交通費' }
            @{ Date = (& $september 10); Kind = '交通費' }
            @{ Date = '9月頃'; Kind = '交通費' }
            @{ Date = ''; Kind = '交通費' }
            @{ Date = (Get-TestSerial -Year 2026 -Month 8 -Day 31); Kind = '交通費' }
        ))
    New-TestWorkbook -Path (Join-Path $folder 'ロンテック勤務表_(2026年9月)(鈴木一郎).xlsm') -SheetName '勤務表' -Validations $placeValidation `
        -Cells (New-KinmuCells -Year 2026 -Month 9 -Name '鈴木一郎' -WorkDays @{ 1 = '田町本社'; 2 = '田町本社' })
    New-TestWorkbook -Path (Join-Path $folder 'ロンテック勤務表_(2026年9月)(田中美咲).xlsm') -SheetName '勤務表' `
        -Cells (New-KinmuCells -Year 2026 -Month 9 -Name '田中美咲' -WorkDays @{ 1 = '在宅'; 2 = '在宅' })
    # 小林優: the 勤務表 is still the August one, so its days must not be compared with the September claims.
    New-TestWorkbook -Path (Join-Path $folder 'ロンテック勤務表_(2026年9月)(小林優).xlsm') -SheetName '勤務表' -Validations $placeValidation `
        -Cells (New-KinmuCells -Year 2026 -Month 8 -Name '小林優' -WorkDays @{ 3 = '田町本社' })
    New-TestWorkbook -Path (Join-Path $folder 'ロンテック交通宿泊費申請書(2026年9月)(小林優).xlsx') -SheetName '交通宿泊申請' `
        -Cells (New-KotsuCells -MonthValue (& $september 1) -Applicant '小林優' -Rows @(@{ Date = (& $september 4); Kind = '交通費' }))
    New-TestWorkbook -Path (Join-Path $folder 'ロンテック勤務表_(2026年9月)(伊藤健).xlsx') -SheetName '勤務表' `
        -Cells (New-KinmuCells -Year 2026 -Month 9 -Name '伊藤健' -WorkDays @{})
    [IO.File]::WriteAllText((Join-Path $folder '山田太郎_領収書.xlsx'), 'not a workbook')
    [IO.File]::WriteAllText((Join-Path $folder '~$ロンテック勤務表_(2026年9月)(山田太郎).xlsm'), 'lock')
    [IO.File]::WriteAllText((Join-Path $folder 'メモ.txt'), 'memo')

    $report = Invoke-SubmissionCheck -Data ([pscustomobject]@{ targetMonth = '2026-09'; folderPath = $folder })
    $reportJson = $report | ConvertTo-Json -Depth 12 -Compress
    $parsed = $reportJson | ConvertFrom-Json
    function Get-TestResult {
        param([string]$Name)
        $result = @($parsed.results | Where-Object { $_.name -eq $Name })
        Assert-True ($result.Count -eq 1) "Result for $Name is missing."
        return $result[0]
    }
    function Get-IssueCodes {
        param([object]$Result)
        return @($Result.issues | ForEach-Object { $_.code })
    }

    $yamada = Get-TestResult -Name '山田太郎'
    Assert-True ($yamada.overall -eq 'ok') "山田太郎 should be OK: $(Get-IssueCodes -Result $yamada)"
    Assert-True ($yamada.cells.dates.text -eq '出社 2日 / 申請 2日') "Duplicate claim rows were not merged: $($yamada.cells.dates.text)"
    Assert-True ((Get-IssueCodes -Result $yamada) -contains 'OTHER_KIND_ROWS') 'Rows of other kinds were not reported as reference information.'

    $sato = Get-TestResult -Name '佐藤花子'
    $satoCodes = Get-IssueCodes -Result $sato
    Assert-True ($sato.overall -eq 'ng') '佐藤花子 should be NG.'
    foreach ($code in @('PLACE_EMPTY', 'PLACE_INVALID', 'KOTSU_MONTH_MISMATCH', 'CLAIM_EXTRA', 'CLAIM_MISSING', 'CLAIM_DATE_EMPTY', 'CLAIM_DATE_INVALID', 'CLAIM_OUT_OF_MONTH', 'FILE_MONTH_MISMATCH')) {
        Assert-True ($satoCodes -contains $code) "佐藤花子 is missing issue $code. Found: $($satoCodes -join ', ')"
    }
    Assert-True ((@(@($sato.issues | Where-Object { $_.code -eq 'PLACE_EMPTY' })[0].days) -join ',') -eq '4') 'Blank 勤務場所 days are wrong.'
    $invalidPlace = @(@($sato.issues | Where-Object { $_.code -eq 'PLACE_INVALID' })[0].days)
    Assert-True ($invalidPlace.Count -eq 1 -and $invalidPlace[0].day -eq 10 -and $invalidPlace[0].value -eq '本社') 'A 勤務場所 outside the dropdown list was not reported.'
    Assert-True ($sato.cells.place.text -eq '未記入 1日・リスト外 1日') "勤務場所 cell text is wrong: $($sato.cells.place.text)"
    Assert-True ($sato.dayCounts.office -eq 3 -and $sato.dayCounts.claim -eq 4) 'Day counts are wrong.'
    Assert-True ($sato.cells.dates.text -eq '出社 3日 / 申請 4日・読めない日付 3行') "Unreadable rows are not named in the dates cell: $($sato.cells.dates.text)"
    $extra = @(@($sato.issues | Where-Object { $_.code -eq 'CLAIM_EXTRA' })[0].days)
    Assert-True ((@($extra | ForEach-Object { $_.day }) -join ',') -eq '5,9') 'Extra claim days are wrong.'
    Assert-True ((@($extra | ForEach-Object { $_.category }) -join ',') -eq 'off,remote') 'Extra claim categories are wrong.'
    Assert-True ((@(@($sato.issues | Where-Object { $_.code -eq 'CLAIM_MISSING' })[0].days) -join ',') -eq '7') 'Missing claim days are wrong.'
    Assert-True ($reportJson -match '"days":\[7\]') 'A single-day list was not serialized as a JSON array.'

    $suzuki = Get-TestResult -Name '鈴木一郎'
    Assert-True ($suzuki.overall -eq 'ok' -and $suzuki.cells.kotsuSubmit.status -eq 'skip') '定期券 holder should skip 交通費.'
    $takahashi = Get-TestResult -Name '高橋誠'
    Assert-True ((Get-IssueCodes -Result $takahashi) -contains 'KINMU_MISSING' -and (Get-IssueCodes -Result $takahashi) -contains 'KOTSU_MISSING') 'Missing submissions were not reported.'
    $tanaka = Get-TestResult -Name '田中美咲'
    Assert-True ($tanaka.overall -eq 'ok' -and $tanaka.cells.kotsuSubmit.text -eq '不要（出社なし）') 'A remote-only month should not require 交通費.'

    $unmatched = @($parsed.unmatchedFiles)
    Assert-True (@($unmatched | Where-Object { $_.name -like '*伊藤健*' -and $_.reason -eq 'notInList' }).Count -eq 1) 'A file outside the list was not reported.'
    Assert-True (@($unmatched | Where-Object { $_.name -eq '山田太郎_領収書.xlsx' -and $_.reason -eq 'unknownKind' }).Count -eq 1) 'A file of unknown kind was not reported.'
    $kobayashi = Get-TestResult -Name '小林優'
    $kobayashiCodes = Get-IssueCodes -Result $kobayashi
    Assert-True ($kobayashiCodes -contains 'KINMU_MONTH_MISMATCH') '小林優 should get a 勤務表 month mismatch.'
    Assert-True ($kobayashiCodes -notcontains 'CLAIM_EXTRA' -and $kobayashiCodes -notcontains 'CLAIM_MISSING') 'Dates were compared against a 勤務表 of another month.'
    Assert-True ($kobayashi.cells.dates.status -eq 'none' -and $kobayashi.cells.dates.text -eq '勤務表の年月違い') "Dates cell is wrong for a month mismatch: $($kobayashi.cells.dates.text)"
    Assert-True (@($kobayashi.calendar).Count -eq 0) 'A calendar was built from a 勤務表 of another month.'
    Assert-True ($parsed.fileCount -eq 10) "Lock files and non-Excel files should be ignored. Counted: $($parsed.fileCount)"

    Write-Host '[7/7] Message template'
    if ($null -ne $node) {
        $reportPath = Join-Path $testRoot 'report.json'
        [IO.File]::WriteAllText($reportPath, $reportJson, [Text.UTF8Encoding]::new($false))
        & $node.Source (Join-Path $PSScriptRoot 'Test-CheckFormat.js') (Join-Path $appPath 'web\check\check-format.js') $reportPath
        Assert-True ($LASTEXITCODE -eq 0) 'Message template test failed.'
    }
    else {
        Write-Host '  Node.js is unavailable; skipped.'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'All smoke tests passed.'
