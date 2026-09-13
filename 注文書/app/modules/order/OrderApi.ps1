Set-StrictMode -Version Latest

function Invoke-OrderGeneration {
    param([Parameter(Mandatory = $true)][object]$Data)

    $errors = @(Test-OrderData -Data $Data -RequireRecords)
    if ($errors.Count -gt 0) {
        throw ($errors -join "`n")
    }

    $requestedOutputRoot = Get-PropertyText -Object $Data -Name 'outputRoot'
    $outputRoot = if ([string]::IsNullOrWhiteSpace($requestedOutputRoot)) {
        Get-ModuleOutputPath -ModuleId 'order'
    }
    else {
        Set-ModuleOutputPath -ModuleId 'order' -OutputPath $requestedOutputRoot
    }
    $records = @($Data.PSObject.Properties['records'].Value)
    $companyCount = @($records | Group-Object { (Get-PropertyText -Object $_ -Name '宛先会社名').ToLowerInvariant() }).Count
    $publishedPath = Invoke-OutputTransaction -OutputRoot $outputRoot -ExpectedCompanyCount $companyCount -Generate {
        param($workingOutputRoot)
        Invoke-OrderGenerator -Data $Data -WorkingOutputRoot $workingOutputRoot
    }
    return [pscustomobject]@{
        log = "選択した$($records.Count)名、$($companyCount)社のExcel・PDFを作成しました。"
        outputPath = $publishedPath
    }
}
