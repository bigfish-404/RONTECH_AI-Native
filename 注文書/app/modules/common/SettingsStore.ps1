Set-StrictMode -Version Latest

function New-DefaultSettings {
    return [pscustomobject]@{
        schemaVersion = 1
        modules = [pscustomobject]@{
            order = [pscustomobject]@{ outputPath = '' }
        }
    }
}

function Read-AppSettings {
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return New-DefaultSettings
    }
    try {
        $settings = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        throw "設定ファイルを読み込めません。settings.json を確認してください: $($_.Exception.Message)"
    }
    if ($null -eq $settings.PSObject.Properties['schemaVersion'] -or [int]$settings.schemaVersion -ne 1) {
        throw '設定ファイルのバージョンに対応していません。'
    }
    return $settings
}

function Get-ModuleOutputPath {
    param([Parameter(Mandatory = $true)][string]$ModuleId)
    $settings = Read-AppSettings
    $modules = $settings.PSObject.Properties['modules']
    if ($null -eq $modules -or $null -eq $modules.Value) {
        return ''
    }
    $module = $modules.Value.PSObject.Properties[$ModuleId]
    if ($null -eq $module -or $null -eq $module.Value) {
        return ''
    }
    $property = $module.Value.PSObject.Properties['outputPath']
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }
    return ([string]$property.Value).Trim()
}

function Save-AppSettings {
    param([Parameter(Mandatory = $true)][object]$Settings)
    [void][IO.Directory]::CreateDirectory((Split-Path $settingsPath -Parent))
    $settingsDirectory = Split-Path $settingsPath -Parent
    $operationId = [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $settingsDirectory ('.settings-' + $operationId + '.tmp')
    $replaceBackupPath = Join-Path $settingsDirectory ('.settings-backup-' + $operationId + '.tmp')
    try {
        $json = ($Settings | ConvertTo-Json -Depth 8) + "`r`n"
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $settingsPath, $replaceBackupPath, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $settingsPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $replaceBackupPath -PathType Leaf) {
            Remove-Item -LiteralPath $replaceBackupPath -Force
        }
    }
}

function Set-ModuleOutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$ModuleId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$OutputPath
    )
    $trimmedPath = $OutputPath.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedPath)) {
        $fullPath = ''
    }
    else {
        if (-not [IO.Path]::IsPathRooted($trimmedPath)) {
            throw '出力先は絶対パスで入力してください。'
        }
        $fullPath = [IO.Path]::GetFullPath($trimmedPath)
    }
    $settings = Read-AppSettings
    if ($null -eq $settings.PSObject.Properties['modules']) {
        $settings | Add-Member -NotePropertyName modules -NotePropertyValue ([pscustomobject]@{})
    }
    if ($null -eq $settings.modules.PSObject.Properties[$ModuleId]) {
        $settings.modules | Add-Member -NotePropertyName $ModuleId -NotePropertyValue ([pscustomobject]@{ outputPath = $fullPath })
    }
    else {
        $settings.modules.$ModuleId.outputPath = $fullPath
    }
    Save-AppSettings -Settings $settings
    return $fullPath
}
