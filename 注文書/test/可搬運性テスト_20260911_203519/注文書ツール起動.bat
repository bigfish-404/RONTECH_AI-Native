:: コンソールをUTF-8に
chcp 65001 >nul
:: SQL*Plusのクライアント文字セットをUTF-8に
set NLS_LANG=Japanese_Japan.AL32UTF8
setlocal EnableDelayedExpansion
@echo off

set "BASE_DIR=%~dp0"
set "SERVER_SCRIPT=%BASE_DIR%注文書Webサーバー.ps1"

if not exist "%SERVER_SCRIPT%" (
    echo エラー: 注文書Webサーバー.ps1 が見つかりません。
    pause
    exit /b 1
)

start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$p=$env:SERVER_SCRIPT; $s=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); & ([ScriptBlock]::Create($s)) -BaseDirectory $env:BASE_DIR"
exit /b 0
