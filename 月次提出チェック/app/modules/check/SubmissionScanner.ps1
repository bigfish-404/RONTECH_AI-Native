Set-StrictMode -Version Latest

function Get-SubmissionKind {
    param([Parameter(Mandatory = $true)][string]$FileName)

    if ($FileName -match '勤務表') {
        return 'kinmu'
    }
    if ($FileName -match '交通') {
        return 'kotsu'
    }
    return ''
}

function Get-FileNameOwner {
    param([AllowEmptyString()][string]$NormalizedBaseName)

    # Take the last bracket group that is neither a copy number like (2) nor a month like (2026年9月).
    $groups = [regex]::Matches($NormalizedBaseName, '\(([^()]*)\)')
    for ($index = $groups.Count - 1; $index -ge 0; $index--) {
        $value = $groups[$index].Groups[1].Value.Trim()
        if ($value -and $value -notmatch '^\d+$' -and $value -notmatch '^\d{4}年\d{1,2}月$') {
            return $value
        }
    }
    return ''
}

function Get-SubmissionFiles {
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    foreach ($file in Get-ChildItem -LiteralPath $FolderPath -File) {
        if ($file.Name.StartsWith('~$')) {
            continue
        }
        if ($file.Extension.ToLowerInvariant() -notin @('.xlsx', '.xlsm', '.xls')) {
            continue
        }
        $baseName = [IO.Path]::GetFileNameWithoutExtension($file.Name).Normalize([Text.NormalizationForm]::FormKC)
        $matchKey = ([regex]::Replace($baseName, '\s+', '')).ToLowerInvariant()
        $fileYear = $null
        $fileMonth = $null
        if ($matchKey -match '(\d{4})年(\d{1,2})月') {
            $fileYear = [int]$Matches[1]
            $fileMonth = [int]$Matches[2]
        }
        [pscustomobject]@{
            Name = $file.Name
            FullName = $file.FullName
            Kind = Get-SubmissionKind -FileName $baseName
            MatchKey = $matchKey
            Owner = Get-FileNameOwner -NormalizedBaseName $baseName
            FileYear = $fileYear
            FileMonth = $fileMonth
            LastWriteTime = $file.LastWriteTime
            OwnerKey = ''
        }
    }
}

function Resolve-SubmissionOwners {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Files,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$NameKeys
    )

    # The list drives the search: a file belongs to the listed full name its file name contains.
    foreach ($file in $Files) {
        foreach ($nameKey in $NameKeys) {
            if ($nameKey -and $file.MatchKey.Contains($nameKey)) {
                $file.OwnerKey = $nameKey
                break
            }
        }
    }
}
