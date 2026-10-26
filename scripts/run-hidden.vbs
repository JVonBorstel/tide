' Runs a program with no window at all and returns ITS exit code, so a scheduled task's Last Run Result is the program's own
' (kitchen/watch.ps1 reads it). Run it as: wscript.exe //B //NoLogo run-hidden.vbs "<program>" [arguments...]
' wscript is a GUI program (no console of its own) and Run(..., 0, True) starts the program hidden and waits for it, so nothing flashes.
' A program that cannot start (missing, moved by an update: 0x80070002) returns that error code, never 0. //B keeps errors silent
' (no dialog on a desktop nobody is watching).
Set sh = CreateObject("WScript.Shell")
cmd = ""
For Each a In WScript.Arguments
    If InStr(a, " ") > 0 Or a = "" Then a = """" & a & """"
    cmd = cmd & a & " "
Next
If cmd = "" Then WScript.Quit 2
On Error Resume Next
rc = sh.Run(Trim(cmd), 0, True)
If Err.Number <> 0 Then WScript.Quit Err.Number
WScript.Quit rc
