Set-StrictMode -Version Latest

function Write-JobState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][string]$Phase,
        [string]$Message = ''
    )
    $state = [pscustomobject]@{
        schemaVersion = 1
        jobId = $JobId
        module = 'order'
        phase = $Phase
        message = $Message
        updatedAt = (Get-Date).ToString('o')
    }
    [IO.File]::WriteAllText($Path, (($state | ConvertTo-Json -Compress) + "`r`n"), [Text.UTF8Encoding]::new($false))
}

function Assert-OutputRoot {
    param([Parameter(Mandatory = $true)][string]$OutputRoot)
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        throw '出力先を選択してください。'
    }
    if (-not [IO.Path]::IsPathRooted($OutputRoot)) {
        throw '出力先は絶対パスで指定してください。'
    }
    $fullPath = [IO.Path]::GetFullPath($OutputRoot)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw '選択した出力先が見つかりません。もう一度選択してください。'
    }
    $deliveryRoot = [IO.Path]::GetFullPath((Split-Path $appPath -Parent))
    $deliveryPrefix = $deliveryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $outputPrefix = $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($fullPath.Equals($deliveryRoot, [StringComparison]::OrdinalIgnoreCase) -or $outputPrefix.StartsWith($deliveryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '出力先には製品フォルダの外側を選択してください。'
    }
    $probe = Join-Path $fullPath ('.rontech-write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($probe, 'test', [Text.Encoding]::ASCII)
    }
    finally {
        if (Test-Path -LiteralPath $probe -PathType Leaf) {
            Remove-Item -LiteralPath $probe -Force
        }
    }
    return $fullPath
}

function Get-VersionedOutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $true)][string]$BaseName
    )
    $candidate = Join-Path $OutputRoot $BaseName
    $version = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $OutputRoot ("${BaseName}（${version}）")
        $version++
    }
    return $candidate
}

function Assert-GeneratedFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][int]$ExpectedCompanyCount
    )
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw '生成結果のフォルダが見つかりません。'
    }
    $xlsx = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter '*.xlsx')
    $pdf = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter '*.pdf')
    if ($xlsx.Count -ne $ExpectedCompanyCount -or $pdf.Count -ne $ExpectedCompanyCount) {
        throw "生成ファイル数が一致しません。会社: $ExpectedCompanyCount / Excel: $($xlsx.Count) / PDF: $($pdf.Count)"
    }
    $empty = @($xlsx + $pdf | Where-Object Length -le 0)
    if ($empty.Count -gt 0) {
        throw "空の生成ファイルがあります: $($empty[0].FullName)"
    }
}

function Invoke-OutputTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $true)][int]$ExpectedCompanyCount,
        [Parameter(Mandatory = $true)][scriptblock]$Generate
    )
    $resolvedOutputRoot = Assert-OutputRoot -OutputRoot $OutputRoot
    $jobId = [guid]::NewGuid().ToString('N')
    $jobRoot = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'RontechDocumentTool') $jobId
    $generationRoot = Join-Path $jobRoot 'generated'
    $jobStatePath = Join-Path $jobRoot 'job.json'
    $stagingRoot = Join-Path $resolvedOutputRoot '.rontech-staging'
    $stagingJob = Join-Path $stagingRoot $jobId
    $phase = 'prepare'
    [void][IO.Directory]::CreateDirectory($generationRoot)
    try {
        Write-JobState -Path $jobStatePath -JobId $jobId -Phase $phase
        $phase = 'generate'
        Write-JobState -Path $jobStatePath -JobId $jobId -Phase $phase
        $generationOutput = @(& $Generate $generationRoot)
        $generatedDirectory = @(
            $generationOutput |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Container) } |
                Select-Object -Last 1
        )
        if ($generatedDirectory.Count -ne 1) {
            throw '生成処理から完成フォルダを取得できませんでした。'
        }
        $generatedDirectory = [string]$generatedDirectory[0]
        Assert-GeneratedFiles -Directory $generatedDirectory -ExpectedCompanyCount $ExpectedCompanyCount

        $phase = 'stage'
        Write-JobState -Path $jobStatePath -JobId $jobId -Phase $phase
        [void][IO.Directory]::CreateDirectory($stagingJob)
        $stagedDirectory = Join-Path $stagingJob ([IO.Path]::GetFileName($generatedDirectory))
        Copy-Item -LiteralPath $generatedDirectory -Destination $stagedDirectory -Recurse
        Assert-GeneratedFiles -Directory $stagedDirectory -ExpectedCompanyCount $ExpectedCompanyCount

        $phase = 'publish'
        Write-JobState -Path $jobStatePath -JobId $jobId -Phase $phase
        $finalPath = Get-VersionedOutputPath -OutputRoot $resolvedOutputRoot -BaseName ([IO.Path]::GetFileName($generatedDirectory))
        [IO.Directory]::Move($stagedDirectory, $finalPath)
        return $finalPath
    }
    catch {
        $wrapped = [InvalidOperationException]::new("注文書の出力に失敗しました（$phase）: $($_.Exception.Message)", $_.Exception)
        $wrapped.Data['Code'] = 'ORDER_OUTPUT_FAILED'
        $wrapped.Data['Stage'] = $phase
        throw $wrapped
    }
    finally {
        if (Test-Path -LiteralPath $jobRoot -PathType Container) {
            Remove-Item -LiteralPath $jobRoot -Recurse -Force
        }
        if (Test-Path -LiteralPath $stagingJob -PathType Container) {
            Remove-Item -LiteralPath $stagingJob -Recurse -Force
        }
        if ((Test-Path -LiteralPath $stagingRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $stagingRoot -Force).Count -eq 0) {
            Remove-Item -LiteralPath $stagingRoot -Force
        }
    }
}
