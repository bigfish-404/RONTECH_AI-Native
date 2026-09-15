Set-StrictMode -Version Latest

function New-DefaultSettings {
    return [pscustomobject]@{
        schemaVersion = 1
        check = [pscustomobject]@{ folderPath = ''; targetMonth = '' }
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

function Save-AppSettings {
    param([Parameter(Mandatory = $true)][object]$Settings)

    $settingsDirectory = Split-Path $settingsPath -Parent
    [void][IO.Directory]::CreateDirectory($settingsDirectory)
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
        foreach ($leftover in @($temporaryPath, $replaceBackupPath)) {
            if (Test-Path -LiteralPath $leftover -PathType Leaf) {
                Remove-Item -LiteralPath $leftover -Force
            }
        }
    }
}

function Get-CheckSetting {
    param([Parameter(Mandatory = $true)][string]$Name)

    $settings = Read-AppSettings
    $section = $settings.PSObject.Properties['check']
    if ($null -eq $section -or $null -eq $section.Value) {
        return ''
    }
    $property = $section.Value.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }
    return ([string]$property.Value).Trim()
}

function Set-CheckSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $settings = Read-AppSettings
    if ($null -eq $settings.PSObject.Properties['check'] -or $null -eq $settings.check) {
        $settings | Add-Member -NotePropertyName check -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($null -eq $settings.check.PSObject.Properties[$Name]) {
        $settings.check | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $settings.check.$Name = $Value
    }
    Save-AppSettings -Settings $settings
}

function Set-CheckFolderPath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$FolderPath)

    $trimmedPath = $FolderPath.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($trimmedPath)) {
        $fullPath = ''
    }
    else {
        if (-not [IO.Path]::IsPathRooted($trimmedPath)) {
            throw 'フォルダは絶対パスで入力してください。'
        }
        $fullPath = [IO.Path]::GetFullPath($trimmedPath)
    }
    Set-CheckSetting -Name 'folderPath' -Value $fullPath
    return $fullPath
}
