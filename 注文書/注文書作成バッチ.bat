:: コンソールをUTF-8に
chcp 65001
:: SQL*Plusのクライアント文字セットをUTF-8に
set NLS_LANG=Japanese_Japan.AL32UTF8
setlocal EnableDelayedExpansion
@echo off

set "BASE_DIR=%~dp0"
set "LAUNCHER_FILE=%BASE_DIR%注文書ツール起動.bat"

if not exist "%LAUNCHER_FILE%" (
    echo エラー: 注文書ツール起動.bat が見つかりません。
    pause
    exit /b 1
)

echo 注文書は画面で技術者を選択して作成します。
call "%LAUNCHER_FILE%"
exit /b !ERRORLEVEL!
