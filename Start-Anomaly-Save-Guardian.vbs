' Anomaly Save Guardian - no-console launcher (recommended for normal use).
'
' Double-click this file to start the app. It launches the PowerShell UI fully
' hidden, so no PowerShell console window stays open in the background - only the
' Anomaly Save Guardian window and its system-tray icon are visible.
'
' It finds the UI script next to itself, so it works wherever you put the files,
' including paths that contain spaces. It does NOT change your system execution
' policy (the bypass applies only to this single launch).

Option Explicit

Dim fso, shell, scriptDir, uiPath, command

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

' Folder this .vbs lives in (the app folder).
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
uiPath = fso.BuildPath(scriptDir, "stalker-gamma-backup-ui.ps1")

If Not fso.FileExists(uiPath) Then
    MsgBox "Could not find:" & vbCrLf & uiPath & vbCrLf & vbCrLf & _
           "Keep Start-Anomaly-Save-Guardian.vbs in the same folder as the app files.", _
           vbExclamation, "Anomaly Save Guardian"
    WScript.Quit 1
End If

' Run the UI from the app folder so relative paths resolve correctly.
shell.CurrentDirectory = scriptDir

' -WindowStyle Hidden on PowerShell plus window style 0 here keeps everything
' off-screen; quotes guard against spaces in the path.
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & uiPath & """"

' 0 = hidden window, False = do not wait for the app to exit.
shell.Run command, 0, False

WScript.Quit 0
