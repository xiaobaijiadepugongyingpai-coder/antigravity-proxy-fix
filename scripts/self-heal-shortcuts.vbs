' Self-heal wrapper for Antigravity proxy shortcuts.
'
' Antigravity gets updated by Squirrel/Electron, which recreates the
' Start Menu shortcut and silently reverts it to the raw exe. This
' wrapper runs the PowerShell self-heal script with no visible window.
'
' Install: copy this file into
'   %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\
' so it runs once per logon. It is a no-op when nothing needs fixing.
'
' NOTE: pure ASCII on purpose - see self-heal-shortcuts.ps1.

Dim sh, fso, script
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

script = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\.agy-shim\self-heal-shortcuts.ps1"

If fso.FileExists(script) Then
    sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
End If
