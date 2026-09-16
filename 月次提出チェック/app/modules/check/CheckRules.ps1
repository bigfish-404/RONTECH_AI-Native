Set-StrictMode -Version Latest

function New-CheckCell {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'ng', 'warn', 'skip', 'none')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Text
    )
    return [ordered]@{ status = $Status; text = $Text }
}

function Format-YearMonth {
    param([int]$Year, [int]$Month)
    return "${Year}年${Month}月"
}

function Get-AttendanceCategory {
    param([Parameter(Mandatory = $true)][object]$Day)

    # office: 勤務場所 filled with anything but 在宅 / remote: 在宅
    # placeEmpty: 出勤・退勤 entered but 勤務場所 blank / off: nothing entered
    if ([string]::IsNullOrWhiteSpace($Day.Place)) {
        if ($Day.HasAttendance) {
            return 'placeEmpty'
        }
        return 'off'
    }
    if ($Day.Place -match '在宅') {
        return 'remote'
    }
    return 'office'
}

function Add-FileMonthIssue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Issues,
        [Parameter(Mandatory = $true)][object]$File,
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$Year,
        [int]$Month
    )
    if ($null -ne $File.FileYear -and ($File.FileYear -ne $Year -or $File.FileMonth -ne $Month)) {
        $Issues.Add(@{
            code = 'FILE_MONTH_MISMATCH'; severity = 'warn'; target = $Target
            file = $File.Name; actual = (Format-YearMonth -Year $File.FileYear -Month $File.FileMonth)
        })
    }
}

function Read-SubmissionWorkbook {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Issues,
        [Parameter(Mandatory = $true)][object[]]$Candidates,
        [Parameter(Mandatory = $true)][ValidateSet('kinmu', 'kotsu')][string]$Target
    )

    $prefix = $Target.ToUpperInvariant()
    $file = $Candidates[0]
    if ($Candidates.Count -gt 1) {
        $Issues.Add(@{
            code = "${prefix}_DUPLICATE"; severity = 'warn'; target = $Target
            files = @($Candidates | ForEach-Object { $_.Name }); used = $file.Name
        })
    }
    try {
        $workbook = if ($Target -eq 'kinmu') { Read-KinmuhyoWorkbook -Path $file.FullName } else { Read-KotsuhiWorkbook -Path $file.FullName }
    }
    catch {
        $Issues.Add(@{ code = "${prefix}_READ_ERROR"; severity = 'ng'; target = $Target; file = $file.Name; error = $_.Exception.Message })
        $workbook = $null
    }
    return $workbook
}

