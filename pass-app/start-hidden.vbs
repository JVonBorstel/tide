' Starts the Chef server with no window (a visible console can be closed by accident, which stops the server). Waits for it, so the
' scheduled task Kitchen-Pass stays "running" while the server is up and its restart-on-failure setting still works.
Set sh = CreateObject("WScript.Shell")
here = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
WScript.Quit sh.Run("""C:\Program Files\nodejs\node.exe"" """ & here & "\server.mjs""", 0, True)
