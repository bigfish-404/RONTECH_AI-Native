Set-StrictMode -Version Latest

function Convert-ToDecimalValue {
    param([string]$Text)
    $normalized = $Text.Trim() -replace '[,￥¥]', ''
    [decimal]$value = 0
    $parsed = [decimal]::TryParse(
        $normalized,
        [Globalization.NumberStyles]::Number,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$value
    )
    if (-not $parsed) {
        return $null
    }
    return $value
}

function Convert-ToHourValue {
    param([string]$Text)
    $normalized = $Text -replace '[\s,hHｈ時間]', ''
    return Convert-ToDecimalValue -Text $normalized
}

function Get-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $safeName = $Name.Trim()
    foreach ($character in [IO.Path]::GetInvalidFileNameChars()) {
        $safeName = $safeName.Replace([string]$character, '_')
    }
    $safeName = $safeName.TrimEnd([char]'.', [char]' ')
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        throw "ファイル名またはフォルダ名に使用できる文字がありません: $Name"
    }
    if ($safeName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        $safeName = "_$safeName"
    }
    return $safeName
}

function Test-OrderData {
    param(
        [Parameter(Mandatory = $true)][object]$Data,
        [switch]$RequireRecords
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $targetMonth = Get-PropertyText -Object $Data -Name 'targetMonth'
    if ($targetMonth -notmatch '^\d{4}-(0[1-9]|1[0-2])$') {
        $errors.Add('対象年月は「2026-10」の形式で入力してください。')
    }

    $recordsProperty = $Data.PSObject.Properties['records']
    [object[]]$records = @()
    if ($null -ne $recordsProperty -and $null -ne $recordsProperty.Value) {
        [object[]]$records = @($recordsProperty.Value)
    }
    if ($RequireRecords -and $records.Count -eq 0) {
        $errors.Add('注文データが1件もありません。')
    }

    $requiredFields = @('宛先会社名', '件名', '業務内容', '工程範囲', '技術者名', '単価', '固定契約', '下限時間', '上限時間', '弊社責任者')
    $duplicateKeys = @{}
    $companyFolders = @{}
    $projectValues = @{}
    $separator = [char]31

    for ($index = 0; $index -lt $records.Count; $index++) {
        $record = $records[$index]
        $displayRow = $index + 1
        foreach ($fieldName in $requiredFields) {
            if ([string]::IsNullOrWhiteSpace((Get-PropertyText -Object $record -Name $fieldName))) {
                $errors.Add("${displayRow}行目の「$fieldName」が未入力です。")
            }
        }

        $companyName = Get-PropertyText -Object $record -Name '宛先会社名'
        $folderName = Get-PropertyText -Object $record -Name '出力フォルダ名'
        $projectName = Get-PropertyText -Object $record -Name '件名'
        $engineerName = Get-PropertyText -Object $record -Name '技術者名'
        $contractType = (Get-PropertyText -Object $record -Name '固定契約').ToUpperInvariant()

        if ($contractType -ne 'Y' -and $contractType -ne 'N') {
            $errors.Add("${displayRow}行目の「固定契約」は Y または N を入力してください。")
        }

        $priceText = Get-PropertyText -Object $record -Name '単価'
        if ($priceText -match '\s') {
            $errors.Add("${displayRow}行目の「単価」に途中の空白またはタブがあります。")
        }
        $price = Convert-ToDecimalValue -Text $priceText
        if ($null -eq $price -or $price -lt 0) {
            $errors.Add("${displayRow}行目の「単価」が正しくありません。")
        }

        $lowerHours = Convert-ToHourValue -Text (Get-PropertyText -Object $record -Name '下限時間')
        $upperHours = Convert-ToHourValue -Text (Get-PropertyText -Object $record -Name '上限時間')
        if ($null -eq $lowerHours -or $lowerHours -le 0) {
            $errors.Add("${displayRow}行目の「下限時間」が正しくありません。")
        }
        if ($null -eq $upperHours -or $upperHours -le 0) {
            $errors.Add("${displayRow}行目の「上限時間」が正しくありません。")
        }
        if ($null -ne $lowerHours -and $null -ne $upperHours -and $lowerHours -ge $upperHours) {
            $errors.Add("${displayRow}行目は下限時間を上限時間より小さくしてください。")
        }

        if (-not [string]::IsNullOrWhiteSpace($companyName) -and -not [string]::IsNullOrWhiteSpace($projectName) -and -not [string]::IsNullOrWhiteSpace($engineerName)) {
            $duplicateKey = ($companyName + $separator + $projectName + $separator + $engineerName).ToLowerInvariant()
            if ($duplicateKeys.ContainsKey($duplicateKey)) {
                $errors.Add("${displayRow}行目は$($duplicateKeys[$duplicateKey])行目と同じ会社・件名・技術者名です。")
            }
            else {
                $duplicateKeys[$duplicateKey] = $displayRow
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($companyName) -and -not [string]::IsNullOrWhiteSpace($folderName)) {
            $companyKey = $companyName.ToLowerInvariant()
            if (-not $companyFolders.ContainsKey($companyKey)) {
                $companyFolders[$companyKey] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            }
            [void]$companyFolders[$companyKey].Add($folderName)
        }

        if (-not [string]::IsNullOrWhiteSpace($companyName) -and -not [string]::IsNullOrWhiteSpace($projectName)) {
            $projectKey = ($companyName + $separator + $projectName).ToLowerInvariant()
            if (-not $projectValues.ContainsKey($projectKey)) {
                $projectValues[$projectKey] = @{
                    Company = $companyName
                    Project = $projectName
                    業務内容 = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    工程範囲 = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    弊社責任者 = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    備考 = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                }
            }
            foreach ($commonField in @('業務内容', '工程範囲', '弊社責任者', '備考')) {
                $commonValue = Get-PropertyText -Object $record -Name $commonField
                if (-not [string]::IsNullOrWhiteSpace($commonValue)) {
                    [void]$projectValues[$projectKey][$commonField].Add($commonValue)
                }
            }
        }
    }

    foreach ($companyKey in $companyFolders.Keys) {
        if ($companyFolders[$companyKey].Count -gt 1) {
            $errors.Add("同一会社の「出力フォルダ名」を統一してください。")
        }
    }

    $folderOwners = @{}
    $companyNames = @($records | ForEach-Object { Get-PropertyText -Object $_ -Name '宛先会社名' } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($companyName in $companyNames) {
        $companyKey = $companyName.ToLowerInvariant()
        $folderName = if ($companyFolders.ContainsKey($companyKey) -and $companyFolders[$companyKey].Count -eq 1) {
            [string]($companyFolders[$companyKey] | Select-Object -First 1)
        }
        else {
            $companyName
        }
        try {
            $safeFolderName = Get-SafeFileName -Name $folderName
        }
        catch {
            $errors.Add($_.Exception.Message)
            continue
        }
        $folderKey = $safeFolderName.ToLowerInvariant()
        if ($folderOwners.ContainsKey($folderKey) -and $folderOwners[$folderKey] -ne $companyName) {
            $errors.Add("異なる会社の「出力フォルダ名」が同じ名前になります: $($folderOwners[$folderKey]) / $companyName")
        }
        else {
            $folderOwners[$folderKey] = $companyName
        }
    }

    foreach ($projectKey in $projectValues.Keys) {
        foreach ($commonField in @('業務内容', '工程範囲', '弊社責任者', '備考')) {
            if ($projectValues[$projectKey][$commonField].Count -gt 1) {
                $errors.Add("同一会社・同一件名の「$commonField」を統一してください: $($projectValues[$projectKey].Company) / $($projectValues[$projectKey].Project)")
            }
        }
    }

    return @($errors)
}