function Get-PersonCheckResult {
    param(
        [Parameter(Mandatory = $true)][object]$Person,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Files,
        [Parameter(Mandatory = $true)][int]$Year,
        [Parameter(Mandatory = $true)][int]$Month
    )

    $name = [string]$Person.氏名
    $nameKey = ConvertTo-NameKey -Name $name
    $commuterPass = [bool]$Person.定期券
    $daysInMonth = [DateTime]::DaysInMonth($Year, $Month)
    $targetLabel = Format-YearMonth -Year $Year -Month $Month
    $issues = [System.Collections.Generic.List[object]]::new()
    $cells = [ordered]@{}
    $fileNames = [ordered]@{ kinmu = ''; kotsu = '' }

    $ownFiles = @($Files | Where-Object { $_.OwnerKey -eq $nameKey })
    $kinmuFiles = @($ownFiles | Where-Object { $_.Kind -eq 'kinmu' } | Sort-Object LastWriteTime -Descending)
    $kotsuFiles = @($ownFiles | Where-Object { $_.Kind -eq 'kotsu' } | Sort-Object LastWriteTime -Descending)

    # ---- 勤務表 ----
    $kinmu = $null
    if ($kinmuFiles.Count -eq 0) {
        $issues.Add(@{ code = 'KINMU_MISSING'; severity = 'ng'; target = 'kinmu' })
        $cells.kinmuSubmit = New-CheckCell -Status 'ng' -Text '未提出'
    }
    else {
        $fileNames.kinmu = $kinmuFiles[0].Name
        $kinmu = Read-SubmissionWorkbook -Issues $issues -Candidates $kinmuFiles -Target 'kinmu'
        $cells.kinmuSubmit = if ($null -eq $kinmu) { New-CheckCell -Status 'ng' -Text '読込不可' }
            elseif ($kinmuFiles.Count -gt 1) { New-CheckCell -Status 'warn' -Text "提出済（$($kinmuFiles.Count)件）" }
            else { New-CheckCell -Status 'ok' -Text '提出済' }
        Add-FileMonthIssue -Issues $issues -File $kinmuFiles[0] -Target 'kinmu' -Year $Year -Month $Month
    }

    $categoryByDay = @{}
    $officeDays = @()
    # Day numbers from a 勤務表 of another month would point at the wrong weekdays, so dates are compared only when the month matches.
    $kinmuMonthMatches = $false
    if ($null -ne $kinmu) {
        if ($null -eq $kinmu.Year -or $null -eq $kinmu.Month) {
            $issues.Add(@{ code = 'KINMU_MONTH_UNREADABLE'; severity = 'ng'; target = 'kinmu' })
            $cells.kinmuMonth = New-CheckCell -Status 'ng' -Text '読取不可'
        }
        elseif ($kinmu.Year -ne $Year -or $kinmu.Month -ne $Month) {
            $actual = Format-YearMonth -Year $kinmu.Year -Month $kinmu.Month
            $issues.Add(@{ code = 'KINMU_MONTH_MISMATCH'; severity = 'ng'; target = 'kinmu'; actual = $actual; expected = $targetLabel })
            $cells.kinmuMonth = New-CheckCell -Status 'ng' -Text $actual
        }
        else {
            $cells.kinmuMonth = New-CheckCell -Status 'ok' -Text $targetLabel
            $kinmuMonthMatches = $true
        }
        if ($kinmu.Name -and (ConvertTo-NameKey -Name $kinmu.Name) -ne $nameKey) {
            $issues.Add(@{ code = 'NAME_MISMATCH'; severity = 'warn'; target = 'kinmu'; actual = $kinmu.Name })
        }

        # PlaceOptions is empty when the workbook has no readable dropdown list; the value check is skipped then.
        $placeOptions = @($kinmu.PlaceOptions | Where-Object { $_ })
        $invalidPlaces = [System.Collections.Generic.List[object]]::new()
        foreach ($day in $kinmu.Days) {
            if ($day.Day -lt 1 -or $day.Day -gt $daysInMonth) {
                continue
            }
            $categoryByDay[$day.Day] = Get-AttendanceCategory -Day $day
            if ($placeOptions.Count -gt 0 -and $day.Place -and $day.Place -notin $placeOptions) {
                $invalidPlaces.Add([ordered]@{ day = $day.Day; value = $day.Place })
            }
        }
        $officeDays = @($categoryByDay.Keys | Where-Object { $categoryByDay[$_] -eq 'office' } | Sort-Object)
        $placeEmptyDays = @($categoryByDay.Keys | Where-Object { $categoryByDay[$_] -eq 'placeEmpty' } | Sort-Object)
        $placeProblems = [System.Collections.Generic.List[string]]::new()
        if ($placeEmptyDays.Count -gt 0) {
            $issues.Add(@{ code = 'PLACE_EMPTY'; severity = 'ng'; target = 'kinmu'; days = $placeEmptyDays })
            $placeProblems.Add("未記入 $($placeEmptyDays.Count)日")
        }
        if ($invalidPlaces.Count -gt 0) {
            $issues.Add(@{ code = 'PLACE_INVALID'; severity = 'ng'; target = 'kinmu'; days = $invalidPlaces.ToArray(); options = $placeOptions })
            $placeProblems.Add("リスト外 $($invalidPlaces.Count)日")
        }
        $cells.place = if ($placeProblems.Count -gt 0) { New-CheckCell -Status 'ng' -Text ($placeProblems -join '・') } else { New-CheckCell -Status 'ok' -Text '記入済' }
    }
    else {
        $cells.kinmuMonth = New-CheckCell -Status 'none' -Text '—'
        $cells.place = New-CheckCell -Status 'none' -Text '—'
    }

    # ---- 交通費 ----
    $claimDays = @{}
    if ($commuterPass) {
        $cells.kotsuSubmit = New-CheckCell -Status 'skip' -Text '定期券'
        $cells.kotsuMonth = New-CheckCell -Status 'skip' -Text '—'
        $cells.dates = New-CheckCell -Status 'skip' -Text '定期券'
    }
    elseif ($kotsuFiles.Count -eq 0) {
        if ($null -ne $kinmu -and $officeDays.Count -eq 0) {
            $cells.kotsuSubmit = New-CheckCell -Status 'ok' -Text '不要（出社なし）'
            $cells.kotsuMonth = New-CheckCell -Status 'skip' -Text '—'
            $cells.dates = New-CheckCell -Status 'ok' -Text '出社 0日'
        }
        else {
            $issues.Add(@{ code = 'KOTSU_MISSING'; severity = 'ng'; target = 'kotsu' })
            $cells.kotsuSubmit = New-CheckCell -Status 'ng' -Text '未提出'
            $cells.kotsuMonth = New-CheckCell -Status 'none' -Text '—'
            $cells.dates = New-CheckCell -Status 'none' -Text '—'
        }
    }
    else {
        $fileNames.kotsu = $kotsuFiles[0].Name
        $kotsu = Read-SubmissionWorkbook -Issues $issues -Candidates $kotsuFiles -Target 'kotsu'
        Add-FileMonthIssue -Issues $issues -File $kotsuFiles[0] -Target 'kotsu' -Year $Year -Month $Month
        if ($null -eq $kotsu) {
            $cells.kotsuSubmit = New-CheckCell -Status 'ng' -Text '読込不可'
            $cells.kotsuMonth = New-CheckCell -Status 'none' -Text '—'
            $cells.dates = New-CheckCell -Status 'none' -Text '—'
        }
        else {
            $cells.kotsuSubmit = if ($kotsuFiles.Count -gt 1) { New-CheckCell -Status 'warn' -Text "提出済（$($kotsuFiles.Count)件）" } else { New-CheckCell -Status 'ok' -Text '提出済' }

            $yearMonth = ConvertFrom-YearMonthValue -Value $kotsu.MonthValue
            if (-not $kotsu.MonthValue) {
                $issues.Add(@{ code = 'KOTSU_MONTH_EMPTY'; severity = 'ng'; target = 'kotsu'; expected = $targetLabel })
                $cells.kotsuMonth = New-CheckCell -Status 'ng' -Text '未入力'
            }
            elseif ($null -eq $yearMonth) {
                $issues.Add(@{ code = 'KOTSU_MONTH_UNREADABLE'; severity = 'ng'; target = 'kotsu'; actual = $kotsu.MonthValue; expected = $targetLabel })
                $cells.kotsuMonth = New-CheckCell -Status 'ng' -Text '読取不可'
            }
            elseif ($yearMonth.Year -ne $Year -or $yearMonth.Month -ne $Month) {
                $actual = Format-YearMonth -Year $yearMonth.Year -Month $yearMonth.Month
                $issues.Add(@{ code = 'KOTSU_MONTH_MISMATCH'; severity = 'ng'; target = 'kotsu'; actual = $actual; expected = $targetLabel })
                $cells.kotsuMonth = New-CheckCell -Status 'ng' -Text $actual
            }
            else {
                $cells.kotsuMonth = New-CheckCell -Status 'ok' -Text $targetLabel
            }
            if ($kotsu.Applicant -and (ConvertTo-NameKey -Name $kotsu.Applicant) -ne $nameKey) {
                $issues.Add(@{ code = 'NAME_MISMATCH'; severity = 'warn'; target = 'kotsu'; actual = $kotsu.Applicant })
            }

            $invalidRows = [System.Collections.Generic.List[object]]::new()
            $emptyDateRows = [System.Collections.Generic.List[object]]::new()
            $outOfMonthRows = [System.Collections.Generic.List[object]]::new()
            $otherKindRows = [System.Collections.Generic.List[object]]::new()
            $commuterRowCount = 0
            foreach ($row in $kotsu.Rows) {
                $kind = ConvertTo-CompactText -Value $row.Kind
                if ($kind -eq '定期券') {
                    $commuterRowCount++
                    continue
                }
                # Only transport rows are compared; 宿泊費・会議費・他の費用 may fall on any day.
                # They are reported as reference rows so that a skipped row never looks like a missing one.
                if ($kind -and $kind -ne '交通費') {
                    $otherKindRows.Add([ordered]@{ row = $row.Row; kind = $row.Kind })
                    continue
                }
                if (-not $row.DateText) {
                    $emptyDateRows.Add($row.Row)
                    continue
                }
                $date = ConvertFrom-ExcelSerialDate -Value $row.DateText
                if ($null -eq $date) {
                    $date = ConvertFrom-JapaneseDateText -Value $row.DateText -DefaultYear $Year
                }
                if ($null -eq $date) {
                    $invalidRows.Add([ordered]@{ row = $row.Row; text = $row.DateText })
                    continue
                }
                if ($date.Year -ne $Year -or $date.Month -ne $Month) {
                    $outOfMonthRows.Add([ordered]@{ row = $row.Row; date = $date.ToString('yyyy/M/d') })
                    continue
                }
                $claimDays[$date.Day] = $true
            }
            if ($emptyDateRows.Count -gt 0) {
                $issues.Add(@{ code = 'CLAIM_DATE_EMPTY'; severity = 'ng'; target = 'kotsu'; rows = $emptyDateRows.ToArray() })
            }
            if ($invalidRows.Count -gt 0) {
                $issues.Add(@{ code = 'CLAIM_DATE_INVALID'; severity = 'ng'; target = 'kotsu'; rows = $invalidRows.ToArray() })
            }
            if ($outOfMonthRows.Count -gt 0) {
                $issues.Add(@{ code = 'CLAIM_OUT_OF_MONTH'; severity = 'ng'; target = 'kotsu'; rows = $outOfMonthRows.ToArray() })
            }
            if ($commuterRowCount -gt 0) {
                $issues.Add(@{ code = 'COMMUTER_ROW'; severity = 'warn'; target = 'kotsu'; count = $commuterRowCount })
            }
            if ($otherKindRows.Count -gt 0) {
                $issues.Add(@{ code = 'OTHER_KIND_ROWS'; severity = 'info'; target = 'kotsu'; rows = $otherKindRows.ToArray() })
            }
            # Rows the comparison could not use are named in the table cell, so 申請 0日 never looks like "nothing submitted".
            $unreadableCount = $emptyDateRows.Count + $invalidRows.Count + $outOfMonthRows.Count
            $unreadableSuffix = $(if ($unreadableCount -gt 0) { "・読めない日付 ${unreadableCount}行" } else { '' })

            $claimDayList = @($claimDays.Keys | Sort-Object)
            if ($kinmuMonthMatches) {
                # Days whose 勤務場所 is blank are reported as PLACE_EMPTY and left out of the comparison.
                $extraDays = @($claimDayList | Where-Object { $categoryByDay[$_] -notin @('office', 'placeEmpty') } | ForEach-Object {
                    [ordered]@{ day = $_; category = $(if ($categoryByDay.ContainsKey($_)) { $categoryByDay[$_] } else { 'off' }) }
                })
                $missingDays = @($officeDays | Where-Object { -not $claimDays.ContainsKey($_) })
                if ($extraDays.Count -gt 0) {
                    $issues.Add(@{ code = 'CLAIM_EXTRA'; severity = 'ng'; target = 'kotsu'; days = $extraDays })
                }
                if ($missingDays.Count -gt 0) {
                    $issues.Add(@{ code = 'CLAIM_MISSING'; severity = 'ng'; target = 'kotsu'; days = $missingDays })
                }
                $hasDateProblem = $extraDays.Count -gt 0 -or $missingDays.Count -gt 0 -or $unreadableCount -gt 0
                $cells.dates = New-CheckCell -Status $(if ($hasDateProblem) { 'ng' } else { 'ok' }) -Text "出社 $($officeDays.Count)日 / 申請 $($claimDayList.Count)日$unreadableSuffix"
            }
            else {
                $cells.dates = New-CheckCell -Status 'none' -Text $(if ($null -ne $kinmu) { '勤務表の年月違い' } else { "申請 $($claimDayList.Count)日$unreadableSuffix" })
            }
        }
    }

    $calendar = [System.Collections.Generic.List[object]]::new()
    if ($kinmuMonthMatches -or ($null -eq $kinmu -and $claimDays.Count -gt 0)) {
        for ($dayNumber = 1; $dayNumber -le $daysInMonth; $dayNumber++) {
            $category = if ($categoryByDay.ContainsKey($dayNumber)) { $categoryByDay[$dayNumber] } else { 'unknown' }
            $calendar.Add([ordered]@{ day = $dayNumber; category = $category; claimed = $claimDays.ContainsKey($dayNumber) })
        }
    }

    $severities = @($issues | ForEach-Object { $_.severity })
    $overall = if ($severities -contains 'ng') { 'ng' } elseif ($severities -contains 'warn') { 'warn' } else { 'ok' }
    return [ordered]@{
        name = $name
        commuterPass = $commuterPass
        overall = $overall
        cells = $cells
        issues = $issues.ToArray()
        files = $fileNames
        dayCounts = [ordered]@{ office = @($officeDays).Count; claim = $claimDays.Count }
        calendar = $calendar.ToArray()
    }
}
