Option Explicit

Dim shell
Dim baseDirectory
Dim serverScript
Dim command
Dim quote

Set shell = CreateObject("WScript.Shell")
baseDirectory = shell.ExpandEnvironmentStrings("%ORDER_TOOL_BASE_DIR%")
serverScript = shell.ExpandEnvironmentStrings("%ORDER_TOOL_SERVER_SCRIPT%")
quote = Chr(34)

command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command " & quote & _
    "$p=$env:ORDER_TOOL_SERVER_SCRIPT; " & _
    "$s=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); " & _
    "& ([ScriptBlock]::Create($s)) -BaseDirectory $env:ORDER_TOOL_BASE_DIR" & quote

shell.Run command, 0, False
