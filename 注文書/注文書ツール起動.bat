:: コンソールをUTF-8に
chcp 65001 >nul
:: SQL*Plusのクライアント文字セットをUTF-8に
set NLS_LANG=Japanese_Japan.AL32UTF8
setlocal EnableDelayedExpansion
@echo off

set "ORDER_TOOL_BASE_DIR=%~dp0"
set "ORDER_TOOL_SERVER_SCRIPT=%ORDER_TOOL_BASE_DIR%注文書Webサーバー.ps1"
set "HIDDEN_LAUNCHER=%ORDER_TOOL_BASE_DIR%注文書ツール非表示起動.vbs"

if not exist "%ORDER_TOOL_SERVER_SCRIPT%" (
    echo エラー: 注文書Webサーバー.ps1 が見つかりません。
    pause
    exit /b 1
)

if not exist "%HIDDEN_LAUNCHER%" (
    echo エラー: 注文書ツール非表示起動.vbs が見つかりません。
    pause
    exit /b 1
)

wscript.exe //B //NoLogo "%HIDDEN_LAUNCHER%"
exit /b 0
