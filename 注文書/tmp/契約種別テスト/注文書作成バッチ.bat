:: コンソールをUTF-8に
chcp 65001
:: SQL*Plusのクライアント文字セットをUTF-8に
set NLS_LANG=Japanese_Japan.AL32UTF8
setlocal EnableDelayedExpansion
@echo off

set "BASE_DIR=%~dp0"
set "SCRIPT_FILE=%BASE_DIR%注文書作成.ps1"

if not exist "%SCRIPT_FILE%" (
    echo エラー: 注文書作成.ps1 が見つかりません。
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:SCRIPT_FILE; $s=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); & ([ScriptBlock]::Create($s)) -BaseDirectory $env:BASE_DIR"
set "EXIT_CODE=!ERRORLEVEL!"

if not "!EXIT_CODE!"=="0" (
    echo.
    echo 注文書の作成に失敗しました。
    pause
    exit /b !EXIT_CODE!
)

echo.
echo 注文書の作成が完了しました。
pause
exit /b 0
