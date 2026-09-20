Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "C:\Users\ivanm\OneDrive\Desktop\money-monitor"
WshShell.Run "Rscript run.R", 0, False