param(
    [Parameter(Mandatory = $true)][string]$BaseDirectory,
    [Parameter(Mandatory = $true)][object]$OrderData,
    [string]$OutputDirectory
)

$root = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $BaseDirectory '成果物'
} else {
    [IO.Path]::GetFullPath($OutputDirectory)
}
$monthDirectory = Join-Path $root ('payload-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($monthDirectory)
$OrderData | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $monthDirectory 'received.json') -Encoding utf8
Write-Host "受信件数: $(@($OrderData.records).Count)"
Write-Host "全ての注文書を作成しました: $monthDirectory"
