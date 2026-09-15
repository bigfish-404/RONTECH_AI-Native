Set-StrictMode -Version Latest

function Get-CheckInitialData {
    $targetMonth = Get-CheckSetting -Name 'targetMonth'
    if ($targetMonth -notmatch '^\d{4}-\d{2}$') {
        $targetMonth = (Get-Date).ToString('yyyy-MM')
    }
    return [ordered]@{
        staff = @(Read-StaffList)
        folderPath = Get-CheckSetting -Name 'folderPath'
        targetMonth = $targetMonth
    }
}

function Invoke-SubmissionCheck {
    param([Parameter(Mandatory = $true)][object]$Data)

    $targetMonth = Get-PropertyText -Object $Data -Name 'targetMonth'
    if ($targetMonth -notmatch '^(\d{4})-(\d{2})$' -or [int]$Matches[2] -lt 1 -or [int]$Matches[2] -gt 12) {
        throw '対象年月を選択してください。'
    }
    $year = [int]$Matches[1]
    $month = [int]$Matches[2]

    $requestedFolder = Get-PropertyText -Object $Data -Name 'folderPath'
    if (-not $requestedFolder) {
        throw 'チェックするフォルダを指定してください。'
    }
    $folderPath = Set-CheckFolderPath -FolderPath $requestedFolder
    if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
        throw "フォルダが見つかりません。`n$folderPath"
    }
    Set-CheckSetting -Name 'targetMonth' -Value $targetMonth

    $staff = @(Read-StaffList)
    if ($staff.Count -eq 0) {
        throw '人員リストが空です。先に人員を追加して保存してください。'
    }
    $files = @(Get-SubmissionFiles -FolderPath $folderPath)
    $nameKeys = [string[]]@($staff | ForEach-Object { ConvertTo-NameKey -Name $_.氏名 })
    Resolve-SubmissionOwners -Files $files -NameKeys $nameKeys

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($person in $staff) {
        $results.Add((Get-PersonCheckResult -Person $person -Files $files -Year $year -Month $month))
    }

    $unmatchedFiles = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        if (-not $file.OwnerKey) {
            $unmatchedFiles.Add([ordered]@{ name = $file.Name; owner = $file.Owner; reason = 'notInList' })
        }
        elseif (-not $file.Kind) {
            $unmatchedFiles.Add([ordered]@{ name = $file.Name; owner = $file.Owner; reason = 'unknownKind' })
        }
    }

    Write-ServerLog -Message "チェック実行: $targetMonth / $($staff.Count)名 / ファイル$($files.Count)件 / $folderPath"
    return [ordered]@{
        targetMonth = $targetMonth
        folderPath = $folderPath
        checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        fileCount = $files.Count
        results = $results.ToArray()
        unmatchedFiles = $unmatchedFiles.ToArray()
    }
}
