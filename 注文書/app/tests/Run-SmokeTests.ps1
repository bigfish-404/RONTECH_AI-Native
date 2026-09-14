param([string]$AppDirectory = (Split-Path $PSScriptRoot -Parent))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appPath = [IO.Path]::GetFullPath($AppDirectory)
$failures = [System.Collections.Generic.List[string]]::new()
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Write-Host '[1/6] PowerShell syntax'
Get-ChildItem -LiteralPath $appPath -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "PowerShell syntax error: $($_.FullName) / $($errors[0].Message)"
    }
}

Write-Host '[2/6] JavaScript syntax'
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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('RontechDocumentToolTests\' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    Write-Host '[3/6] Settings round trip'
    $settingsPath = Join-Path $testRoot 'config\settings.json'
    . (Join-Path $appPath 'modules\common\SettingsStore.ps1')
    $chosenOutput = Join-Path $testRoot 'chosen-output'
    [void][IO.Directory]::CreateDirectory($chosenOutput)
    [void](Set-ModuleOutputPath -ModuleId 'order' -OutputPath $chosenOutput)
    Assert-True ((Get-ModuleOutputPath -ModuleId 'order') -eq $chosenOutput) 'Output path was not persisted.'
    [void](Set-ModuleOutputPath -ModuleId 'order' -OutputPath '')
    Assert-True ((Get-ModuleOutputPath -ModuleId 'order') -eq '') 'Output path could not be cleared.'
    [void](Set-ModuleOutputPath -ModuleId 'order' -OutputPath $chosenOutput)

    Write-Host '[4/6] CSV read and atomic save'
    . (Join-Path $appPath 'modules\common\Http.ps1')
    . (Join-Path $appPath 'modules\order\OrderValidation.ps1')
    . (Join-Path $appPath 'modules\order\OrderRepository.ps1')
    $csvHeaders = @('宛先会社名','出力フォルダ名','業務内容','工程範囲','技術者名','単価','固定契約','下限時間','上限時間','弊社責任者','備考')
    $csvPath = Join-Path $testRoot 'data\order\注文データ.csv'
    $backupRoot = Join-Path $testRoot 'backup\order'
    [void][IO.Directory]::CreateDirectory((Split-Path $csvPath -Parent))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\order\minimal.csv') -Destination $csvPath
    $data = Read-OrderData
    Assert-True (@($data.records).Count -eq 1) 'Fixture record could not be read.'
    $backup = Save-OrderData -Data $data
    Assert-True (Test-Path -LiteralPath $backup -PathType Leaf) 'Atomic CSV backup was not created.'
    foreach ($savedCsv in @($csvPath, $backup)) {
        $prefix = [IO.File]::ReadAllBytes($savedCsv)
        Assert-True ($prefix.Length -ge 3 -and $prefix[0] -eq 0xEF -and $prefix[1] -eq 0xBB -and $prefix[2] -eq 0xBF) "CSV is not Excel-compatible UTF-8 BOM: $savedCsv"
    }
    $emptyData = [pscustomobject]@{ targetMonth = '2026-10'; records = @() }
    [void](Save-OrderData -Data $emptyData)
    $emptyReload = Read-OrderData
    Assert-True (@($emptyReload.records).Count -eq 0) 'An empty master CSV could not be saved and reloaded.'

    Write-Host '[5/6] Output transaction success and rollback'
    . (Join-Path $appPath 'modules\common\OutputTransaction.ps1')
    $deliveryRootRejected = $false
    try {
        [void](Assert-OutputRoot -OutputRoot (Split-Path $appPath -Parent))
    }
    catch {
        $deliveryRootRejected = $true
    }
    Assert-True $deliveryRootRejected 'Delivery root was unexpectedly accepted as an output path.'
    $successRoot = Join-Path $testRoot 'transaction-success'
    [void][IO.Directory]::CreateDirectory($successRoot)
    $published = Invoke-OutputTransaction -OutputRoot $successRoot -ExpectedCompanyCount 1 -Generate {
        param($workingRoot)
        Write-Output ''
        $month = Join-Path $workingRoot '2026年10月'
        $company = Join-Path $month 'テスト株式会社'
        [void][IO.Directory]::CreateDirectory($company)
        [IO.File]::WriteAllText((Join-Path $company 'order.xlsx'), 'xlsx')
        [IO.File]::WriteAllText((Join-Path $company 'order.pdf'), 'pdf')
        return $month
    }
    Assert-True (Test-Path -LiteralPath $published -PathType Container) 'Transaction did not publish the result.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $successRoot '.rontech-staging'))) 'Staging directory was not cleaned.'

    $failureRoot = Join-Path $testRoot 'transaction-failure'
    [void][IO.Directory]::CreateDirectory($failureRoot)
    $failedAsExpected = $false
    try {
        [void](Invoke-OutputTransaction -OutputRoot $failureRoot -ExpectedCompanyCount 1 -Generate {
            param($workingRoot)
            $month = Join-Path $workingRoot '2026年10月'
            $company = Join-Path $month 'テスト株式会社'
            [void][IO.Directory]::CreateDirectory($company)
            [IO.File]::WriteAllText((Join-Path $company 'order.xlsx'), 'xlsx')
            return $month
        })
    }
    catch {
        $failedAsExpected = $true
    }
    Assert-True $failedAsExpected 'Incomplete output was unexpectedly accepted.'
    Assert-True (@(Get-ChildItem -LiteralPath $failureRoot -Force).Count -eq 0) 'Failed transaction left output files behind.'

    Write-Host '[6/6] Generate request output path'
    . (Join-Path $appPath 'modules\order\OrderApi.ps1')
    $requestedOutput = Join-Path $testRoot 'request-output'
    [void][IO.Directory]::CreateDirectory($requestedOutput)
    $data | Add-Member -NotePropertyName outputRoot -NotePropertyValue $requestedOutput
    $script:capturedOutputRoot = ''
    function Invoke-OutputTransaction {
        param([string]$OutputRoot, [int]$ExpectedCompanyCount, [scriptblock]$Generate)
        $script:capturedOutputRoot = $OutputRoot
        return (Join-Path $OutputRoot '2026年10月')
    }
    [void](Invoke-OrderGeneration -Data $data)
    Assert-True ($script:capturedOutputRoot -eq $requestedOutput) 'Generate request output path was ignored.'
    Assert-True ((Get-ModuleOutputPath -ModuleId 'order') -eq $requestedOutput) 'Generate request output path was not persisted.'
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'All smoke tests passed.'
