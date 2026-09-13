Set-StrictMode -Version Latest

function Invoke-OrderGenerator {
    param(
        [Parameter(Mandatory = $true)][object]$Data,
        [Parameter(Mandatory = $true)][string]$WorkingOutputRoot
    )
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "統合テンプレートが見つかりません: $templatePath"
    }
    return Invoke-OrderWorkbookGeneration -AppDirectory $appPath -OrderData $Data -WorkingOutputRoot $WorkingOutputRoot -TemplatePath $templatePath
}
